#lang racket/base

;; Capture layer tests. Only the safe, permission-free paths are asserted in
;; automated runs: file format roundtrips (classic + pcapng), the packet
;; store, and graceful error paths of the libpcap FFI. Real-device capture
;; needs root/BPF access and is exercised by the manual self-check instead.

(require rackunit
         racket/file
         racket/list
         racket/promise
         "../capture/pcap-io.rkt"
         "../capture/store.rkt"
         "../capture/live.rkt"
         "../proto/encode.rkt"
         "../proto/decode.rkt")

;; ---- pcap file roundtrip -----------------------------------------------------

(define frame1 (build-ethernet-frame
                (build-ptp-message #x00 (hasheq 'sequence-id 1) (timestamp->bytes 10 100))))
(define frame2 (build-ethernet-frame
                (build-ptp-message #x0B (hasheq 'sequence-id 2) (make-bytes 20))))

(define frames
  (list (list 1000.000001 (bytes-length frame1) (bytes-length frame1) frame1)
        (list 1000.125000 (bytes-length frame2) (bytes-length frame2) frame2)))

(define tmp (make-temporary-file "capture-~a.pcap"))
(write-capture-file tmp frames)
(check-equal? (capture-file-format tmp) 'pcap-le)
(define-values (r1 lt) (read-capture-file tmp))
(check-equal? (length r1) 2)
(check-equal? lt 1) ; LINKTYPE_ETHERNET
(check-equal? (list-ref (first r1) 0) 1000.000001)
(check-equal? (list-ref (first r1) 3) frame1)
(check-equal? (list-ref (second r1) 0) 1000.125)
(check-equal? (list-ref (second r1) 3) frame2)
(delete-file tmp)

;; captured frames decode back as PTP
(define f (decode-frame (list-ref (first r1) 3)))
(check-true (hash-ref f 'is_ptp))

;; ---- pcapng parse (hand-built minimal file) ---------------------------------

;; SHB (28 bytes) + IDB (20) + EPB with one frame (48) + IDB opts carrying
;; if_tsresol=6 (microsecond is default; use power-of-2 = 64us to prove the
;; option parse) — keep the default resolution but verify block skipping.
(define shb
  (bytes-append #"\x50\x0D\x0D\x0A"              ; block type 0x0A0D0D50, little-endian
                (bytes 28 0 0 0)                 ; total length (LE)
                #"\x4D\x3C\x2B\x1A"              ; byte-order magic 0x1A2B3C4D, LE
                (bytes 1 0)                      ; version major (u16)
                (bytes 0 0)                      ; version minor (u16)
                (bytes #xFF #xFF #xFF #xFF #xFF #xFF #xFF #xFF) ; section length -1 (i64)
                (bytes 28 0 0 0)))
(define idb
  (bytes-append (bytes 1 0 0 0)                  ; IDB
                (bytes 24 0 0 0)                 ; total length
                (bytes 1 0 0 0)                  ; linktype ethernet
                (bytes 0 0 0 0)                  ; reserved
                (bytes 0 0 #x00 0)               ; snaplen
                (bytes 24 0 0 0)))               ; trailing total
(define pkt (build-ethernet-frame
             (build-ptp-message #x02 (hasheq 'sequence-id 9) (make-bytes 20))))
(define epb
  (let* ([caplen (bytes-length pkt)]
         [pad (- (* 4 (ceiling (/ caplen 4))) caplen)]
         [body-len (+ 20 caplen pad)] ; ifid..origlen = 20 bytes between the length fields
         [total (+ body-len 12)]) ; + type(4) + both total-length fields(4+4)
    (bytes-append (bytes 6 0 0 0)
                  (integer->integer-bytes total 4 #f #f)
                  (bytes 0 0 0 0)              ; interface id
                  (bytes 0 0 0 0)              ; ts high
                  (bytes #xA0 #x86 #x01 0)     ; ts low = 100000 (LE)
                  (integer->integer-bytes caplen 4 #f #f)
                  (integer->integer-bytes caplen 4 #f #f)
                  pkt
                  (make-bytes pad)
                  (integer->integer-bytes total 4 #f #f))))

(define tmp2 (make-temporary-file "capture-~a.pcapng"))
(call-with-output-file tmp2
  (lambda (out) (write-bytes (bytes-append shb idb epb) out))
  #:exists 'replace)
(check-equal? (capture-file-format tmp2) 'pcapng-le)
(define-values (r2 lt2) (read-capture-file tmp2))
(check-equal? (length r2) 1)
(check-equal? lt2 1)
;; ts = 100000 (ticks) * 1e-6 (default µs resolution) = 0.1s
(check-true (< (abs (- (list-ref (first r2) 0) 0.1)) 1e-6))
(define f2 (decode-frame (list-ref (first r2) 3)))
(check-equal? (hash-ref (hash-ref f2 'ptp) 'sequence_id) 9)
(delete-file tmp2)

;; ---- packet store ------------------------------------------------------------

(define store (make-packet-store 3))
(for ([i (in-range 5)])
  (packet-store-push! store (hasheq 'seq i)))
(check-equal? (packet-store-count store) 3)     ; ring capped
(define-values (stored total) (packet-store-stats store))
(check-equal? total 5)                          ; total counts everything
(define snap (packet-store-snapshot store))
(check-equal? (map (lambda (f) (hash-ref f 'seq)) snap) (list 4 3 2)) ; newest first
(check-equal? (map (lambda (f) (hash-ref f 'index)) snap) (list 0 1 2))
(packet-store-clear! store)
(check-equal? (packet-store-count store) 0)
(define-values (stored2 total2) (packet-store-stats store))
(check-equal? total2 5)

;; ---- libpcap FFI: graceful paths ---------------------------------------------

(check-true (capture-supported?))

(define-values (cap err) (capture-open "gptp-studio-no-such-iface"))
(check-false cap)
(check-true (string? err))
(check-true (> (string-length err) 0))
