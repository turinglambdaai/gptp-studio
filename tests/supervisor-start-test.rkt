#lang racket/base

(require rackunit
         racket/file
         glaze/events
         "../engine/config.rkt"
         "../engine/supervisor.rkt"
         "../data/logstore.rkt"
         "../data/series.rkt"
         "../capture/store.rkt")

(define tmp (make-temporary-file "gptp-studio-supervisor~a" 'directory))
(define sup
  (make-supervisor #:bus (make-event-bus)
                   #:logs (make-logstore 200)
                   #:offset-series (make-series 200)
                   #:delay-series (make-series 200)
                   #:packets (make-packet-store 200)
                   #:run-dir tmp))

(dynamic-wind
  void
  (lambda ()
    (define-values (sim-ok? sim-err)
      (sup-start sup
                 'grandmaster
                 #f
                 (default-params-for-role 'grandmaster)
                 'sim))
    (check-true sim-ok?)
    (check-false sim-err)
    (check-equal? (hash-ref (sup-status sup) 'mode) "sim")

    ;; A rejected replacement session must not tear down a healthy session.
    ;; Real Listener is deterministically invalid on every platform, so this
    ;; test does not depend on CI having linuxptp or PTP hardware installed.
    (define-values (real-ok? real-err)
      (sup-start sup
                 'listener
                 "definitely-not-used"
                 (default-params-for-role 'listener)
                 'real))
    (check-false real-ok?)
    (check-true (string? real-err))
    (check-equal? (hash-ref (sup-status sup) 'mode) "sim")
    (check-equal? (hash-ref (sup-status sup) 'role) "grandmaster"))
  (lambda ()
    (sup-stop sup)
    (delete-directory/files tmp)))
