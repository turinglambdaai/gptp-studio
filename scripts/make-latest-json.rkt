#lang racket/base

;; Regenerate the update feed (latest.json, manifest v2) from the built
;; release artifacts. The Release workflow runs this after the assets are
;; published and commits the result to main ("feed: x.y.z") — that commit
;; is what makes the update check fire for older installs. It is also the
;; manual tool for rebuilding the feed by hand:
;;
;;   racket scripts/make-latest-json.rkt \
;;     --version 1.1.0 \
;;     --deb gPTP-Studio-linux-x64.deb \
;;     --tarball gPTP-Studio-linux-x64.tar.gz \
;;     --private-key updater-priv.pem \
;;     --notes "one-line release notes" \
;;     --verify-public-key app/keys/updater/public.pem
;;
;; Wire format contract — must stay identical to what support/updater.rkt
;; verifies (glaze/signing):
;;   sha256    := lowercase hex sha256 of the artifact file
;;   signature := base64(Ed25519(private key, "sha256:" ++ sha256))
;; i.e. glaze/signing's sign-file / verify-signature pair over the artifact
;; bytes, against the pinned app/keys/updater/public.pem. Artifact urls are
;; the stable releases/latest/download/<name> aliases; the top-level url
;; points at the release tag page.
;;
;; The private key never touches this repo: the caller materializes it as a
;; file (CI: an encrypted Actions secret; locally: the operator's vault)
;; and deletes it afterwards.

(require glaze/signing
         json
         racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string)

(define default-base-url "https://github.com/turinglambdaai/gptp-studio")

(define version-param (make-parameter #f))
(define deb-param (make-parameter #f))
(define tarball-param (make-parameter #f))
(define key-param (make-parameter #f))
(define notes-param (make-parameter #f))
(define out-param (make-parameter "latest.json"))
(define base-url-param (make-parameter default-base-url))
(define verify-pub-param (make-parameter #f))

(command-line
 #:program "make-latest-json"
 #:once-each
 [("--version") v "release version, x.y.z without the leading v" (version-param v)]
 [("--deb") p "path to the built deb asset" (deb-param p)]
 [("--tarball") p "path to the built tarball asset" (tarball-param p)]
 [("--private-key") p "PEM file holding the UPDATER Ed25519 private key" (key-param p)]
 [("--notes") n "one-line release notes for the manifest" (notes-param n)]
 [("--out") p "output path (default: latest.json)" (out-param p)]
 [("--base-url") u "repository base url" (base-url-param u)]
 [("--verify-public-key") p
  "after writing, re-verify the feed with this public key"
  (verify-pub-param p)])

(define (require-arg what value)
  (unless (and (string? value) (not (string=? value "")))
    (raise-user-error 'make-latest-json "missing required argument: ~a" what))
  value)

(define version (require-arg "--version" (version-param)))
(define deb-path (require-arg "--deb" (deb-param)))
(define tarball-path (require-arg "--tarball" (tarball-param)))
(define private-key (require-arg "--private-key" (key-param)))
(define notes (require-arg "--notes" (notes-param)))

(unless (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+$" version)
  (raise-user-error 'make-latest-json
                    "version must be x.y.z without the leading v, got: ~a" version))

;; ---- build the artifact entries ----------------------------------------------

;; {kind, url, sha256, signature} exactly as support/updater.rkt consumes it.
(define (artifact-entry kind file)
  (define name (path->string (file-name-from-path (simple-form-path file))))
  (hasheq 'kind kind
          'url (string-append (base-url-param) "/releases/latest/download/" name)
          'sha256 (sha256-file file)
          'signature (sign-file file #:private-key private-key)))

(for ([p (list deb-path tarball-path)])
  (unless (file-exists? p)
    (raise-user-error 'make-latest-json "artifact not found: ~a" p))
  (unless (file-exists? private-key)
    (raise-user-error 'make-latest-json "private key not found: ~a" private-key)))

(define entries
  (list (artifact-entry "deb" deb-path)
        (artifact-entry "tarball" tarball-path)))

;; ---- JSON emission ------------------------------------------------------------
;; Hand-rolled so the shape stays byte-identical to the shipped feed: two-space
;; indent, fields in the documented order, trailing newline.

(define (json-string s)
  (string-append
   "\""
   (apply string
          (append*
           (for/list ([c (in-string s)])
             (case c
               [(#\") (string->list "\\\"")]
               [(#\\) (string->list "\\\\")]
               [(#\newline) (string->list "\\n")]
               [(#\return) (string->list "\\r")]
               [(#\tab) (string->list "\\t")]
               [(#\backspace) (string->list "\\b")]
               [(#\page) (string->list "\\f")]
               [else
                (if (< (char->integer c) 32)
                    (string->list
                     (string-append "\\u" (~r (char->integer c) #:base 16 #:min-width 4 #:pad-string "0")))
                    (list c))]))))
   "\""))

(define (write-artifact out entry)
  (fprintf out "    {\n")
  (fprintf out "      \"kind\": ~a,\n" (json-string (hash-ref entry 'kind)))
  (fprintf out "      \"url\": ~a,\n" (json-string (hash-ref entry 'url)))
  (fprintf out "      \"sha256\": ~a,\n" (json-string (hash-ref entry 'sha256)))
  (fprintf out "      \"signature\": ~a\n" (json-string (hash-ref entry 'signature)))
  (fprintf out "    }"))

(define (write-feed out)
  (fprintf out "{\n")
  (fprintf out "  \"version\": ~a,\n" (json-string version))
  (fprintf out "  \"url\": ~a,\n"
           (json-string (format "~a/releases/tag/v~a" (base-url-param) version)))
  (fprintf out "  \"notes\": ~a,\n" (json-string notes))
  (fprintf out "  \"artifacts\": [\n")
  (write-artifact out (first entries))
  (fprintf out ",\n")
  (write-artifact out (second entries))
  (fprintf out "\n  ]\n")
  (fprintf out "}\n"))

(define out-path (path->complete-path (out-param)))
(with-output-to-file out-path
  (lambda () (write-feed (current-output-port)))
  #:exists 'replace)

(printf "wrote ~a (version ~a)~%" (out-param) version)
(for ([entry entries])
  (printf "  ~a: ~a~%" (hash-ref entry 'kind) (hash-ref entry 'sha256)))

;; ---- optional post-write verification -----------------------------------------
;; Prove the feed we just wrote verifies exactly the way the updater will,
;; against the pinned public key of the build being released.

(when (verify-pub-param)
  (define manifest
    (string->jsexpr (file->string out-path)))
  (define pairs (list (cons "deb" deb-path) (cons "tarball" tarball-path)))
  (for ([pair pairs])
    (define kind (car pair))
    (define file (cdr pair))
    (define entry
      (for/first ([a (in-list (hash-ref manifest 'artifacts))]
                  #:when (equal? (hash-ref a 'kind) kind))
        a))
    (unless (verify-signature file
                              #:public-key (verify-pub-param)
                              #:signature (hash-ref entry 'signature)
                              #:expected-sha256 (hash-ref entry 'sha256))
      (raise-user-error
       'make-latest-json
       "feed self-verification failed for ~a against ~a; do not publish" kind (verify-pub-param)))
    (printf "  verified ~a signature against ~a~%" kind (verify-pub-param))))
