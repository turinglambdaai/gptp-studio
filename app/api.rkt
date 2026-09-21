#lang racket/base

;; HTTP API for the frontend. One define-api-routes block generates the
;; Racket procedures (unit-testable), the route table and the JS client
;; (/glaze/api.js: apiBootstrap(), apiEngineStart({...}), ...).
;;
;; Live data (curves, packets, logs, state changes) streams over the SSE bus
;; (/glaze/events); these endpoints are for commands and backfill.

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         glaze
         "state.rkt"
         "i18n.rkt"
         "gate.rkt"
         "../engine/config.rkt"
         "../engine/detect.rkt"
         "../engine/supervisor.rkt"
         "../engine/ptp4l.rkt"
         "../proto/decode.rkt"
         "../capture/pcap-io.rkt"
         "../capture/store.rkt"
         "../capture/manager.rkt"
         "../data/preset.rkt"
         "../data/series.rkt"
         "../data/logstore.rkt")

(provide api-routes engine-start bootstrap)

;; tier-dependent packet store capacity
(define (apply-tier-capacity!)
  (packet-store-set-capacity! app-packets (if (gate-pro?) 50000 2000)))

(define current-params-box (box (default-params-for-role 'listener)))
(define verify-box (box (hasheq)))  ; latest in-page verification snapshot

(define (current-params) (unbox current-params-box))
(define (set-current-params! p) (set-box! current-params-box p))

(define-api-routes api-routes
  ;; ---- bootstrap: everything the UI needs on load -------------------------
  [(GET "api/bootstrap")
   (bootstrap)
   (begin
     (gate-init!)
     (apply-tier-capacity!)
     (define lang (settings-ref 'language))
     (hasheq 'version app-version
             'platform (platform-name)
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

  ;; ---- nics ---------------------------------------------------------------
  [(GET "api/nics")
   (nics)
   (hasheq 'list (detect-interfaces))]

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
   (begin (sup-stop app-supervisor) (hasheq 'ok #t 'status (sup-status app-supervisor)))]

  [(POST "api/engine/check")
   (engine-check)
   (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
     (hasheq 'ok #t 'blocks (sup-check-offsets app-supervisor)))]

  ;; Reference selection is now real backend state. For a real GrandMaster,
  ;; `system` causes supervisor startup to launch phc2sys alongside ptp4l;
  ;; `none` intentionally leaves the PHC without a Studio-managed reference.
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
   (if ok? (hasheq 'ok #t) (hasheq 'ok #f 'error err))]

  [(POST "api/capture/stop")
   (capture-stop)
   (begin (cm-stop app-capture) (hasheq 'ok #t))]

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
   (begin (packet-store-clear! app-packets)
          (bus-broadcast! app-bus 'packets-cleared (hasheq))
          (hasheq 'ok #t))]

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
            (decode-frame (list-ref f 3)
                          #:ts (list-ref f 0)
                          #:iface "offline"
                          #:source (path->string path))))
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
     [(not (eq? gate #t)) (hasheq 'ok #f 'need_pro #t 'error gate)]
     [else
      (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
        (define path (save-file-dialog #:title "导出 pcap"
                                       #:default-name "gptp-studio-capture.pcap"
                                       #:filters '(("pcap 文件" "*.pcap"))))
        (cond
          [(not path) (hasheq 'ok #f 'cancelled #t)]
          [else
           (define frames
             (reverse (for/list ([f (in-list (packet-store-snapshot app-packets 999999))])
                        (list (or (hash-ref f 'ts 0) 0)
                              (hash-ref f 'length 0)
                              (hash-ref f 'length 0)
                              (jsexpr-hex->bytes f)))))
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
           (display-to-file (log->text (log-snapshot app-logs #:limit 100000)) path
                            #:mode 'text #:exists 'replace)
           (hasheq 'ok #t))))]

  ;; ---- presets ------------------------------------------------------------
  [(GET "api/presets")
   (presets)
   (hasheq 'names (preset-names)
           'list (for/list ([n (in-list (preset-names))])
                   (define p (preset-load n))
                   (if p p (hasheq 'name n))))]

  [(POST "api/preset/save")
   (preset-save-route [name string?] [role string?] [iface string? ""])
   (cond
     [(= (string-length name) 0) (hasheq 'ok #f 'error "预设名不能为空")]
     [else
      (preset-save name (string->symbol role)
                   (current-params)
                   (if (= (string-length iface) 0) #f iface))
      (hasheq 'ok #t)])]

  [(POST "api/preset/apply")
   (preset-apply [name string?])
   (define p (preset-load name))
   (cond
     [(not p) (hasheq 'ok #f 'error "预设不存在")]
     [else
      (set-current-params! (hash-ref p 'params))
      (hasheq 'ok #t 'role (hash-ref p 'role) 'iface (hash-ref p 'iface)
              'params (params->jsexpr (hash-ref p 'params))
              'conf (params->conf (hash-ref p 'params) #:role (hash-ref p 'role)))])]

  [(DELETE "api/preset/:name")
   (preset-delete-route name)
   (hasheq 'ok (preset-delete name))]

  ;; ---- license ------------------------------------------------------------
  [(POST "api/license/trial")
   (license-trial)
   (begin (gate-trial-start!) (hasheq 'ok #t 'gate (gate-info)))]

  [(POST "api/license/activate")
   (license-activate [path string? ""])
   (define target
     (if (> (string-length path) 0)
         path
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (pick-file #:title "选择许可证文件"
                      #:filters '(("许可证" "*.lic" "*.license"))))))
   (cond
     [(not target) (hasheq 'ok #f 'cancelled #t)]
     [else
      (define-values (ok? msg) (gate-activate! target))
      (hasheq 'ok ok? (if ok? 'subject 'error) msg)])]

  [(POST "api/license/deactivate")
   (license-deactivate)
   (begin (gate-deactivate!) (hasheq 'ok #t 'gate (gate-info)))]

  [(GET "api/license")
   (license-status)
   (gate-info)]

  ;; ---- dev / verification --------------------------------------------------
  [(POST "api/dev/shot")
   (dev-shot)
   (define wv (unbox app-wv-box))
   (cond
     [(not wv) (hasheq 'ok #f 'error "no window")]
     [else
      (define path (build-path (app-dir) "shot.png"))
      (define shot (webview-capture! wv path))
      (hasheq 'ok (and shot #t) 'path (path->string path))])]

  [(POST "api/dev/verify")
   (dev-verify [payload string? "DEFAULT-UNTOUCHED"])
   (begin (set-box! verify-box (hasheq 'payload payload)) (hasheq 'ok #t))]
  [(GET "api/dev/verify")
   (dev-verify-read)
   (unbox verify-box)]
  [(GET "api/dev/status")
   (dev-status)
   (define wv (unbox app-wv-box))
   (hasheq 'title (and wv (webview-title wv))
           'url (and wv (webview-url wv)))]

  [(POST "api/dev/focus")
   (dev-focus)
   (define wv (unbox app-wv-box))
   (if wv (begin (webview-focus! wv) (hasheq 'ok #t)) (hasheq 'ok #f))]

  [(POST "api/dev/nav")
   (dev-nav [url string?])
   (define wv (unbox app-wv-box))
   (if wv (begin (webview-navigate wv url) (hasheq 'ok #t)) (hasheq 'ok #f))]

  [(POST "api/dev/quit")
   (dev-quit)
   (begin (thread (lambda () (sleep 0.3) (exit 0))) (hasheq 'ok #t))]

  ;; ---- misc ---------------------------------------------------------------
  [(POST "api/series/reset")
   (series-reset)
   (begin (series-clear! app-offset-series)
          (series-clear! app-delay-series)
          (hasheq 'ok #t))]

  [(POST "api/notify")
   (do-notify [title string?] [body string? ""])
   (begin (thread (lambda () (notify! title body)))
          (hasheq 'ok #t))])

;; ---- helpers ----------------------------------------------------------------

(define (sup-status-app-role)
  (define r (hash-ref (sup-status app-supervisor) 'role 'listener))
  r)

(define (sup-set-alarm-threshold! sup ns)
  (set-box! (supervisor-state sup)
            (hash-set (unbox (supervisor-state sup)) 'offset-warn-ns ns)))

(define (series->points s max-points)
  (for/list ([pt (in-list (series-snapshot s max-points))])
    (list (car pt) (cdr pt))))

;; Export re-encodes from the raw hex carried by every decoded frame.
(define (jsexpr-hex->bytes f)
  (define hex (hash-ref f 'raw_hex #f))
  (if hex
      (apply bytes (for/list ([i (in-range 0 (string-length hex) 2)])
                     (string->number (substring hex i (+ i 2)) 16)))
      (make-bytes (max 60 (hash-ref f 'length 60)) 0)))
