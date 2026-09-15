#lang racket/base

;; Packet store: a bounded FIFO of decoded frames feeding the 报文分析 page.
;; Capacity differs by tier (Free 2000 / Pro 50000). Thread-safe; the API
;; layer snapshots it for the frontend.

(require racket/list
         "../proto/decode.rkt")

(provide make-packet-store
         packet-store-push!
         packet-store-snapshot
         packet-store-count
         packet-store-stats
         packet-store-clear!
         packet-store-set-capacity!)

(struct packet-store (items total cap sema) #:mutable)

(define (make-packet-store [cap 2000])
  (packet-store '() 0 cap (make-semaphore 1)))

(define (packet-store-set-capacity! s cap)
  (call-with-semaphore
   (packet-store-sema s)
   (lambda ()
     (set-packet-store-cap! s cap)
     (when (> (length (packet-store-items s)) cap)
       (set-packet-store-items! s (take (packet-store-items s) cap))))))

;; push a decoded frame (jsexpr); keeps newest at the front
(define (packet-store-push! s frame)
  (call-with-semaphore
   (packet-store-sema s)
   (lambda ()
     (define items (cons frame (packet-store-items s)))
     (set-packet-store-items! s items)
     (set-packet-store-total! s (add1 (packet-store-total s)))
     (when (> (length items) (packet-store-cap s))
       (set-packet-store-items! s (take items (packet-store-cap s)))))))

;; newest-first page; each frame carries its absolute index for detail lookup
(define (packet-store-snapshot s [limit 200] [offset 0])
  (call-with-semaphore
   (packet-store-sema s)
   (lambda ()
     (for/list ([f (in-list (list-take* (packet-store-items s) (+ limit offset)))]
                [i (in-naturals)]
                #:when (>= i offset))
       (hash-set f 'index i)))))

(define (list-take* l n)
  (let loop ([l l] [n n] [acc '()])
    (if (or (null? l) (zero? n))
        (reverse acc)
        (loop (cdr l) (sub1 n) (cons (car l) acc)))))

(define (packet-store-count s)
  (call-with-semaphore (packet-store-sema s) (lambda () (length (packet-store-items s)))))

;; (values stored-total) under lock — the field name is taken by the
;; struct accessor, so expose the ring state via one combined call.
(define (packet-store-stats s)
  (call-with-semaphore
   (packet-store-sema s)
   (lambda () (values (length (packet-store-items s)) (packet-store-total s)))))

(define (packet-store-clear! s)
  (call-with-semaphore
   (packet-store-sema s)
   (lambda ()
     (set-packet-store-items! s '()))))
