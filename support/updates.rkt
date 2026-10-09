#lang racket/base

;; Online update check. Deliberately thin over glaze/update: fetch the
;; manifest once at startup (background thread — a 5s network stall must
;; never delay first paint), broadcast 'update-available on the app bus and
;; let the UI decide what "update available" means (a pill + toast here).
;;
;; The product is a system deb: it never self-installs silently. The
;; signed-artifact download/verify/stage/apply flow lives in
;; support/updater.rkt and only runs when the operator clicks through the
;; UI. Air-gapped hosts: --no-update-check skips everything.
;;
;; latest.json (manifest v2) lives on the repo's main branch; a release
;; bumps "version" there last, which is what makes the check fire for
;; older installs. Artifact entries carry the release download url, the
;; artifact sha256 and its Ed25519 signature (glaze/signing).

(require glaze/update
         json
         net/http-client
         racket/file
         racket/list
         racket/port
         racket/string)

(provide update-manifest-url
         read-repo-manifest-version
         manifest-version-valid?
         update-info-box
         update-manifest-box
         fetch-latest-manifest)

(define update-manifest-url
  "https://raw.githubusercontent.com/turinglambdaai/gptp-studio/main/latest.json")

;; Last successful check result (hasheq: version/url/notes) or #f. The
;; startup thread writes it; /api/bootstrap reads it so the header pill
;; survives page reloads — the SSE broadcast is fire-and-forget and never
;; replays.
(define update-info-box (box #f))

;; The full v2 manifest of the last successful check (hasheq with an
;; `artifacts` list) or #f. The in-app updater stages from this.
(define update-manifest-box (box #f))

;; Repo-hygiene helper (used by tests): the shipped latest.json must stay a
;; well-formed manifest, otherwise every older install silently loses its
;; update check.
(define (read-repo-manifest-version path)
  (define data
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (string->jsexpr (file->string path))))
  (and (hash? data)
       (hash-ref data 'version #f)))

(define (manifest-version-valid? v)
  (and (string? v)
       (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+$" v)))

;; Fetch and parse the manifest; #f on any network/parse failure (callers
;; treat that as "no update information").
(define (fetch-latest-manifest url)
  (define m (regexp-match #rx"^https?://([^/]+)(/.*)?$" url))
  (unless m (error 'updates "bad manifest url: ~a" url))
  (define host (list-ref m 1))
  (define path (or (list-ref m 2) "/"))
  (define ssl? (string-ci=? (substring url 0 5) "https"))
  ;; Preload the openssl/ssl module so https-sendrecv finds it. Racket 9.3's
  ;; dynamic-require rejects anything but 'error in the fail position — passing #f
  ;; here (the old form) raised exn:fail:contract before the connection was
  ;; even attempted, which the startup handler then swallowed: the https
  ;; update check silently never ran.
  (when ssl? (dynamic-require 'openssl #f))
  (define-values (_st _hd in)
    (with-handlers ([exn:fail? (lambda (_) (values #f #f #f))])
      (http-sendrecv host path
                     #:port (or (let ([p (regexp-match #rx":([0-9]+)$" host)])
                                  (and p (string->number (second p))))
                                (if ssl? 443 80))
                     #:ssl? (if ssl? 'auto #f))))
  (unless in (raise (error 'updates "manifest fetch failed")))
  (define body (port->string in))
  (close-input-port in)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (string->jsexpr body)))
