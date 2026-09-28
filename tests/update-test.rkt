#lang racket/base

;; Update-check wiring: the shipped manifest must stay well formed (a broken
;; latest.json silently kills the check for every older install), and the
;; glaze check-update contract must hold over real HTTP end to end.

(require rackunit
         racket/file
         racket/runtime-path
         glaze/server
         glaze/update
         "../support/updates.rkt")

(define-runtime-path repo-manifest "../latest.json")

;; ---- shipped manifest hygiene ------------------------------------------------

(define manifest-version (read-repo-manifest-version repo-manifest))
(check-true (manifest-version-valid? manifest-version)
            "latest.json carries an x.y.z version")
(check-true (file-exists? repo-manifest))

;; ---- end-to-end check over real HTTP ------------------------------------------

;; serve a manifest from a temp dir: a newer release must surface, and the
;; same version must report nothing.
(define tmp (make-temporary-file "gptp-update-~a" 'directory))
(define-values (port stop) (start-server #:port 18931 #:public-dir tmp))
(call-with-output-file (build-path tmp "manifest.json")
  (lambda (out)
    (display "{\"version\": \"9.9.9\", \"url\": \"https://example.com/rel\", \"notes\": \"test\"}" out))
  #:exists 'replace)
(define hit (check-update (format "http://127.0.0.1:~a/manifest.json" port)
                          #:current-version "1.0.0"))
(check-true (hash? hit) "newer manifest is detected")
(check-equal? (and hit (hash-ref hit 'version #f)) "9.9.9")
(check-equal? (and hit (hash-ref hit 'url #f)) "https://example.com/rel")

(define none (check-update (format "http://127.0.0.1:~a/manifest.json" port)
                           #:current-version "9.9.9"))
(check-false none "same version reports no update")

;; a missing/garbage manifest degrades to #f, never raises
(check-false (check-update (format "http://127.0.0.1:~a/nope.json" port)
                           #:current-version "1.0.0"))
(stop)
(delete-directory/files tmp)
