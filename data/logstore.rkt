#lang racket/base

;; Aggregated log store: engine output, capture events, license checks and
;; the app's own notices, all funnel into one ring with level + source tags.
;; Thread-safe; queried by the logs page with optional filters.

(require racket/format
         racket/list
         racket/string)

(provide make-logstore
         log-add!
         log-snapshot
         log-clear!
         log-count
         log->text)

(struct logstore (vec head count cap sema) #:mutable)

(define (make-logstore [cap 5000])
  (logstore (make-vector cap #f) 0 0 cap (make-semaphore 1)))

;; (log-add! store 'ptp4l 'info "port 1: LISTENING")
(define (log-add! s source level message)
  (define entry (list (current-inexact-milliseconds)
                      (if (symbol? source) (symbol->string source) source)
                      (if (symbol? level) (symbol->string level) level)
                      (if (string? message) message (~a message))))
  (call-with-semaphore
   (logstore-sema s)
   (lambda ()
     (vector-set! (logstore-vec s) (logstore-head s) entry)
     (set-logstore-head! s (remainder (add1 (logstore-head s)) (logstore-cap s)))
     (when (< (logstore-count s) (logstore-cap s))
       (set-logstore-count! s (add1 (logstore-count s)))))))

;; Newest first. Filters are case-insensitive substring matches.
(define (log-snapshot s
                      #:level [level #f]
                      #:source [source #f]
                      #:search [search #f]
                      #:limit [limit 500])
  (define (match? e)
    (and (or (not level) (string=? level (list-ref e 2)))
         (or (not source) (string=? source (list-ref e 1)))
         (or (not search)
             (string-contains? (string-downcase (list-ref e 3))
                               (string-downcase search)))))
  (call-with-semaphore
   (logstore-sema s)
   (lambda ()
     (define head (logstore-head s))
     (define cap (logstore-cap s))
     (define count (logstore-count s))
     (define rows
       (for*/list ([k (in-range count)]
                   [e (in-value (vector-ref (logstore-vec s)
                                            (modulo (- head 1 k) cap)))]
                   #:when (match? e))
         e))
     (if (<= (length rows) limit) rows (take rows limit)))))

(define (take* lst n)
  (if (<= (length lst) n) lst (reverse (list-tail (reverse lst) (- (length lst) n)))))

(define (log-count s)
  (call-with-semaphore (logstore-sema s) (lambda () (logstore-count s))))

(define (log-clear! s)
  (call-with-semaphore
   (logstore-sema s)
   (lambda ()
     (set-logstore-head! s 0)
     (set-logstore-count! s 0))))

;; Plain-text export.
(define (log->text entries)
  (string-join
   (for/list ([e (in-list entries)])
     (format "~a [~a] [~a] ~a"
             (ms->iso (list-ref e 0))
             (list-ref e 1)
             (string-upcase (list-ref e 2))
             (list-ref e 3)))
   "\n"))

(define (ms->iso ms)
  (define sec (floor (/ ms 1000)))
  (define frac (modulo (inexact->exact (floor ms)) 1000))
  (define d (seconds->date sec #f))
  (format "~a-~a-~aT~a:~a:~a.~a"
          (date-year d)
          (~r (date-month d) #:base 10 #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:base 10 #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:base 10 #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:base 10 #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:base 10 #:min-width 2 #:pad-string "0")
          (~r frac #:base 10 #:min-width 3 #:pad-string "0")))
