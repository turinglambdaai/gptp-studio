#lang racket/base

;; Update-check wiring: the shipped manifest must stay well formed (a broken
;; latest.json silently kills the check for every older install), and the
;; glaze check-update contract must hold over real HTTP end to end.

(require rackunit
         racket/file
         racket/path
         racket/runtime-path
         racket/tcp
         glaze/server
         glaze/signing
         glaze/update
         "../support/updates.rkt"
         "../support/updater.rkt")

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

;; ---- manifest v2 artifacts: download, verify, stage --------------------------
(require glaze/signing
         racket/runtime-path
         "../support/updater.rkt")

;; repo hygiene: the pinned updater public key ships with the source
(define-runtime-path updater-pub "../app/keys/updater/public.pem")
(check-true (file-exists? updater-pub) "pinned updater public key exists")

;; test-local keypair in its own fresh temp dir (CI has no access to the
;; release signing key; the module takes the public key explicitly for
;; exactly this reason)
(define keydir (make-temporary-file "upd-keys~a" 'directory))
(define-values (tpriv tpub)
  (signing-keygen #:private-key (build-path keydir "updater-priv.pem")
                  #:public-key (build-path keydir "updater-pub.pem")))

;; self-contained server: the first section already stopped/deleted ITS
;; temp dir, so serve the artifact from a fresh one
(define v2-dir (make-temporary-file "upd-artifact~a" 'directory))
(define-values (v2-port v2-stop) (start-server #:port 18932 #:public-dir v2-dir))
;; poll-until-accepting (deadline 5s) — a fixed sleep races the listener
(let loop ([n 50])
  (define connected?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define-values (i o) (tcp-connect "127.0.0.1" v2-port))
      (close-input-port i)
      (close-output-port o)
      #t))
  (unless (or connected? (zero? n))
    (sleep 0.1)
    (loop (- n 1))))
(call-with-output-file (build-path v2-dir "gPTP-Studio-linux-x64.deb")
  (lambda (out) (write-bytes (make-bytes 1024 3) out)))
(define art-sig (sign-file (build-path v2-dir "gPTP-Studio-linux-x64.deb")
                           #:private-key tpriv))
(define art-sha (sha256-file (build-path v2-dir "gPTP-Studio-linux-x64.deb")))

(define manifest-v2
  (hasheq 'version "9.9.9"
          'artifacts
          (list (hasheq 'kind "deb"
                        'url (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" v2-port)
                        'sha256 art-sha
                        'signature art-sig))))

(check-equal? (hash-ref (artifact-entry manifest-v2 "deb") 'sha256) art-sha
              "artifact-entry picks by kind")
(check-false (artifact-entry manifest-v2 "nope") "unknown kind -> #f")

;; happy path: download + verify + stage
(define staged (download-and-verify-artifact
                (artifact-entry manifest-v2 "deb")
                #:public-key tpub))
(check-true (file-exists? staged) "staged artifact exists")
(v2-stop)
(delete-directory/files v2-dir)
(check-equal? (sha256-file staged) art-sha "staged bytes match the manifest sha256")

;; tampered signature -> error raised, nothing staged
(define bad-manifest
  (hasheq 'version "9.9.9"
          'artifacts
          (list (hasheq 'kind "deb"
                        'url (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" v2-port)
                        'sha256 art-sha
                        'signature "AA"))))
(check-exn exn:fail?
           (lambda ()
             (download-and-verify-artifact
              (hash-ref bad-manifest 'artifacts) #:public-key tpub))
           "broken entry raises")

;; wrong-key signature must also fail (authenticity, not just integrity)
(define-values (_wpriv _wpub)
  (signing-keygen #:private-key (build-path keydir "wrong.pem")
                  #:public-key (build-path keydir "wrong-pub.pem")))
(check-exn exn:fail?
           (lambda ()
             (download-and-verify-artifact
              (hasheq 'kind "deb"
                      'url (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" v2-port)
                      'sha256 art-sha
                      'signature (sign-file (build-path v2-dir "gPTP-Studio-linux-x64.deb")
                                            #:private-key tpriv))
              #:public-key tpub))
           "signature under a different key is rejected")

;; staged-artifact-path sanity
(check-equal? (file-name-from-path (staged-artifact-path 'deb))
              (string->path "gPTP-Studio-linux-x64.deb"))
