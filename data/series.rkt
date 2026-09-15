#lang racket/base

;; Time-series ring buffer for the live offset / delay curves. Thread-safe
;; (mutex); the engine pump pushes points, the HTTP API drains snapshots.

(require racket/base)

(provide make-series
         series-push!
         series-snapshot
         series-length
         series-clear!
         series-last)

(struct series (vec head count cap sema) #:mutable)

;; (make-series 21600) — capacity ~45 min at 8 Hz
(define (make-series [cap 21600])
  (series (make-vector cap #f) 0 0 cap (make-semaphore 1)))

(define (with-series s thunk)
  (call-with-semaphore (series-sema s) thunk))

(define (series-push! s t v)
  (with-series
   s
   (lambda ()
     (define vec (series-vec s))
     (define head (series-head s))
     (vector-set! vec head (cons t v))
     (set-series-head! s (remainder (add1 head) (series-cap s)))
     (when (< (series-count s) (series-cap s))
       (set-series-count! s (add1 (series-count s)))))))

;; Chronological snapshot: list of (cons timestamp value), oldest first.
;; `max-points` downsamples by stride when the caller wants fewer points.
;; Oldest element lives at (head - count) mod cap, not at head: head is the
;; NEXT write slot while the buffer is still filling.
(define (series-snapshot s [max-points #f])
  (with-series
   s
   (lambda ()
     (define n (series-count s))
     (define start (modulo (- (series-head s) n) (series-cap s)))
     (define cap (series-cap s))
     (define (at i) (vector-ref (series-vec s) (remainder (+ start i) cap)))
     (if (or (not max-points) (<= n max-points))
         (for/list ([i (in-range n)]) (at i))
         (let ([stride (ceiling (/ n max-points))])
           (for/list ([i (in-range 0 n stride)]) (at i)))))))

(define (series-length s)
  (with-series s (lambda () (series-count s))))

(define (series-clear! s)
  (with-series
   s
   (lambda ()
     (set-series-head! s 0)
     (set-series-count! s 0))))

(define (series-last s)
  (with-series
   s
   (lambda ()
     (and (> (series-count s) 0)
          (vector-ref (series-vec s)
                      (remainder (sub1 (+ (series-head s) (series-cap s)))
                                 (series-cap s)))))))
