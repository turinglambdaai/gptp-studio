#lang racket/base

;; In-app self-update: download the new release artifact, verify its
;; Ed25519 signature against the pinned updater public key, check the
;; manifest sha256, and stage it for installation.
;;
;; Trust chain: TLS gets the manifest; the Ed25519 signature (made with a
;; private key that never lives on a server) authenticates the artifact;
;; the pinned public key in this repo decides what the app accepts. A
;; compromised release host can serve stale artifacts, never accepted
;; malicious ones.
;;
;; Apply policy: this product installs as a system deb, so applying needs
;; the operator's explicit consent — pkexec raises the standard system
;; authentication dialog for `apt-get install ./staged.deb` (nothing is
;; done behind their back; headless environments get the exact command to
;; run themselves). Air-gapped hosts: --no-update-check skips everything.

(require glaze/signing
         net/http-client
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         racket/system)

(provide update-stage-dir
         ensure-update-stage-dir
         pinned-updater-public-key
         artifact-entry
         pick-artifact-entry
         download-and-verify-artifact
         staged-artifact-path
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

;; The updater public key is committed next to the license one; it pins
;; what this build accepts. (The private half lives off-repo, in the
;; operator's key vault.)
(define-runtime-path updater-public-key-path
  "../app/keys/updater/public.pem")

(define (pinned-updater-public-key)
  updater-public-key-path)

;; Manifest v2 artifact entry:
;;   {"kind": "deb"|"tarball", "url": ..., "sha256": ..., "signature": ...}
(define (artifact-entry manifest kind)
  (and (hash? manifest)
       (for/first ([a (in-list (hash-ref manifest 'artifacts '()))]
                   #:when (equal? (hash-ref a 'kind #f) kind))
         a)))

;; Pick the artifact matching the running install: deb for system
;; installs (/opt, /usr), tarball for relocatable ones.
(define (pick-artifact-entry manifest)
  (define system-install?
    (let ([exe (find-system-path 'run-file)])
      (and (path? exe)
           (let ([s (path->string exe)])
             (or (string-contains? s "/opt/") (string-contains? s "/usr/"))))))
  (artifact-entry manifest (if system-install? "deb" "tarball")))

;; Download url to dest, streaming with a hard size cap (150 MB — the
;; release artifacts are well under; a runaway mirror cannot fill the disk).
(define (download-to-file url dest #:max-bytes [max-bytes (* 150 1024 1024)])
  (define m (regexp-match #rx"^https?://([^/]+)(/.*)?$" url))
  (unless m (error 'updater "bad download url: ~a" url))
  (define authority (list-ref m 1))
  ;; strip any :port suffix — http-sendrecv takes host and port separately,
  ;; and getaddrinfo rejects "host:port" as a hostname
  (define host (car (string-split authority ":")))
  (define ssl? (string-ci=? (substring url 0 5) "https"))
  (when ssl? (dynamic-require 'openssl 'ssl-connect #f))
  (define port-num
    (or (let ([p (regexp-match #rx":([0-9]+)$" authority)])
          (and p (string->number (second p))))
        (if ssl? 443 80)))
  (define path (or (list-ref m 2) "/"))
  (define-values (_st _hd in)
    (http-sendrecv host path
                   #:port port-num
                   #:ssl? (if ssl? 'auto #f)))
  (call-with-output-file dest
    (lambda (out)
      (define total 0)
      (let loop ()
        (define chunk (read-bytes 65536 in))
        (unless (eof-object? chunk)
          (set! total (+ total (bytes-length chunk)))
          (when (> total max-bytes)
            (error 'updater "download exceeds ~a bytes; aborting" max-bytes))
          (write-bytes chunk out)
          (loop))))
    #:exists 'replace)
  (close-input-port in)
  dest)

;; Download url, verify signature (Ed25519, pinned key) + sha256 (manifest),
;; stage under the update dir. Returns the staged path; raises on any
;; verification failure (the caller surfaces the message verbatim).
;; #:public-key overrides the pinned key — the test suite uses that to
;; sign/verify with its own keypair (CI has no access to the release key).
(define (download-and-verify-artifact entry
                                      #:dest-name [dest-name #f]
                                      #:public-key [public-key (pinned-updater-public-key)])
  (unless (and (hash? entry)
               (string? (hash-ref entry 'url #f))
               (string? (hash-ref entry 'sha256 #f))
               (string? (hash-ref entry 'signature #f)))
    (error 'updater "manifest artifact entry is missing url/sha256/signature"))
  (ensure-update-stage-dir)
  (define dest
    (build-path (update-stage-dir)
                (or dest-name
                    (path->string
                     (file-name-from-path
                      (string->path (hash-ref entry 'url)))))))
  (download-to-file (hash-ref entry 'url) dest)
  (unless (verify-signature dest
                            #:public-key public-key
                            #:signature (hash-ref entry 'signature)
                            #:expected-sha256 (hash-ref entry 'sha256))
    (delete-file dest)
    (error 'updater
           "update artifact failed signature verification; deleted. Report this."))
  dest)

;; The exact command that applies a staged deb on a system install
;; (shown in the UI; apply itself goes through pkexec with the operator's
;; explicit authentication).
(define (apply-staged-deb-command staged-path)
  (format "sudo apt-get install -y ~a" (path->string staged-path)))

(define (pkexec-available?)
  (file-exists? "/usr/bin/pkexec"))

(define (staged-artifact-path kind)
  (define dir (update-stage-dir))
  (case kind
    [(deb) (build-path dir "gPTP-Studio-linux-x64.deb")]
    [(tarball) (build-path dir "gPTP-Studio-linux-x64.tar.gz")]
    [else #f]))

;; ---- flow state machine (prepare -> staged -> apply -> applied) --------------

(provide update-prepare!
         update-apply!
         update-flow-status)

;; One flow at a time; the UI polls this hash through /api/update/status.
(define flow-box (box (hasheq 'state 'idle)))

(define (flow-set! state #:error [error #f] #:staged [staged #f])
  (set-box! flow-box
            (hasheq 'state state
                    'error (or error #f)
                    'staged (or staged #f))))

(define (update-flow-status)
  (define f (unbox flow-box))
  (hasheq 'state (hash-ref f 'state)
          'error (hash-ref f 'error #f)
          'staged (let ([p (hash-ref f 'staged #f)]) (and p (path->string p)))
          'install_command
          (let ([p (hash-ref f 'staged #f)])
            (and p (apply-staged-deb-command p)))))

;; Download + verify + stage the manifest artifact for `kind`. Runs in the
;; caller's thread (the API spawns one) — a second prepare while running
;; fails with "already running".
(define (update-prepare! kind manifest)
  (define state (hash-ref (unbox flow-box) 'state))
  (when (member state '(downloading applying))
    (error 'updater "an update flow is already running"))
  (flow-set! 'downloading)
  (thread
   (lambda ()
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (flow-set! 'failed #:error (exn-message e))
             (log-error "update prepare failed: ~a" (exn-message e)))])
       (define entry
         (or (pick-artifact-entry manifest)
             (error 'updater "manifest has no ~a artifact" kind)))
       (define staged (download-and-verify-artifact entry))
       (flow-set! 'staged #:staged staged)))))

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
