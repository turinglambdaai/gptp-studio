#lang racket/base

;; Drive the production backend over real RVT1 frames. This catches protocol,
;; registration, argument-order, record-codec, and Event regressions that a
;; direct function test cannot see.

(require rackunit
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         rivet/backend
         rivet/protocol)

(define scratch (make-temporary-file "gptp-studio-wire-~a" 'directory))
(putenv "GPTP_STUDIO_HOME" (path->string scratch))

(define test-directory
  (or (current-load-relative-directory) (current-directory)))
(define backend-path
  (simplify-path (build-path test-directory ".." "app" "backend.rkt")))
(void (dynamic-require backend-path #f))
;; `serve` below owns the in-memory ports, while the production `start` entry
;; owns OS file descriptors. Install the same application-level Event bridge
;; that `start` installs so this test exercises typed event encoding too.
(parameterize ([current-namespace (module->namespace backend-path)])
  (eval '(forward-engine-events!)))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define (read-frame/timeout label)
  (define result (box #f))
  (define failure (box #f))
  (define reader
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (exception)
                                    (set-box! failure exception))])
         (set-box! result (read-frame client-in))))))
  (unless (sync/timeout 30 reader)
    (fail (format "timed out waiting for ~a" label)))
  (when (unbox failure) (raise (unbox failure)))
  (unbox result))

(define next-id 0)
(define last-events '())
(define (call-rpc name . arguments)
  (set! next-id (add1 next-id))
  (define id next-id)
  (write-frame
   (frame message:request id (encode-value (cons name arguments)))
   client-out)
  (flush-output client-out)
  (let loop ([events '()])
    (define response (read-frame/timeout name))
    (match (frame-type response)
      [(== message:event)
       (loop (cons (decode-value (frame-payload response)) events))]
      [(== message:response)
       (check-equal? (frame-id response) id)
       (set! last-events (reverse events))
       (values (decode-value (frame-payload response)) #f)]
      [(== message:error)
       (check-equal? (frame-id response) id)
       (values #f (decode-value (frame-payload response)))]
      [_ (loop events)])))

(dynamic-wind
 void
 (lambda ()
   (define hello (read-frame/timeout "RVT1 hello"))
   (check-equal? (frame-type hello) message:hello)
   (check-equal? (decode-value (frame-payload hello))
                 (list "rivet" protocol-version))

   (define-values (bootstrap bootstrap-error) (call-rpc "bootstrap"))
   (check-false bootstrap-error)
   (check-equal? (length bootstrap) 12)
   (check-equal? (list-ref bootstrap 1) "linux")

   (define-values (started start-error)
     (call-rpc "engine-start" "slave" "sim" "" '()))
   (check-false start-error)
   ;; EngineStartResult = [ok need-pro error status].
   (check-equal? (take started 2) (list #t #f))
   (check-true (list? (list-ref started 3)))
   (check-true
    (for/or ([event (in-list last-events)])
      (and (pair? event) (equal? (car event) "engine-state")))
    "the simulator mutation must publish its state Event over RVT1")

   (define-values (status status-error) (call-rpc "engine-status-now"))
   (check-false status-error)
   (check-equal? (take status 2) (list "sim" "slave"))

   (define-values (stopped stop-error) (call-rpc "engine-stop"))
   (check-false stop-error)
   (check-equal? (list-ref stopped 0) "#f"))
 (lambda ()
   (kill-thread server-thread)
   (delete-directory/files scratch)))
