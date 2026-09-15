#lang racket/base

;; Live capture over libpcap via Racket's FFI (the PRD's planned FFI
;; approach). Runs on THIS platform's libpcap (macOS BPF / Linux PF_PACKET).
;;
;; Cooperative-scheduler note: Racket CS threads must not block inside a
;; raw foreign call, so the capture loop uses pcap_set_nonblock + a 10 ms
;; poll — every FFI call returns in microseconds and other threads keep
;; running between calls. (Verified against glaze's scheduler guidance.)

(require ffi/unsafe
         ffi/unsafe/define
         racket/format
         racket/list
         racket/string
         "../proto/decode.rkt")

(provide capture-supported?
         capture-open
         capture-close
         capture-poll!
         capture-open?
         capture-handle
         capture-iface)

(define-ffi-definer define-pcap (ffi-lib "libpcap" '("1" ".1" "")))

(define _pcap_t (_cpointer/null 'pcap_t))

(define PCAP_ERRBUF_SIZE 256)
(define DLT_EN10MB 1)

;; int pcap_create(const char *name, char *errbuf) — errbuf allocated here;
;; the _fun output-arg form proved unreliable across Racket versions.
(define-pcap pcap-create-raw (_fun _string _bytes -> _pcap_t)
  #:c-id pcap_create)
(define-pcap pcap_set_snaplen (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_promisc (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_timeout (_fun _pcap_t _int -> _int))
(define-pcap pcap_set_immediate_mode (_fun _pcap_t _int -> _int))
;; macOS ships the pre-1.0 spelling `pcap_setnonblock`; Linux libpcap
;; exposes both names, so bind the old one for portability.
(define-pcap pcap-setnonblock-raw (_fun _pcap_t _int _bytes -> _int)
  #:c-id pcap_setnonblock)

(define (pcap-create iface)
  (define buf (make-bytes PCAP_ERRBUF_SIZE 0))
  (values buf (pcap-create-raw iface buf)))

(define (pcap-setnonblock h flag)
  (define buf (make-bytes PCAP_ERRBUF_SIZE 0))
  (values buf (pcap-setnonblock-raw h flag buf)))
(define-pcap pcap_activate (_fun _pcap_t -> _int))
(define-pcap pcap_close (_fun _pcap_t -> _void))
(define-pcap pcap_datalink (_fun _pcap_t -> _int))
(define-pcap pcap-geterr (_fun _pcap_t -> _string)
  #:c-id pcap_geterr)
;; int pcap_compile(pcap_t *, struct bpf_program *, const char *, int, bpf_u_int32)
(define-pcap pcap_compile (_fun _pcap_t _pointer _string _int _uint32 -> _int))
(define-pcap pcap_setfilter (_fun _pcap_t _pointer -> _int))
(define-pcap pcap_freecode (_fun _pointer -> _void))
;; int pcap_next_ex(pcap_t *, struct pcap_pkthdr **, const u_char **)
(define-pcap pcap_next_ex (_fun _pcap_t (hdr : (_ptr o _pointer)) (data : (_ptr o _pointer))
                                -> (r : _int)
                                -> (values r hdr data)))

(struct capture (handle iface filter-text bpf))

(define (capture-supported?)
  ;; libpcap must be loadable (it is on stock macOS and any distro with
  ;; libpcap installed — effectively universal)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (begin0 #t
            (void (ffi-lib "libpcap" '("1" ".1" ""))))))

;; Open `iface` with a BPF filter. Returns (values capture error-string).
(define (capture-open iface
                      #:filter [filter-text "ether proto 0x88f7"]
                      #:timeout-ms [timeout-ms 1000])
  (define errbuf (make-bytes PCAP_ERRBUF_SIZE 0))
  (define-values (err h) (pcap-create iface))
  (when err (bytes-copy! errbuf 0 err 0 (min PCAP_ERRBUF_SIZE (bytes-length err))))
  (cond
    [(not h) (values #f (errbuf->string errbuf))]
    [else
     (pcap_set_snaplen h 65535)
     (pcap_set_promisc h 1)
     (pcap_set_timeout h timeout-ms)
     (pcap_set_immediate_mode h 1) ; deliver packets without waiting to fill a buffer
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
           (define bpf (malloc 64 'raw)) ; struct bpf_program: bf_len(4)+bf_insns(ptr)
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
                 (pcap_close h)
                 (values #f msg)]
                [else
                 (pcap-setnonblock h 1) ; poll loop keeps the scheduler free
                 (values (capture h iface filter-text bpf) #f)])])])])]))
(define (errbuf->string b)
  (define s (bytes->string/utf-8 b #\_ 0 (or (index-of b 0) (bytes-length b))))
  (if (string=? s "") "unknown libpcap error" s))

(define (capture-open? c) (and (capture? c) #t))

;; Drain packets currently available; calls (on-frame ts-bytes) for each.
;; Returns the number of frames delivered. Never raises for individual
;; malformed packets.
(define (capture-poll! c on-frame)
  (let loop ([n 0])
    (define-values (r hdr data) (pcap_next_ex (capture-handle c)))
    (cond
      [(= r 1)
       ;; struct pcap_pkthdr: ts.tv_sec (8), ts.tv_usec, caplen @16, len @20
       (define caplen (ptr-ref hdr _uint32 16))
       (define origlen (ptr-ref hdr _uint32 20))
       (define sec (ptr-ref hdr _int64 0))
       (define usec (ptr-ref hdr _int32 8))
       (define bs (ptr-ref data (_bytes o caplen)))
       (on-frame (+ sec (/ usec 1000000.0)) caplen origlen bs)
       (if (> n 256) n (loop (add1 n)))]
      [(= r 0) n]         ; nonblocking: nothing available
      [else -1])))        ; error (device gone); caller stops the loop

(define (capture-close c)
  (when (capture? c)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (pcap_freecode (capture-bpf c)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (pcap_close (capture-handle c)))))
