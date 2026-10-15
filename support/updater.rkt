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
;; Apply policy (docs/update-contract.md), per install shape:
;; - deb (system installs under /opt or /usr): the download is kept and the
;;   operator gets the exact package-manager command; apply itself goes
;;   through pkexec, which raises the standard system authentication
;;   dialog — nothing is done behind their back, and headless environments
;;   run the printed command themselves.
;; - tar.gz (relocatable installs): apply swaps the payload in place —
;;   extract to a temp dir beside the stage, rename the running install
;;   root to <root>.old (kept until the next swap), move the extracted
;;   payload in, and chmod the launch executables with the integer mode
;;   #o755. The running process keeps its mappings; the next launch is the
;;   new version. A failed swap restores <root>.old, so the previous
;;   install always stays runnable.
;; Air-gapped hosts: --no-update-check skips everything (the host owns the
;; flag; the RPCs stay reachable for the About dialog only).

(require rivet/distribution
         racket/file
         racket/path
         racket/string
         racket/system
         "updates.rkt")

(provide update-stage-dir
         ensure-update-stage-dir
         staged-artifact-path
         download-candidate!
         apply-staged-deb-command
         pkexec-available?
         payload-root
         tarball-apply!)

;; Where verified artifacts wait for installation.
(define (update-stage-dir)
  (build-path (find-system-path 'home-dir)
              ".local" "share" "gptp-studio" "updates"))

(define (ensure-update-stage-dir)
  (define dir (update-stage-dir))
  (make-directory* dir)
  dir)

;; Staged file name for an artifact — derived from the feed entry's URL
;; basename, which is the release asset name itself (rivet releases name
;; assets versioned: gptp-studio-<v>-linux-<arch>.deb/.tar.gz). Staging
;; under the asset name keeps the printed install command identical to the
;; manual download flow.
(define (staged-artifact-path artifact)
  (define name (file-name-from-path (update-artifact-url artifact)))
  (and name (build-path (update-stage-dir) name)))

;; Download the candidate's artifact into the stage dir. rivet owns the
;; redirect-following fetch (releases/latest/download aliases answer 302
;; with a CDN handoff), the signed-size cap, .partial cleanup on any
;; failure, SHA-256 + size verification against the signed manifest, and
;; the atomic rename. Synchronous; raises on failure — update-prepare!
;; wraps it in the watched worker thread. Every progress report feeds the
;; watchdog's stall clock and the flow's percent.
(define (download-candidate! candidate)
  (define artifact (update-candidate-artifact candidate))
  (define destination (staged-artifact-path artifact))
  (unless destination
    (error 'updater "no staged name for artifact url ~a"
           (update-artifact-url artifact)))
  (define total (update-artifact-size artifact))
  (download-update (make-updater-config) candidate destination
                   #:on-progress
                   (lambda (bytes)
                     (set-box! last-progress-seconds (current-seconds))
                     (set-box! download-percent-box
                               (if (> total 0)
                                   (min 100 (quotient (* 100 bytes) total))
                                   0))))
  destination)

;; The exact command that applies a staged deb on a system install
;; (shown in the UI; apply itself goes through pkexec with the operator's
;; explicit authentication).
(define (apply-staged-deb-command staged-path)
  (format "sudo apt-get install -y ~a" (path->string staged-path)))

(define (pkexec-available?)
  (file-exists? "/usr/bin/pkexec"))

;; ---- tarball swap (relocatable installs) -------------------------------------
;;
;; 资产派生 -> download (digest gate) -> chmod (#o755, integer) -> 落盘.
;; The staged tar.gz extracts to a single top-level payload directory
;; (gptp-studio-distributed); the running install root is replaced by
;; renames with a <root>.old backup kept until the next swap.

;; The running payload root, or #f when it cannot be derived. The tarball
;; payload layout is <root>/bin/gptp-studio (the deb's /opt/gptp-studio is
;; the same layout); a top-level executable next to bin/ is fine too.
;; #:exe overrides the executable path so tests can pretend.
(define (payload-root #:exe [exe (find-system-path 'run-file)])
  (define s (and (path? exe) (path->string exe)))
  (define dir
    (and s
         (let ([m (regexp-match #px"^(.*)/[^/]+$" s)])
           (and m (cadr m)))))
  (define candidate
    (and dir
         (let ([m (regexp-match #px"^(.*)/bin$" dir)])
           (if m (cadr m) dir))))
  (and candidate
       (directory-exists? (build-path candidate "bin"))
       (string->path candidate)))

;; chmod the launch executables of a payload root. The mode MUST be the
;; integer bitmask #o755 — the symbol-list/vector form is the getter's
;; return shape, not a mode, and passing it is a contract violation the
;; family has shipped three times (taskly/movebit/pdfgist).
(define (chmod-payload-executables! root)
  (for ([rel (list (string->path "gptp-studio")
                   (build-path "bin" (string->path "gptp-studio")))]
        #:when (file-exists? (build-path root rel)))
    (file-or-directory-permissions (build-path root rel) #o755)))

;; Move a directory tree, falling back to copy+delete when src and dest
;; live on different filesystems (rename answers EXDEV).
(define (move-directory! src dest)
  (with-handlers ([exn:fail:filesystem?
                   (lambda (_)
                     (copy-directory/files src dest)
                     (delete-directory/files src))])
    (rename-file-or-directory src dest #f)))

;; tar lives at /usr/bin/tar on the validated floor (Ubuntu 24.04); resolve
;; through PATH where possible because dev machines (macOS) may carry PATH
;; entries that break subprocess's own relative-name resolution.
(define (tar-executable)
  (or (find-executable-path "tar") (string->path "/usr/bin/tar")))

;; Extract the staged tarball and swap it over the running payload root.
;; Returns the new root. The .old backup is restored if anything after the
;; first rename fails, so the previous install stays runnable.
(define (tarball-apply! staged-path
                        #:exe [exe (find-system-path 'run-file)])
  (define root (payload-root #:exe exe))
  (unless root
    (error 'updater "cannot locate the running payload root to replace"))
  (unless (file-exists? staged-path)
    (error 'updater "staged tarball is gone: ~a" staged-path))
  (ensure-update-stage-dir)
  (define extract-dir
    (make-temporary-file "gptp-extract~a" 'directory (update-stage-dir)))
  (define old-root (path-add-extension root ".old"))
  (dynamic-wind
    (lambda ()
      (define rc
        (system*/exit-code (tar-executable) "-xzf" (path->string staged-path)
                           "-C" (path->string extract-dir)))
      (unless (zero? rc)
        (error 'updater "tar extraction failed (exit ~a)" rc)))
    (lambda ()
      (define top
        (for/first ([entry (in-list (directory-list extract-dir))]
                    #:when (directory-exists? (build-path extract-dir entry)))
          entry))
      (unless top
        (error 'updater "the update tarball has no payload directory"))
      (define new-root (build-path extract-dir top))
      (when (directory-exists? old-root)
        (delete-directory/files old-root))
      (rename-file-or-directory root old-root)
      (with-handlers
          ([exn:fail?
            (lambda (e)
              ;; restore the previous install before surfacing the failure
              (with-handlers ([exn:fail? (lambda (_) (void))])
                (when (directory-exists? root)
                  (delete-directory/files root))
                (rename-file-or-directory old-root root))
              (raise e))])
        (move-directory! new-root root)
        (chmod-payload-executables! root))
      (delete-directory/files extract-dir)
      root)
    (lambda ()
      (when (directory-exists? extract-dir)
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files extract-dir))))))

;; ---- flow state machine (prepare -> staged -> apply -> applied) --------------

(provide update-prepare!
         update-apply!
         update-flow-status
         reset-update-flow!
         flow-set!)

;; One flow at a time; the host polls this through update-state.
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

;; Percent of the current download (0-100); meaningful in the downloading
;; phase, reported through update-flow-status for the host's progress bar.
(define download-percent-box (box 0))

(define (flow-set! state
                   #:error [error #f]
                   #:staged [staged #f]
                   #:percent [percent (unbox download-percent-box)])
  (set-box! flow-box
            (hasheq 'state state
                    'error (or error #f)
                    'staged (or staged #f)
                    'percent percent)))

(define (update-flow-status)
  (define f (unbox flow-box))
  ;; jsexpr only allows symbol KEYS, never symbol VALUES — the state is
  ;; transported as a string
  (hasheq 'state (let ([st (hash-ref f 'state)])
                   (if (symbol? st) (symbol->string st) st))
          'error (hash-ref f 'error #f)
          'staged (let ([p (hash-ref f 'staged #f)]) (and p (path->string p)))
          'percent (hash-ref f 'percent 0)
          'install_command
          (let ([p (hash-ref f 'staged #f)])
            (and p (equal? (path-get-extension p) #".deb")
                 (apply-staged-deb-command p)))))

;; Test/host seam: put the machine back to idle between flows.
(define (reset-update-flow!)
  (set-box! download-percent-box 0)
  (flow-set! 'idle #:error #f #:staged #f #:percent 0))

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
  (flow-set! 'downloading #:error #f #:staged #f #:percent 0)
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
         (flow-set! 'staged #:staged staged #:percent 100)))))
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

;; Apply a staged update, dispatching on what was staged:
;; - .deb: pkexec — the operator sees the standard system authentication
;;   dialog and consents explicitly. Nothing runs without that consent
;;   (headless sessions have no polkit agent; they use the printed command
;;   instead).
;; - .tar.gz: in-place payload swap (relocatable installs only — a system
;;   deb install always stages a deb, since pick-artifact keys off the
;;   install shape).
(define (update-apply!)
  (define f (unbox flow-box))
  (unless (equal? (hash-ref f 'state) 'staged)
    (error 'updater "nothing staged to apply"))
  (define staged (hash-ref f 'staged #f))
  (unless staged
    (error 'updater "nothing staged to apply"))
  (cond
    [(equal? (path-get-extension staged) #".deb")
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
                               (path->string staged)))
          (if (zero? rc)
              (flow-set! 'applied #:percent 100)
              (flow-set! 'failed #:error "pkexec install failed")))))]
    [(equal? (path-get-extension staged) #".gz")
     (when (system-install?)
       (error 'updater
              "system installs upgrade through the package manager; this staged artifact cannot be applied here"))
     (flow-set! 'applying)
     (thread
      (lambda ()
        (with-handlers
            ([exn:fail?
              (lambda (e)
                (flow-set! 'failed #:error (exn-message e))
                (log-error "update apply failed: ~a" (exn-message e)))])
          (tarball-apply! staged)
          (flow-set! 'applied #:percent 100))))]
    [else
     (error 'updater "unknown staged artifact shape: ~a" staged)]))
