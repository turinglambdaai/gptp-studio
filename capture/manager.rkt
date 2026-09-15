#lang racket/base

;; Live capture manager: opens a libpcap handle on a chosen NIC, pumps a
;; non-blocking poll loop on a worker thread, decodes frames through the
;; shared pipeline and streams batches to the frontend.

(require racket/format
         racket/list
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
                         handle-box     ; box: #f or live capture struct
                         thread-box     ; box: worker thread
                         bus
                         logs
                         packets))

(define (make-capture-manager #:bus bus #:logs logs #:packets packets)
  (capture-manager (make-semaphore 1) (box #f) (box #f) bus logs packets))

(define (cm-running? cm)
  (and (unbox (capture-manager-handle-box cm)) #t))

(define (log! cm level msg) (log-add! (capture-manager-logs cm) 'capture level msg))
(define (emit! cm name payload)
  (bus-broadcast! (capture-manager-bus cm) name payload))

;; Start capturing. Returns (values ok? error-string).
(define (cm-start cm iface)
  (cm-stop cm)
  (unless (capture-supported?)
    (values #f "本机 libpcap 不可用，无法抓包"))
  (define-values (cap err) (capture-open iface))
  (cond
    [cap
     (unbox-set! (capture-manager-handle-box cm) cap)
     (log! cm 'info (format "抓包启动：~a（BPF: ether proto 0x88f7）" iface))
     (define th (thread (lambda () (capture-loop! cm iface cap))))
     (unbox-set! (capture-manager-thread-box cm) th)
     (emit! cm 'capture-state (hasheq 'running #t 'iface iface))
     (values #t #f)]
    [else
     (log! cm 'error (format "抓包打开失败（~a）：~a" iface err))
     (values #f err)]))

;; worker loop: poll, decode, batch-emit, repeat until the handle is cleared
(define (capture-loop! cm iface cap)
  (let loop ()
    (define handle (unbox (capture-manager-handle-box cm)))
    (when handle
      (define batch-box (box '()))
      (define n
        (with-handlers ([exn:fail? (lambda (_) -1)])
          (capture-poll!
           cap
           (lambda (ts caplen origlen bs)
             (define f (decode-frame bs #:ts ts #:iface iface #:source "live"))
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
         (unbox-set! (capture-manager-handle-box cm) #f)]
        [else (sleep 0.012) (loop)]))))

(define (cm-stop cm)
  (define handle (unbox (capture-manager-handle-box cm)))
  (when handle
    (unbox-set! (capture-manager-handle-box cm) #f)
    (capture-close handle)
    (define th (unbox (capture-manager-thread-box cm)))
    (when th
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (sync/timeout 1 th)))
    (log! cm 'info "抓包已停止")
    (emit! cm 'capture-state (hasheq 'running #f))))

(define (cm-status cm)
  (hasheq 'running (cm-running? cm)
          'iface (let ([h (unbox (capture-manager-handle-box cm))])
                   (and h (capture-iface h)))))

(define (unbox-set! b v) (set-box! b v))
