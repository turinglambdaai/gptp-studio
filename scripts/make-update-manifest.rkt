#lang racket/base

;; Regenerate the update feed (update-stable.json, the rivet signed
;; manifest wrapper) from the built release artifacts. The Release workflow
;; runs this after the assets are published and commits the result to main
;; ("feed: x.y.z") — that commit is what makes the update check fire for
;; older installs. It is also the manual tool for rebuilding the feed:
;;
;;   racket scripts/make-update-manifest.rkt \
;;     --version 1.3.0 \
;;     --deb gPTP-Studio-linux-x64.deb \
;;     --tarball gPTP-Studio-linux-x64.tar.gz \
;;     --private-key updater-priv.pem \
;;     --verify-public-key app/keys/updater/public.pem
;;
;; Wire format: rivet/distribution's signed wrapper (schema + base64
;; payload + Ed25519 signature block) — exactly what
;; support/updates.rkt's fetch-update-manifest verifies, with key id
;; gptp-studio-2026-10. The payload carries the artifact urls (stable
;; releases/latest/download aliases), sizes and lowercase-hex SHA-256
;; digests; there is no free-form notes field (release notes live on the
;; release page, which the header pill links to).
;;
;; The private key never touches this repo: the caller materializes it as
;; a file (CI: the UPDATER_PRIVATE_KEY Actions secret; locally: the
;; operator's vault) and deletes it afterwards. Both PEM (PKCS#8, what the
;; Actions secret stores) and raw DER are accepted.

(require net/base64
         racket/cmdline
         racket/file
         racket/format
         racket/path
         racket/port
         racket/string
         rivet/distribution)

(define default-base-url "https://github.com/turinglambdaai/gptp-studio")
(define feed-key-id "gptp-studio-2026-10")
(define feed-application-id "site.jrtx.gptp-studio")
(define feed-channel 'stable)

(define version-param (make-parameter #f))
(define deb-param (make-parameter #f))
(define tarball-param (make-parameter #f))
(define key-param (make-parameter #f))
(define out-param (make-parameter "update-stable.json"))
(define base-url-param (make-parameter default-base-url))
(define verify-pub-param (make-parameter #f))

(command-line
 #:program "make-update-manifest"
 #:once-each
 [("--version") v "release version, x.y.z without the leading v" (version-param v)]
 [("--deb") p "path to the built deb asset" (deb-param p)]
 [("--tarball") p "path to the built tarball asset" (tarball-param p)]
 [("--private-key") p "Ed25519 private key file, PEM (PKCS#8) or DER" (key-param p)]
 [("--out") p "output path (default: update-stable.json)" (out-param p)]
 [("--base-url") u "repository base url" (base-url-param u)]
 [("--verify-public-key") p
  "after writing, re-verify the feed with this public key (PEM or DER)"
  (verify-pub-param p)])

(define (require-arg what value)
  (unless (and (string? value) (not (string=? "" value)))
    (raise-user-error 'make-update-manifest "missing required argument: ~a" what))
  value)

(define version (require-arg "--version" (version-param)))
(define deb-path (require-arg "--deb" (deb-param)))
(define tarball-path (require-arg "--tarball" (tarball-param)))
(define private-key (require-arg "--private-key" (key-param)))

(unless (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+$" version)
  (raise-user-error 'make-update-manifest
                    "version must be x.y.z without the leading v, got: ~a" version))

(for ([p (list deb-path tarball-path)])
  (unless (file-exists? p)
    (raise-user-error 'make-update-manifest "artifact not found: ~a" p)))
(unless (file-exists? private-key)
  (raise-user-error 'make-update-manifest "private key not found: ~a" private-key))

;; ---- key material --------------------------------------------------------------
;; rivet's read-ed25519-*-key decode DER (OneAsymmetricKey / PrivateKeyInfo /
;; SubjectPublicKeyInfo); the release secret and the repo anchor are PEM
;; (base64 armor around the same DER), so strip the armor when markers are
;; present. The DER detour runs through a temp file that is deleted before
;; this process exits.

(define (pem-armor->der raw)
  (define b64
    (string-append*
     (for/list ([line (in-lines (open-input-bytes raw))]
                #:unless (or (string-prefix? line "-----")
                             (equal? "" (string-trim line))))
       (string-trim line))))
  (or (base64-decode (string->bytes/utf-8 b64))
      (raise-user-error 'make-update-manifest
                        "PEM body is not valid base64: ~a" private-key)))

(define (der-of-key-file path)
  (define raw (file->bytes path))
  (if (regexp-match? #px"-----BEGIN" raw)
      (pem-armor->der raw)
      raw))

(define (call-with-der-file bytes proc)
  (define der-file (make-temporary-file "gptp-feed-key~a.der"))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? der-file) (delete-file der-file))
                     (raise e))])
    (call-with-output-file der-file
      (lambda (out) (write-bytes bytes out))
      #:exists 'truncate)
    (begin0 (proc der-file)
      (when (file-exists? der-file) (delete-file der-file)))))

(define signing-key
  (call-with-der-file
   (der-of-key-file private-key)
   read-ed25519-private-key))

;; ---- build + sign the manifest --------------------------------------------------
;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.

(define (artifact installer file)
  (unless (file-exists? file)
    (raise-user-error 'make-update-manifest "missing artifact: ~a" file))
  (update-artifact 'linux 'x64
                   (string-append (base-url-param)
                                  "/releases/latest/download/"
                                  (path->string (file-name-from-path
                                                 (simple-form-path file))))
                   (sha256-file/hex file)
                   (file-size file)
                   installer
                   '()))

(define manifest
  (update-manifest
   feed-application-id
   version
   1
   feed-channel
   ;; published-at: RFC 3339, second precision, UTC
   (let ([d (seconds->date (current-seconds) #f)])
     (format "~a-~a-~aT~a:~a:~aZ"
             (date-year d)
             (~r (date-month d) #:min-width 2 #:pad-string "0")
             (~r (date-day d) #:min-width 2 #:pad-string "0")
             (~r (date-hour d) #:min-width 2 #:pad-string "0")
             (~r (date-minute d) #:min-width 2 #:pad-string "0")
             (~r (date-second d) #:min-width 2 #:pad-string "0")))
   "0.0.0"
   #f
   #t
   100
   (list (artifact 'deb deb-path)
         (artifact 'targz tarball-path))))

(define out-path (path->complete-path (out-param)))
(call-with-output-file out-path
  (lambda (out)
    (write-signed-manifest manifest signing-key feed-key-id out)
    (newline out))
  #:exists 'replace)

(printf "wrote ~a (version ~a, key-id ~a)~%"
        (out-param) version feed-key-id)
(for ([a (in-list (update-manifest-artifacts manifest))])
  (printf "  ~a: ~a (~a bytes)~%"
          (update-artifact-installer a)
          (update-artifact-sha256 a)
          (update-artifact-size a)))

;; ---- post-write verification ----------------------------------------------------
;; Prove the feed we just wrote verifies exactly the way the updater will,
;; against the pinned public key of the build being released — this is the
;; release guard: a private key that is not the exact counterpart of the
;; pinned public key fails here, before anything is committed.

(when (verify-pub-param)
  (define verified
    (call-with-der-file
     (der-of-key-file (verify-pub-param))
     (lambda (der-file)
       (verify-signed-manifest
        (open-input-string (file->string out-path))
        (read-ed25519-public-key der-file)
        #:key-id feed-key-id))))
  (unless (equal? (update-manifest-version verified) version)
    (raise-user-error 'make-update-manifest
                      "feed self-verification version mismatch: ~a vs ~a"
                      (update-manifest-version verified) version))
  (define pairs (list (cons 'deb deb-path) (cons 'targz tarball-path)))
  (for ([pair pairs])
    (define file (cdr pair))
    (define entry
      (for/first ([a (in-list (update-manifest-artifacts verified))]
                  #:when (eq? (update-artifact-installer a) (car pair)))
        a))
    (unless (and entry
                 (equal? (update-artifact-sha256 entry) (sha256-file/hex file))
                 (= (update-artifact-size entry) (file-size file)))
      (raise-user-error
       'make-update-manifest
       "feed self-verification failed for ~a against ~a; do not publish"
       (car pair) (verify-pub-param)))
    (printf "  verified ~a digest/size against ~a~%"
            (car pair) (verify-pub-param))))
