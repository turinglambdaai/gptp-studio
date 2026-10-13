#lang racket/base

;; Time-series ring buffer for the live offset / delay curves.
;;
;; Storage is rivet/chart's chart-series — the same ring, monotonic
;; enforcement, and binary batch drain the native chart widgets consume —
;; so the engine pump, the windowed RPC pull, and the batch event all read
;; one buffer instead of copying between two.
;;
;; Producers push domain timestamps (sim-time seconds or wall-clock ms
;; depending on the engine mode). The adapter stamps wall-clock ns and
;; keeps it strictly increasing (ties and restarts advance by 1 ns), which
;; preserves arrival order — the property every consumer relies on. Values
;; are floored to exact integers; offsets are nanosecond-domain integers
;; by construction.

(require racket/list
         rivet/chart)

(provide make-series
         series-push!
         series-snapshot
         series-length
         series-clear!
         series-last
         series-chart
         series-drain-batch!
         series-watermark)

(struct series (chart) #:transparent)

;; (make-series 21600) — capacity ~45 min at 8 Hz
(define (make-series [cap 21600])
  (series (make-chart-series "series" #:capacity cap)))

(define (wall-ns) (inexact->exact (floor (* (current-inexact-milliseconds) 1000000))))

(define (series-push! s t v)
  (define cs (series-chart s))
  (define last-sample (chart-series-latest cs))
  (define base (wall-ns))
  (define ts
    (if (and last-sample (<= base (car last-sample)))
        (add1 (car last-sample))
        base))
  (chart-series-append! cs (list (cons ts (value->exact v)))))

(define (value->exact v)
  (cond
    [(exact-integer? v) v]
    [(real? v) (inexact->exact (floor v))]
    [else (raise-argument-error 'series-push! "real?" v)]))

;; Chronological snapshot: list of (cons timestamp value), oldest first.
;; `max-points` downsamples by stride when the caller wants fewer points.
(define (series-snapshot s [max-points #f])
  (define all (chart-series-window (series-chart s)))
  (cond
    [(not max-points) all]
    [(<= (length all) max-points) all]
    [else
     (define n (length all))
     (define stride (inexact->exact (ceiling (/ n max-points))))
     (for/list ([sample (in-list all)]
                [index (in-naturals)]
                #:when (or (zero? (modulo index stride))
                           (= index (sub1 n))))
       sample)]))

(define (series-length s)
  (chart-series-count (series-chart s)))

(define (series-clear! s)
  (chart-series-reset! (series-chart s)))

(define (series-last s)
  (chart-series-latest (series-chart s)))

;; The rivet data-plane extras the backend ticker uses directly.
(define (series-drain-batch! s)
  (chart-series-drain-batch! (series-chart s)))

(define (series-watermark s)
  (chart-series-appended (series-chart s)))
