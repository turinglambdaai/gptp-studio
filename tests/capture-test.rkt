#lang racket/base

;; Capture layer tests cover permission-free correctness: classic pcap
;; micro/nano roundtrips, pcapng per-interface timestamp resolution, packet
;; storage, and graceful libpcap error paths. Real-device timestamp source
;; validation remains a hardware acceptance test.

(require rackunit
         racket/file
         racket/list
         "../capture/pcap-io.rkt"
         "../capture/store.rkt"
         "../capture/live.rkt"
         "../proto/encode.rkt"
         "../proto/decode.rkt")

(define frame1
  (build-ethernet-frame
   (build-ptp-message #x00 (hasheq 'sequence-id 1) (timestamp->bytes 10 100))))
(define frame2
  (build-ethernet-frame
   (build-ptp-message #x0B (hasheq 'sequence-id 2) (make-bytes 20))))

;; ---- classic pcap microsecond compatibility ---------------------------------

(define frames
  (list (list 1000.000001 (bytes-length frame1) (bytes-length frame1) frame1)
        (list 1000.125000 (bytes-length frame2) (bytes-length frame2) frame2)))

(define tmp (make-temporary-file "capture-~a.pcap"))
(write-capture-file tmp frames)
(check-equal? (capture-file-format tmp) 'pcap-le)
(define-values (r1 lt) (read-capture-file tmp))
(check-equal? (length r1) 2)
(check-equal? lt 1)
(check-= (list-ref (first r1) 0) 1000.000001 1e-9)
(check-equal? (hash-ref (list-ref (first r1) 4) 'ts_sec) 1000)
(check-equal? (hash-ref (list-ref (first r1) 4) 'ts_nsec) 1000)
(check-equal? (hash-ref (list-ref (first r1) 4) 'timestamp_precision) "micro")
(check-equal? (list-ref (first r1) 3) frame1)
(check-= (list-ref (second r1) 0) 1000.125 1e-9)
(check-equal? (list-ref (second r1) 3) frame2)
(delete-file tmp)

(define f (decode-frame (list-ref (first r1) 3)))
(check-true (hash-ref f 'is_ptp))

;; ---- classic pcap nanosecond preservation -----------------------------------

(define exact-meta
  (hasheq 'ts_sec 1700000000
          'ts_nsec 123456789
          'timestamp_precision "nano"))
(define nano-frame
  (list 1700000000.1234567
        (bytes-length frame1)
        (bytes-length frame1)
        frame1
        exact-meta))
(define tmp-nano (make-temporary-file "capture-nano-~a.pcap"))
(write-capture-file tmp-nano (list nano-frame))
(check-equal? (capture-file-format tmp-nano) 'pcap-nano-le)
(define-values (nano-read _nano-lt) (read-capture-file tmp-nano))
(define nano-meta (list-ref (first nano-read) 4))
(check-equal? (hash-ref nano-meta 'ts_sec) 1700000000)
(check-equal? (hash-ref nano-meta 'ts_nsec) 123456789)
(check-equal? (hash-ref nano-meta 'timestamp_precision) "nano")
(delete-file tmp-nano)

;; ---- pcapng exact per-interface timestamp resolution ------------------------

(define (u16le n) (integer->integer-bytes n 2 #f #f))
(define (u32le n) (integer->integer-bytes n 4 #f #f))

(define shb
  (bytes-append #"\x0A\x0D\x0D\x0A"
                (u32le 28)
                #"\x4D\x3C\x2B\x1A"
                (u16le 1)
                (u16le 0)
                (bytes #xFF #xFF #xFF #xFF #xFF #xFF #xFF #xFF)
                (u32le 28)))

;; IDB with if_tsresol option (code 9, length 1) and opt_endofopt.
(define (make-idb tsresol-byte)
  (define total 32)
  (bytes-append (u32le 1)
                (u32le total)
                (u16le 1)             ; LINKTYPE_ETHERNET
                (u16le 0)
                (u32le 65535)
                (u16le 9)
                (u16le 1)
                (bytes tsresol-byte 0 0 0)
                (u16le 0)
                (u16le 0)
                (u32le total)))

(define pkt
  (build-ethernet-frame
   (build-ptp-message #x02 (hasheq 'sequence-id 9) (make-bytes 20))))

(define (make-epb interface-id ticks payload)
  (define caplen (bytes-length payload))
  (define padded-len (* 4 (ceiling (/ caplen 4))))
  (define pad (- padded-len caplen))
  (define total (+ 32 padded-len))
  (define ts-high (quotient ticks 4294967296))
  (define ts-low (remainder ticks 4294967296))
  (bytes-append (u32le 6)
                (u32le total)
                (u32le interface-id)
                (u32le ts-high)
                (u32le ts-low)
                (u32le caplen)
                (u32le caplen)
                payload
                (make-bytes pad)
                (u32le total)))

;; Interface 0: decimal 10^-9, Interface 1: decimal 10^-6,
;; Interface 2: binary 2^-10. The EPBs prove each interface uses its own IDB.
(define idb-nano (make-idb 9))
(define idb-micro (make-idb 6))
(define idb-binary (make-idb #x8A))
(define epb-nano (make-epb 0 1234567890 pkt))     ; 1.234567890 s
(define epb-micro (make-epb 1 2500001 pkt))       ; 2.500001 s
(define epb-binary (make-epb 2 1536 pkt))         ; 1536 / 1024 = 1.5 s

(define tmp2 (make-temporary-file "capture-~a.pcapng"))
(call-with-output-file tmp2
  (lambda (out)
    (write-bytes
     (bytes-append shb
                   idb-nano idb-micro idb-binary
                   epb-nano epb-micro epb-binary)
     out))
  #:exists 'replace)

(check-equal? (capture-file-format tmp2) 'pcapng-le)
(define-values (r2 lt2) (read-capture-file tmp2))
(check-equal? (length r2) 3)
(check-equal? lt2 1)

(define m0 (list-ref (list-ref r2 0) 4))
(check-equal? (hash-ref m0 'interface_id) 0)
(check-equal? (hash-ref m0 'ts_sec) 1)
(check-equal? (hash-ref m0 'ts_nsec) 234567890)
(check-equal? (hash-ref m0 'timestamp_resolution_num) 1)
(check-equal? (hash-ref m0 'timestamp_resolution_den) 1000000000)

(define m1 (list-ref (list-ref r2 1) 4))
(check-equal? (hash-ref m1 'interface_id) 1)
(check-equal? (hash-ref m1 'ts_sec) 2)
(check-equal? (hash-ref m1 'ts_nsec) 500001000)
(check-equal? (hash-ref m1 'timestamp_resolution_den) 1000000)

(define m2 (list-ref (list-ref r2 2) 4))
(check-equal? (hash-ref m2 'interface_id) 2)
(check-equal? (hash-ref m2 'ts_sec) 1)
(check-equal? (hash-ref m2 'ts_nsec) 500000000)
(check-equal? (hash-ref m2 'timestamp_resolution_den) 1024)

(define f2 (decode-frame (list-ref (first r2) 3)))
(check-equal? (hash-ref (hash-ref f2 'ptp) 'sequence_id) 9)
(delete-file tmp2)

;; ---- packet store ------------------------------------------------------------

(define store (make-packet-store 3))
(for ([i (in-range 5)])
  (packet-store-push! store (hasheq 'seq i)))
(check-equal? (packet-store-count store) 3)
(define-values (_stored total) (packet-store-stats store))
(check-equal? total 5)
(define snap (packet-store-snapshot store))
(check-equal? (map (lambda (x) (hash-ref x 'seq)) snap) (list 4 3 2))
(check-equal? (map (lambda (x) (hash-ref x 'index)) snap) (list 0 1 2))
(packet-store-clear! store)
(check-equal? (packet-store-count store) 0)
(define-values (_stored2 total2) (packet-store-stats store))
(check-equal? total2 5)

;; ---- libpcap FFI: graceful paths ---------------------------------------------

(check-true (capture-supported?))
(define-values (cap err) (capture-open "gptp-studio-no-such-iface"))
(check-false cap)
(check-true (string? err))
(check-true (> (string-length err) 0))
