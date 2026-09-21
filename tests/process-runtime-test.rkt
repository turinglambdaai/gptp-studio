#lang racket/base

(require rackunit
         "../engine/process-runtime.rkt")

(define racket-exe (path->string (find-executable-path "racket")))

;; Regression: supervisor stores processes as `(name . subprocess)`. Passing
;; that whole pair to subprocess-kill used to be swallowed by with-handlers and
;; left ptp4l alive. Exercise the exact representation here.
(define-values (sleep-p sleep-out sleep-in sleep-err)
  (subprocess #f #f #f racket-exe "-e" "(sleep 30)"))
(close-output-port sleep-in)
(define sleep-entry (cons 'test sleep-p))
(check-true (process-entry-running? sleep-entry))
(check-true (stop-process-entry! sleep-entry))
(check-false (process-entry-running? sleep-entry))
(close-input-port sleep-out)
(close-input-port sleep-err)

;; Regression: subprocess-wait returns void; the numeric exit code lives in
;; subprocess-status after the process has terminated.
(define-values (exit-p exit-out exit-in exit-err)
  (subprocess #f #f #f racket-exe "-e" "(exit 7)"))
(close-output-port exit-in)
(check-equal? (wait-process-exit-code exit-p) 7)
(close-input-port exit-out)
(close-input-port exit-err)

;; Invalid entries fail closed instead of throwing.
(check-false (process-entry-running? '(not . a-process)))
(check-false (stop-process-entry! '(not . a-process)))
