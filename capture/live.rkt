#lang racket/base

;; Live capture over libpcap via Racket FFI.
;;
;; Timestamp rules are deliberately conservative:
;; - request nanosecond *resolution* when the loaded libpcap supports it;
;; - prefer adapter/device timestamps only when libpcap explicitly advertises
;;   that timestamp type and accepts the selection;
;; - otherwise record the source as host/default instead of inferring it from
;;   NIC hardware capability;
;; - keep sec+nsec as exact integers all the way out of this module.
;;
;; The timestamp-selection APIs are optional bindings. Older/system libpcap
;; builds must keep working and simply fall back to their default timestamp
;; source/precision.

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

;; pcap_pkthdr starts with struct timeval. timeval fields are C `long`, not
;; fixed int64/int32. ptr-ref offsets are byte offsets only with `'abs`.
(define C-LONG-SIZE (ctype-sizeof _long))
(define PCAP-HDR-CAPLEN-OFF (* 2 C-LONG-SIZE))
(define PCAP-HDR-LEN-OFF (+ PCAP-HDR-CAPLEN-OFF 4))

;; Core APIs required for capture. If any of these are absent, loading this
;; module should fail because the platform cannot provide the capture feature.
(define-pcap pcap-create-raw (_fun _string _bytes -> _pcap_t)
  #:c-id pcap_create)
(define-pcap pcap_set_snaplen (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_promisc (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_timeout (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_immediate_mode (_fun _pcap_t _int -> _int))

;; Optional timestamp APIs. get-ffi-obj's failure thunk gives us a #f binding
;; instead of making an older macOS/system libpcap unloadable.
(define pcap-set-tstamp-precision
  (get-ffi-obj "pcap_set_tstamp_precision" pcap-lib
               (_fun _pcap_t _int -> _int)
               (lambda () #f)))
(define pcap-get-tstamp-precision
  (get-ffi-obj "pcap_get_tstamp_precision" pcap-lib
               (_fun _pcap_t -> _int)
               (lambda () #f)))
(define pcap-set-tstamp-type
  (get-ffi-obj "pcap_set_tstamp_type" pcap-lib
               (_fun _pcap_t _int -> _int)
               (lambda () #f)))
(define pcap-list-tstamp-types
  (get-ffi-obj "pcap_list_tstamp_types" pcap-lib
               (_fun _pcap_t
                     (types : (_ptr o _pointer))
                     -> (count : _int)
                     -> (values count types))
               (lambda () #f)))
(define pcap-free-tstamp-types
  (get-ffi-obj "pcap_free_tstamp_types" pcap-lib
               (_fun _pointer -> _void)
               (lambda () #f)))

;; macOS ships the historical pcap_setnonblock spelling; Linux exports it too.
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
  (define s
    (bytes->string/utf-8 b #\_ 0 (or (index-of b 0) (bytes-length b))))
  (if (string=? s "") "unknown libpcap error" s))

;; Return advertised timestamp type IDs. Missing APIs mean "unknown/default",
;; not a capture failure.
(define (available-tstamp-types h)
  (cond
    [(not pcap-list-tstamp-types) '()]
    [else
     (with-handlers ([exn:fail? (lambda (_) '())])
       (define-values (count arr) (pcap-list-tstamp-types h))
       (cond
         [(or (<= count 0) (not arr)) '()]
         [else
          (define result
            (for/list ([i (in-range count)])
              (ptr-ref arr _int i)))
          (when pcap-free-tstamp-types
            (pcap-free-tstamp-types arr))
          result])]))

(define (select-timestamp-source! h)
  (define types (available-tstamp-types h))
  (define preferred
    (cond
      [(member PCAP_TSTAMP_ADAPTER types) PCAP_TSTAMP_ADAPTER]
      [(member PCAP_TSTAMP_HOST_HIPREC types) PCAP_TSTAMP_HOST_HIPREC]
      [(member PCAP_TSTAMP_HOST types) PCAP_TSTAMP_HOST]
      [else #f]))
  (cond
    [(or (not preferred) (not pcap-set-tstamp-type)) "libpcap-default"]
    [(zero? (pcap-set-tstamp-type h preferred))
     (case preferred
       [(3) "adapter"]
       [(2) "host-high-precision"]
       [(0) "host"]
       [else "libpcap-default"])]
    [else "libpcap-default"]))

;; Returns the best-known delivered precision. When the setter is absent or
;; rejects nanoseconds, libpcap's default timeval fraction is microseconds.
(define (request-timestamp-precision! h)
  (cond
    [(not pcap-set-tstamp-precision) "micro"]
    [(not (zero? (pcap-set-tstamp-precision h PCAP_TSTAMP_PRECISION_NANO)))
     "micro"]
    [else "nano-requested"]))

(define (actual-timestamp-precision h requested)
  (cond
    [pcap-get-tstamp-precision
     (if (= (pcap-get-tstamp-precision h) PCAP_TSTAMP_PRECISION_NANO)
         "nano"
         "micro")]
    [(string=? requested "nano-requested") "nano"]
    [else "micro"]))

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
     (define requested-precision (request-timestamp-precision! h))
     (define act (pcap_activate h))
     (cond
       [(not (zero? act))
        (define msg
          (string-append (pcap-geterr h)
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
              (define msg
                (string-append "BPF 过滤器编译失败: " (pcap-geterr h)))
              (free bpf)
              (pcap_close h)
              (values #f msg)]
             [else
              (define rc2 (pcap_setfilter h bpf))
              (cond
                [(not (zero? rc2))
                 (define msg
                   (string-append "BPF 过滤器应用失败: " (pcap-geterr h)))
                 (pcap_freecode bpf)
                 (free bpf)
                 (pcap_close h)
                 (values #f msg)]
                [else
                 (pcap-setnonblock h 1)
                 (values
                  (capture h iface filter-text bpf
                           timestamp-source
                           (actual-timestamp-precision h requested-precision))
                  #f)])])])])]))

(define (capture-open? c)
  (and (capture? c) #t))

;; Drain currently available packets. Callback signature:
;;   (on-frame exact-sec exact-nsec caplen origlen bytes)
;;
;; Exact sec+nsec preserves timestamp resolution; conversion to a display float
;; happens later at the protocol/UI boundary only.
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
      (free (capture-bpf c)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (pcap_close (capture-handle c)))))
