#lang racket/base

;; Online update check. Deliberately thin over glaze/update: fetch the
;; manifest once at startup (background thread — a 5s network stall must
;; never delay first paint), broadcast 'update-available on the app bus and
;; let the UI decide what "update available" means (a pill + toast here).
;;
;; The product is a system deb: it never self-installs. The manifest's url
;; points at the releases page so the operator stays in control of what is
;; installed on a timing host — same posture as the packaging scripts that
;; refuse to touch privilege behind the operator's back.
;;
;; latest.json lives on the repo's main branch; a release bumps "version"
;; there last, which is what makes the check fire for older installs.

(require glaze/update
         json
         racket/file
         racket/string)

(provide update-manifest-url
         read-repo-manifest-version
         manifest-version-valid?)

(define update-manifest-url
  "https://raw.githubusercontent.com/turinglambdaai/gptp-studio/main/latest.json")

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
