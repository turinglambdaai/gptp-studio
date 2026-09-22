#lang racket/base

;; HTTP API for the frontend. One define-api-routes block generates the
;; Racket procedures (unit-testable), the route table and the JS client
;; (/glaze/api.js: apiBootstrap(), apiEngineStart({...}), ...).
;;
;; Live data (curves, packets, logs, state changes) streams over the SSE bus
;; (/glaze/events); these endpoints are for commands and backfill.

(require racket/file
         racket/format
         racket/hash
         racket/list
         racket/path
         racket/string
         glaze
         "state.rkt"
         "i18n.rkt"
         "gate.rkt"
         "../engine/config.rkt"
         "../engine/detect.rkt"
         "../engine/qualification.rkt"
         "../engine/supervisor.rkt"
         "../engine/ptp4l.rkt"
         "../proto/decode.rkt"
         "../capture/pcap-io.rkt"
         "../capture/store.rkt"
         "../capture/manager.rkt"
         "../data/preset.rkt"
         "../data/series.rkt"
         "../data/logstore.rkt"
         "../support/diagnostics.rkt"
         "../support/platform-fingerprint.rkt")

(provide api-routes engine-start bootstrap)

(define (apply-tier-capacity!)
  (packet-store-set-capacity! app-packets (if (gate-pro?) 50000 2000)))

(define current-params-box (box (default-params-for-role 'listener)))
(define verify-box (box (hasheq)))

(define (current-params) (unbox current-params-box))
(define (set-current-params! p) (set-box! current-params-box p))

(define-api-routes api-routes
  ;; ---- bootstrap -----------------------------------------------------------
  [(GET "api/bootstrap")
   (bootstrap)
   (begin
     (gate-init!)
     (apply-tier-capacity!)
     (define lang (settings-ref 'language))
     (hasheq 'version app-version
             'platform (platform-name)
             'host (collect-platform-fingerprint)
             'gate (gate-info)
             'i18n (i18n-dict lang)
             'language lang
             'settings (hasheq 'capture-iface (settings-ref 'capture-iface)
                               'offset-warn-us (settings-ref 'offset-warn-us))
             'nics (detect-interfaces)
             'engine (sup-status app-supervisor)
             'capture (cm-status app-capture)
             'params (params->jsexpr (current-params))
             'conf (params->conf (current-params) #:role (role-name (sup-status-app-role)))))]

  ;; ---- settings -----------------------------------------------------------
  [(POST "api/settings")
   (set-settings [language string? ""] [offset-warn-us exact-integer? -1])
   (let ((result ""))
     (when (and (string? language) (> (string-length language) 0))
       (settings-set! 'language language)
       (set! result "language"))
     (when (>= offset-warn-us 1)
       (settings-set! 'offset-warn-us offset-warn-us)
       (sup-set-alarm-threshold! app-supervisor (* offset-warn-us 1000))
       (set! result (string-append result " offset-warn")))
     (hasheq 'ok #t 'applied (string-trim result)))]

  [(GET "api/i18n")
   (i18n)
   (i18n-dict (settings-ref 'language))]

  ;; ---- nics / qualification ----------------------------------------------
  [(GET "api/nics")
   (nics)
   (hasheq 'list (detect-interfaces))]

  [(POST "api/qualification")
   (qualification [iface string? ""] [role string? "listener"] [reference string? "system"])
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (define nics (detect-interfaces))
     (hasheq 'ok #t
             'qualification (current-qualification iface role reference nics)))]

  [(POST "api/diagnostics/export")
   (diagnostics-export [iface string? ""] [role string? "listener"] [reference string? "system"])
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (define path
       (save-file-dialog #:title "导出 gPTP Studio 诊断快照"
                         #:default-name "gptp-studio-diagnostics.json"
                         #:filters '(("JSON" "*.json"))))
     (cond
       [(not path) (hasheq 'ok #f 'cancelled #t)]
       [else
        (define nics (detect-interfaces))
        (define qualification (current-qualification iface role reference nics))
        (define snapshot
          (make-diagnostic-snapshot
           #:version app-version
           #:platform (platform-name)
           #:host (collect-platform-fingerprint)
           #:nics nics
           #:qualification qualification
           #:engine (sup-status app-supervisor)
           #:capture (cm-status app-capture)
           #:params (params->jsexpr (current-params))
           #:conf (params->conf (current-params) #:role role)
           #:logs (log-snapshot app-logs #:limit 500)
           #:redact-network? #t))
        (write-diagnostic-snapshot! path snapshot)
        (hasheq 'ok #t
                'path (path->string path)
                'redacted #t
                'qualification qualification)]))]

  ;; ---- engine -------------------------------------------------------------
  [(POST "api/engine/start")
   (engine-start [role string?] [mode string?] [iface string? ""])
   (define role* (string->symbol role))
   (define mode* (string->symbol mode))
   (define iface* (if (= (string-length iface) 0) #f iface))
   (cond
     [(not (member role* '(grandmaster slave listener)))
      (hasheq 'ok #f 'error "未知角色")]
     [(not (member mode* '(real sim)))
      (hasheq 'ok #f 'error "未知运行方式")]
     [(and (eq? mode* 'real) (not (eq? role* 'listener)) (not (gate-pro?)))
      (hasheq 'ok #f 'need_pro #t 'error (gate-check 'engine))]
     [else
      (define-values (ok? err)
        (sup-start app-supervisor role* iface* (current-params) mode*))
      (if ok?
          (hasheq 'ok #t 'status (sup-status app-supervisor))
          (hasheq 'ok #f 'error (or err "启动失败")))])]

  [(POST "api/engine/stop")
   (engine-stop)
   (begin
     (sup-stop app-supervisor)
     (hasheq 'ok #t 'status (sup-status app-supervisor)))]

  [(POST "api/engine/check")
   (engine-check)
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (hasheq 'ok #t 'blocks (sup-check-offsets app-supervisor)))]

  [(POST "api/engine/reference")
   (engine-reference [source string?])
   (define ref (string->symbol source))
   (cond
     [(not (memq ref '(system none)))
      (hasheq 'ok #f 'error "未知参考源")]
     [else
      (sup-set-reference app-supervisor ref)
      (hasheq 'ok #t 'status (sup-status app-supervisor))])]

  ;; ---- params & conf preview ---------------------------------------------
  [(POST "api/params/merge")
   (merge-params [domain exact-integer? -999] [priority1 exact-integer? -999]
                 [priority2 exact-integer? -999]
                 [log_announce_interval exact-integer? -999]
                 [log_sync_interval exact-integer? -999]
                 [network_transport string? ""]
                 [delay_mechanism string? ""]
                 [transport_specific exact-integer? -999]
                 [ptp_dst_mac string? ""] [p2p_dst_mac string? ""]
                 [gm_capable exact-integer? -999] [slave_only exact-integer? -999]
                 [assume_two_step exact-integer? -999]
                 [path_trace_enabled exact-integer? -999]
                 [follow_up_info exact-integer? -999]
                 [clock_class exact-integer? -999])
   (define body
     (for/hasheq ([k (in-list '(domain priority1 priority2 log_announce_interval
                                log_sync_interval network_transport delay_mechanism
                                transport_specific ptp_dst_mac p2p_dst_mac
                                gm_capable slave_only assume_two_step
                                path_trace_enabled follow_up_info clock_class))]
                  [v (in-list (list domain priority1 priority2 log_announce_interval
                                    log_sync_interval network_transport delay_mechanism
                                    transport_specific ptp_dst_mac p2p_dst_mac
                                    gm_capable slave_only assume_two_step
                                    path_trace_enabled follow_up_info clock_class))])
       (values k v)))
   (define p (update-params-from-json (current-params) body))
   (set-current-params! p)
   (define errs (validate-params p))
   (hasheq 'ok (null? errs)
           'errors errs
           'params (params->jsexpr p)
           'conf (params->conf p #:role (role-name (sup-status-app-role))))]

  [(GET "api/conf")
   (conf-preview)
   (hasheq 'conf (params->conf (current-params) #:role (role-name (sup-status-app-role))))]

  ;; ---- capture ------------------------------------------------------------
  [(POST "api/capture/start")
   (capture-start [iface string?])
   (settings-set! 'capture-iface iface)
   (define-values (ok? err) (cm-start app-capture iface))
   (if ok?
       (hasheq 'ok #t 'status (cm-status app-capture))
       (hasheq 'ok #f 'error err))]

  [(POST "api/capture/stop")
   (capture-stop)
   (begin
     (cm-stop app-capture)
     (hasheq 'ok #t 'status (cm-status app-capture)))]

  ;; ---- packets ------------------------------------------------------------
  [(GET "api/packets")
   (packets)
   (hasheq 'list (packet-store-snapshot app-packets 200)
           'stored (packet-store-count app-packets)
           'total (let-values (((_c total) (packet-store-stats app-packets))) total))]

  [(GET "api/packets/:n")
   (packets-n n)
   (hasheq 'list (packet-store-snapshot app-packets n)
           'stored (packet-store-count app-packets)
           'total (let-values (((_c total) (packet-store-stats app-packets))) total))]

  [(POST "api/packets/clear")
   (packets-clear)
   (begin
     (packet-store-clear! app-packets)
     (bus-broadcast! app-bus 'packets-cleared (hasheq))
     (hasheq 'ok #t))]

  ;; ---- pcap / pcapng ------------------------------------------------------
  [(POST "api/pcap/import")
   (pcap-import)
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (define path (pick-file #:title "导入抓包文件"
                             #:filters '(("pcap 文件" "*.pcap" "*.pcapng"))))
     (cond
       [(not path) (hasheq 'ok #f 'cancelled #t)]
       [else
        (define-values (frames linktype) (read-capture-file path))
        (packet-store-clear! app-packets)
        (define decoded
          (for/list ([f (in-list frames)])
            (capture-file-frame->packet f path)))
        (for ([d (in-list (reverse decoded))])
          (packet-store-push! app-packets d))
        (log-add! app-logs 'capture 'info
                  (format "导入 ~a：~a 帧（链路层 ~a），其中 PTP 帧 ~a"
                          (path->string path) (length frames) linktype
                          (count (lambda (d) (hash-ref d 'is_ptp #f)) decoded)))
        (hasheq 'ok #t 'count (length frames))]))]

  [(POST "api/pcap/export")
   (pcap-export)
   (define gate (gate-check 'export))
   (cond
     [(not (eq? gate #t))
      (hasheq 'ok #f 'need_pro #t 'error gate)]
     [else
      (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
        (define path (save-file-dialog #:title "导出 pcap"
                                       #:default-name "gptp-studio-capture.pcap"
                                       #:filters '(("pcap 文件" "*.pcap"))))
        (cond
          [(not path) (hasheq 'ok #f 'cancelled #t)]
          [else
           (define frames
             (reverse
              (for/list ([f (in-list (packet-store-snapshot app-packets 999999))])
                (packet->capture-file-frame f))))
           (write-capture-file path frames)
           (hasheq 'ok #t 'count (length frames) 'path (path->string path))]))])]

  ;; ---- series backfill ----------------------------------------------------
  [(GET "api/series")
   (series)
   (hasheq 'offset (series->points app-offset-series 1200)
           'delay (series->points app-delay-series 1200))]

  ;; ---- logs ---------------------------------------------------------------
  [(GET "api/logs")
   (logs)
   (hasheq 'list (log-snapshot app-logs #:limit 400))]

  [(POST "api/logs/export")
   (logs-export)
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (define path (save-file-dialog #:title "导出日志"
                                    #:default-name "gptp-studio.log"
                                    #:filters '(("日志" "*.log" "*.txt"))))
     (if (not path)
         (hasheq 'ok #f 'cancelled #t)
         (begin
           (log-export! app-logs path)
           (hasheq 'ok #t 'path (path->string path)))))]

  ;; ---- presets ------------------------------------------------------------
  [(GET "api/presets")
   (presets)
   (hasheq 'list (preset-list))]

  [(POST "api/presets/save")
   (presets-save [name string?] [role string?] [iface string? ""])
   (preset-save! name role iface (current-params))
   (hasheq 'ok #t 'list (preset-list))]

  [(POST "api/presets/apply")
   (presets-apply [name string?])
   (define p (preset-ref name))
   (cond
     [(not p) (hasheq 'ok #f 'error "预设不存在")]
     [else
      (define role (hash-ref p 'role "listener"))
      (define params (preset->params p))
      (set-current-params! params)
      (hasheq 'ok #t
              'role role
              'iface (hash-ref p 'iface "")
              'params (params->jsexpr params)
              'conf (params->conf params #:role role))])]

  [(POST "api/presets/delete")
   (presets-delete [name string?])
   (preset-delete! name)
   (hasheq 'ok #t 'list (preset-list))]

  ;; ---- license ------------------------------------------------------------
  [(POST "api/license/trial")
   (license-trial)
   (gate-trial-start!)
   (apply-tier-capacity!)
   (hasheq 'ok #t 'gate (gate-info))]

  [(POST "api/license/activate")
   (license-activate)
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (define path (pick-file #:title "选择许可证文件"
                             #:filters '(("许可证" "*.license" "*.lic"))))
     (cond
       [(not path) (hasheq 'ok #f 'cancelled #t)]
       [else
        (define-values (ok? msg) (gate-activate! path))
        (when ok? (apply-tier-capacity!))
        (hasheq 'ok ok? 'message msg 'gate (gate-info))]))]

  [(POST "api/license/deactivate")
   (license-deactivate)
   (gate-deactivate!)
   (apply-tier-capacity!)
   (hasheq 'ok #t 'gate (gate-info))])

;; Current application role as stored in the supervisor status hash.
(define (sup-status-app-role)
  (string->symbol (hash-ref (sup-status app-supervisor) 'role "listener")))

(define (role-name r)
  (if (symbol? r) (symbol->string r) r))
