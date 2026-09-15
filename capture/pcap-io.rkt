#lang racket/base

;; pcap / pcapng file I/O for offline analysis and exports.
;;
;; Read: classic libpcap (both endiannesses, micro + nano resolution) and
;; pcapng (SHB/IDB/EPB blocks — what Wireshark writes by default). Files are
;; parsed in memory with an explicit cursor, so truncated or corrupt files
;; degrade to "whatever frames parsed" instead of hanging.
;;
;; Frames are (list ts-seconds caplen orig-len bytes).

(require racket/bytes
         racket/file
         racket/match)

(provide read-capture-file
         write-capture-file
         capture-file-format)

(define max-parse-bytes (* 512 1024 1024)) ; refuse >512 MB inputs

;; ---- read dispatch ----------------------------------------------------------

(define (capture-file-format path)
  (call-with-input-file path
    (lambda (in)
      (define m (peek-bytes 4 0 in))
      (cond
        [(equal? m #"\xD4\xC3\xB2\xA1") 'pcap-le]
        [(equal? m #"\xA1\xB2\xC3\xD4") 'pcap-be]
        [(equal? m #"\x4D\x3C\xB2\xA1") 'pcap-nano-le]
        [(equal? m #"\xA1\xB2\x3C\x4D") 'pcap-nano-be]
        [(equal? m #"\x50\x0D\x0D\x0A") 'pcapng-le]
        [(equal? m #"\x0A\x0D\x0D\x50") 'pcapng-be]
        [else 'unknown]))))

;; Returns (values frames linktype); raises exn:fail on an unreadable file.
(define (read-capture-file path)
  (unless (file-exists? path)
    (raise (exn:fail "文件不存在" (current-continuation-marks))))
  (when (> (file-size path) max-parse-bytes)
    (raise (exn:fail "文件超过 512 MB 解析上限" (current-continuation-marks))))
  (define data (file->bytes path))
  (case (capture-file-format path)
    [(pcap-le pcap-be pcap-nano-le pcap-nano-be)
     (parse-classic-pcap data)]
    [(pcapng-le pcapng-be)
     (parse-pcapng data)]
    [else (raise (exn:fail "无法识别的抓包文件格式（支持 pcap 与 pcapng）"
                           (current-continuation-marks)))]))

;; ---- cursor helpers ----------------------------------------------------------

(define (u16-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 2)))
(define (u32-at bs off big?)
  (integer-bytes->integer bs #f big? off (+ off 4)))

;; ---- classic pcap ------------------------------------------------------------

(define (parse-classic-pcap bs)
  (define big? (= (bytes-ref bs 0) #xA1))
  (define nano? (= (bytes-ref bs 3) #x4D))
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
              [(> incl-len (max snaplen 262144)) (reverse acc)] ; resync stop
              [(> (+ data-off incl-len) (bytes-length bs)) (reverse acc)]
              [else
               (loop (+ data-off incl-len)
                     (cons (list (+ ts-sec (/ ts-frac (if nano? 1000000000.0 1000000.0)))
                                 incl-len orig-len
                                 (subbytes bs data-off (+ data-off incl-len)))
                           acc))])))))
  (values frames linktype))

;; ---- pcapng ------------------------------------------------------------------

;; Scan IDB options for if_tsresol (option code 9). Returns the resolution
;; in seconds per timestamp tick.
(define (scan-idb-tsresol bs start end big?)
  (let scan ([p start])
    (if (> (+ p 4) end)
        1e-6
        (let ([code (integer-bytes->integer bs #f big? p (+ p 2))]
              [olen (integer-bytes->integer bs #f big? (+ p 2) (+ p 4))])
          (cond
            [(= code 0) 1e-6] ; opt_endofopt
            [(and (= code 9) (>= olen 1))
             (define resol (bytes-ref bs (+ p 4)))
             (if (> resol 128)
                 (expt 2 (- resol 128))
                 (expt 10 (- 255 resol)))]
            [else (scan (+ p 4 (* 4 (ceiling (/ olen 4)))))])))))

(define (parse-pcapng bs)
  (define big? (equal? (subbytes bs 8 12) #"\x1A\x2B\x3C\x4D"))
  (define total (bytes-length bs))
  ;; state carried across blocks
  (define ts-resol (box 1e-6))
  (define linktype-box (box 1))
  (define frames
    (let loop ([pos 0] [acc '()])
      (cond
        [(> (+ pos 12) total) (reverse acc)]
        [else
         ;; pcapng layout: [pos]=block type, [pos+4]=block total length
         (define type (u32-at bs pos big?))
         (define block-len (u32-at bs (+ pos 4) big?))
         (cond
           [(or (< block-len 12) (> (+ pos block-len) total)) (reverse acc)]
           [else
            (case type
              [(#x00000001) ; interface description block
               (when (>= block-len 20)
                 (set-box! linktype-box
                           (bitwise-and (u32-at bs (+ pos 8) big?) #xFFFF))
                 (set-box! ts-resol
                           (scan-idb-tsresol bs (+ pos 20) (+ pos block-len -4) big?)))]
              [(#x00000006) ; enhanced packet block
               (when (>= block-len 32)
                 (define ts-high (u32-at bs (+ pos 12) big?))
                 (define ts-low (u32-at bs (+ pos 16) big?))
                 (define caplen (u32-at bs (+ pos 20) big?))
                 (define orig-len (u32-at bs (+ pos 24) big?))
                 (when (<= (+ 28 caplen) block-len)
                   (define raw (+ (* ts-high 4294967296) ts-low))
                   (set! acc
                         (cons (list (* raw (unbox ts-resol)) caplen orig-len
                                     (subbytes bs (+ pos 28) (+ pos 28 caplen)))
                               acc))))]
              [else (void)])
            (loop (+ pos block-len) acc)])])))
  (values frames (unbox linktype-box)))

;; ---- write classic pcap ------------------------------------------------------

(define (write-capture-file path frames)
  (call-with-output-file path
    (lambda (out)
      (write-bytes #"\xD4\xC3\xB2\xA1" out) ; little-endian magic
      (write-bytes (bytes 2 4 0 0) out)     ; version 2.4
      (write-bytes (bytes 0 0 0 0) out)     ; thiszone
      (write-bytes (bytes 0 0 0 0) out)     ; sigfigs
      (write-bytes (integer->integer-bytes 262144 4 #f #f) out) ; snaplen
      (write-bytes (integer->integer-bytes 1 4 #f #f) out)      ; LINKTYPE_ETHERNET
      (for ([f (in-list frames)])
        (match-define (list ts caplen orig-len data) f)
        (define sec (inexact->exact (floor ts)))
        (define usec (inexact->exact (floor (+ (* (- ts (exact->inexact sec)) 1000000) 0.5))))
        (write-bytes (integer->integer-bytes sec 4 #f #f) out)
        (write-bytes (integer->integer-bytes usec 4 #f #f) out)
        (write-bytes (integer->integer-bytes caplen 4 #f #f) out)
        (write-bytes (integer->integer-bytes orig-len 4 #f #f) out)
        (write-bytes data out)))
    #:exists 'replace))
