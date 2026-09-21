#lang racket/base

;; pcap / pcapng file I/O for offline analysis and exports.
;;
;; Compatibility: each frame still begins with the historical four fields
;;   (list display-seconds caplen orig-len bytes ...)
;; so existing callers continue to work. A fifth metadata hash now carries
;; exact timestamp components and capture-file timing semantics:
;;   ts_sec, ts_nsec, timestamp_precision, timestamp_resolution_num/den,
;;   interface_id and linktype.
;;
;; Precision-sensitive code must use the exact sec+nsec pair rather than the
;; display float. This avoids losing sub-microsecond detail at modern Unix
;; epoch magnitudes.

(require racket/bytes
         racket/file
         racket/match)

(provide read-capture-file
         write-capture-file
         capture-file-format)

(define max-parse-bytes (* 512 1024 1024))
(define pcapng-shb-magic #"\x0A\x0D\x0D\x0A")
(define default-pcapng-resolution (/ 1 1000000))

;; ---- read dispatch ----------------------------------------------------------

(define (capture-file-format path)
  (call-with-input-file path
    (lambda (in)
      (define m (peek-bytes 12 0 in))
      (define first4 (and (bytes? m) (>= (bytes-length m) 4) (subbytes m 0 4)))
      (cond
        [(equal? first4 #"\xD4\xC3\xB2\xA1") 'pcap-le]
        [(equal? first4 #"\xA1\xB2\xC3\xD4") 'pcap-be]
        [(equal? first4 #"\x4D\x3C\xB2\xA1") 'pcap-nano-le]
        [(equal? first4 #"\xA1\xB2\x3C\x4D") 'pcap-nano-be]
        [(and (equal? first4 pcapng-shb-magic)
              (>= (bytes-length m) 12))
         (cond
           [(equal? (subbytes m 8 12) #"\x1A\x2B\x3C\x4D") 'pcapng-be]
           [(equal? (subbytes m 8 12) #"\x4D\x3C\x2B\x1A") 'pcapng-le]
           [else 'unknown])]
        [else 'unknown]))))

(define (read-capture-file path)
  (unless (file-exists? path)
    (raise (exn:fail "文件不存在" (current-continuation-marks))))
  (when (> (file-size path) max-parse-bytes)
    (raise (exn:fail "文件超过 512 MB 解析上限" (current-continuation-marks))))
  (define data (file->bytes path))
  (define fmt (capture-file-format path))
  (case fmt
    [(pcap-le pcap-be pcap-nano-le pcap-nano-be)
     (parse-classic-pcap data fmt)]
    [(pcapng-le pcapng-be)
     (parse-pcapng data)]
    [else
     (raise (exn:fail "无法识别的抓包文件格式（支持 pcap 与 pcapng）"
                      (current-continuation-marks)))]))

;; ---- exact timestamp helpers ------------------------------------------------

(define (timestamp->display sec nsec)
  (+ (exact->inexact sec) (/ nsec 1000000000.0)))

(define (resolution-label r)
  (cond
    [(= r (/ 1 1000000000)) "nano"]
    [(= r (/ 1 1000000)) "micro"]
    [(< r (/ 1 1000000)) "submicro-custom"]
    [else "custom"]))

(define (exact-time->parts exact-seconds)
  (define sec0 (floor exact-seconds))
  (define nsec0 (round (* (- exact-seconds sec0) 1000000000)))
  (if (>= nsec0 1000000000)
      (values (add1 sec0) 0)
      (values sec0 nsec0)))

(define (make-frame sec nsec caplen orig-len data
                    #:resolution resolution
                    #:interface-id [interface-id 0]
                    #:linktype [linktype 1]
                    #:ticks [ticks #f])
  (list (timestamp->display sec nsec)
        caplen
        orig-len
        data
        (hasheq 'ts_sec sec
                'ts_nsec nsec
                'timestamp_precision (resolution-label resolution)
                'timestamp_resolution_num (numerator resolution)
                'timestamp_resolution_den (denominator resolution)
                'timestamp_ticks ticks
                'interface_id interface-id
                'linktype linktype)))

(define (frame-meta f)
  (and (>= (length f) 5) (hash? (list-ref f 4)) (list-ref f 4)))

(define (frame-exact-parts f)
  (define meta (frame-meta f))
  (cond
    [(and meta
          (exact-integer? (hash-ref meta 'ts_sec #f))
          (exact-integer? (hash-ref meta 'ts_nsec #f)))
     (values (hash-ref meta 'ts_sec) (hash-ref meta 'ts_nsec))]
    [else
     (define ts (list-ref f 0))
     (define sec (inexact->exact (floor ts)))
     (define nsec
       (inexact->exact
        (round (* (- ts (exact->inexact sec)) 1000000000.0))))
     (if (>= nsec 1000000000)
         (values (add1 sec) 0)
         (values sec nsec))]))

;; ---- cursor helpers ----------------------------------------------------------

(define (u16-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 2)))

(define (u32-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 4)))

;; ---- classic pcap ------------------------------------------------------------

(define (parse-classic-pcap bs fmt)
  (define big? (memq fmt '(pcap-be pcap-nano-be)))
  (define nano? (memq fmt '(pcap-nano-le pcap-nano-be)))
  (define resolution (if nano? (/ 1 1000000000) (/ 1 1000000)))
  (define snaplen (u32-at bs 16 big?))
  (define linktype (bitwise-and (u32-at bs 20 big?) #xFFFF))
  (define frames
    (let loop ([pos 24] [acc '()])
      (if (> (+ pos 16) (bytes-length bs))
          (reverse acc)
          (let* ([ts-sec (u32-at bs pos big?)]
                 [ts-frac (u32-at bs (+ pos 4) big?)]
                 [incl-len (u32-at bs (+ pos 8) big?)]
                 [orig-len (u32-at bs (+ pos 12) big?)]
                 [data-off (+ pos 16)])
            (cond
              [(> incl-len (max snaplen 262144)) (reverse acc)]
              [(> (+ data-off incl-len) (bytes-length bs)) (reverse acc)]
              [else
               (define nsec (if nano? ts-frac (* ts-frac 1000)))
               (loop (+ data-off incl-len)
                     (cons (make-frame ts-sec nsec incl-len orig-len
                                       (subbytes bs data-off (+ data-off incl-len))
                                       #:resolution resolution
                                       #:linktype linktype
                                       #:ticks (+ (* ts-sec (denominator resolution)) ts-frac))
                           acc))])))))
  (values frames linktype))

;; ---- pcapng ------------------------------------------------------------------

;; if_tsresol (option 9): high bit clear means 10^-N seconds; high bit set
;; means 2^-(N & 0x7f) seconds. Keep the result exact.
(define (tsresol-byte->resolution raw)
  (define exponent (bitwise-and raw #x7F))
  (if (zero? (bitwise-and raw #x80))
      (/ 1 (expt 10 exponent))
      (/ 1 (expt 2 exponent))))

(define (scan-idb-tsresol bs start end big?)
  (let scan ([p start])
    (cond
      [(> (+ p 4) end) default-pcapng-resolution]
      [else
       (define code (u16-at bs p big?))
       (define olen (u16-at bs (+ p 2) big?))
       (define payload-start (+ p 4))
       (define payload-end (+ payload-start olen))
       (cond
         [(= code 0) default-pcapng-resolution]
         [(> payload-end end) default-pcapng-resolution]
         [(and (= code 9) (>= olen 1))
          (tsresol-byte->resolution (bytes-ref bs payload-start))]
         [else
          (scan (+ p 4 (* 4 (ceiling (/ olen 4)))))] )]))

(define (shb-at? bs pos)
  (and (<= (+ pos 4) (bytes-length bs))
       (equal? (subbytes bs pos (+ pos 4)) pcapng-shb-magic)))

(define (shb-big-endian? bs pos fallback)
  (if (<= (+ pos 12) (bytes-length bs))
      (cond
        [(equal? (subbytes bs (+ pos 8) (+ pos 12)) #"\x1A\x2B\x3C\x4D") #t]
        [(equal? (subbytes bs (+ pos 8) (+ pos 12)) #"\x4D\x3C\x2B\x1A") #f]
        [else fallback])
      fallback))

(define (parse-pcapng bs)
  (define total (bytes-length bs))
  (define current-big? (box #f))
  ;; Interface IDs are scoped to a section and assigned by IDB order.
  ;; value: (cons linktype exact-resolution)
  (define interfaces (make-hash))
  (define next-interface 0)
  (define first-linktype (box 1))

  (define frames
    (let loop ([pos 0] [acc '()])
      (cond
        [(> (+ pos 12) total) (reverse acc)]
        [else
         (define is-shb? (shb-at? bs pos))
         (define block-big?
           (if is-shb?
               (shb-big-endian? bs pos (unbox current-big?))
               (unbox current-big?)))
         (define type (if is-shb? #x0A0D0D0A (u32-at bs pos block-big?)))
         (define block-len (u32-at bs (+ pos 4) block-big?))
         (cond
           [(or (< block-len 12) (> (+ pos block-len) total)) (reverse acc)]
           [else
            (case type
              [(#x0A0D0D0A)
               (set-box! current-big? block-big?)
               (hash-clear! interfaces)
               (set! next-interface 0)]
              [(#x00000001)
               ;; IDB fixed body is 8 bytes after the block header:
               ;; linktype(2), reserved(2), snaplen(4). Options begin at +16.
               (when (>= block-len 20)
                 (define linktype (u16-at bs (+ pos 8) block-big?))
                 (define resolution
                   (scan-idb-tsresol bs (+ pos 16) (+ pos block-len -4) block-big?))
                 (hash-set! interfaces next-interface (cons linktype resolution))
                 (when (zero? next-interface) (set-box! first-linktype linktype))
                 (set! next-interface (add1 next-interface)))]
              [(#x00000006)
               (when (>= block-len 32)
                 (define interface-id (u32-at bs (+ pos 8) block-big?))
                 (define ts-high (u32-at bs (+ pos 12) block-big?))
                 (define ts-low (u32-at bs (+ pos 16) block-big?))
                 (define caplen (u32-at bs (+ pos 20) block-big?))
                 (define orig-len (u32-at bs (+ pos 24) block-big?))
                 (define data-start (+ pos 28))
                 (define data-end (+ data-start caplen))
                 (when (<= data-end (+ pos block-len -4))
                   (define iface-info
                     (hash-ref interfaces interface-id
                               (cons (unbox first-linktype) default-pcapng-resolution)))
                   (define linktype (car iface-info))
                   (define resolution (cdr iface-info))
                   (define ticks (+ (* ts-high 4294967296) ts-low))
                   (define exact-time (* ticks resolution))
                   (define-values (sec nsec) (exact-time->parts exact-time))
                   (set! acc
                         (cons (make-frame sec nsec caplen orig-len
                                           (subbytes bs data-start data-end)
                                           #:resolution resolution
                                           #:interface-id interface-id
                                           #:linktype linktype
                                           #:ticks ticks)
                               acc))))]
              [else (void)])
            (loop (+ pos block-len) acc)])])))
  (values frames (unbox first-linktype)))

;; ---- write classic pcap ------------------------------------------------------

(define (frame-needs-nano? f)
  (define meta (frame-meta f))
  (define-values (_sec nsec) (frame-exact-parts f))
  (or (and meta (equal? (hash-ref meta 'timestamp_precision #f) "nano"))
      (not (zero? (remainder nsec 1000)))))

(define (write-capture-file path frames)
  (define nano? (ormap frame-needs-nano? frames))
  (call-with-output-file path
    (lambda (out)
      ;; little-endian classic pcap. Nano magic preserves exact packet time when
      ;; any frame carries sub-microsecond information.
      (write-bytes (if nano? #"\x4D\x3C\xB2\xA1" #"\xD4\xC3\xB2\xA1") out)
      (write-bytes (bytes 2 4 0 0) out)
      (write-bytes (bytes 0 0 0 0) out)
      (write-bytes (bytes 0 0 0 0) out)
      (write-bytes (integer->integer-bytes 262144 4 #f #f) out)
      (write-bytes (integer->integer-bytes 1 4 #f #f) out)
      (for ([f (in-list frames)])
        (define caplen (list-ref f 1))
        (define orig-len (list-ref f 2))
        (define data (list-ref f 3))
        (define-values (sec nsec) (frame-exact-parts f))
        (define fraction
          (if nano?
              nsec
              (quotient (+ nsec 500) 1000)))
        (define-values (sec* fraction*)
          (if (>= fraction (if nano? 1000000000 1000000))
              (values (add1 sec) 0)
              (values sec fraction)))
        (write-bytes (integer->integer-bytes sec* 4 #f #f) out)
        (write-bytes (integer->integer-bytes fraction* 4 #f #f) out)
        (write-bytes (integer->integer-bytes caplen 4 #f #f) out)
        (write-bytes (integer->integer-bytes orig-len 4 #f #f) out)
        (write-bytes data out)))
    #:exists 'replace))
