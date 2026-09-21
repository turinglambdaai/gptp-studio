#lang racket/base

;; Live capture over libpcap via Racket FFI.
;;
;; Timestamp rules are deliberately conservative:
;; - request nanosecond *resolution* when libpcap supports it;
;; - prefer adapter/device timestamps when libpcap explicitly advertises them;
;; - otherwise record the actual selected source as host/default;
;; - keep sec+nsec as exact integers all the way out of this module.
;;
;; A NIC advertising IEEE 1588 hardware timestamping does NOT prove that a
;; libpcap handle is currently delivering adapter timestamps. The capture
;; object therefore records the source selected by libpcap independently from
;; NIC capability detection.

(require ffi/unsafe
         ffi/unsafe/define
         racket/format
         racket/list
         racket/string)

(provide capture-supported?
         capture-open
         capture-close
         capture-poll!
         capture-open?
         capture-handle
         capture-iface
         capture-timestamp-source
         capture-timestamp-precision)

(define pcap-lib (ffi-lib "libpcap" '("1" ".1" "")))
(define-ffi-definer define-pcap pcap-lib)

(define _pcap_t (_cpointer/null 'pcap_t))

(define PCAP_ERRBUF_SIZE 256)
(define DLT_EN10MB 1)
(define PCAP_TSTAMP_PRECISION_MICRO 0)
(define PCAP_TSTAMP_PRECISION_NANO 1)
(define PCAP_TSTAMP_HOST 0)
(define PCAP_TSTAMP_HOST_HIPREC 2)
(define PCAP_TSTAMP_ADAPTER 3)

;; pcap_pkthdr begins with struct timeval. timeval fields are C `long`, not
;; fixed int64/int32. ptr-ref offsets are byte offsets only when `'abs` is used.
(define C-LONG-SIZE (ctype-sizeof _long))
(define PCAP-HDR-CAPLEN-OFF (* 2 C-LONG-SIZE))
(define PCAP-HDR-LEN-OFF (+ PCAP-HDR-CAPLEN-OFF 4))

(define-pcap pcap-create-raw (_fun _string _bytes -> _pcap_t)
  #:c-id pcap_create)
(define-pcap pcap_set_snaplen (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_promisc (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_timeout (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_immediate_mode (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_tstamp_precision (_fun _pcap_t _int -> _int))
(define-pcap pcap_get_tstamp_precision (_fun _pcap_t -> _int))
(define-pcap pcap_set_tstamp_type (_fun _pcap_t _int -> _int))
(define-pcap pcap_list_tstamp_types (_fun _pcap_t _pointer -> _int))
(define-pcap pcap_free_tstamp_types (_fun _pointer -> _void))

;; macOS ships the historical `pcap_setnonblock` spelling; Linux exports it
;; too, so this is the portable binding used by the nonblocking worker loop.
(define-pcap pcap-setnonblock-raw (_fun _pcap_t _int _bytes -> _int)
  #:c-id pcap_setnonblock)
(define-pcap pcap_activate (_fun _pcap_t -> _int))
(define-pcap pcap_close (_fun _pcap_t -> _void))
(define-pcap pcap_datalink (_fun _pcap_t -> _int))
(define-pcap pcap-geterr (_fun _pcap_t -> _string)
  #:c-id pcap_geterr)
(define-pcap pcap_compile (_fun _pcap_t _pointer _string _int _uint32 -> _int))
(define-pcap pcap_setfilter (_fun _pcap_t _pointer -> _int))
(define-pcap pcap_freecode (_fun _pointer -> _void))
(define-pcap pcap_next_ex (_fun _pcap_t
                                (hdr : (_ptr o _pointer))
                                (data : (_ptr o _pointer))
                                -> (r : _int)
                                -> (values r hdr data)))

(struct capture (handle iface filter-text bpf timestamp-source timestamp-precision))

(define (capture-supported?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and pcap-lib #t)))

(define (pcap-create iface)
  (define buf (make-bytes PCAP_ERRBUF_SIZE 0))
  (values buf (pcap-create-raw iface buf)))

(define (pcap-setnonblock h flag)
  (define buf (make-bytes PCAP_ERRBUF_SIZE 0))
  (values buf (pcap-setnonblock-raw h flag buf)))

(define (errbuf->string b)
  (define s (bytes->string/utf-8 b #\_ 0 (or (index-of b 0) (bytes-length b))))
  (if (string=? s "") "unknown libpcap error" s))

;; Return advertised libpcap timestamp type ids. Failure is not fatal; it just
;; means the source remains libpcap's default host timestamp path.
(define (available-tstamp-types h)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (define holder (malloc (ctype-sizeof _pointer) 'raw))
    (define count (pcap_list_tstamp_types h holder))
    (define result
      (if (> count 0)
          (let ([arr (ptr-ref holder _pointer 0 'abs)])
            (begin0
              (for/list ([i (in-range count)])
                (ptr-ref arr _int i))
              (pcap_free_tstamp_types arr)))
          '()))
    (free holder)
    result))

(define (select-timestamp-source! h)
  (define types (available-tstamp-types h))
  (define preferred
    (cond
      [(member PCAP_TSTAMP_ADAPTER types) PCAP_TSTAMP_ADAPTER]
      [(member PCAP_TSTAMP_HOST_HIPREC types) PCAP_TSTAMP_HOST_HIPREC]
      [(member PCAP_TSTAMP_HOST types) PCAP_TSTAMP_HOST]
      [else #f]))
  (cond
    [(not preferred) "libpcap-default"]
    [(zero? (pcap_set_tstamp_type h preferred))
     (case preferred
       [(3) "adapter"]
       [(2) "host-high-precision"]
       [(0) "host"]
       [else "libpcap-default"])]
    [else "libpcap-default"]))

(define (request-timestamp-precision! h)
  (if (zero? (pcap_set_tstamp_precision h PCAP_TSTAMP_PRECISION_NANO))
      "nano-requested"
      "micro-requested"))

(define (actual-timestamp-precision h)
  (if (= (pcap_get_tstamp_precision h) PCAP_TSTAMP_PRECISION_NANO)
      "nano"
      "micro"))

;; Open `iface` with a BPF filter. Returns (values capture error-string).
(define (capture-open iface
                      #:filter [filter-text "ether proto 0x88f7"]
                      #:timeout-ms [timeout-ms 1000])
  (define errbuf (make-bytes PCAP_ERRBUF_SIZE 0))
  (define-values (err h) (pcap-create iface))
  (when err
    (bytes-copy! errbuf 0 err 0 (min PCAP_ERRBUF_SIZE (bytes-length err))))
  (cond
    [(not h) (values #f (errbuf->string errbuf))]
    [else
     (pcap_set_snaplen h 65535)
     (pcap_set_promisc h 1)
     (pcap_set_timeout h timeout-ms)
     (pcap_set_immediate_mode h 1)
     (define timestamp-source (select-timestamp-source! h))
     (request-timestamp-precision! h)
     (define act (pcap_activate h))
     (cond
       [(not (zero? act))
        (define msg (string-append (pcap-geterr h)
                                   " (pcap_activate rc=" (number->string act) ")"))
        (pcap_close h)
        (values #f msg)]
       [else
        (define dlt (pcap_datalink h))
        (cond
          [(not (= dlt DLT_EN10MB))
           (pcap_close h)
           (values #f (format "链路层类型 ~a 不是以太网（请选择物理网卡）" dlt))]
          [else
           (define bpf (malloc 64 'raw))
           (define rc (pcap_compile h bpf filter-text 1 0))
           (cond
             [(not (zero? rc))
              (define msg (string-append "BPF 过滤器编译失败: " (pcap-geterr h)))
              (pcap_close h)
              (values #f msg)]
             [else
              (define rc2 (pcap_setfilter h bpf))
              (cond
                [(not (zero? rc2))
                 (define msg (string-append "BPF 过滤器应用失败: " (pcap-geterr h)))
                 (pcap_freecode bpf)
                 (pcap_close h)
                 (values #f msg)]
                [else
                 (pcap-setnonblock h 1)
                 (values (capture h iface filter-text bpf
                                  timestamp-source
                                  (actual-timestamp-precision h))
                         #f)])])])])]))

(define (capture-open? c) (and (capture? c) #t))

;; Drain currently available packets. Callback signature:
;;   (on-frame exact-sec exact-nsec caplen origlen bytes)
;;
;; Exact integer sec+nsec preserves timing resolution; conversion to a display
;; float happens later at the protocol/UI boundary only.
(define (capture-poll! c on-frame)
  (let loop ([n 0])
    (define-values (r hdr data) (pcap_next_ex (capture-handle c)))
    (cond
      [(= r 1)
       (define sec (ptr-ref hdr _long 0 'abs))
       (define frac (ptr-ref hdr _long C-LONG-SIZE 'abs))
       (define caplen (ptr-ref hdr _uint32 PCAP-HDR-CAPLEN-OFF 'abs))
       (define origlen (ptr-ref hdr _uint32 PCAP-HDR-LEN-OFF 'abs))
       (define nsec
         (if (string=? (capture-timestamp-precision c) "nano")
             frac
             (* frac 1000)))
       (define bs (ptr-ref data (_bytes o caplen)))
       (on-frame sec nsec caplen origlen bs)
       (if (>= n 256) (add1 n) (loop (add1 n)))]
      [(= r 0) n]
      [else -1])))

(define (capture-close c)
  (when (capture? c)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (pcap_freecode (capture-bpf c)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (pcap_close (capture-handle c)))))
