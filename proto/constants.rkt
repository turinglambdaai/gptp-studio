#lang racket/base

;; IEEE 1588-2008 / IEEE 802.1AS protocol constants: message types, header
;; flag bits, TLV types, port states, clock qualities. Shared by the decoder,
;; the encoder, the simulator and the UI field tables.

(provide message-type-name
         message-type-category
         all-message-types
         flag-names
         tlv-type-name
         port-state-name
         clock-class-hint
         time-source-name
         gptp-ethertype
         gptp-l2-dst-mac
         gptp-follow-up-info-tlv-subtype
         ptp-udp-event-port
         ptp-udp-general-port
         ipv4-multicast-addr
         pdelay-ipv4-multicast-addr)

;; ---- ethertypes / ports ---------------------------------------------------

(define gptp-ethertype #x88f7)
(define gptp-l2-dst-mac (bytes #x01 #x80 #xC2 #x00 #x00 #x0E))
(define ptp-udp-event-port 319)
(define ptp-udp-general-port 320)
(define ipv4-multicast-addr "224.0.1.129")        ; PTP primary (event)
(define pdelay-ipv4-multicast-addr "224.0.0.107") ; PTP peer delay

;; ---- message types ---------------------------------------------------------

;; hasheq: type byte -> (cons name category)
(define message-types
  (hasheq #x00 (cons "Sync" 'event)
          #x01 (cons "Delay_Req" 'event)
          #x02 (cons "PDelay_Req" 'event)
          #x03 (cons "PDelay_Resp" 'event)
          #x04 (cons "Reserved-4" 'event)
          #x05 (cons "Reserved-5" 'event)
          #x06 (cons "Reserved-6" 'event)
          #x07 (cons "Reserved-7" 'event)
          #x08 (cons "Follow_Up" 'general)
          #x09 (cons "Delay_Resp" 'general)
          #x0A (cons "PDelay_Resp_Follow_Up" 'general)
          #x0B (cons "Announce" 'general)
          #x0C (cons "Signalling" 'general)
          #x0D (cons "Management" 'general)))

(define (message-type-name t)
  (cond
    [(hash-ref message-types t #f) => car]
    [else (format "Unknown-0x~x" t)]))

(define (message-type-category t)
  (cond
    [(hash-ref message-types t #f) => cdr]
    [else 'unknown]))

(define (all-message-types)
  (for/list ([t (in-list '(#x00 #x01 #x02 #x03 #x08 #x09 #x0A #x0B #x0C #x0D))])
    (hasheq 'type t 'name (message-type-name t))))

;; ---- header flags (16-bit big-endian bitfield) ------------------------------

(define header-flag-table
  (list (cons #x0001 "leap61")
        (cons #x0002 "leap59")
        (cons #x0004 "currentUtcOffsetValid")
        (cons #x0008 "ptpTimescale")
        (cons #x0010 "timeTraceable")
        (cons #x0020 "frequencyTraceable")
        (cons #x0400 "unicast")
        (cons #x0800 "twoStep")
        (cons #x1000 "alternateMasterFlag")))

(define (flag-names flags)
  (for/list ([pair (in-list header-flag-table)]
             #:when (not (zero? (bitwise-and flags (car pair)))))
    (cdr pair)))

;; ---- TLV types --------------------------------------------------------------

(define tlv-type-names
  (hasheq #x00 "MANAGEMENT"
          #x01 "MANAGEMENT_ERROR_STATUS"
          #x02 "ORGANIZATION_EXTENSION"
          #x03 "REQUEST_UNICAST_TRANSMISSION"
          #x04 "GRANT_UNICAST_TRANSMISSION"
          #x05 "CANCEL_UNICAST_TRANSMISSION"
          #x06 "ACKNOWLEDGE_CANCEL_UNICAST_TRANSMISSION"
          #x08 "PATH_TRACE"
          #x09 "ALTERNATE_TIME_OFFSET_INDICATOR"
          #x0C "AUTHENTICATION"
          #x1F "L1_SYNC"
          #x20 "PORT_COMMUNICATION_AVAILABILITY"))

(define (tlv-type-name t)
  (hash-ref tlv-type-names t (format "Unknown-0x~x" t)))

;; The 802.1AS organization-extension subtype carried in Follow_Up
;; (org id 00:1B:19 = IEEE 802.1, subtype 1 = follow-up information).
(define gptp-follow-up-info-tlv-subtype 1)

;; ---- port states ------------------------------------------------------------

;; Values follow ptp4l / pmc textual states (idx matches pmc's portState).
(define port-states
  (vector "INITIALIZING" "LISTENING" "PASSIVE" "UNCALIBRATED"
          "FAULTY" "DISABLED" "PRE_MASTER" "MASTER" "GRAND_MASTER"
          "SLAVE" "UNDEFINED"))

(define (port-state-name idx)
  (cond
    [(string? idx) idx]                 ; already a name (802.1AS names)
    [(and (integer? idx) (>= idx 0) (< idx (vector-length port-states)))
     (vector-ref port-states idx)]
    [else (format "UNKNOWN(~a)" idx)]))

;; ---- clock classes ----------------------------------------------------------

(define (clock-class-hint class)
  (cond
    [(<= class 5) "locked to primary reference (atomic/GNSS)"]
    [(<= class 6) "holdover within spec (primary ref)"]
    [(and (>= class 7) (<= class 31)) "application-specific (locked)"]
    [(and (>= class 32) (<= class 47)) "holdover, application-specific"]
    [(and (>= class 48) (<= class 51)) "IEEE 1588 profile network"]
    [(and (>= class 52) (<= class 127)) "reserved"]
    [(and (>= class 128) (<= class 191)) "application-specific (slave-only)"]
    [(= class 248) "default"]
    [(= class 255) "slave-only"]
    [else "reserved"]))

;; ---- timeSource values ------------------------------------------------------

(define time-source-names
  (hasheq #x10 "ATOMIC_CLOCK"
          #x20 "GPS"
          #x40 "RADIO_TIME"
          #x50 "PTP"
          #x60 "NTP"
          #x80 "HAND_SET"
          #x90 "OTHER"
          #xA0 "INTERNAL_OSCILLATOR"))

(define (time-source-name v)
  (hash-ref time-source-names v (format "UNKNOWN(0x~x)" v)))
