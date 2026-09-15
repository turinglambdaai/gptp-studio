#lang racket/base

;; Minimal gPTP frame builder — the mirror of decode.rkt. Used by the
;; simulator (synthetic frames travel the exact same decode path as live
;; captures) and by the encode/decode roundtrip tests. L2 transport only;
;; UDPv4 injection is a future feature.

(require racket/format
         racket/list
         racket/string
         "constants.rkt")

(provide build-ethernet-frame
         build-ptp-message
         build-follow-up-info-tlv
         timestamp->bytes
         clock-id-string->bytes)

;; ---- primitives -------------------------------------------------------------

(define (u16->bytes v)
  (bytes (bitwise-and (arithmetic-shift v -8) #xFF) (bitwise-and v #xFF)))

(define (u32->bytes v)
  (bytes (bitwise-and (arithmetic-shift v -24) #xFF)
         (bitwise-and (arithmetic-shift v -16) #xFF)
         (bitwise-and (arithmetic-shift v -8) #xFF)
         (bitwise-and v #xFF)))

(define (u48->bytes v)
  (bytes (bitwise-and (arithmetic-shift v -40) #xFF)
         (bitwise-and (arithmetic-shift v -32) #xFF)
         (bitwise-and (arithmetic-shift v -24) #xFF)
         (bitwise-and (arithmetic-shift v -16) #xFF)
         (bitwise-and (arithmetic-shift v -8) #xFF)
         (bitwise-and v #xFF)))

(define (i32->bytes v)
  (u32->bytes (bitwise-and v #xFFFFFFFF)))

(define (mac-string->bytes s)
  (apply bytes (for/list ([p (in-list (string-split s ":"))]) (string->number p 16))))

(define (clock-id-string->bytes s)
  (apply bytes (for/list ([p (in-list (string-split s ":"))]) (string->number p 16))))

;; seconds+nanoseconds -> 10-byte PTP timestamp
(define (timestamp->bytes seconds nanoseconds)
  (bytes-append (u48->bytes seconds) (u32->bytes nanoseconds)))

;; ---- PTP header + body ------------------------------------------------------

;; header: (hash domain flags sequence-id clock-id port-number
;;          transport-specific correction-raw control log-interval)
;; body-bytes: the type-specific fixed body. TLVs appended verbatim.
(define (build-ptp-message message-type header body-bytes [tlv-bytes #""])
  (define domain (hash-ref header 'domain 0))
  (define flags (hash-ref header 'flags 0))
  (define seq (hash-ref header 'sequence-id 0))
  (define cid (clock-id-string->bytes (hash-ref header 'clock-id "00:11:22:33:44:55:66:77")))
  (define port (hash-ref header 'port-number 1))
  (define tspec (hash-ref header 'transport-specific #x1))
  (define correction (hash-ref header 'correction-raw 0))
  (define control (hash-ref header 'control 0))
  (define log-interval (hash-ref header 'log-interval 0))
  (define length (+ 34 (bytes-length body-bytes) (bytes-length tlv-bytes)))
  (bytes-append
   (bytes (bitwise-ior (arithmetic-shift tspec 4) (bitwise-and message-type #x0F)))
   (bytes 2)                                 ; version
   (u16->bytes length)
   (bytes domain 0)
   (u16->bytes flags)
   (let ([c (bitwise-and correction #xFFFFFFFFFFFFFFFF)])
     (bytes (bitwise-and (arithmetic-shift c -56) #xFF)
            (bitwise-and (arithmetic-shift c -48) #xFF)
            (bitwise-and (arithmetic-shift c -40) #xFF)
            (bitwise-and (arithmetic-shift c -32) #xFF)
            (bitwise-and (arithmetic-shift c -24) #xFF)
            (bitwise-and (arithmetic-shift c -16) #xFF)
            (bitwise-and (arithmetic-shift c -8) #xFF)
            (bitwise-and c #xFF)))
   (bytes 0 0 0 0)                           ; reserved
   cid
   (u16->bytes port)
   (u16->bytes seq)
   (bytes control)
   (bytes (bitwise-and log-interval #xFF))
   body-bytes
   tlv-bytes))

;; 802.1AS follow-up information TLV (org 00:1B:19, subtype 1).
(define (build-follow-up-info-tlv #:cumulative-rate-offset [csro 0]
                                  #:gm-time-base [tbi 0]
                                  #:gm-present [gm? #t])
  (define payload
    (bytes-append
     (bytes #x00 #x1B #x19)        ; IEEE 802.1 org id
     (bytes 0 gptp-follow-up-info-tlv-subtype)
     (i32->bytes csro)
     (u16->bytes tbi)
     (i32->bytes 0)                ; scaledLastGmPhaseChange
     (bytes (if gm? 1 0) 0 0 0)))  ; gmPresent + reserved
  (bytes-append (u16->bytes #x02) (u16->bytes (+ 4 (bytes-length payload))) payload))

;; ---- full frames ------------------------------------------------------------

;; Wrap a PTP message into an Ethernet L2 frame (dst = PTP multicast).
(define (build-ethernet-frame ptp-bytes
                              #:src-mac [src "02:00:00:00:00:01"]
                              #:dst-mac [dst (mac->string-const)])
  (bytes-append (mac-string->bytes dst)
                (mac-string->bytes src)
                (u16->bytes gptp-ethertype)
                ptp-bytes))

(define (mac->string-const)
  (apply string-append
         (add-between (for/list ([b (in-bytes gptp-l2-dst-mac)])
                        (define s (number->string b 16))
                        (if (< (string-length s) 2) (string-append "0" s) s))
                      ":")))
