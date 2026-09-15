#lang racket/base

;; 802.1AS / PTPv2 frame decoder. Consumes a full Ethernet frame (as captured)
;; and produces a jsexpr describing every decoded layer: Ethernet, optional
;; VLAN/IPv4/UDP, the PTP common header, the type-specific body and any
;; trailing TLVs. Field names are snake_case symbols; values are JSON-safe so
;; the same structure travels to the frontend untouched.
;;
;; Robustness rule: a malformed frame never raises — the result carries
;; 'ok #f plus an 'error tag and everything decoded so far.

(require racket/format
         racket/hash
         racket/match
         racket/string
         "constants.rkt")

(provide decode-frame
         decode-ptp-from-offset
         frame-summary)

;; ---- byte helpers -----------------------------------------------------------

(define (u16 bs off)
  (+ (arithmetic-shift (bytes-ref bs off) 8) (bytes-ref bs (add1 off))))

(define (u24 bs off)
  (+ (arithmetic-shift (bytes-ref bs off) 16)
     (arithmetic-shift (bytes-ref bs (add1 off)) 8)
     (bytes-ref bs (+ off 2))))

(define (u32 bs off)
  (+ (arithmetic-shift (bytes-ref bs off) 24)
     (arithmetic-shift (bytes-ref bs (add1 off)) 16)
     (arithmetic-shift (bytes-ref bs (+ off 2)) 8)
     (bytes-ref bs (+ off 3))))

;; 48-bit unsigned (big-endian, 6 bytes)
(define (u48 bs off)
  (+ (arithmetic-shift (u16 bs off) 32) (u32 bs (+ off 2))))

;; int32 big-endian two's complement
(define (i32 bs off)
  (define v (u32 bs off))
  (if (>= v #x80000000) (- v #x100000000) v))

(define (hex2 v)
  (define s (number->string v 16))
  (if (< (string-length s) 2) (string-append "0" s) s))

(define (mac->string bs off)
  (string-join
   (for/list ([i (in-range 6)]) (hex2 (bytes-ref bs (+ off i))))
   ":"))

(define (clock-id->string bs off)  ; 8-byte clock identity
  (string-join
   (for/list ([i (in-range 8)]) (hex2 (bytes-ref bs (+ off i))))
   ":"))

(define (hex-dump bs [limit (bytes-length bs)])
  (define n (min limit (bytes-length bs)))
  (apply string-append
         (for/list ([i (in-range n)]) (hex2 (bytes-ref bs i)))))

(define (need-bytes bs off n what)
  (when (< (bytes-length bs) (+ off n))
    (raise (exn:fail:ptp-truncate (format "truncated: need ~a bytes at ~a for ~a" n off what)
                                  (current-continuation-marks)))))

(struct exn:fail:ptp-truncate exn:fail ())

;; PTP timestamp: 6-byte seconds + 4-byte nanoseconds -> jsexpr
(define (decode-timestamp bs off)
  (need-bytes bs off 10 "timestamp")
  (define secs (u48 bs off))
  (define ns (u32 bs (+ off 6)))
  (hasheq 'seconds secs
          'nanoseconds ns
          'ns_total (+ (* secs 1000000000) ns)))

;; ---- header -----------------------------------------------------------------

;; Decode the 34-byte PTP common header starting at `off`.
;; Returns (values header-jsexpr end-offset).
(define (decode-header bs off)
  (need-bytes bs off 34 "ptp header")
  (define mt (bitwise-and (bytes-ref bs off) #x0F))
  (define transport-specific (arithmetic-shift (bytes-ref bs off) -4))
  (define version (bytes-ref bs (+ off 1)))
  (define msg-length (u16 bs (+ off 2)))
  (define domain (bytes-ref bs (+ off 4)))
  (define flags (u16 bs (+ off 6)))
  (define correction-raw (+ (arithmetic-shift (u32 bs (+ off 8)) 32) (u32 bs (+ off 12))))
  (define clock-id (clock-id->string bs (+ off 20)))
  (define port-number (u16 bs (+ off 28)))
  (define seq (u16 bs (+ off 30)))
  (define control (bytes-ref bs (+ off 32)))
  (define log-interval (let ([v (bytes-ref bs (+ off 33))])
                         (if (>= v 128) (- v 256) v)))
  (values (hasheq 'message_type mt
                  'message_type_name (message-type-name mt)
                  'transport_specific transport-specific
                  'ptp_version version
                  'message_length msg-length
                  'domain_number domain
                  'flags flags
                  'flags_list (flag-names flags)
                  'correction_field_raw correction-raw
                  'correction_field_ns (/ correction-raw 65536.0)
                  'source_clock_identity clock-id
                  'source_port_number port-number
                  'source_port_identity (format "~a.~a" clock-id port-number)
                  'sequence_id seq
                  'control_field control
                  'log_message_interval log-interval)
          (+ off 34)))

;; ---- TLVs -------------------------------------------------------------------

;; Decode a TLV chain starting at `off` with `avail` bytes remaining.
;; ORGANIZATION_EXTENSION with the 802.1 org id gets a named sub-decode
;; (follow-up information / gPTP rate offset fields).
(define (decode-tlvs bs off avail)
  (let loop ([pos off] [left avail] [acc '()])
    (if (< left 4)
        (reverse acc)
        (with-handlers ([exn:fail:ptp-truncate? (lambda (_) (reverse acc))])
          (define type (u16 bs pos))
          (define len-field (u16 bs (+ pos 2))) ; includes the 4 header bytes
          (if (and (>= len-field 4) (<= len-field left))
              (loop (+ pos len-field) (- left len-field)
                    (cons (decode-tlv-payload type bs (+ pos 4) (- len-field 4)) acc))
              (reverse acc))))))

(define (decode-tlv-payload type bs off len)
  (define base
    (hasheq 'tlv_type type
            'tlv_type_name (tlv-type-name type)
            'length (+ len 4)))
  (case type
    [(#x08) ; PATH_TRACE: sequence of 8-byte clock identities
     (define path
       (for/list ([i (in-range 0 (- len (remainder len 8)) 8)]
                  #:when (<= (+ off i 8) (bytes-length bs)))
         (clock-id->string bs (+ off i))))
     (hash-set base 'clock_ids path)]
    [(#x02) ; ORGANIZATION_EXTENSION
     (if (>= len 8)
         (let ([org (string-join (list (hex2 (bytes-ref bs off))
                                       (hex2 (bytes-ref bs (add1 off)))
                                       (hex2 (bytes-ref bs (+ off 2)))) ":")]
               [subtype (+ (arithmetic-shift (bytes-ref bs (+ off 3)) 8) (bytes-ref bs (+ off 4)))])
           (define b2 (hash-set* base 'organization_id org 'subtype subtype))
           (if (and (string=? org "00:1b:19") (= subtype gptp-follow-up-info-tlv-subtype))
               (decode-follow-up-info b2 bs (+ off 5) (- len 5))
               b2))
         base)]
    [else
     (hash-set base 'payload_hex (hex-dump bs off (min len 64)))]))

;; 802.1AS follow-up information (cumulative scaled rate offset etc.)
(define (decode-follow-up-info base bs off len)
  (if (< len 11)
      base
      (let ([csro (i32 bs off)]                       ; scaled rate offset, 2^-41
            [time-base (u16 bs (+ off 4))]
            [last-gm-phase (i32 bs (+ off 6))]         ; high part, 2^-16 scaled
            [gm-present (not (zero? (bytes-ref bs (+ off 10))))])
        (hash-set* base
                   'cumulative_scaled_rate_offset (/ csro 2199023255552.0) ; 2^41
                   'gm_time_base_indicator time-base
                   'scaled_last_gm_phase_change last-gm-phase
                   'gm_present gm-present))))

;; ---- message bodies ---------------------------------------------------------

(define (decode-body mt bs off avail header)
  (case mt
    [(#x00 #x01) ; Sync / Delay_Req
     (hasheq 'origin_timestamp (decode-timestamp bs off))]
    [(#x02) ; PDelay_Req
     (hasheq 'origin_timestamp (decode-timestamp bs off))]
    [(#x03) ; PDelay_Resp
     (hasheq 'request_receipt_timestamp (decode-timestamp bs off)
             'requesting_port_identity
             (format "~a.~a" (clock-id->string bs (+ off 10)) (u16 bs (+ off 18))))]
    [(#x08) ; Follow_Up (preciseOriginTimestamp; gPTP suffix decoded as TLVs)
     (hasheq 'precise_origin_timestamp (decode-timestamp bs off))]
    [(#x09) ; Delay_Resp
     (hasheq 'receive_timestamp (decode-timestamp bs off)
             'requesting_port_identity
             (format "~a.~a" (clock-id->string bs (+ off 10)) (u16 bs (+ off 18))))]
    [(#x0A) ; PDelay_Resp_Follow_Up
     (hasheq 'response_origin_timestamp (decode-timestamp bs off)
             'requesting_port_identity
             (format "~a.~a" (clock-id->string bs (+ off 10)) (u16 bs (+ off 18))))]
    [(#x0B) ; Announce
     (need-bytes bs off 20 "announce body")
     (hasheq 'current_utc_offset (i16 bs off)
             'grandmaster_priority1 (bytes-ref bs (+ off 3))
             'grandmaster_clock_class (bytes-ref bs (+ off 4))
             'grandmaster_clock_accuracy (bytes-ref bs (+ off 5))
             'grandmaster_offset_scaled_log_variance (u16 bs (+ off 6))
             'grandmaster_priority2 (bytes-ref bs (+ off 8))
             'grandmaster_identity (clock-id->string bs (+ off 9))
             'steps_removed (u16 bs (+ off 17))
             'time_source (bytes-ref bs (+ off 19))
             'time_source_name (time-source-name (bytes-ref bs (+ off 19))))]
    [(#x0C) ; Signalling: targetPortIdentity then TLVs
     (hasheq 'target_port_identity
             (format "~a.~a" (clock-id->string bs off) (u16 bs (+ off 8))))]
    [(#x0D) ; Management
     (hasheq 'target_port_identity
             (format "~a.~a" (clock-id->string bs off) (u16 bs (+ off 8))))]
    [else (hasheq 'payload_hex (hex-dump bs off (min avail 64)))]))

(define (i16 bs off)
  (define v (u16 bs off))
  (if (>= v #x8000) (- v #x10000) v))

;; Fixed body length per message type (everything before TLV suffixes).
(define (fixed-body-length mt)
  (case mt
    [(#x00 #x01 #x02) 10]
    [(#x03 #x09 #x0A) 20]
    [(#x08) 10]
    [(#x0B) 20]
    [(#x0C #x0D) 10]
    [else 0]))

;; ---- frame layers -----------------------------------------------------------

;; Decode a full captured Ethernet frame into a jsexpr. Never raises.
;;
;;   (decode-frame raw-bytes #:ts seconds #:iface "eth0" #:frame-no 12)
;;
(define (decode-frame raw
                      #:ts [ts #f]
                      #:iface [iface #f]
                      #:frame-no [frame-no #f]
                      #:source [source #f])
  (with-handlers ([exn:fail:ptp-truncate?
                   (lambda (e) (error-frame raw ts iface frame-no source (exn-message e)))]
                  [exn:fail?
                   (lambda (e) (error-frame raw ts iface frame-no source (exn-message e)))])
    (need-bytes raw 0 14 "ethernet header")
    (define dst (mac->string raw 0))
    (define src (mac->string raw 6))
    (define ethertype (u16 raw 12))
    (define-values (ptp-off transport payload-ethertype ip-info)
      (skip-to-ptp raw 14 ethertype))
    (define base
      (hasheq 'ts ts
              'frame_no frame-no
              'iface iface
              'source source
              'mac_dst dst
              'mac_src src
              'ethertype ethertype
              'ethertype_hex (format "0x~x" ethertype)
              'length (bytes-length raw)
              'raw_hex (hex-dump raw 512)
              'ok #t
              'is_ptp (and ptp-off #t)
              'transport transport
              'ip ip-info))
    (if ptp-off
        (decode-ptp-from-offset raw ptp-off base)
        (hash-set base 'error (format "not a PTP frame (ethertype ~a)" payload-ethertype)))))

;; Walk VLAN tags / IPv4+UDP to the PTP payload. Returns
;; (values ptp-offset-or-#f transport effective-ethertype ip-info-jsexpr).
(define (skip-to-ptp bs off ethertype)
  (cond
    [(= ethertype gptp-ethertype) (values off "L2" ethertype #f)]
    [(or (= ethertype #x8100) (= ethertype #x88a8))
     (if (< (bytes-length bs) (+ off 4))
         (values #f "unknown" ethertype #f)
         (skip-to-ptp bs (+ off 4) (u16 bs (+ off 2))))]
    [(= ethertype #x0800)
     (cond
       [(< (bytes-length bs) (+ off 20)) (values #f "unknown" ethertype #f)]
       [else
        (define ihl (* 4 (bitwise-and (bytes-ref bs off) #x0F)))
        (define proto (bytes-ref bs (+ off 9)))
        (define src-ip (string-join (for/list ([i (in-range 4)]) (~a (bytes-ref bs (+ off 12 i)))) "."))
        (define dst-ip (string-join (for/list ([i (in-range 4)]) (~a (bytes-ref bs (+ off 16 i)))) "."))
        (define udp-off (+ off ihl))
        (define info (hasheq 'src_ip src-ip 'dst_ip dst-ip 'protocol proto))
        (if (and (= proto 17) (<= (+ udp-off 8) (bytes-length bs)))
            (let ([sport (u16 bs udp-off)] [dport (u16 bs (+ udp-off 2))])
              (if (or (and (= sport ptp-udp-event-port) (= dport ptp-udp-event-port))
                      (and (= sport ptp-udp-general-port) (= dport ptp-udp-general-port))
                      (= dport ptp-udp-event-port) (= dport ptp-udp-general-port)
                      (= sport ptp-udp-event-port) (= sport ptp-udp-general-port))
                  (values (+ udp-off 8) "UDPv4" ethertype (hash-set* info 'src_port sport 'dst_port dport))
                  (values #f "unknown" ethertype (hash-set* info 'src_port sport 'dst_port dport))))
            (values #f "unknown" ethertype info))])]
    [else (values #f "unknown" ethertype #f)]))

;; Decode the PTP part of a frame at a known offset; merges into `base`.
(define (decode-ptp-from-offset bs ptp-off base)
  (define-values (hdr end) (decode-header bs ptp-off))
  (define mt (hash-ref hdr 'message_type))
  (define declared-len (hash-ref hdr 'message_length))
  ;; Avail for body+TLVs: honour declared length but never run past capture.
  (define avail (min (max (- declared-len (- ptp-off end)) 0)
                     (- (bytes-length bs) end)))
  (define body
    (with-handlers ([exn:fail:ptp-truncate?
                     (lambda (e) (hasheq 'decode_error (exn-message e)))])
      (if (>= avail (fixed-body-length mt))
          (decode-body mt bs end avail hdr)
          (hasheq 'decode_error "body shorter than the fixed layout for this message type"))))
  (define tlv-off (+ end (fixed-body-length mt)))
  (define tlvs
    (if (and (>= avail (fixed-body-length mt)) (member mt '(#x08 #x0B #x0C #x0D)))
        (decode-tlvs bs tlv-off (- avail (fixed-body-length mt)))
        '()))
  (hash-set* base
             'ptp hdr
             'body body
             'tlvs tlvs))

(define (error-frame raw ts iface frame-no source msg)
  (hasheq 'ts ts 'frame_no frame-no 'iface iface 'source source
          'length (bytes-length raw) 'ok #f 'is_ptp #f
          'error msg 'mac_src #f 'mac_dst #f 'transport #f))

;; Compact one-line summary for logs/tests.
(define (frame-summary f)
  (if (hash-ref f 'is_ptp #f)
      (let ([hdr (hash-ref f 'ptp)])
        (format "[~a] ~a seq=~a domain=~a src=~a"
                (or (hash-ref f 'iface #f) "-")
                (hash-ref hdr 'message_type_name)
                (hash-ref hdr 'sequence_id)
                (hash-ref hdr 'domain_number)
                (hash-ref hdr 'source_port_identity)))
      (format "[~a] not-ptp (~a)" (hash-ref f 'iface #f) (hash-ref f 'error "n/a"))))
