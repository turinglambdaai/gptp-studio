#lang racket/base

;; Small, testable helpers around external linuxptp processes. Keeping these
;; details out of supervisor.rkt makes lifecycle behavior explicit and lets CI
;; exercise the exact stop/exit-code paths that previously failed only on a
;; real Linux target.

(require racket/port
         racket/string
         racket/system)

(provide process-entry-running?
         stop-process-entry!
         wait-process-exit-code
         executable-capabilities
         executable-has-capability?
         sudo-noninteractive?
         running-as-root?
         launch-plan)

(define (entry-process entry)
  (cond
    [(and (pair? entry) (subprocess? (cdr entry))) (cdr entry)]
    [(subprocess? entry) entry]
    [else #f]))

(define (process-entry-running? entry)
  (define p (entry-process entry))
  (and p
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (eq? (subprocess-status p) 'running))))

;; Stop one `(name . subprocess)` entry. Returns #t when the process is no
;; longer running (including the already-exited case), #f for an invalid entry.
(define (stop-process-entry! entry [force? #t])
  (define p (entry-process entry))
  (cond
    [(not p) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (when (eq? (subprocess-status p) 'running)
         (subprocess-kill p force?))
       ;; Give the OS a short chance to reap it; status is still authoritative.
       (sync/timeout 0.5 p)
       (not (eq? (subprocess-status p) 'running))) ]))

;; `subprocess-wait` itself returns void. The exit status must be read with
;; `subprocess-status` after the wait.
(define (wait-process-exit-code p)
  (subprocess-wait p)
  (subprocess-status p))

(define (run-out . args)
  (define exe (find-executable-path (car args)))
  (and exe
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define out (open-output-string))
         (parameterize ([current-output-port out]
                        [current-error-port (open-output-nowhere)]
                        [current-input-port (open-input-string "")])
           (define rc (apply system*/exit-code exe (cdr args)))
           (and (zero? rc) (string-trim (get-output-string out)))))))

(define (running-as-root?)
  (define uid (run-out "id" "-u"))
  (and uid (string=? uid "0")))

(define (sudo-noninteractive?)
  (and (find-executable-path "sudo")
       (run-out "sudo" "-n" "true")
       #t))

;; Returns the textual `getcap` result or #f when getcap is unavailable / the
;; executable has no file capabilities.
(define (executable-capabilities executable)
  (define out (run-out "getcap" executable))
  (and out (not (string=? out "")) out))

(define (executable-has-capability? executable capability)
  (define caps (executable-capabilities executable))
  (and caps (regexp-match? (regexp (regexp-quote capability)) caps)))

;; Decide how to invoke an external program without actually spawning it.
;; required-capabilities is a list like '("cap_net_raw" "cap_net_admin").
;; Return values: argv-list and a symbolic mode for diagnostics.
;;
;; Priority is intentional:
;;   1. root -> direct
;;   2. executable file capabilities -> direct (the README's setcap path)
;;   3. passwordless sudo -> sudo -n
;;   4. direct best-effort -> lets ambient/container capabilities work and
;;      preserves the real stderr instead of failing before exec.
(define (launch-plan executable args #:required-capabilities [required '()])
  (define direct? (or (running-as-root?)
                      (and (pair? required)
                           (for/and ([cap (in-list required)])
                             (executable-has-capability? executable cap)))))
  (cond
    [direct? (values (cons executable args)
                     (if (running-as-root?) 'root 'file-capabilities))]
    [(sudo-noninteractive?)
     (values (append (list (path->string (find-executable-path "sudo")) "-n" executable) args)
             'sudo-noninteractive)]
    [else (values (cons executable args) 'direct-best-effort)]))
