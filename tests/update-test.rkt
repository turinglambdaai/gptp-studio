#lang racket/base

;; Update tests on the rivet/distribution scheme (family shape, ported from
;; pdfgist): the embedded public key stays glued to the rotation anchor
;; (app/keys/updater/public.pem), a signed manifest verifies and selects
;; the way the live checker does (throwaway Ed25519 keypair), the artifact
;; download runs against local TCP servers (happy path, 302 alias,
;; truncated body -> .partial cleanup, digest mismatch), the feed-script
;; contract holds end to end, and an unreachable https feed fails as a
;; network error — never a contract violation. (fetch-update-manifest only
;; accepts HTTPS, so the network half of the check is exercised in
;; production; everything else runs offline here.)

(require crypto
         crypto/all
         net/base64
         rackunit
         rivet/distribution
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         (only-in racket/system process*/ports)
         racket/tcp
         "../support/updates.rkt"
         "../support/updater.rkt")

(use-all-factories!)

;; ---- rotation anchor coherence -------------------------------------------------
;; The rotation anchor is app/keys/updater/public.pem (commit 3fb3c4f); the
;; engine trusts the embedded raw key. The two must stay the same key or a
;; rotation would silently split what the feed job signs from what the app
;; accepts.

(define-runtime-path rotation-anchor "../app/keys/updater/public.pem")
(check-true (file-exists? rotation-anchor) "pinned updater public key exists")

(define anchor-der
  (let ([pem (file->string rotation-anchor)])
    (base64-decode
     (string->bytes/utf-8
      (string-append*
       (for/list ([line (in-lines (open-input-string pem))]
                  #:unless (or (string-prefix? line "-----")
                               (equal? "" (string-trim line))))
         (string-trim line)))))))
(check-true (bytes? anchor-der) "anchor PEM body decodes")

;; SubjectPublicKeyInfo DER for Ed25519 = the SPKI prefix + the raw 32 bytes
(check-equal? (subbytes anchor-der 0 (bytes-length ed25519-spki-prefix))
              ed25519-spki-prefix
              "anchor DER carries the Ed25519 SPKI prefix")
(check-equal? (bytes->string/utf-8
               (base64-encode (subbytes anchor-der (bytes-length ed25519-spki-prefix)) #""))
              update-public-key-b64
              "embedded raw key is the anchor's key bytes")
(check-true
 (equal? (pk-key->datum (datum->pk-key anchor-der 'SubjectPublicKeyInfo)
                        'rkt-public)
         (pk-key->datum (embedded-public-key) 'rkt-public))
 "embedded key and rotation anchor are the same key")

;; ---- offline trust chain --------------------------------------------------------
;; craft a manifest, sign it with a throwaway Ed25519 key, verify and
;; select it exactly the way the live checker does (verify-signed-manifest
;; is what fetch-update-manifest runs on the fetched bytes)

(define keydir (make-temporary-file "gptp-upd-keys~a" 'directory))
(define test-priv (generate-private-key 'eddsa '((curve ed25519))))
(define test-pub (datum->pk-key (pk-key->datum test-priv 'rkt-public) 'rkt-public))

(define artifact-file (make-temporary-file "gptp-artifact~a.deb"))
(void
 (call-with-output-file artifact-file
  (lambda (out) (write-bytes (make-bytes 1024 3) out))
  #:exists 'truncate))


(define signed-manifest
  (update-manifest
   app-update-identifier "9.9.9" 1 'stable
   "2026-10-13T00:00:00Z" "0.0.0" #f #t 100
   (list (update-artifact (platform-symbol) (architecture-symbol)
                          "https://github.com/turinglambdaai/gptp-studio/releases/latest/download/gPTP-Studio-linux-x64.deb"
                          (sha256-file/hex artifact-file)
                          (file-size artifact-file)
                          'deb '())
         (update-artifact (platform-symbol) (architecture-symbol)
                          "https://github.com/turinglambdaai/gptp-studio/releases/latest/download/gPTP-Studio-linux-x64.tar.gz"
                          (sha256-file/hex artifact-file)
                          (file-size artifact-file)
                          'targz '()))))

(define wrapped (open-output-bytes))
(write-signed-manifest signed-manifest test-priv update-key-id wrapped)
(check-true (> (bytes-length (get-output-bytes wrapped)) 0) "wrapper written")

(define verified
  (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                          test-pub
                          #:key-id update-key-id))
(check-equal? (update-manifest-version verified) "9.9.9")
(check-equal? (update-manifest-application-id verified)
              app-update-identifier)

;; a different key id fails closed
(check-exn exn:fail?
           (lambda ()
             (verify-signed-manifest
              (open-input-bytes (get-output-bytes wrapped))
              test-pub
              #:key-id "some-other-key"))
           "unexpected key id is rejected")

;; a different key fails closed (authenticity, not just integrity)
(define other-priv (generate-private-key 'eddsa '((curve ed25519))))
(check-exn exn:fail?
           (lambda ()
             (define other-wrapped (open-output-bytes))
             (write-signed-manifest signed-manifest other-priv update-key-id other-wrapped)
             (verify-signed-manifest
              (open-input-bytes (get-output-bytes other-wrapped))
              test-pub
              #:key-id update-key-id))
           "signature under a different key is rejected")

;; selection policy (the same select-update call the live check makes)
(define (config-as version)
  (updater-config app-update-identifier version 'stable
                  (platform-symbol) (architecture-symbol)
                  test-pub update-key-id 0 (* 150 1024 1024)))

(define candidate (select-update (config-as "1.2.0") verified))
(check-true (update-candidate? candidate) "newer release is selected")
(check-false (select-update (config-as "9.9.9") verified)
             "same version reports no update")
(check-false (select-update (config-as "10.0.0") verified)
             "newer-running install is up to date")

(check-exn exn:fail?
           (lambda ()
             (select-update
              (struct-copy updater-config (config-as "1.2.0")
                           [application-id "dev.other.test"])
              verified))
           "application identity mismatch is rejected")

;; product pick: deb for system installs, tarball for relocatable ones
(check-equal? (update-artifact-installer
               (pick-artifact verified #:system-install? #t))
              'deb)
(check-equal? (update-artifact-installer
               (pick-artifact verified #:system-install? #f))
              'targz)

;; a manifest without artifacts for this platform selects nothing
(check-false
 (select-update (config-as "1.2.0")
                (update-manifest
                 app-update-identifier "9.9.9" 1 'stable
                 "2026-10-13T00:00:00Z" "0.0.0" #f #t 100
                 (list (update-artifact 'windows 'x64
                                        "https://example.com/x.msi"
                                        (make-string 64 #\a) 4 'msi '()))))
 "no artifact for this platform -> no update")

;; check-result summary for the header pill
(define info (update-info (update-candidate verified
                                            (pick-artifact verified #:system-install? #t))))
(check-equal? (hash-ref info 'version) "9.9.9")
(check-equal? (hash-ref info 'url) releases-page-url)

;; ---- download leg against a local TCP server ------------------------------------
;; A minimal one-shot HTTP artifact server: rivet fetches with get-pure-port,
;; which insists on a well-formed response head. The declared Content-Length
;; and the bytes actually sent are separate, so the truncated case can mimic
;; a dropped connection mid-download.

(define staged-deb (staged-artifact-path 'deb))
(define staged-targz (staged-artifact-path 'targz))
(define (clean-stage!)
  (for ([p (list staged-deb staged-targz)])
    (when (file-exists? p) (delete-file p))
    (define partial (path-add-extension p #".partial"))
    (when (file-exists? partial) (delete-file partial))))
(clean-stage!)

(define (serve-artifact! payload declared-length)
  (define listener (tcp-listen 0 4 #f "127.0.0.1"))
  (define-values (_bh port-number _ph _pp) (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (let accept-loop ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (let drain ()
              (define line (read-line in 'any))
              (unless (or (eof-object? line) (equal? line "") (equal? line "\r"))
                (drain)))
            (write-string
             (format "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n" declared-length)
             out)
            (write-string "Content-Type: application/octet-stream\r\n\r\n" out)
            (write-bytes payload out)
            (close-output-port out)
            (close-input-port in)))
         (accept-loop)))))
  (values port-number
          (lambda ()
            (kill-thread server)
            (tcp-close listener))))

(define (candidate-for installer url payload)
  (define manifest
    (update-manifest
     app-update-identifier "9.9.9" 1 'stable
     "2026-10-13T00:00:00Z" "0.0.0" #f #t 100
     (list (update-artifact (platform-symbol) (architecture-symbol)
                            url
                            (bytes->hex-string (sha256-bytes payload))
                            (bytes-length payload)
                            installer '()))))
  (select-update (config-as "1.2.0") manifest))

;; happy path: download + verify + atomic rename into the stage dir
(define payload (make-bytes 300000 42))
(define-values (port-number stop-server!) (serve-artifact! payload (bytes-length payload)))
(define staged
  (download-candidate!
   (candidate-for 'deb (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" port-number)
                  payload)))
(check-true (file-exists? staged) "staged artifact exists")
(check-equal? (file-size staged) (bytes-length payload))
(check-equal? staged staged-deb "deb stages under the deb name")
(check-false (file-exists? (path-add-extension staged #".partial"))
             "no .partial survives a successful download")
(delete-file staged)
(stop-server!)

;; tarball install shape stages under the tarball name
(define-values (port-number* stop-server!*) (serve-artifact! payload (bytes-length payload)))
(define staged-gz
  (download-candidate!
   (candidate-for 'targz (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.tar.gz" port-number*)
                  payload)))
(check-equal? staged-gz staged-targz "targz stages under the tarball name")
(check-true (file-exists? staged-gz))
(delete-file staged-gz)
(stop-server!*)

;; a truncated download raises and leaves no .partial behind
(define-values (trunc-port trunc-stop!) (serve-artifact! (subbytes payload 0 150000)
                                                         (bytes-length payload)))
(check-exn exn:fail?
           (lambda ()
             (download-candidate!
              (candidate-for 'deb
                             (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" trunc-port)
                             payload)))
           "short body fails the size gate")
(check-false (file-exists? staged-deb) "nothing staged")
(check-false (file-exists? (path-add-extension staged-deb #".partial"))
             "rivet's partial cleanup removed the residue")
(trunc-stop!)

;; wrong bytes with a correct Content-Length fail the digest gate
(define tampered (make-bytes (bytes-length payload) 99))
(define-values (bad-port bad-stop!) (serve-artifact! tampered (bytes-length tampered)))
(check-exn exn:fail?
           (lambda ()
             (download-candidate!
              (candidate-for 'deb
                             (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" bad-port)
                             payload)))
           "digest mismatch is rejected")
(check-false (file-exists? staged-deb))
(check-false (file-exists? (path-add-extension staged-deb #".partial")))
(bad-stop!)

;; releases/latest/download aliases answer 302 — the download must follow
;; and still verify (the same trap rivet's fetch redirect budget exists for)
(define redirect-listener (tcp-listen 0 16 #f "127.0.0.1"))
(define-values (_rh redirect-port _rph _rpp) (tcp-addresses redirect-listener #t))
(define redirect-payload (make-bytes 2048 7))
(define redirect-serve-thread
  (thread
   (lambda ()
     (let accept-loop ()
       (define-values (in out) (tcp-accept redirect-listener))
       (thread
        (lambda ()
          (define path
            (let ([m (regexp-match #px"^GET (\\S+)" (or (read-line in 'any) ""))])
              (and m (cadr m))))
          (let drain ()
            (define l (read-line in 'any))
            (unless (or (eof-object? l) (equal? l "")) (drain)))
          (cond
            [(equal? path "/gPTP-Studio-linux-x64.deb")
             (fprintf out "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                      (bytes-length redirect-payload))
             (write-bytes redirect-payload out)]
            [else
             ;; the /latest/ alias the manifest carries answers 302, like GitHub
             (fprintf out
                      "HTTP/1.0 302 Found\r\nLocation: http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                      redirect-port)])
          (close-output-port out)))
       (accept-loop)))))
(dynamic-wind
 void
 (lambda ()
   (define staged-redirect
     (download-candidate!
      (candidate-for 'deb
                     (format "http://127.0.0.1:~a/latest/gPTP-Studio-linux-x64.deb" redirect-port)
                     redirect-payload)))
   (check-equal? (file-size staged-redirect) 2048
                 "the 302 was actually followed (not the empty redirect body)")
   (check-equal? (sha256-file/hex staged-redirect)
                 (bytes->hex-string (sha256-bytes redirect-payload))
                 "302 is followed and the digest still matches")
   (delete-file staged-redirect))
 (lambda ()
   (kill-thread redirect-serve-thread)
   (tcp-close redirect-listener)))

;; ---- the flow: prepare downloads on a watched thread -----------------------------

(define (flow-state)
  (string->symbol (hash-ref (update-flow-status) 'state)))

(define (wait-for-flow! deadline-seconds)
  (let loop ([deadline (+ (current-seconds) deadline-seconds)])
    (define st (flow-state))
    (if (or (memq st '(staged applied failed))
            (> (current-seconds) deadline))
        st
        (begin (sleep 0.1) (loop deadline)))))

(define-values (flow-port flow-stop!) (serve-artifact! payload (bytes-length payload)))
(update-prepare! 'deb
                 (candidate-for 'deb
                                (format "http://127.0.0.1:~a/gPTP-Studio-linux-x64.deb" flow-port)
                                payload))
(check-equal? (wait-for-flow! 30) 'staged "prepare reaches staged")
(check-true (file-exists? staged-deb) "flow staged the artifact")
(check-equal? (hash-ref (update-flow-status) 'install_command)
              (format "sudo apt-get install -y ~a" (path->string staged-deb))
              "status carries the apply command")
(delete-file staged-deb)
(flow-stop!)

;; prepare without a candidate fails fast and clean (the API folds it to
;; ok:false); the flow is idle again at this point, so the guard order is
;; observable either way
(check-exn exn:fail?
           (lambda () (update-prepare! 'deb #f))
           "no candidate -> clean error")

;; ---- feed-script contract --------------------------------------------------------
;; the release pipeline's signer must produce a wrapper the shipped verifier
;; accepts, over both PEM (what the Actions secret stores) and DER keys

(define-runtime-path feed-script "../scripts/make-update-manifest.rkt")
(define racket-exe (find-executable-path "racket"))
(check-true (and racket-exe #t) "racket on PATH to drive the feed script")

(define (der->pem-private der)
  (string-append
   "-----BEGIN PRIVATE KEY-----\n"
   (bytes->string/utf-8 (base64-encode der #""))
   "\n-----END PRIVATE KEY-----\n"))

(define script-priv-der (pk-key->datum test-priv 'OneAsymmetricKey))
(define script-priv-pem (build-path keydir "feed-priv.pem"))
(void
 (call-with-output-file script-priv-pem
  (lambda (out) (display (der->pem-private script-priv-der) out))
  #:exists 'truncate))

(define script-priv-der-file (build-path keydir "feed-priv.der"))
(void
 (call-with-output-file script-priv-der-file
  (lambda (out) (write-bytes script-priv-der out))
  #:exists 'truncate))

(define script-pub-der (build-path keydir "feed-pub.spki.der"))
(void
 (call-with-output-file script-pub-der
  (lambda (out)
    (write-bytes (pk-key->datum test-pub 'SubjectPublicKeyInfo) out))
  #:exists 'truncate))

(define wrong-priv (generate-private-key 'eddsa '((curve ed25519))))
(define wrong-pub-der (build-path keydir "wrong-pub.spki.der"))
(void
 (call-with-output-file wrong-pub-der
  (lambda (out)
    (write-bytes (pk-key->datum
                  (datum->pk-key (pk-key->datum wrong-priv 'rkt-public) 'rkt-public)
                  'SubjectPublicKeyInfo)
                 out))
  #:exists 'truncate))


(define script-deb (build-path keydir "gPTP-Studio-linux-x64.deb"))
(define script-gz (build-path keydir "gPTP-Studio-linux-x64.tar.gz"))
(void
 (call-with-output-file script-deb
  (lambda (out) (write-bytes (make-bytes 4096 1) out))
  #:exists 'truncate))

(void
 (call-with-output-file script-gz
  (lambda (out) (write-bytes (make-bytes 2048 2) out))
  #:exists 'truncate))


(define (run-feed-script! key-file out-file verify-key #:quiet [quiet #f])
  ;; process*/ports pumps the subprocess output into a capture port —
  ;; parameterizing current-output-port would not: system* inherits the
  ;; underlying file descriptor. Argument order is stdout, stdin, stderr,
  ;; then the argv pieces individually; the result's last element is the
  ;; control function (there is no subprocess object in the result).
  (define captured (open-output-bytes))
  (define result
    (process*/ports captured
                    (open-input-bytes #"")
                    captured
                    racket-exe
                    (path->string feed-script)
                    "--version" "9.9.9"
                    "--deb" (path->string script-deb)
                    "--tarball" (path->string script-gz)
                    "--private-key" (path->string key-file)
                    "--out" (path->string out-file)
                    "--verify-public-key" (path->string verify-key)))
  (define control (list-ref result 4))
  (control 'wait)
  (define status (control 'exit-code))
  (unless (or quiet (eqv? status 0))
    ;; surface the child's output so a contract regression is debuggable
    (display (get-output-bytes captured) (current-error-port)))
  (or status -1))

(define feed-out (build-path keydir "update-stable.json"))
(check-equal? (run-feed-script! script-priv-pem feed-out script-pub-der) 0
              "PEM secret signs and self-verifies the feed")
(check-true (file-exists? feed-out))

;; the wrapper the script wrote verifies the way the shipped updater will
(define feed-manifest
  (verify-signed-manifest (open-input-string (file->string feed-out))
                          test-pub
                          #:key-id update-key-id))
(check-equal? (update-manifest-version feed-manifest) "9.9.9")
(check-equal? (length (update-manifest-artifacts feed-manifest)) 2)
(for ([a (in-list (update-manifest-artifacts feed-manifest))])
  (check-true (string-contains? (update-artifact-url a)
                                "/releases/latest/download/")
              "artifact urls are the stable release aliases"))

;; the DER key branch behaves identically
(check-equal? (run-feed-script! script-priv-der-file feed-out script-pub-der) 0
              "DER key signs and self-verifies the feed")

;; a private key that is not the anchor's counterpart fails the release
(check-not-equal? (run-feed-script! script-priv-pem feed-out wrong-pub-der
                                   #:quiet #t)
                  0
                  "mismatched signing key refuses to publish")

;; ---- unreachable feed is a network failure, never a contract violation ------------
;; Regression (kept from the glaze era in spirit): a refused connection must
;; surface as a network error the startup handler can fold, not an
;; exn:fail:contract — that class of contract bug once killed the https
;; check before it ever reached the network.

(define https-exn
  (with-handlers ([exn:fail? (lambda (e) e)])
    (check-for-update "https://127.0.0.1:1/update-stable.json")
    #f))
(check-true (exn? https-exn) "refused https fetch raises a network failure")
(check-false (exn:fail:contract? https-exn)
             "network layer must not raise a contract violation")

;; ---- staged names ------------------------------------------------------------------
(check-equal? (file-name-from-path staged-deb)
              (string->path "gPTP-Studio-linux-x64.deb"))
(check-equal? (file-name-from-path staged-targz)
              (string->path "gPTP-Studio-linux-x64.tar.gz"))

;; ---- cleanup -----------------------------------------------------------------------
(clean-stage!)
(delete-directory/files keydir)
(delete-directory/files artifact-file #:must-exist? #f)
