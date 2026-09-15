#lang racket/base

;; Decoder/encoder golden tests. The Sync vector below is hand-computed from
;; IEEE 1588-2008 §13 (34-byte header + 10-byte Sync body); everything else
;; rides encode->decode roundtrips so both sides are exercised together.

(require rackunit
         racket/list
         "../proto/decode.rkt"
         "../proto/encode.rkt"
         "../proto/constants.rkt")

;; ---- helpers (module definitions are sequential: keep these first) ----------

(define (u16->bytes* v)
  (bytes (bitwise-and (arithmetic-shift v -8) #xFF) (bitwise-and v #xFF)))

(define (string-contains? hay needle)
  (and (regexp-match (regexp-quote needle) hay) #t))

;; ---- hand-built golden Sync frame ------------------------------------------

;; eth: 01:80:C2:00:00:0E -> 02:11:22:33:44:55, ethertype 0x88f7
;; header: tspec 0x1, Sync(0x0), v2, len 44, domain 0, flags twoStep(0x0800),
;;         correction 0, clockId a0:b0:0c:0d:0e:0f:10:11.1, seq 42, ctrl 0,
;;         logInterval -3
;; body: originTimestamp = 1000s 500000000ns
(define golden-sync
  (bytes-append
   #"\x01\x80\xC2\x00\x00\x0E"  ; dst
   #"\x02\x11\x22\x33\x44\x55"  ; src
   #"\x88\xF7"                  ; ethertype
   #"\x10\x02\x00\x2C"          ; tspec|mt, version, length 44
   #"\x00\x00"                  ; domain, reserved
   #"\x08\x00"                  ; flags: twoStep
   #"\x00\x00\x00\x00\x00\x00\x00\x00" ; correction 0
   #"\x00\x00\x00\x00"          ; reserved
   #"\xA0\xB0\x0C\x0D\x0E\x0F\x10\x11" ; clockIdentity
   #"\x00\x01"                  ; port 1
   #"\x00\x2A"                  ; seq 42
   #"\x00"                      ; control
   #"\xFD"                      ; logMessageInterval -3
   #"\x00\x00\x00\x00\x03\xE8"  ; seconds 1000
   #"\x1D\xCD\x65\x00"))        ; nanoseconds 500000000

(define f (decode-frame golden-sync #:ts 100.25 #:iface "eth0" #:frame-no 7))

(check-true (hash-ref f 'ok))
(check-true (hash-ref f 'is_ptp))
(check-equal? (hash-ref f 'mac_dst) "01:80:c2:00:00:0e")
(check-equal? (hash-ref f 'mac_src) "02:11:22:33:44:55")
(check-equal? (hash-ref f 'transport) "L2")
(check-equal? (hash-ref f 'ts) 100.25)
(check-equal? (hash-ref f 'frame_no) 7)

(define hdr (hash-ref f 'ptp))
(check-equal? (hash-ref hdr 'message_type) #x00)
(check-equal? (hash-ref hdr 'message_type_name) "Sync")
(check-equal? (hash-ref hdr 'transport_specific) 1)
(check-equal? (hash-ref hdr 'ptp_version) 2)
(check-equal? (hash-ref hdr 'message_length) 44)
(check-equal? (hash-ref hdr 'domain_number) 0)
(check-equal? (hash-ref hdr 'flags) #x0800)
(check-equal? (hash-ref hdr 'flags_list) '("twoStep"))
(check-equal? (hash-ref hdr 'correction_field_raw) 0)
(check-equal? (hash-ref hdr 'source_clock_identity) "a0:b0:0c:0d:0e:0f:10:11")
(check-equal? (hash-ref hdr 'source_port_number) 1)
(check-equal? (hash-ref hdr 'source_port_identity) "a0:b0:0c:0d:0e:0f:10:11.1")
(check-equal? (hash-ref hdr 'sequence_id) 42)
(check-equal? (hash-ref hdr 'log_message_interval) -3)

(define body (hash-ref f 'body))
(check-equal? (hash-ref body 'origin_timestamp)
              (hasheq 'seconds 1000 'nanoseconds 500000000
                      'ns_total 1000500000000))

;; ---- roundtrips --------------------------------------------------------------

(define test-header
  (hasheq 'domain 0
          'flags #x0000
          'sequence-id 7
          'clock-id "b6:2f:08:11:22:33:44:55"
          'port-number 1
          'transport-specific #x1
          'correction-raw 6553600            ; 100.0 ns
          'control 2
          'log-interval -3))

;; Announce: full body check against values chosen to match the standard's
;; field order.
(define announce-body
  (bytes-append
   #"\x00\x25"                    ; currentUtcOffset 37 (big-endian)
   #"\x00"                        ; reserved
   #"\xF8"                        ; gm priority1 248
   #"\xF8\x20\x20\xFE"            ; class 248, accuracy 0x20, variance 0x20FE
   #"\xF8"                        ; gm priority2 248
   #"\xB6\x2F\x08\x11\x22\x33\x44\x55" ; gm identity
   #"\x00\x00"                    ; stepsRemoved 0
   #"\xA0"))                      ; timeSource 0xA0 INTERNAL_OSCILLATOR

(define announce-frame
  (build-ethernet-frame
   (build-ptp-message #x0B test-header announce-body)
   #:src-mac "b6:2f:08:00:00:01"))

(check-equal? (hash-ref (hash-ref (decode-frame announce-frame) 'ptp) 'message_type) #x0B)
(define af (decode-frame announce-frame))
(define ab (hash-ref af 'body))
(check-equal? (hash-ref ab 'current_utc_offset) 37)
(check-equal? (hash-ref ab 'grandmaster_priority1) 248)
(check-equal? (hash-ref ab 'grandmaster_clock_class) 248)
(check-equal? (hash-ref ab 'grandmaster_clock_accuracy) #x20)
(check-equal? (hash-ref ab 'grandmaster_offset_scaled_log_variance) #x20FE)
(check-equal? (hash-ref ab 'grandmaster_priority2) 248)
(check-equal? (hash-ref ab 'grandmaster_identity) "b6:2f:08:11:22:33:44:55")
(check-equal? (hash-ref ab 'steps_removed) 0)
(check-equal? (hash-ref ab 'time_source_name) "INTERNAL_OSCILLATOR")

;; Follow_Up with the gPTP follow-up information TLV
(define fu-body (timestamp->bytes 1000 625000000))
(define fu-tlv (build-follow-up-info-tlv #:cumulative-rate-offset 2199023  ; 0.000001
                                         #:gm-time-base 5))
(define fu-frame
  (build-ethernet-frame
   (build-ptp-message #x08 (hash-set test-header 'control 2) fu-body fu-tlv)))
(define ff (decode-frame fu-frame))
(check-equal? (hash-ref (hash-ref ff 'ptp) 'message_type) #x08)
(define fb (hash-ref ff 'body))
(check-equal? (hash-ref (hash-ref fb 'precise_origin_timestamp) 'nanoseconds) 625000000)
(check-equal? (length (hash-ref ff 'tlvs)) 1)
(define tlv (first (hash-ref ff 'tlvs)))
(check-equal? (hash-ref tlv 'tlv_type_name) "ORGANIZATION_EXTENSION")
(check-equal? (hash-ref tlv 'organization_id) "00:1b:19")
(check-equal? (hash-ref tlv 'subtype) 1)
(check-true (< (abs (- (hash-ref tlv 'cumulative_scaled_rate_offset)
                       (/ 2199023 2199023255552.0)))
               1e-12))
(check-equal? (hash-ref tlv 'gm_time_base_indicator) 5)

;; PDelay_Resp roundtrip
(define pdr-body
  (bytes-append (timestamp->bytes 1000 750000000)
                (clock-id-string->bytes "aa:bb:cc:dd:ee:ff:00:11")
                (u16->bytes* 3)))
(define pdr (decode-frame (build-ethernet-frame (build-ptp-message #x03 test-header pdr-body))))
(check-equal? (hash-ref (hash-ref pdr 'body) 'requesting_port_identity)
              "aa:bb:cc:dd:ee:ff:00:11.3")

;; ---- correction field --------------------------------------------------------

(define corr (decode-frame
              (build-ethernet-frame (build-ptp-message #x00
                                                       (hash-set test-header 'correction-raw 6553600)
                                                       (timestamp->bytes 0 0)))))
(check-equal? (hash-ref (hash-ref corr 'ptp) 'correction_field_ns) 100.0)

;; ---- negative cases ----------------------------------------------------------

;; truncated: cut inside the header
(define trunc (subbytes golden-sync 0 30))
(define tf (decode-frame trunc))
(check-false (hash-ref tf 'ok))
(check-true (string-contains? (hash-ref tf 'error) "truncated"))

;; body truncated to less than the fixed layout (eth 14 + header 34 = 48)
(define short-body
  (bytes-append (subbytes golden-sync 0 48) #"\x00\x00\x00"))
(define sb (decode-frame short-body))
(check-true (hash-ref sb 'ok)) ; header fine
(check-true (and (hash-ref (hash-ref sb 'body) 'decode_error #f) #t) "body should report decode error")

;; not a PTP frame at all
(define arp-ish (bytes-append #"\xFF\xFF\xFF\xFF\xFF\xFF" #"\x02\x11\x22\x33\x44\x55" #"\x08\x06" (make-bytes 28)))
(define nf (decode-frame arp-ish))
(check-false (hash-ref nf 'is_ptp))

