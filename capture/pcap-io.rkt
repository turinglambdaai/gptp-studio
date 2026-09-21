#lang racket/base

;; pcap / pcapng file I/O for offline analysis and export.
;;
;; Frames keep the historical first four values for compatibility:
;;   (list display-seconds caplen orig-len bytes metadata)
;; The optional fifth value carries exact timestamp metadata. Precision-aware
;; code must use ts_sec + ts_nsec instead of the display float.

(require racket/bytes
         racket/file
         racket/list)

(provide read-capture-file
         write-capture-file
         capture-file-format)

(define max-parse-bytes (* 512 1024 1024))
(define pcapng-shb-magic #"\x0A\x0D\x0D\x0A")
(define default-pcapng-resolution (/ 1 1000000))

;; ---- format detection -------------------------------------------------------

(define (capture-file-format path)
  (call-with-input-file path
    (lambda (in)
      (define raw (peek-bytes 12 0 in))
      (define first4
        (and (bytes? raw)
             (>= (bytes-length raw) 4)
             (subbytes raw 0 4)))
      (cond
        [(equal? first4 #"\xD4\xC3\xB2\xA1") 'pcap-le]
        [(equal? first4 #"\xA1\xB2\xC3\xD4") 'pcap-be]
        [(equal? first4 #"\x4D\x3C\xB2\xA1") 'pcap-nano-le]
        [(equal? first4 #"\xA1\xB2\x3C\x4D") 'pcap-nano-be]
        [(and (equal? first4 pcapng-shb-magic)
              (>= (bytes-length raw) 12))
         (cond
           [(equal? (subbytes raw 8 12) #"\x1A\x2B\x3C\x4D") 'pcapng-be]
           [(equal? (subbytes raw 8 12) #"\x4D\x3C\x2B\x1A") 'pcapng-le]
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

;; ---- timestamp helpers ------------------------------------------------------

(define (timestamp->display sec nsec)
  (+ (exact->inexact sec) (/ nsec 1000000000.0)))

(define (resolution-label resolution)
  (cond
    [(= resolution (/ 1 1000000000)) "nano"]
    [(= resolution (/ 1 1000000)) "micro"]
    [(< resolution (/ 1 1000000)) "submicro-custom"]
    [else "custom"]))

(define (exact-time->parts exact-seconds)
  (define sec (floor exact-seconds))
  (define nsec (round (* (- exact-seconds sec) 1000000000)))
  (if (>= nsec 1000000000)
      (values (add1 sec) 0)
      (values sec nsec)))

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

(define (frame-meta frame)
  (and (>= (length frame) 5)
       (hash? (list-ref frame 4))
       (list-ref frame 4)))

(define (frame-exact-parts frame)
  (define meta (frame-meta frame))
  (cond
    [(and meta
          (exact-integer? (hash-ref meta 'ts_sec #f))
          (exact-integer? (hash-ref meta 'ts_nsec #f)))
     (values (hash-ref meta 'ts_sec)
             (hash-ref meta 'ts_nsec))]
    [else
     (define ts (list-ref frame 0))
     (define sec (inexact->exact (floor ts)))
     (define nsec
       (inexact->exact
        (round (* (- ts (exact->inexact sec)) 1000000000.0))))
     (if (>= nsec 1000000000)
         (values (add1 sec) 0)
         (values sec nsec))]))

;; ---- integer helpers --------------------------------------------------------

(define (u16-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 2)))

(define (u32-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 4)))

;; ---- classic pcap -----------------------------------------------------------

(define (parse-classic-pcap bs fmt)
  (define big? (and (memq fmt '(pcap-be pcap-nano-be)) #t))
  (define nano? (and (memq fmt '(pcap-nano-le pcap-nano-be)) #t))
  (define resolution (if nano? (/ 1 1000000000) (/ 1 1000000)))
  (define snaplen (u32-at bs 16 big?))
  (define linktype (bitwise-and (u32-at bs 20 big?) #xFFFF))

  (define frames
    (let loop ([pos 24] [acc '()])
      (cond
        [(> (+ pos 16) (bytes-length bs)) (reverse acc)]
        [else
         (define ts-sec (u32-at bs pos big?))
         (define ts-frac (u32-at bs (+ pos 4) big?))
         (define incl-len (u32-at bs (+ pos 8) big?))
         (define orig-len (u32-at bs (+ pos 12) big?))
         (define data-off (+ pos 16))
         (cond
           [(> incl-len (max snaplen 262144)) (reverse acc)]
           [(> (+ data-off incl-len) (bytes-length bs)) (reverse acc)]
           [else
            (define nsec (if nano? ts-frac (* ts-frac 1000)))
            (define frame
              (make-frame ts-sec nsec incl-len orig-len
                          (subbytes bs data-off (+ data-off incl-len))
                          #:resolution resolution
                          #:linktype linktype
                          #:ticks (+ (* ts-sec (denominator resolution)) ts-frac)))
            (loop (+ data-off incl-len) (cons frame acc))])]))))
  (values frames linktype))

;; ---- pcapng -----------------------------------------------------------------

;; if_tsresol option 9:
;;   bit7 clear -> units are 10^-N seconds
;;   bit7 set   -> units are 2^-(N & 0x7f) seconds
(define (tsresol-byte->resolution raw)
  (define exponent (bitwise-and raw #x7F))
  (if (zero? (bitwise-and raw #x80))
      (/ 1 (expt 10 exponent))
      (/ 1 (expt 2 exponent))))

(define (scan-idb-tsresol bs start end big?)
  (let scan ([pos start])
    (if (> (+ pos 4) end)
        default-pcapng-resolution
        (let* ([code (u16-at bs pos big?)]
               [option-len (u16-at bs (+ pos 2) big?)]
               [payload-start (+ pos 4)]
               [payload-end (+ payload-start option-len)])
          (cond
            [(= code 0) default-pcapng-resolution]
            [(> payload-end end) default-pcapng-resolution]
            [(and (= code 9) (>= option-len 1))
             (tsresol-byte->resolution (bytes-ref bs payload-start))]
            [else
             (define padded-len (* 4 (ceiling (/ option-len 4))))
             (scan (+ pos 4 padded-len))])))))

(define (shb-at? bs pos)
  (and (<= (+ pos 4) (bytes-length bs))
       (equal? (subbytes bs pos (+ pos 4)) pcapng-shb-magic)))

(define (shb-big-endian? bs pos fallback)
  (if (> (+ pos 12) (bytes-length bs))
      fallback
      (cond
        [(equal? (subbytes bs (+ pos 8) (+ pos 12)) #"\x1A\x2B\x3C\x4D") #t]
        [(equal? (subbytes bs (+ pos 8) (+ pos 12)) #"\x4D\x3C\x2B\x1A") #f]
        [else fallback])))

(define (parse-pcapng bs)
  (define total (bytes-length bs))
  (define current-big? #f)
  ;; Interface IDs are scoped to a section and assigned by IDB order.
  ;; value = (cons linktype exact-resolution)
  (define interfaces (make-hash))
  (define next-interface 0)
  (define first-linktype 1)

  (define (reset-section! big?)
    (set! current-big? big?)
    (hash-clear! interfaces)
    (set! next-interface 0))

  (define (handle-idb! pos block-len big?)
    (when (>= block-len 20)
      (define linktype (u16-at bs (+ pos 8) big?))
      ;; block header 8 + fixed IDB body 8 => options start at +16.
      (define resolution
        (scan-idb-tsresol bs (+ pos 16) (+ pos block-len -4) big?))
      (hash-set! interfaces next-interface (cons linktype resolution))
      (when (zero? next-interface)
        (set! first-linktype linktype))
      (set! next-interface (add1 next-interface))))

  (define (epb->frame pos block-len big?)
    (and
     (>= block-len 32)
     (let* ([interface-id (u32-at bs (+ pos 8) big?)]
            [ts-high (u32-at bs (+ pos 12) big?)]
            [ts-low (u32-at bs (+ pos 16) big?)]
            [caplen (u32-at bs (+ pos 20) big?)]
            [orig-len (u32-at bs (+ pos 24) big?)]
            [data-start (+ pos 28)]
            [data-end (+ data-start caplen)])
       (and
        (<= data-end (+ pos block-len -4))
        (let* ([iface-info
                (hash-ref interfaces interface-id
                          (cons first-linktype default-pcapng-resolution))]
               [linktype (car iface-info)]
               [resolution (cdr iface-info)]
               [ticks (+ (* ts-high 4294967296) ts-low)]
               [exact-time (* ticks resolution)])
          (define-values (sec nsec) (exact-time->parts exact-time))
          (make-frame sec nsec caplen orig-len
                      (subbytes bs data-start data-end)
                      #:resolution resolution
                      #:interface-id interface-id
                      #:linktype linktype
                      #:ticks ticks))))))

  (define frames
    (let loop ([pos 0] [acc '()])
      (cond
        [(> (+ pos 12) total) (reverse acc)]
        [else
         (define is-shb? (shb-at? bs pos))
         (define big?
           (if is-shb?
               (shb-big-endian? bs pos current-big?)
               current-big?))
         (define type (if is-shb? #x0A0D0D0A (u32-at bs pos big?)))
         (define block-len (u32-at bs (+ pos 4) big?))
         (cond
           [(or (< block-len 12) (> (+ pos block-len) total))
            (reverse acc)]
           [else
            (define next-acc
              (case type
                [(#x0A0D0D0A)
                 (reset-section! big?)
                 acc]
                [(#x00000001)
                 (handle-idb! pos block-len big?)
                 acc]
                [(#x00000006)
                 (define frame (epb->frame pos block-len big?))
                 (if frame (cons frame acc) acc)]
                [else acc]))
            (loop (+ pos block-len) next-acc)])])))

  (values frames first-linktype))

;; ---- classic pcap writer ----------------------------------------------------

(define (frame-needs-nano? frame)
  (define meta (frame-meta frame))
  (define-values (_sec nsec) (frame-exact-parts frame))
  (or (and meta (equal? (hash-ref meta 'timestamp_precision #f) "nano"))
      (not (zero? (remainder nsec 1000)))))

(define (write-capture-file path frames)
  (define nano? (ormap frame-needs-nano? frames))
  (call-with-output-file path
    (lambda (out)
      ;; little-endian classic pcap; choose nano magic only when required.
      (write-bytes (if nano? #"\x4D\x3C\xB2\xA1" #"\xD4\xC3\xB2\xA1") out)
      (write-bytes (bytes 2 4 0 0) out)
      (write-bytes (bytes 0 0 0 0) out)
      (write-bytes (bytes 0 0 0 0) out)
      (write-bytes (integer->integer-bytes 262144 4 #f #f) out)
      (write-bytes (integer->integer-bytes 1 4 #f #f) out)

      (for ([frame (in-list frames)])
        (define caplen (list-ref frame 1))
        (define orig-len (list-ref frame 2))
        (define data (list-ref frame 3))
        (define-values (sec nsec) (frame-exact-parts frame))
        (define fraction
          (if nano?
              nsec
              (quotient (+ nsec 500) 1000)))
        (define limit (if nano? 1000000000 1000000))
        (define carry? (>= fraction limit))
        (define sec* (if carry? (add1 sec) sec))
        (define fraction* (if carry? 0 fraction))
        (write-bytes (integer->integer-bytes sec* 4 #f #f) out)
        (write-bytes (integer->integer-bytes fraction* 4 #f #f) out)
        (write-bytes (integer->integer-bytes caplen 4 #f #f) out)
        (write-bytes (integer->integer-bytes orig-len 4 #f #f) out)
        (write-bytes data out)))
    #:exists 'replace))
