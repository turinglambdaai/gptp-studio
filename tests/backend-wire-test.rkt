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
         rivet/protocol
         "../engine/detect.rkt")

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

;; Wait until an event with the given name arrives (non-matching events are
;; consumed); #f on timeout. Lives outside call-rpc because the live-data
;; delivery (issue #45) streams events while no RPC is in flight.
(define (wait-for-event name seconds)
  (let loop ([deadline (+ (current-inexact-milliseconds) (* seconds 1000))])
    (define remaining (- deadline (current-inexact-milliseconds)))
    (cond
      [(<= remaining 0) #f]
      [(not (sync/timeout (/ remaining 1000) client-in)) #f]
      [else
       (define frame (read-frame client-in))
       (cond
         [(not (equal? (frame-type frame) message:event)) (loop deadline)]
         [else
          (define decoded (decode-value (frame-payload frame)))
          (if (and (pair? decoded) (string=? (car decoded) name))
              #t
              (loop deadline)))])]))))

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
   ;; The platform field must report the host truthfully: "linux" on the
   ;; supported product platform, "unsupported" anywhere else.
   (check-equal? (list-ref bootstrap 1) (platform-name))

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

   ;; Live-data delivery (issue #45): a running simulator must push packet
   ;; events and chart batches to the host, and packets-page/series-window
   ;; must round-trip. CI stayed green while both surfaces were dead
   ;; because nothing asserted them.
   (check-true (wait-for-event "packets-appended" 10)
               "packet events must reach the host")
   (check-true (wait-for-event "chart-batch" 10)
               "chart batches must reach the host")
   (define-values (page page-error) (call-rpc "packets-page" 200))
   (check-false page-error)
   ;; PacketPage = [rows stored total]; PacketRow = [ts frame_no ...].
   (check-true (list? page))
   (check-true (> (length (list-ref page 0)) 0) "packets-page must carry rows")
   (check-true (exact-integer? (list-ref (list-ref (list-ref page 0) 0) 1))
               "frame_no must be an integer, never absent")
   (define-values (window window-error) (call-rpc "series-window" "offset"))
   (check-false window-error)
   (check-true (bytes? (list-ref window 2)))
   (check-true (> (bytes-length (list-ref window 2)) 12)
               "the offset ring must carry samples")

   (define-values (status status-error) (call-rpc "engine-status-now"))
   (check-false status-error)
   (check-equal? (take status 2) (list "sim" "slave"))

   (define-values (stopped stop-error) (call-rpc "engine-stop"))
   (check-false stop-error)
   (check-equal? (list-ref stopped 0) "#f")

   ;; Raw-data access is free scope (the 2026-10-auth-1 decision): pcap
   ;; export answers on the wire with no entitlement at all, while the
   ;; engineering report refuses with need-pro before doing any work.
   (define export-path (build-path scratch "free-export.pcap"))
   (define-values (exported export-error)
     (call-rpc "pcap-export" (path->string export-path)))
   (check-false export-error)
   (check-equal? (list-ref exported 0) #t)
   (check-true (file-exists? export-path) "the free export wrote a capture file")

   (define report-path (build-path scratch "free-report.json"))
   (define-values (report report-error)
     (call-rpc "report-export" (path->string report-path) "" "" ""))
   (check-false report-error)
   (check-equal? (take report 2) (list #f #t))
   (check-false (file-exists? report-path) "the refused report wrote nothing"))
 (lambda ()
   (kill-thread server-thread)
   (delete-directory/files scratch)))
