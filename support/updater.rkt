#lang racket/base

;; In-app self-update: download the update artifact chosen by the signed
;; manifest check (support/updates.rkt), verify it, and stage it for
;; installation. The download leg is rivet's download-update — a
;; redirect-following fetch under the SIGNED size cap, .partial cleanup on
;; every failure, SHA-256 + size verification against the signed manifest,
;; and the final atomic rename; this module only runs it on a watched
;; worker thread and maps the outcome onto the flow state machine.
;;
;; Trust chain: TLS gets the bytes; the Ed25519-signed manifest (made with
;; a private key that never lives on a server) authenticates the whole
;; chain — the artifact digest and size ride the signature. This replaces
;; the old per-artifact glaze/signing signatures over an unsigned
;; latest.json: a compromised release host can now serve nothing accepted
;; at all, not merely stale artifacts.
;;
;; Apply policy: this product installs as a system deb, so applying needs
;; the operator's explicit consent — pkexec raises the standard system
;; authentication dialog for `apt-get install ./staged.deb` (nothing is
;; done behind their back; headless environments get the exact command to
;; run themselves). Air-gapped hosts: --no-update-check skips everything.

(require rivet/distribution
         racket/file
         racket/system
         "updates.rkt")

(provide update-stage-dir
         ensure-update-stage-dir
         staged-artifact-path
         download-candidate!
         apply-staged-deb-command
         pkexec-available?)

;; Where verified artifacts wait for installation.
(define (update-stage-dir)
  (build-path (find-system-path 'home-dir)
              ".local" "share" "gptp-studio" "updates"))

(define (ensure-update-stage-dir)
  (define dir (update-stage-dir))
  (make-directory* dir)
  dir)

;; Staged file name per signed manifest installer symbol. Both feed
;; artifacts for this product are linux x64; the names match the release
;; assets so the printed install command reads like the manual one.
(define (staged-artifact-path installer)
  (define dir (update-stage-dir))
  (case installer
    [(deb) (build-path dir "gPTP-Studio-linux-x64.deb")]
    [(targz) (build-path dir "gPTP-Studio-linux-x64.tar.gz")]
    [else #f]))

;; Download the candidate's artifact into the stage dir. rivet owns the
;; redirect-following fetch (releases/latest/download aliases answer 302
;; with a CDN handoff), the signed-size cap, .partial cleanup on any
;; failure, SHA-256 + size verification against the signed manifest, and
;; the atomic rename. Synchronous; raises on failure — update-prepare!
;; wraps it in the watched worker thread. Every progress report feeds the
;; watchdog's stall clock.
(define (download-candidate! candidate)
  (define artifact (update-candidate-artifact candidate))
  (define destination
    (staged-artifact-path (update-artifact-installer artifact)))
  (unless destination
    (error 'updater "no staged name for installer ~a"
           (update-artifact-installer artifact)))
  (download-update (make-updater-config) candidate destination
                   #:on-progress
                   (lambda (_bytes)
                     (set-box! last-progress-seconds (current-seconds))))
  destination)

;; The exact command that applies a staged deb on a system install
;; (shown in the UI; apply itself goes through pkexec with the operator's
;; explicit authentication).
(define (apply-staged-deb-command staged-path)
  (format "sudo apt-get install -y ~a" (path->string staged-path)))

(define (pkexec-available?)
  (file-exists? "/usr/bin/pkexec"))

;; ---- flow state machine (prepare -> staged -> apply -> applied) --------------

(provide update-prepare!
         update-apply!
         update-flow-status)

;; One flow at a time; the UI polls this hash through /api/update/status.
(define flow-box (box (hasheq 'state 'idle)))

;; Download watchdog bounds. rivet's copy loop waits on read-bytes-avail!
;; with no timeout, so a connection that stalls without RST/FIN parks the
;; worker thread forever — visibly "stuck" with no terminal state. Two
;; finite bounds keep the phase machine honest: no byte progress for the
;; stall limit, or wall clock past the total limit, breaks the worker
;; (rivet's partial-file cleanup still runs) so the flow always reaches a
;; terminal state.
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))
(define last-progress-seconds (box 0))

(define (flow-set! state #:error [error #f] #:staged [staged #f])
  (set-box! flow-box
            (hasheq 'state state
                    'error (or error #f)
                    'staged (or staged #f))))

(define (update-flow-status)
  (define f (unbox flow-box))
  ;; jsexpr only allows symbol KEYS, never symbol VALUES — the state is
  ;; transported as a string
  (hasheq 'state (let ([st (hash-ref f 'state)])
                   (if (symbol? st) (symbol->string st) st))
          'error (hash-ref f 'error #f)
          'staged (let ([p (hash-ref f 'staged #f)]) (and p (path->string p)))
          'install_command
          (let ([p (hash-ref f 'staged #f)])
            (and p (apply-staged-deb-command p)))))

;; Download + verify + stage the checked candidate. Runs on a watched
;; worker thread (the API spawns the flow and polls the status) — a second
;; prepare while running fails with "already running". The kind argument is
;; kept for the API shape; what gets staged is the artifact the signed
;; manifest picked for this install at check time.
(define (update-prepare! kind candidate)
  (define state (hash-ref (unbox flow-box) 'state))
  (when (member state '(downloading applying))
    (error 'updater "an update flow is already running"))
  (unless (update-candidate? candidate)
    (error 'updater "no verified update candidate; run an update check first"))
  (flow-set! 'downloading)
  (set-box! last-progress-seconds (current-seconds))
  (define worker
    (thread
     (lambda ()
       ;; The watchdog breaks a stalled worker; exn:break is not an
       ;; exn:fail, so it needs its own arm — either way rivet's partial
       ;; cleanup removes the .partial and the flow lands on failed
       ;; (never mid-flight).
       (with-handlers
           ([(lambda (e) (or (exn:fail? e) (exn:break? e)))
             (lambda (e)
               (define message
                 (if (exn:break? e)
                     "update download stalled or timed out"
                     (exn-message e)))
               (flow-set! 'failed #:error message)
               (log-error "update prepare failed: ~a" message))])
         (define staged (download-candidate! candidate))
         (flow-set! 'staged #:staged staged)))))
  ;; Watchdog: exits once the worker finishes on its own; otherwise a stall
  ;; (no byte progress) or the total wall-clock limit breaks the worker so
  ;; the flow never rests on "downloading" indefinitely.
  (define started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout download-stall-limit-seconds (thread-dead-evt worker))
          (void)]
         [(or (> (- (current-seconds) (unbox last-progress-seconds))
                 download-stall-limit-seconds)
              (> (- (current-seconds) started) download-total-limit-seconds))
          (break-thread worker)]
         [else (loop)]))))
  (void))

;; Apply a staged deb through pkexec — the operator sees the standard
;; system authentication dialog and consents explicitly. Nothing runs
;; without that consent (headless sessions have no polkit agent; they use
;; the printed command instead).
(define (update-apply!)
  (define f (unbox flow-box))
  (unless (equal? (hash-ref f 'state) 'staged)
    (error 'updater "nothing staged to apply"))
  (unless (pkexec-available?)
    (error 'updater "pkexec not available; run the install command manually"))
  (flow-set! 'applying)
  (thread
   (lambda ()
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (flow-set! 'failed #:error (exn-message e)))])
       (define rc
         (system*/exit-code "pkexec" "apt-get" "install" "-y"
                            (path->string (hash-ref f 'staged))))
       (if (zero? rc)
           (flow-set! 'applied)
           (flow-set! 'failed #:error "pkexec install failed"))))))
