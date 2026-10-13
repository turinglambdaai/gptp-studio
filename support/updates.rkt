#lang racket/base

;; Online update check, built on rivet/distribution — the family pattern
;; (taskly benchmark; pdfgist/syncpilot/regexmate/podlens/autarx): the feed
;; is an Ed25519-signed manifest wrapper (update-stable.json on this repo's
;; main branch) that rivet's fetch-update-manifest fetches over HTTPS-only
;; with a built-in redirect budget (the GitHub release-asset 302 onto the
;; CDN), caps the body at 1 MiB, and signature-verifies before anything
;; else looks at the bytes. Selection policy (identity, channel, SemVer
;; precedence, rollout) is rivet's select-update; picking the artifact for
;; the running install (deb vs tarball) stays product policy here — rivet's
;; installer kinds have no deb/tarball pair (regexmate's pick-artifact
;; pattern).
;;
;; The check runs once at startup on a background thread (a slow network
;; must never delay first paint) and every failure folds to "no update":
;; the fetch is wrapped in a watchdog because rivet's socket has no read
;; timeout — a connection that stalls without RST/FIN would otherwise park
;; the startup thread forever.
;;
;; Trust chain: TLS authenticates nothing here; the Ed25519 signature
;; (made with a private key that never leaves the operator's vault)
;; decides what this build accepts, pinned via update-public-key-b64
;; below. The rotation anchor remains app/keys/updater/public.pem (the
;; test suite ties the two together). This retires the unsigned
;; latest.json scheme: pre-switch installs (<= 1.2.0) fetch a feed that no
;; longer exists, so they silently lose the automatic check and need a
;; one-off manual update (the release notes say so; the podlens/autarx
;; precedent).
;;
;; The product is a system deb: it never self-installs silently. The
;; download/stage/apply flow lives in support/updater.rkt and only runs
;; when the operator clicks through the UI. Air-gapped hosts:
;; --no-update-check skips everything; GPTP_UPDATE_MANIFEST_URL (if set)
;; must be HTTPS — the signed scheme refuses plain HTTP by design.

(require crypto
         rivet/distribution
         racket/string)

(provide app-update-identifier
         app-update-channel
         update-key-id
         update-public-key-b64
         ed25519-spki-prefix
         releases-page-url
         update-manifest-url
         embedded-public-key
         update-current-version
         make-updater-config
         platform-symbol
         architecture-symbol
         system-install?
         pick-artifact
         check-for-update
         update-info
         update-info-box
         update-manifest-box
         call-under-watchdog!)

;; ---- product facts -------------------------------------------------------------

;; The feed's application identity. rivet.rktd has no identifier field; the
;; family convention is site.jrtx.<product>.
(define app-update-identifier "site.jrtx.gptp-studio")
(define app-update-channel 'stable)

;; Key id of the release signing key (the UPDATER_PRIVATE_KEY secret).
(define update-key-id "gptp-studio-2026-10")

;; Ed25519 public key, base64 of the raw 32 bytes — the tail of
;; app/keys/updater/public.pem's SPKI DER (the PEM body is the whole DER).
;; The private half lives only in the operator's vault plus the repo's
;; UPDATER_PRIVATE_KEY secret; it never ships. Rotate by shipping a build
;; that trusts the next key before signing releases exclusively with it
;; (rivet docs/release-and-updates.md).
(define update-public-key-b64
  "MlDmygu/WAI5F4TDyRzx5xswfR7i1H1J5XNbAH9rBEk=")

;; SubjectPublicKeyInfo DER prefix (hex 302a300506032b6570032100): the 12
;; bytes every raw Ed25519 public key is prefixed with to form its SPKI DER.
(define ed25519-spki-prefix
  (bytes 48 42 48 5 6 3 43 101 112 3 33 0))

(define (embedded-public-key)
  (datum->pk-key (bytes-append ed25519-spki-prefix
                               (base64-string->bytes update-public-key-b64))
                 'SubjectPublicKeyInfo))

;; The running version — set by main.rkt from app/state.rkt's app-version.
;; A parameter (not a require of app/state.rkt) so the updater drags none
;; of the engine into scope and tests can drive the selection policy.
(define update-current-version (make-parameter "0.0.0"))

;; rivet release tooling emits these exact symbols into update manifests
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; Releases go out at 100% rollout and there is no per-install state file
;; to make a bucket sticky, so bucket 0 — which always sees the release
;; (the regexmate rule).
(define update-rollout-bucket 0)

;; Hard ceiling on any staged download; the signed per-artifact size is the
;; tighter bound rivet enforces first. 150 MB — the release artifacts are
;; well under; a runaway mirror cannot fill the disk.
(define maximum-download-bytes (* 150 1024 1024))

(define (make-updater-config [current-version (update-current-version)])
  (updater-config app-update-identifier
                  current-version
                  app-update-channel
                  (platform-symbol)
                  (architecture-symbol)
                  (embedded-public-key)
                  update-key-id
                  update-rollout-bucket
                  maximum-download-bytes))

;; ---- feed location -------------------------------------------------------------

(define releases-page-url
  "https://github.com/turinglambdaai/gptp-studio/releases/latest")

;; The signed feed lives on the repo's main branch; raw.githubusercontent
;; serves it over HTTPS like any file server. A release regenerates and
;; commits it last ("feed: x.y.z") — that commit is what makes the check
;; fire for older installs.
(define update-manifest-url
  "https://raw.githubusercontent.com/turinglambdaai/gptp-studio/main/update-stable.json")

;; ---- install shape -------------------------------------------------------------

;; System installs live under /opt or /usr (the deb); everything else is a
;; relocatable tarball. #:exe overrides the executable path so tests can
;; pretend.
(define (system-install? #:exe [exe (find-system-path 'run-file)])
  (and (path? exe)
       (let ([s (path->string exe)])
         (or (string-contains? s "/opt/") (string-contains? s "/usr/")))))

;; Product-side artifact pick over a verified manifest (rivet's
;; #:install-kind has no deb/tarball pair; regexmate's pick-artifact
;; pattern): deb for system installs, tarball otherwise. The feed serves
;; linux x64 deb + targz; arm64 installs pick nothing and stay on manual
;; updates (CHANGELOG 1.2.0).
(define (pick-artifact manifest #:system-install? [system? (system-install?)])
  (define kind-wanted (if system? 'deb 'targz))
  (for/first ([a (in-list (update-manifest-artifacts manifest))]
              #:when (and (eq? (update-artifact-platform a) (platform-symbol))
                          (eq? (update-artifact-architecture a) (architecture-symbol))
                          (eq? (update-artifact-installer a) kind-wanted)))
    a))

;; ---- transport -----------------------------------------------------------------
;; rivet owns the network leg: fetch-update-manifest enforces HTTPS, caps
;; the body, follows the release-asset redirects and verifies the Ed25519
;; signature before anything else looks at the bytes. Timeouts: rivet's
;; copy loop waits on read-bytes-avail! with no deadline — net/url ports
;; have no read timeout, so a connection that stalls without RST/FIN would
;; park the startup thread forever. The fetch runs on a supervised worker
;; thread that a watchdog breaks on the deadline (the taskly updater's
;; watchdog, regexmate's synchronous adaptation).

(define manifest-deadline-seconds 60)

;; Run THUNK (receiving a `touch` procedure that refreshes the stall clock)
;; on a worker thread under a watchdog. Returns the thunk's value; a
;; timeout or worker failure raises. The manifest fetch has no progress
;; surface and ignores `touch` (its deadline is the stall limit).
(define (call-under-watchdog! who stall-limit-seconds total-limit-seconds thunk)
  (define last-tick (box (current-seconds)))
  (define outcome (box #f))
  (define timed-out? (box #f))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([(lambda (e) #t)
                        (lambda (e) (set-box! outcome (cons 'raised e)))])
         (set-box! outcome
                   (cons 'returned
                         (thunk (lambda ()
                                  (set-box! last-tick (current-seconds))))))))))
  (define started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout stall-limit-seconds (thread-dead-evt worker)) (void)]
         [(or (> (- (current-seconds) (unbox last-tick)) stall-limit-seconds)
              (> (- (current-seconds) started) total-limit-seconds))
          (set-box! timed-out? #t)
          (break-thread worker)]
         [else (loop)]))))
  ;; The watchdog breaks the worker at the limits; wait a little past them
  ;; so the break lands before this call gives up on the worker.
  (unless (sync/timeout (+ total-limit-seconds 30) worker)
    (error who "update transfer outlived its watchdog budget"))
  (define record (unbox outcome))
  (cond
    [(and record (eq? (car record) 'returned)) (cdr record)]
    [(unbox timed-out?)
     (error who "update transfer timed out (stall or wall-clock limit)")]
    [(and record (eq? (car record) 'raised)) (raise (cdr record))]
    [else (error who "update worker failed without a result")]))

;; ---- check ---------------------------------------------------------------------

;; Fetch and verify the signed feed at url, apply rivet's selection policy
;; for the running install, and pick this install's artifact. Returns an
;; update-candidate, or #f when the release is not actionable for this
;; install (up to date, channel mismatch, rollout, no artifact for this
;; platform/arch/install shape). Raises on network or verification failure
;; — the startup caller folds those to "no update information".
(define (check-for-update url
                          #:current-version [current (update-current-version)])
  (define manifest
    (call-under-watchdog!
     'check-for-update
     manifest-deadline-seconds
     manifest-deadline-seconds
     (lambda (_touch)
       (fetch-update-manifest url
                              (embedded-public-key)
                              #:key-id update-key-id))))
  (define candidate (select-update (make-updater-config current) manifest))
  (and candidate
       (let ([artifact (pick-artifact manifest)])
         (and artifact (update-candidate manifest artifact)))))

;; UI-facing summary for the header pill. The rivet manifest schema carries
;; no free-form notes — the release page (which the pill links to) carries
;; them, so the pill's tooltip simply stays unset.
(define (update-info candidate)
  (define manifest (update-candidate-manifest candidate))
  (hasheq 'version (update-manifest-version manifest)
          'url releases-page-url
          'build (update-manifest-build manifest)
          'published-at (update-manifest-published-at manifest)))

;; ---- shared boxes (protocol unchanged since the glaze check) -------------------

;; Last successful check result (hasheq: version/url/...) or #f. The
;; startup thread writes it; /api/bootstrap reads it so the header pill
;; survives page reloads — the SSE broadcast is fire-and-forget and never
;; replays.
(define update-info-box (box #f))

;; The verified update-candidate (signed manifest + this install's
;; artifact) of the last successful check, or #f. The in-app updater
;; stages from this.
(define update-manifest-box (box #f))
