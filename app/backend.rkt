#lang racket/base

;; gPTP Studio backend — Rivet typed surface.
;;
;; This is the RVT1 boundary that replaced the Glaze HTTP/SSE API: typed
;; RPCs for commands and pulls, typed events for the live stream. Policy
;; stays in the engine modules (supervisor, capture, qualification, gate);
;; this file declares the contract and converts between engine hashes and
;; typed records.
;;
;; Conventions:
;; - File dialogs are host-owned. Export/import RPCs take an absolute path
;;   the native side chose and return counts; nothing here opens a dialog.
;; - Deep protocol trees (PTP header/body/TLVs, params jsexprs, i18n
;;   dictionaries, qualification sentence lists) travel as Any leaves on a
;;   typed spine — the open tree is the honest shape for protocol detail.
;; - Live curves flow through rivet/chart batches (docs/chart-series.md in
;;   the Rivet repo); the window RPC serves initial paint and gap recovery.

(require json
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         rivet/backend
         rivet/chart
         "state.rkt"
         "bus.rkt"
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
         "../support/doctor.rkt"
         "../support/engineering-report.rkt"
         "../support/platform-fingerprint.rkt"
         "../support/updates.rkt"
         "../support/updater.rkt"
         "../support/wireshark.rkt")

(provide start)

;; ---- types ----------------------------------------------------------------

(define-enum EngineRole (grandmaster slave listener boundary))
(define-enum EngineMode (real sim))
(define-enum ReferenceSource (system none))

(define-record TimestampInfo ([seconds : Int64] [nanoseconds : Int64] [source : String]))

(define-record ProcessStatus ([name : String] [running : Bool]))

(define-record EngineStatus
  ([mode : String]
   [role : String]
   [iface : (Optional String)]
   [ifaces : (List String)]
   [reference : String]
   [reference_status : String]
   [launch_mode : (Optional String)]
   [last_failure : (Optional String)]
   [port_state : Any]
   [port_states : Any]
   [gm_id : Any]
   [offset_ns : Any]
   [delay_ns : Any]
   [freq_ppb : Any]
   [uptime_ms : (Optional Int64)]
   [faults : Any]
   [processes : (List ProcessStatus)]))

(define-record EngineStartResult
  ([ok : Bool]
   [need_pro : Bool]
   [error : (Optional String)]
   [status : (Optional EngineStatus)]))

(define-record CaptureStatus
  ([running : Bool]
   [iface : (Optional String)]
   [timestamp_source : (Optional String)]
   [timestamp_precision : (Optional String)]))

(define-record NicInfo
  ([name : String]
   [description : String]
   [detail : Any]))

(define-record PacketRow
  ([ts : TimestampInfo]
   [frame_no : Int64]
   [iface : String]
   [source : String]
   [mac_src : (Optional String)]
   [mac_dst : (Optional String)]
   [ethertype_hex : String]
   [length : Int64]
   [raw_hex : String]
   [ok : Bool]
   [is_ptp : Bool]
   [transport : (Optional String)]
   [summary : String]
   [error : (Optional String)]
   [ptp : Any]))

(define-record PacketPage
  ([rows : (List PacketRow)]
   [stored : Int64]
   [total : Int64]))

(define-record ChartBatchEnvelope ([series : String] [batch : Bytes]))

(define-record SeriesWindow
  ([series : String]
   [watermark : Int64]
   [samples : Bytes]))

(define-record LogRow
  ([ts_ms : Int64]
   [source : String]
   [level : String]
   [message : String]))

(define-record AlarmEvent
  ([kind : String]
   [value : Int64]
   [threshold : Int64]
   [message : String]))

(define-record GateInfo
  ([tier : String]
   [pro : Bool]
   [trial_days : Int64]
   [detail : Any]))

(define-record PresetEntry
  ([name : String]
   [role : String]
   [iface : (Optional String)]
   [params : Any]))

(define-record GmSettings ([settings : Any]))

(define-record Bootstrap
  ([version : String]
   [platform : String]
   [language : String]
   [gate : GateInfo]
   [i18n : Any]
   [nics : (List NicInfo)]
   [engine : EngineStatus]
   [capture : CaptureStatus]
   [offset_warn_us : Int64]
   [capture_iface : (Optional String)]
   [params : Any]
   [conf : String]))

(define-record ActionResult
  ([ok : Bool]
   [need_pro : Bool]
   [error : (Optional String)]
   [info : Any]))

;; Headless support report (the --doctor / --doctor-json product surface):
;; the host prints it to stdout without opening the window.
(define-record DoctorReport
  ([json : String]
   [text : String]))

;; Online update surface (docs/update-contract.md; the rivet/distribution
;; family pattern): check-updates verifies the signed feed and applies
;; rivet's selection policy, start-download stages the chosen artifact on a
;; watched worker thread, update-state reports the flow phase, apply-update
;; hands a staged artifact to its install shape (deb: pkexec consent;
;; tarball: in-place payload swap). The 4-hour silent-check throttle is
;; host-owned (the host's stamp file), so the backend stays stateless.
(define-record UpdateCheck
  ([status : String]
   [message : (Optional String)]
   [current_version : String]
   [available_version : (Optional String)]
   [url : (Optional String)]))

(define-record UpdateState
  ([state : String]
   [percent : Int64]
   [error : (Optional String)]
   [staged_path : (Optional String)]
   [install_command : (Optional String)]))

;; ---- conversion helpers ------------------------------------------------------

(define (symbol->string* v) (if (symbol? v) (symbol->string v) (~a v)))

(define (optional-string v)
  (cond
    [(not v) (void)]
    [(string? v) v]
    [else (~a v)]))

(define (exact-or-false v)
  (cond
    [(exact-integer? v) v]
    [(and (real? v) (= v v)) (inexact->exact (floor v))]  ; (= v v) drops NaN
    [else (void)]))

(define (optional-int v)
  (define n (exact-or-false v))
  (if (integer? n) n (void)))

;; RVT1 Any values are recursive Lists over the protocol primitives; Racket
;; hashes, symbols, vectors, and inexact numbers are not wire values.  Keep the
;; application's naturally hash-shaped data, but normalize every open Any leaf
;; at this boundary.  Hashes use a deterministic list of [key value] entries so
;; native clients can still render and inspect the full tree.
(define (any->wire value)
  (cond
    [(or (void? value) (boolean? value) (string? value) (bytes? value)
         (exact-integer? value))
     value]
    [(symbol? value) (symbol->string value)]
    [(hash? value)
     (for/list ([key (in-list (sort (hash-keys value) string<? #:key ~a))])
       (list (~a key) (any->wire (hash-ref value key))))]
    [(vector? value)
     (for/list ([item (in-vector value)]) (any->wire item))]
    [(list? value) (map any->wire value)]
    [(real? value)
     (define normalized (exact-or-false value))
     (if (integer? normalized) normalized (void))]
    [else (~a value)]))

(define (timestamp-info->record ts)
  (TimestampInfo
   (optional-int (hash-ref ts 'seconds 0))
   (optional-int (hash-ref ts 'nanoseconds 0))
   (symbol->string* (hash-ref ts 'source "unknown"))))

(define (packet->record row)
  (define ts (hash-ref row 'ts #f))
  (PacketRow
   (if (hash? ts) (timestamp-info->record ts) (TimestampInfo 0 0 "unknown"))
   (optional-int (hash-ref row 'frame_no 0))
   (symbol->string* (hash-ref row 'iface "?"))
   (symbol->string* (hash-ref row 'source "?"))
   (optional-string (hash-ref row 'mac_src #f))
   (optional-string (hash-ref row 'mac_dst #f))
   (symbol->string* (hash-ref row 'ethertype_hex "?"))
   (optional-int (hash-ref row 'length 0))
   (symbol->string* (hash-ref row 'raw_hex ""))
   (and (hash-ref row 'ok #f) #t)
   (and (hash-ref row 'is_ptp #f) #t)
   (optional-string (hash-ref row 'transport #f))
   (with-handlers ([exn:fail? (lambda (_) "")])
     (frame-summary row))
   (optional-string (hash-ref row 'error #f))
   (any->wire (hash-ref row 'ptp (void)))))

(define (sup-status->record status)
  (EngineStatus
   (symbol->string* (hash-ref status 'mode "idle"))
   (symbol->string* (hash-ref status 'role "listener"))
   (optional-string (hash-ref status 'iface #f))
   (for/list ([i (in-list (hash-ref status 'ifaces '()))]) (~a i))
   (symbol->string* (hash-ref status 'reference "system"))
   (symbol->string* (hash-ref status 'reference_status "idle"))
   (optional-string (hash-ref status 'launch_mode #f))
   (optional-string (hash-ref status 'last_failure #f))
   (any->wire (hash-ref status 'port_state (void)))
   (any->wire (hash-ref status 'port_states (void)))
   (any->wire (hash-ref status 'gm_id (void)))
   (any->wire (hash-ref status 'offset_ns (void)))
   (any->wire (hash-ref status 'delay_ns (void)))
   (any->wire (hash-ref status 'freq_ppb (void)))
   (optional-int (hash-ref status 'uptime_ms #f))
   (any->wire (hash-ref status 'faults (void)))
   (for/list ([entry (in-list (hash-ref status 'processes '()))])
     (ProcessStatus (symbol->string* (hash-ref entry 'name "?"))
                    (and (hash-ref entry 'running #f) #t)))))

(define (cm-status->record status)
  (CaptureStatus
   (and (hash-ref status 'running #f) #t)
   (optional-string (hash-ref status 'iface #f))
   (optional-string (hash-ref status 'timestamp_source #f))
   (optional-string (hash-ref status 'timestamp_precision #f))))

(define (nic->record nic)
  ;; detect-interfaces entries: hasheq with name/description plus open detail
  (NicInfo (symbol->string* (hash-ref nic 'name "?"))
           (symbol->string* (hash-ref nic 'description ""))
           (any->wire nic)))

(define (gate-info->record info)
  (GateInfo (symbol->string* (hash-ref info 'tier "free"))
            (and (hash-ref info 'pro #f) #t)
            (optional-int (hash-ref info 'trial_days 0))
            (any->wire (hash-ref info 'detail (void)))))

(define (current-engine-status) (sup-status->record (sup-status app-supervisor)))

(define (apply-tier-capacity!)
  (packet-store-set-capacity! app-packets (if (gate-pro?) 50000 2000)))

(define (sup-set-alarm-threshold! sup ns)
  (set-box! (supervisor-state sup)
            (hash-set (unbox (supervisor-state sup)) 'offset-warn-ns ns)))

(define (sup-status-app-role)
  (define role (hash-ref (sup-status app-supervisor) 'role "listener"))
  (if (symbol? role) role (string->symbol role)))

(define (capture-file-frame-meta f)
  (and (>= (length f) 5)
       (hash? (list-ref f 4))
       (list-ref f 4)))

;; Promote the exact pcap/pcapng time metadata into the packet object carried
;; to the store. `ts` remains the display-compatible float; sec+nsec is the
;; authoritative timestamp representation.
(define (capture-file-frame->packet f path)
  (define packet
    (decode-frame (list-ref f 3)
                  #:ts (list-ref f 0)
                  #:iface "offline"
                  #:source (path->string path)))
  (define meta (capture-file-frame-meta f))
  (if (not meta)
      packet
      (hash-set* packet
                 'ts_sec (hash-ref meta 'ts_sec #f)
                 'ts_nsec (hash-ref meta 'ts_nsec #f)
                 'timestamp_source "pcap-file"
                 'timestamp_precision (hash-ref meta 'timestamp_precision "unknown")
                 'timestamp_resolution_num (hash-ref meta 'timestamp_resolution_num #f)
                 'timestamp_resolution_den (hash-ref meta 'timestamp_resolution_den #f)
                 'capture_interface_id (hash-ref meta 'interface_id #f)
                 'capture_linktype (hash-ref meta 'linktype #f))))

(define (jsexpr-hex->bytes f)
  (define hex (hash-ref f 'raw_hex #f))
  (if hex
      (apply bytes
             (for/list ([i (in-range 0 (string-length hex) 2)])
               (string->number (substring hex i (+ i 2)) 16)))
      #""))

(define (open-retained-in-wireshark)
  (define frames
    (reverse
     (for/list ([f (in-list (packet-store-snapshot app-packets 999999))])
       (packet->capture-file-frame f))))
  (cond
    [(null? frames)
     (fail-action "packet store is empty; nothing to open")]
    [else
     (define path (wireshark-temp-pcap-path))
     (write-capture-file path frames)
     (define result (launch-wireshark-file! path))
     (log-add! app-logs 'app 'info
               (format "Wireshark opened retained packets: ~a frames -> ~a"
                       (length frames) (hash-ref result 'path)))
     (ok-action (hasheq 'count (length frames) 'path (hash-ref result 'path)))]))

(define (packet->capture-file-frame f)
  (define base
    (list (or (hash-ref f 'ts 0) 0)
          (hash-ref f 'length 0)
          (hash-ref f 'length 0)
          (jsexpr-hex->bytes f)))
  (define sec (hash-ref f 'ts_sec #f))
  (define nsec (hash-ref f 'ts_nsec #f))
  (if (and (exact-integer? sec) (exact-integer? nsec))
      (append base
              (list
               (hasheq 'ts_sec sec
                       'ts_nsec nsec
                       'timestamp_precision (hash-ref f 'timestamp_precision "unknown")
                       'timestamp_resolution_num (hash-ref f 'timestamp_resolution_num #f)
                       'timestamp_resolution_den (hash-ref f 'timestamp_resolution_den #f)
                       'interface_id (hash-ref f 'capture_interface_id 0)
                       'linktype (hash-ref f 'capture_linktype 1))))
      base))

(define (ok-action [info (void)]) (ActionResult #t #f (void) (any->wire info)))

(define (deny-pro message) (ActionResult #f #t message (void)))

(define (fail-action message) (ActionResult #f #f message (void)))

;; ---- live event forwarding ---------------------------------------------------

(define forwarder-installed? (box #f))

(define (series-window-batch s series-id)
  (define chart (series-chart s))
  (SeriesWindow series-id
                (chart-series-appended chart)
                (chart-batch-encode
                 (for/list ([sample (in-list (chart-series-window chart))]) sample)
                 0)))

(define (forward-engine-events!)
  (unless (unbox forwarder-installed?)
    (set-box! forwarder-installed? #t)
    (define (handle name data)
      (with-handlers ([exn:fail? (lambda (e) (void))])
        (case name
          [(state-changed) (engine-state (current-engine-status))]
          [(capture-state) (capture-state-changed (cm-status->record data))]
          [(capture-stopped) (capture-state-changed (cm-status->record (cm-status app-capture)))]
          [(packets)
           (define rows (for/list ([row (in-list (hash-ref data 'packets '()))])
                          (packet->record row)))
           (unless (null? rows) (packets-appended rows))]
          [(packets-cleared) (packets-cleared #t)]
          [(alarm)
           (alarm-event
            (AlarmEvent (symbol->string* (hash-ref data 'kind "offset"))
                        (optional-int (hash-ref data 'value 0))
                        (optional-int (hash-ref data 'threshold 0))
                        (symbol->string* (hash-ref data 'message ""))))]
          [(series)
           ;; The real-engine monitor path pushes curves through the bus;
           ;; route both engine paths through the chart rings.
           (define t (hash-ref data 't 0))
           (define off (hash-ref data 'offset_ns #f))
           (define delay (hash-ref data 'delay_ns #f))
           (when off (series-push! app-offset-series t off))
           (when delay (series-push! app-delay-series t delay))]
          [(backend-error)
           (backend-error (symbol->string* (hash-ref data 'message (hash-ref data 'error ""))))]
          [else (void)])))
    (bus-subscribe! app-bus
                    (lambda (name data)
                      (handle name data)))))

;; The chart-batch ticker: drains both rings at UI cadence and emits typed
;; batch events. Runs under the backend's own custodian space via a thread
;; started once at serve time.
(define batch-ticker-thread (box #f))

(define (start-batch-ticker!)
  (unless (unbox batch-ticker-thread)
    (set-box! batch-ticker-thread
              (thread
               (lambda ()
                 (let loop ()
                   (sleep 33/1000)
                   (with-handlers ([exn:fail? (lambda (_) (void))])
                     (for ([pair (in-list (list (cons "offset" app-offset-series)
                                                (cons "delay" app-delay-series)))])
                       (define batch (series-drain-batch! (cdr pair)))
                       (when (positive? (chart-batch-sample-count batch))
                         (chart-batch (ChartBatchEnvelope (car pair) batch)))))
                   (loop)))))))

;; ---- RPCs -----------------------------------------------------------------

(define-rpc (bootstrap : Bootstrap)
  (gate-init!)
  (apply-tier-capacity!)
  (define status (sup-status app-supervisor))
  (define lang (settings-ref 'language))
  (Bootstrap
   app-version
   (platform-name)
   lang
   (gate-info->record (gate-info))
   (any->wire (i18n-dict lang))
   (for/list ([nic (in-list (detect-interfaces))]) (nic->record nic))
   (sup-status->record status)
   (cm-status->record (cm-status app-capture))
   (optional-int (settings-ref 'offset-warn-us))
   (optional-string (settings-ref 'capture-iface))
   (void)
   (params->conf (current-engine-params) #:role (role-name status))))

(define current-params-box (box (default-params-for-role 'listener)))

(define (current-engine-params) (unbox current-params-box))

(define (set-current-engine-params! p) (set-box! current-params-box p))

(define-rpc (list-nics : (List NicInfo))
  (for/list ([nic (in-list (detect-interfaces))]) (nic->record nic)))

(define-rpc (qualify [iface : String] [role : String] [reference : String] [ifaces : (List String)] : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (define nics (detect-interfaces))
    (define qualification
      (if (string=? role "boundary")
          (qualify-ports #:platform (platform-name)
                         #:nics nics
                         #:ifaces ifaces
                         #:reference reference
                         #:capture-status (cm-status app-capture)
                         #:lang (settings-ref 'language))
          (qualify-interface #:platform (platform-name)
                             #:nics nics
                             #:iface iface
                             #:role (string->symbol role)
                             #:reference reference
                             #:capture-status (cm-status app-capture)
                             #:lang (settings-ref 'language))))
    (ok-action qualification)))

(define-rpc (engine-start [role : String] [mode : String] [iface : String] [ifaces : (List String)] : EngineStartResult)
  (define role* (string->symbol role))
  (define mode* (string->symbol mode))
  (define iface* (if (= (string-length iface) 0) #f iface))
  (define ifaces* (filter (lambda (i) (> (string-length i) 0)) ifaces))
  (define (denied? message) (EngineStartResult #f #t message (void)))
  (define (failed message) (EngineStartResult #f #f message (void)))
  (cond
    [(not (member role* '(grandmaster slave listener boundary)))
     (failed "unknown role")]
    [(not (member mode* '(real sim)))
     (failed "unknown mode")]
    [(and (eq? mode* 'real) (not (eq? role* 'listener)) (not (gate-pro?)))
     (denied? (gate-check 'engine))]
    [(and (eq? role* 'boundary) (null? ifaces*))
     (failed "boundary clock requires the port list (ifaces)")]
    [(eq? role* 'boundary)
     (define-values (ok? err)
       (if (null? ifaces*)
           (values #f "boundary clock needs at least two distinct interfaces")
           (sup-start app-supervisor role* (first ifaces*) (current-engine-params) mode*
                      #:ifaces ifaces*)))
     (if ok?
         (EngineStartResult #t #f (void) (current-engine-status))
         (failed (or err "start failed")))]
    [else
     (define-values (ok? err)
       (sup-start app-supervisor role* iface* (current-engine-params) mode*))
     (if ok?
         (EngineStartResult #t #f (void) (current-engine-status))
         (failed (or err "start failed")))]))

(define-rpc (engine-stop : EngineStatus)
  (sup-stop app-supervisor)
  (current-engine-status))

(define-rpc (engine-status-now : EngineStatus)
  (current-engine-status))

(define-rpc (engine-check-offsets : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (ok-action (sup-check-offsets app-supervisor))))

(define-rpc (engine-set-reference [source : String] : ActionResult)
  (define ref (string->symbol source))
  (cond
    [(not (memq ref '(system none))) (fail-action "unknown reference source")]
    [else
     (sup-set-reference app-supervisor ref)
     (ok-action (current-engine-status))]))

(define-rpc (gm-settings : GmSettings)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (GmSettings (any->wire (sup-gm-settings app-supervisor)))))

(define-rpc (gm-settings-apply
             [clock_class : (Optional Int64)]
             [clock_accuracy : (Optional Int64)]
             [offset_scaled_log_variance : (Optional Int64)]
             [current_utc_offset : (Optional Int64)]
             [leap61 : (Optional Int64)]
             [leap59 : (Optional Int64)]
             [current_utc_offset_valid : (Optional Int64)]
             [ptp_timescale : (Optional Int64)]
             [time_traceable : (Optional Int64)]
             [frequency_traceable : (Optional Int64)]
             [time_source : (Optional Int64)]
             [priority1 : (Optional Int64)]
             [priority2 : (Optional Int64)]
             : ActionResult)
  (cond
    [(not (gate-pro?)) (deny-pro (gate-check 'engine))]
    [else
     (define provided
       (for*/hasheq ([pair (in-list (list (cons 'clock_class clock_class)
                                           (cons 'clock_accuracy clock_accuracy)
                                           (cons 'offset_scaled_log_variance offset_scaled_log_variance)
                                           (cons 'current_utc_offset current_utc_offset)
                                           (cons 'leap61 leap61)
                                           (cons 'leap59 leap59)
                                           (cons 'current_utc_offset_valid current_utc_offset_valid)
                                           (cons 'ptp_timescale ptp_timescale)
                                           (cons 'time_traceable time_traceable)
                                           (cons 'frequency_traceable frequency_traceable)
                                           (cons 'time_source time_source)
                                           (cons 'priority1 priority1)
                                           (cons 'priority2 priority2)))]
                     #:when (integer? (cdr pair)))
         (values (car pair) (cdr pair))))
     (define-values (ok? result)
       (sup-gm-settings-set! app-supervisor provided))
     (if ok? (ok-action result) (fail-action result))]))

(define-rpc (simulator-faults : Any)
  (any->wire (hash-ref (sup-status app-supervisor) 'faults)))

(define-rpc (capture-start [iface : String] : ActionResult)
  (settings-set! 'capture-iface iface)
  (define-values (ok? err) (cm-start app-capture iface))
  (if ok? (ok-action (cm-status->record (cm-status app-capture))) (fail-action err)))

(define-rpc (capture-stop : CaptureStatus)
  (cm-stop app-capture)
  (cm-status->record (cm-status app-capture)))

(define-rpc (capture-status-now : CaptureStatus)
  (cm-status->record (cm-status app-capture)))

(define-rpc (packets-page [limit : Int64] : PacketPage)
  (define bound (if (<= 1 limit 5000) limit 200))
  (define-values (captured total) (packet-store-stats app-packets))
  (PacketPage
   (for/list ([row (in-list (packet-store-snapshot app-packets bound))])
     (packet->record row))
   (packet-store-count app-packets)
   total))

(define-rpc (packets-clear : Bool)
  (packet-store-clear! app-packets)
  (packets-cleared #t)
  #t)

(define-rpc (pcap-import [path : String] : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (define-values (frames linktype) (read-capture-file path))
    (packet-store-clear! app-packets)
    (define decoded
      (for/list ([f (in-list frames)])
        (capture-file-frame->packet f path)))
    (for ([d (in-list (reverse decoded))])
      (packet-store-push! app-packets d))
    (log-add! app-logs 'capture 'info
              (format "imported ~a: ~a frames (link layer ~a), PTP frames ~a"
                      (path->string path) (length frames) linktype
                      (count (lambda (d) (hash-ref d 'is_ptp #f)) decoded)))
    (ok-action (length decoded))))

(define-rpc (pcap-export [path : String] : ActionResult)
  (cond
    [(not (eq? (gate-check 'export) #t)) (deny-pro (gate-check 'export))]
    [else
     (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
       (define frames
         (reverse
          (for/list ([f (in-list (packet-store-snapshot app-packets 999999))])
            (packet->capture-file-frame f))))
       (write-capture-file path frames)
       (ok-action (length frames)))]))

(define-rpc (wireshark-launch [action : String] [iface : String] : ActionResult)
  (cond
    [(not (member action '("live" "retained"))) (fail-action "unknown wireshark action")]
    [(not (wireshark-available?))
     (fail-action "wireshark not found; install it first (sudo apt install wireshark)")]
    [(string=? action "live")
     (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
       (define filter
         (gptp-capture-filter (gptp-params-network-transport (current-engine-params))))
       (define result (launch-wireshark-live! iface filter))
       (log-add! app-logs 'app 'info
                 (format "Wireshark live: iface=~a filter=~a" iface filter))
       (ok-action result))]
    [(not (eq? (gate-check 'export) #t)) (deny-pro (gate-check 'export))]
    [else (ok-action (open-retained-in-wireshark))]))

(define-rpc (series-window [series-id : String] : SeriesWindow)
  (cond
    [(string=? series-id "offset") (series-window-batch app-offset-series "offset")]
    [(string=? series-id "delay") (series-window-batch app-delay-series "delay")]
    [else (raise-arguments-error 'series-window "unknown series" "series" series-id)]))

(define-rpc (series-reset : Bool)
  (series-clear! app-offset-series)
  (series-clear! app-delay-series)
  #t)

(define-rpc (logs : (List LogRow))
  (for/list ([entry (in-list (log-snapshot app-logs #:limit 400))])
    (LogRow (optional-int (hash-ref entry 'ts 0))
            (symbol->string* (hash-ref entry 'source "app"))
            (symbol->string* (hash-ref entry 'level "info"))
            (symbol->string* (hash-ref entry 'message "")))))

(define-rpc (logs-export [path : String] : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (display-to-file (log->text (log-snapshot app-logs #:limit 100000)) path
                     #:mode 'text #:exists 'replace)
    (ok-action)))

(define-rpc (conf-preview : String)
  (params->conf (current-engine-params) #:role (role-name (sup-status app-supervisor))))

(define-rpc (presets : (List PresetEntry))
  (for/list ([n (in-list (preset-names))])
    (define p (preset-load n))
    (if p
        (PresetEntry n
                     (symbol->string* (hash-ref p 'role "listener"))
                     (optional-string (hash-ref p 'iface #f))
                     (any->wire (hash-ref p 'params (void))))
        (PresetEntry n "listener" (void) (void)))))

(define-rpc (preset-save-rpc [name : String] [role : String] [iface : String] : ActionResult)
  (cond
    [(= (string-length name) 0) (fail-action "preset name must not be empty")]
    [else
     (preset-save name (string->symbol role)
                  (current-engine-params)
                  (if (= (string-length iface) 0) #f iface))
     (ok-action)]))

(define-rpc (preset-apply-rpc [name : String] : ActionResult)
  (define p (preset-load name))
  (cond
    [(not p) (fail-action "preset does not exist")]
    [else
     (set-current-engine-params! (hash-ref p 'params))
     (ok-action (hasheq 'role (hash-ref p 'role)
                        'iface (hash-ref p 'iface)
                        'conf (params->conf (hash-ref p 'params)
                                            #:role (hash-ref p 'role))))]))

(define-rpc (preset-delete-rpc [name : String] : ActionResult)
  (ok-action (preset-delete name)))

(define-rpc (license-status : GateInfo)
  (gate-info->record (gate-info)))

(define-rpc (license-trial-start : GateInfo)
  (gate-trial-start!)
  (gate-info->record (gate-info)))

(define-rpc (license-activate [path : String] : ActionResult)
  (define-values (ok? msg) (gate-activate! path))
  (if ok? (ok-action msg) (fail-action msg)))

(define-rpc (license-deactivate : GateInfo)
  (gate-deactivate!)
  (gate-info->record (gate-info)))

(define-rpc (set-settings [language : String] [offset_warn_us : Int64] : ActionResult)
  (let ((applied ""))
    (when (> (string-length language) 0)
      (settings-set! 'language language)
      (set! applied "language"))
    (when (>= offset_warn_us 1)
      (settings-set! 'offset-warn-us offset_warn_us)
      (sup-set-alarm-threshold! app-supervisor (* offset_warn_us 1000))
      (set! applied (string-trim (string-append applied " offset-warn"))))
    (ok-action applied)))

(define-rpc (diagnostics-export [path : String] [iface : String] [role : String] [reference : String] : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (define nics (detect-interfaces))
    (define qualification
      (qualify-interface #:platform (platform-name)
                         #:nics nics
                         #:iface (if (string=? iface "") "eth0" iface)
                         #:role (if (string=? role "") "listener" role)
                         #:reference reference
                         #:capture-status (cm-status app-capture)))
    (define snapshot
      (make-diagnostic-snapshot
       #:version app-version
       #:platform (platform-name)
       #:host (collect-platform-fingerprint)
       #:nics nics
       #:qualification qualification
       #:engine (sup-status app-supervisor)
       #:capture (cm-status app-capture)
       #:params (params->jsexpr (current-engine-params))
       #:conf (params->conf (current-engine-params) #:role role)
       #:logs (log-snapshot app-logs #:limit 500)
       #:redact-network? #t))
    (write-diagnostic-snapshot! path snapshot)
    (ok-action (hasheq 'path (path->string path) 'redacted #t))))

(define-rpc (report-export [path : String] [iface : String] [role : String] [reference : String] : ActionResult)
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (define nics (detect-interfaces))
    (define chosen-iface
      (if (string=? iface "")
          (or (hash-ref (sup-status app-supervisor) 'iface #f)
              (hash-ref (cm-status app-capture) 'iface #f)
              (settings-ref 'capture-iface)
              "eth0")
          iface))
    (define qualification
      (qualify-interface #:platform (platform-name)
                         #:nics nics
                         #:iface chosen-iface
                         #:role (if (string=? role "") "listener" role)
                         #:reference reference
                         #:capture-status (cm-status app-capture)))
    (define threshold-ns (* (settings-ref 'offset-warn-us) 1000))
    (define report
      (make-engineering-report
       #:version app-version
       #:platform (platform-name)
       #:nics nics
       #:qualification qualification
       #:engine (sup-status app-supervisor)
       #:capture (cm-status app-capture)
       #:params (params->jsexpr (current-engine-params))
       #:conf (params->conf (current-engine-params) #:role role)
       #:offset-points (series-snapshot app-offset-series 5000)
       #:delay-points (series-snapshot app-delay-series 5000)
       #:packets (packet-store-snapshot app-packets 5000)
       #:logs (log-snapshot app-logs #:limit 300)
       #:offset-jump-threshold-ns threshold-ns))
    (define markdown-path
      (if (regexp-match? #rx"[.]json$" path)
          (path-replace-extension path #".md")
          path))
    (write-engineering-report-json! path report)
    (write-engineering-report-markdown! markdown-path report)
    (ok-action (hasheq 'json (path->string path)
                       'markdown (path->string markdown-path)))))

(define-rpc (params-merge
             [domain : (Optional Int64)]
             [priority1 : (Optional Int64)]
             [priority2 : (Optional Int64)]
             [log_announce_interval : (Optional Int64)]
             [log_sync_interval : (Optional Int64)]
             [network_transport : (Optional String)]
             [delay_mechanism : (Optional String)]
             [transport_specific : (Optional Int64)]
             [ptp_dst_mac : (Optional String)]
             [p2p_dst_mac : (Optional String)]
             [gm_capable : (Optional Int64)]
             [slave_only : (Optional Int64)]
             [assume_two_step : (Optional Int64)]
             [path_trace_enabled : (Optional Int64)]
             [follow_up_info : (Optional Int64)]
             [clock_class : (Optional Int64)]
             [ifaces : (List String)]
             : ActionResult)
  ;; Optionals are the typed replacement for the endpoint's old -999/""
  ;; sentinels: an absent field must never reach update-params-from-json,
  ;; or the untouched advanced fields corrupt the conf preview.
  (with-handlers ([exn:fail? (lambda (e) (fail-action (exn-message e)))])
    (define body
      (for*/hasheq ([pair (in-list (list (cons 'domain domain)
                                          (cons 'priority1 priority1)
                                          (cons 'priority2 priority2)
                                          (cons 'log_announce_interval log_announce_interval)
                                          (cons 'log_sync_interval log_sync_interval)
                                          (cons 'network_transport network_transport)
                                          (cons 'delay_mechanism delay_mechanism)
                                          (cons 'transport_specific transport_specific)
                                          (cons 'ptp_dst_mac ptp_dst_mac)
                                          (cons 'p2p_dst_mac p2p_dst_mac)
                                          (cons 'gm_capable gm_capable)
                                          (cons 'slave_only slave_only)
                                          (cons 'assume_two_step assume_two_step)
                                          (cons 'path_trace_enabled path_trace_enabled)
                                          (cons 'follow_up_info follow_up_info)
                                          (cons 'clock_class clock_class)))]
                    #:when (cdr pair))
        (values (car pair) (cdr pair))))
    (define merged (update-params-from-json (current-engine-params) body))
    (set-current-engine-params! merged)
    (define errs (validate-params merged))
    (define app-role (sup-status-app-role))
    (define preview-ifaces
      (if (eq? app-role 'boundary)
          (filter (lambda (i) (> (string-length i) 0)) ifaces)
          '()))
    (ok-action (hasheq 'errors errs
                       'params (params->jsexpr merged)
                       'conf (params->conf merged #:role (role-name app-role)
                                           #:ifaces preview-ifaces)))))

(define-rpc (doctor-report : DoctorReport)
  (define report (collect-doctor-report app-version))
  (define json-out (open-output-string))
  (write-json report json-out)
  (DoctorReport (get-output-string json-out) (doctor->text report)))

;; ---- online updates (docs/update-contract.md) ----------------------------------

;; Never raises: a network or verification failure is the "error" status
;; with the message — a headless check must not take the host down.
(define-rpc (check-updates : UpdateCheck)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (log-error "update check failed: ~a" (exn-message e))
          (UpdateCheck "error" (optional-string (exn-message e))
                       app-version (void) (void)))])
    (define candidate (check-for-update update-manifest-url))
    (cond
      [candidate
       (set-box! update-manifest-box candidate)
       (set-box! update-info-box (update-info candidate))
       (define info (update-info candidate))
       (UpdateCheck "available" (void) app-version
                    (optional-string (hash-ref info 'version))
                    (optional-string (hash-ref info 'url)))]
      [else
       (set-box! update-manifest-box #f)
       (set-box! update-info-box #f)
       (UpdateCheck "up-to-date" (void) app-version (void) (void))])))

;; Runs the download on the watched worker thread; the host follows progress
;; through update-state. Never raises: failures land on the flow's failed
;; phase and surface through the next update-state poll.
(define-rpc (start-download : UpdateState)
  (with-handlers
      ([exn:fail?
        (lambda (e) (flow-set! 'failed #:error (exn-message e)))])
    (update-prepare! 'download (unbox update-manifest-box)))
  (update-state-now))

;; Applies what is staged, per install shape (deb: pkexec with the
;; operator's consent; tarball: in-place payload swap). Never raises.
(define-rpc (apply-update : UpdateState)
  (with-handlers
      ([exn:fail?
        (lambda (e) (flow-set! 'failed #:error (exn-message e)))])
    (update-apply!))
  (update-state-now))

(define-rpc (update-state : UpdateState)
  (update-state-now))

(define (update-state-now)
  (define s (update-flow-status))
  (UpdateState
   (hash-ref s 'state "idle")
   (optional-int (hash-ref s 'percent 0))
   (optional-string (hash-ref s 'error #f))
   (optional-string (hash-ref s 'staged #f))
   (optional-string (hash-ref s 'install_command #f))))

;; Diagnostics-for-the-clipboard (the issue-template opener): the doctor
;; report's redacted text plus the two triage facts doctor->text does not
;; carry — the exact Racket runtime and the license tier. Nothing here adds
;; network or host identifiers (the doctor report omits them by contract).
(define-rpc (diagnostics-text : String)
  (define report (collect-doctor-report app-version))
  (define host (hash-ref report 'host (hasheq)))
  (define head
    (list (format "gPTP Studio ~a" app-version)
          (format "Distro: ~a"
                  (hash-ref (hash-ref host 'distro (hasheq))
                            'pretty_name "unknown"))
          (format "Kernel: ~a ~a"
                  (hash-ref (hash-ref host 'kernel (hasheq)) 'release "unknown")
                  (hash-ref (hash-ref host 'kernel (hasheq)) 'architecture
                            "unknown"))
          (format "Racket runtime: ~a"
                  (hash-ref (hash-ref host 'runtime (hasheq)) 'racket_version
                            "unknown"))
          (format "License tier: ~a~a"
                  (hash-ref (gate-info) 'tier "free")
                  (if (hash-ref (gate-info) 'pro #f) " (Pro)" ""))
          ""))
  (define log-lines
    (for/list ([entry (in-list (log-snapshot app-logs #:limit 15))])
      (format "[~a/~a] ~a"
              (hash-ref entry 'source "app")
              (hash-ref entry 'level "info")
              (hash-ref entry 'message ""))))
  (string-join (append head
                       (list (doctor->text report))
                       (list "" "Recent log (tail):")
                       log-lines)
               "\n"))

;; ---- events -----------------------------------------------------------------

(define-event engine-state : EngineStatus)
(define-event chart-batch : ChartBatchEnvelope)
(define-event packets-appended : (List PacketRow))
(define-event packets-cleared : Bool)
(define-event capture-state-changed : CaptureStatus)
(define-event alarm-event : AlarmEvent)
(define-event backend-error : String)

;; ---- entry --------------------------------------------------------------------

(define (start in-fd out-fd)
  (gate-init!)
  (apply-tier-capacity!)
  ;; the updater's selection policy keys off the running version — bind it
  ;; once from the single source (app/state.rkt, checked by
  ;; scripts/check-release-version.sh)
  (update-current-version app-version)
  (forward-engine-events!)
  (start-batch-ticker!)
  (serve-fds in-fd out-fd))
