#lang racket/base

;; gPTP parameter model + ptp4l.conf generator. The GUI form edits a
;; gptp-params struct; the generator emits a ptp4l.conf that is byte-for-byte
;; what ptp4l expects (values follow the canonical linuxptp configs/gPTP.cfg
;; profile). Role presets (grandmaster / slave / listener) fill the fields
;; that differ per role, per the PRD's MA-902 mapping table.

(require racket/format
         racket/string
         json)

(provide (struct-out gptp-params)
         make-params
         default-params
         default-params-for-role
         role-name
         params->conf
         params->jsexpr
         jsexpr->params
         update-params-from-json
         validate-params)

;; ---- model ------------------------------------------------------------------

(struct gptp-params
  (domain              ; 0..127
   priority1           ; 0..255 (BMCA tie-break, lower wins)
   priority2           ; 0..255
   log-announce-interval  ; 2^x seconds; gPTP: 0 (1s)
   log-sync-interval      ; 2^x seconds; gPTP: -3 (125ms)
   network-transport      ; 'L2 | 'UDPv4
   delay-mechanism        ; 'P2P | 'E2E
   transport-specific     ; 0x1 for 802.1AS
   ptp-dst-mac
   p2p-dst-mac
   gm-capable             ; 1 when the port may become grandmaster
   slave-only             ; 1 -> never become master
   assume-two-step
   path-trace-enabled
   follow-up-info         ; 802.1AS follow_up info TLV
   log-min-pdelay-req-interval ; gPTP: 0
   neighbor-prop-delay-thresh  ; asCapable threshold, ns (gPTP: 800)
   sync-receipt-timeout   ; 0 = gPTP default (no announce-based timeout)
   clock-class            ; advertised when GM (248 default)
   clock-accuracy         ; 0xFE default
   offset-scaled-log-variance) ; 0xFFFF default
  #:transparent)

(define (make-params
         #:domain [domain 0]
         #:priority1 [priority1 248]
         #:priority2 [priority2 248]
         #:log-announce-interval [announce 0]
         #:log-sync-interval [sync -3]
         #:network-transport [transport 'L2]
         #:delay-mechanism [delay 'P2P]
         #:transport-specific [tspec 1]
         #:ptp-dst-mac [ptp-mac "01:80:C2:00:00:0E"]
         #:p2p-dst-mac [p2p-mac "01:80:C2:00:00:0E"]
         #:gm-capable [gm 1]
         #:slave-only [slave 0]
         #:assume-two-step [two-step 1]
         #:path-trace-enabled [pt 1]
         #:follow-up-info [fui 1]
         #:log-min-pdelay-req-interval [pdelay 0]
         #:neighbor-prop-delay-thresh [npdt 800]
         #:sync-receipt-timeout [srt 0]
         #:clock-class [class 248]
         #:clock-accuracy [acc #xFE]
         #:offset-scaled-log-variance [var 65535])
  (gptp-params domain priority1 priority2 announce sync transport delay tspec
               ptp-mac p2p-mac gm slave two-step pt fui pdelay npdt srt
               class acc var))

(define (default-params) (make-params))

;; Role presets per the PRD:
;;  - grandmaster: low priority1 so BMCA elects us, may act as GM
;;  - slave: slaveOnly, never contends
;;  - listener: no engine runs; the params are only a starting point for
;;    exports, keep slave defaults
(define (default-params-for-role role)
  (case role
    [(grandmaster)
     (make-params #:priority1 0 #:gm-capable 1 #:slave-only 0)]
    [(slave)
     (make-params #:priority1 248 #:gm-capable 0 #:slave-only 1)]
    [(listener)
     (make-params #:priority1 248 #:gm-capable 0 #:slave-only 1)]
    [else (make-params)]))

(define (role-name role)
  (case role
    [(grandmaster) "grandmaster"]
    [(slave) "slave"]
    [(listener) "listener"]
    [else "unknown"]))

;; ---- validation --------------------------------------------------------------

(define (in-range? v lo hi) (and (integer? v) (>= v lo) (<= v hi)))

(define (validate-params p)
  (filter
   values
   (list
    (and (not (in-range? (gptp-params-domain p) 0 127)) "domainNumber 必须在 0-127")
    (and (not (in-range? (gptp-params-priority1 p) 0 255)) "priority1 必须在 0-255")
    (and (not (in-range? (gptp-params-priority2 p) 0 255)) "priority2 必须在 0-255")
    (and (not (in-range? (gptp-params-log-announce-interval p) -7 7)) "logAnnounceInterval 必须在 -7..7")
    (and (not (in-range? (gptp-params-log-sync-interval p) -7 7)) "logSyncInterval 必须在 -7..7")
    (and (not (in-range? (gptp-params-log-min-pdelay-req-interval p) -7 7)) "logMinPdelayReqInterval 必须在 -7..7")
    (and (not (memq (gptp-params-network-transport p) '(L2 UDPv4))) "network_transport 必须是 L2 或 UDPv4")
    (and (not (memq (gptp-params-delay-mechanism p) '(P2P E2E))) "delay_mechanism 必须是 P2P 或 E2E")
    (and (not (regexp-match? #px"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$" (gptp-params-ptp-dst-mac p))) "ptp_dst_mac 格式无效")
    (and (not (regexp-match? #px"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$" (gptp-params-p2p-dst-mac p))) "p2p_dst_mac 格式无效")
    (and (not (in-range? (gptp-params-transport-specific p) 0 15)) "transportSpecific 必须在 0-15")
    (and (not (in-range? (gptp-params-neighbor-prop-delay-thresh p) 0 1000000)) "neighborPropDelayThresh 必须在 0-1000000")
    (and (not (in-range? (gptp-params-clock-class p) 0 255)) "clockClass 必须在 0-255"))))

;; ---- conf generation ---------------------------------------------------------

(define (fmt-mac m) (string-downcase m))

(define (params->conf p #:role [role "listener"] #:iface [iface #f])
  (string-append
   (format "# ptp4l.conf generated by gPTP Studio\n")
   (format "# role: ~a   iface: ~a\n"
           (role-name (string->symbol role))
           (or iface "auto"))
   (format "# profile: IEEE 802.1AS (gPTP)\n")
   "\n[global]\n"
   (kv "gmCapable" (gptp-params-gm-capable p))
   (kv "slaveOnly" (gptp-params-slave-only p))
   (kv "priority1" (gptp-params-priority1 p))
   (kv "priority2" (gptp-params-priority2 p))
   (kv "domainNumber" (gptp-params-domain p))
   (kv "logAnnounceInterval" (gptp-params-log-announce-interval p))
   (kv "logSyncInterval" (gptp-params-log-sync-interval p))
   (kv "logMinPdelayReqInterval" (gptp-params-log-min-pdelay-req-interval p))
   (kv "transportSpecific" (format "0x~x" (gptp-params-transport-specific p)))
   (kv "network_transport"
       (case (gptp-params-network-transport p) [(L2) "L2"] [(UDPv4) "UDPv4"]))
   (kv "delay_mechanism"
       (case (gptp-params-delay-mechanism p) [(P2P) "P2P"] [(E2E) "E2E"]))
   (kv "ptp_dst_mac" (fmt-mac (gptp-params-ptp-dst-mac p)))
   (kv "p2p_dst_mac" (fmt-mac (gptp-params-p2p-dst-mac p)))
   (kv "assume_two_step" (gptp-params-assume-two-step p))
   (kv "path_trace_enabled" (gptp-params-path-trace-enabled p))
   (kv "follow_up_info" (gptp-params-follow-up-info p))
   (kv "neighborPropDelayThresh" (gptp-params-neighbor-prop-delay-thresh p))
   (kv "syncReceiptTimeout" (gptp-params-sync-receipt-timeout p))
   (kv "clockClass" (gptp-params-clock-class p))
   (kv "clockAccuracy" (format "0x~a" (~r (gptp-params-clock-accuracy p) #:base 16 #:min-width 2 #:pad-string "0")))
   (kv "offsetScaledLogVariance" (format "0x~a" (~r (gptp-params-offset-scaled-log-variance p) #:base 16 #:min-width 4 #:pad-string "0")))
   (kv "summary_interval" 0)
   (kv "time_stamping" "hardware")   ; falls back to software gracefully in ptp4l
   (kv "verbose" 1)
   (kv "logging_level" 6)))

(define (kv k v)
  (define s (~a v))
  (define pad (make-string (max 1 (- 24 (string-length k))) #\space))
  (string-append k pad s "\n"))

;; ---- JSON interop (HTTP API form posts) --------------------------------------

(define (params->jsexpr p)
  (hasheq 'domain (gptp-params-domain p)
          'priority1 (gptp-params-priority1 p)
          'priority2 (gptp-params-priority2 p)
          'log_announce_interval (gptp-params-log-announce-interval p)
          'log_sync_interval (gptp-params-log-sync-interval p)
          'network_transport (symbol->string (gptp-params-network-transport p))
          'delay_mechanism (symbol->string (gptp-params-delay-mechanism p))
          'transport_specific (gptp-params-transport-specific p)
          'ptp_dst_mac (gptp-params-ptp-dst-mac p)
          'p2p_dst_mac (gptp-params-p2p-dst-mac p)
          'gm_capable (gptp-params-gm-capable p)
          'slave_only (gptp-params-slave-only p)
          'assume_two_step (gptp-params-assume-two-step p)
          'path_trace_enabled (gptp-params-path-trace-enabled p)
          'follow_up_info (gptp-params-follow-up-info p)
          'log_min_delay_req_interval (gptp-params-log-min-pdelay-req-interval p)
          'neighbor_prop_delay_thresh (gptp-params-neighbor-prop-delay-thresh p)
          'sync_receipt_timeout (gptp-params-sync-receipt-timeout p)
          'clock_class (gptp-params-clock-class p)
          'clock_accuracy (gptp-params-clock-accuracy p)
          'offset_scaled_log_variance (gptp-params-offset-scaled-log-variance p)))

;; Merge a partial jsexpr into params; unknown keys are ignored so the
;; frontend can post extra UI state alongside.
(define (update-params-from-json p body)
  (define (int key cur)
    (define v (hash-ref body key #f))
    (if (exact-integer? v) v cur))
  (define (sym key cur allowed)
    (define v (hash-ref body key #f))
    (if (and (string? v) (member (string->symbol v) allowed))
        (string->symbol v)
        cur))
  (struct-copy gptp-params p
               [domain (int 'domain (gptp-params-domain p))]
               [priority1 (int 'priority1 (gptp-params-priority1 p))]
               [priority2 (int 'priority2 (gptp-params-priority2 p))]
               [log-announce-interval (int 'log_announce_interval (gptp-params-log-announce-interval p))]
               [log-sync-interval (int 'log_sync_interval (gptp-params-log-sync-interval p))]
               [network-transport (sym 'network_transport (gptp-params-network-transport p) '(L2 UDPv4))]
               [delay-mechanism (sym 'delay_mechanism (gptp-params-delay-mechanism p) '(P2P E2E))]
               [transport-specific (int 'transport_specific (gptp-params-transport-specific p))]
               [ptp-dst-mac (let ([v (hash-ref body 'ptp_dst_mac #f)]) (if (string? v) v (gptp-params-ptp-dst-mac p)))]
               [p2p-dst-mac (let ([v (hash-ref body 'p2p_dst_mac #f)]) (if (string? v) v (gptp-params-p2p-dst-mac p)))]
               [gm-capable (int 'gm_capable (gptp-params-gm-capable p))]
               [slave-only (int 'slave_only (gptp-params-slave-only p))]
               [assume-two-step (int 'assume_two_step (gptp-params-assume-two-step p))]
               [path-trace-enabled (int 'path_trace_enabled (gptp-params-path-trace-enabled p))]
               [follow-up-info (int 'follow_up_info (gptp-params-follow-up-info p))]
               [log-min-pdelay-req-interval (int 'log_min_pdelay_req_interval (gptp-params-log-min-pdelay-req-interval p))]
               [neighbor-prop-delay-thresh (int 'neighbor_prop_delay_thresh (gptp-params-neighbor-prop-delay-thresh p))]
               [sync-receipt-timeout (int 'sync_receipt_timeout (gptp-params-sync-receipt-timeout p))]
               [clock-class (int 'clock_class (gptp-params-clock-class p))]
               [clock-accuracy (int 'clock_accuracy (gptp-params-clock-accuracy p))]
               [offset-scaled-log-variance (int 'offset_scaled_log_variance (gptp-params-offset-scaled-log-variance p))]))

;; Alias with a name matching its use at call sites reading posted bodies.
(define (jsexpr->params body) (update-params-from-json (default-params) body))
