#lang racket/base

;; Live capture manager: opens a libpcap handle on a chosen NIC, pumps a
;; non-blocking poll loop, decodes frames and preserves exact capture timing
;; metadata alongside the legacy display timestamp.

(require racket/format
         racket/list
         racket/hash
         glaze/events
         "live.rkt"
         "../proto/decode.rkt"
         "../capture/store.rkt"
         "../data/logstore.rkt")

(provide (struct-out capture-manager)
         make-capture-manager
         cm-start
         cm-stop
         cm-status
         cm-running?)

(struct capture-manager (sema
                         handle-box
                         thread-box
                         bus
                         logs
                         packets))

(define (make-capture-manager #:bus bus #:logs logs #:packets packets)
  (capture-manager (make-semaphore 1) (box #f) (box #f) bus logs packets))

(define (cm-running? cm)
  (and (unbox (capture-manager-handle-box cm)) #t))

(define (log! cm level msg)
  (log-add! (capture-manager-logs cm) 'capture level msg))

(define (emit! cm name payload)
  (bus-broadcast! (capture-manager-bus cm) name payload))

;; Start capturing. Returns (values ok? error-string).
(define (cm-start cm iface)
  (cm-stop cm)
  (cond
    [(not (capture-supported?))
     (values #f "本机 libpcap 不可用，无法抓包")]
    [else
     (define-values (cap err) (capture-open iface))
     (cond
       [cap
        (set-box! (capture-manager-handle-box cm) cap)
        (log! cm 'info
              (format "抓包启动：~a（BPF: ether proto 0x88f7；timestamp=~a/~a）"
                      iface
                      (capture-timestamp-source cap)
                      (capture-timestamp-precision cap)))
        (define th (thread (lambda () (capture-loop! cm iface cap))))
        (set-box! (capture-manager-thread-box cm) th)
        (emit! cm 'capture-state
               (hasheq 'running #t
                       'iface iface
                       'timestamp_source (capture-timestamp-source cap)
                       'timestamp_precision (capture-timestamp-precision cap)))
        (values #t #f)]
       [else
        (log! cm 'error (format "抓包打开失败（~a）：~a" iface err))
        (values #f err)])]))

;; Keep exact sec+nsec as separate JSON-safe integers. The historical `ts`
;; float remains for existing UI sorting/display only; timing analysis should
;; use the exact pair.
(define (with-capture-time f sec nsec cap)
  (hash-set* f
             'ts_sec sec
             'ts_nsec nsec
             'timestamp_source (capture-timestamp-source cap)
             'timestamp_precision (capture-timestamp-precision cap)))

(define (capture-loop! cm iface cap)
  (let loop ()
    (define handle (unbox (capture-manager-handle-box cm)))
    (when handle
      (define batch-box (box '()))
      (define n
        (with-handlers ([exn:fail?
                         (lambda (e)
                           (log! cm 'error (format "抓包循环异常：~a" (exn-message e)))
                           -1)])
          (capture-poll!
           cap
           (lambda (sec nsec caplen origlen bs)
             (define ts (+ (exact->inexact sec) (/ nsec 1000000000.0)))
             (define f
               (with-capture-time
                (decode-frame bs #:ts ts #:iface iface #:source "live")
                sec nsec cap))
             (when (hash-ref f 'is_ptp #f)
               (packet-store-push! (capture-manager-packets cm) f)
               (set-box! batch-box (cons f (unbox batch-box))))))))
      (define batch (unbox batch-box))
      (when (pair? batch)
        (emit! cm 'packets (reverse batch)))
      (cond
        [(negative? n)
         (log! cm 'error "抓包设备错误，停止抓包")
         (emit! cm 'capture-stopped (hasheq 'reason "device-error"))
         (set-box! (capture-manager-handle-box cm) #f)]
        [else
         (sleep 0.012)
         (loop)]))))

(define (cm-stop cm)
  (define handle (unbox (capture-manager-handle-box cm)))
  (when handle
    ;; Clear first so the worker cannot perform another poll after close.
    (set-box! (capture-manager-handle-box cm) #f)
    (capture-close handle)
    (define th (unbox (capture-manager-thread-box cm)))
    (when th
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (sync/timeout 1 th)))
    (set-box! (capture-manager-thread-box cm) #f)
    (log! cm 'info "抓包已停止")
    (emit! cm 'capture-state (hasheq 'running #f))))

(define (cm-status cm)
  (define h (unbox (capture-manager-handle-box cm)))
  (hasheq 'running (and h #t)
          'iface (and h (capture-iface h))
          'timestamp_source (and h (capture-timestamp-source h))
          'timestamp_precision (and h (capture-timestamp-precision h))))
