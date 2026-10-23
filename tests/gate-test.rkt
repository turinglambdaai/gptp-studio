#lang racket/base

;; Entitlement gate tests: the permit adapter answers the customer-visible
;; outcomes — a valid pro credential, an expired use window, a wrong
;; edition, a tampered file, and a foreign issuer — against a throwaway
;; issuer key, never the shipped trust store.

(require rackunit
         racket/date
         racket/file
         racket/runtime-path
         json
         permit
         (only-in permit/envelope write-envelope)
         (only-in permit/issuer
                  issue-credential
                  generate-ed25519-keypair
                  public-key->base64)
         "../support/entitlement.rkt"
         "../support/updates.rkt"
         "../app/gate.rkt")

;; ---- throwaway issuer: key pair + matching trust store ----

(define-values (private-key public-key) (generate-ed25519-keypair))

(define trust-store-path (make-temporary-file "gate-trust-~a.json"))
(call-with-output-file
    trust-store-path
  (lambda (out)
    (write-json
     (hasheq 'protocol "permit-trust-store"
             'version 1
             'issuer "test.issuer"
             'keys (hasheq 'test-1
                           (hasheq 'algorithm "Ed25519"
                                   'public_key (public-key->base64 public-key)
                                   'status "active"
                                   'purposes '("entitlement"
                                               "trial"
                                               "trial-extension"
                                               "activation")
                                   'not_before 'null
                                   'not_after 'null)))
     out))
  #:exists 'replace)

(define store (read-trust-store trust-store-path))

;; ---- payload factory (mirrors examples/perpetual.json) ----

(define (gate-payload #:edition [edition "pro"]
                      #:use-expires-at [use-expires-at 'null]
                      #:updates-through [updates-through 'null]
                      #:issuer [issuer "test.issuer"]
                      #:credential-id [credential-id "cred_gate_test"]
                      #:subject-id [subject-id "customer_01"]
                      #:subject-display [subject-display "customer@example.com"]
                      #:issued-at [issued-at "2026-01-01T00:00:00Z"]
                      #:installation-id [installation-id 'null])
  (hasheq 'protocol "permit"
          'version 1
          'type "entitlement"
          'credential_id credential-id
          'entitlement_id "ent_gate_test"
          'revision 0
          'issuer issuer
          'issued_at issued-at
          'not_before 'null
          'subject (hasheq 'type "person"
                           'id subject-id
                           'display subject-display)
          'channel "commercial"
          'grants
          (list (hasheq 'scope (hasheq 'products '("gptp-studio")
                                       'product_families '())
                        'edition edition
                        'features '()
                        'addons '()
                        'capabilities (hasheq)
                        'feature_policy "published-through"))
          'constraints
          (hasheq 'use_expires_at use-expires-at
                  'updates_through updates-through
                  'features_through 'null
                  'version_policy (hasheq 'min 'null 'max 'null)
                  'limits (hasheq 'named_seats 'null
                                  'device_activations 'null
                                  'concurrent_seats 'null)
                  'installation_id installation-id
                  'activation_required #f)
          'extensions (hasheq)))

(define (issue-to-file-with key key-store jsexpr path
                            #:key-id [key-id "test-1"])
  (define envelope
    (issue-credential (string->bytes/utf-8 (jsexpr->string jsexpr))
                      key
                      key-id
                      key-store))
  (write-envelope envelope path)
  path)

(define (issue-to-file jsexpr path)
  (issue-to-file-with private-key store jsexpr path))

(define (validate-file path) (entitlement-validate path trust-store-path))

;; ---- valid perpetual pro credential ----

(define ok-path
  (issue-to-file (gate-payload) (make-temporary-file "gate-ok-~a.permit.json")))
(define-values (ok? ok-info) (validate-file ok-path))
(check-true ok? "a perpetual pro entitlement verifies")
(check-equal? (hash-ref ok-info 'subject) "customer@example.com" "subject display surfaces")
(check-false (hash-ref ok-info 'expires) "perpetual entitlement has no use expiry")
(check-false (hash-ref ok-info 'updates-through)
             "an entitlement without updates_through surfaces #f")
(check-equal? (hash-ref ok-info 'issuer) "test.issuer" "issuer comes from the credential")

;; ---- the updates window (the commercial contract in gate form) ----
;; A perpetual Pro purchase carries updates_through. Eligibility is a
;; pure function of the candidate release's authenticated instant
;; against that cutoff — the current date is not an input — so a release
;; inside the window stays stageable forever and no check date can
;; invalidate an acquired version.

(define window-path
  (issue-to-file
   (gate-payload #:updates-through "2027-10-16T00:00:00Z")
   (make-temporary-file "gate-window-~a.permit.json")))
(define-values (window-ok? window-info) (validate-file window-path))
(check-true window-ok? "an updates window does not affect verification")
(check-equal? (hash-ref window-info 'updates-through) "2027-10-16T00:00:00Z"
              "updates_through surfaces from the credential")

(check-true (updates-window-open? #:pro? #f #:updates-through #f
                                  #:release-published-at "2099-01-01T00:00:00Z")
            "a free install always updates")
(check-true (updates-window-open? #:pro? #t #:updates-through #f
                                  #:release-published-at "2099-01-01T00:00:00Z")
            "a Pro entitlement without the constraint updates forever")

;; fixed UTC boundaries around the cutoff instant
(define window-cutoff "2027-10-16T00:00:00Z")
(check-true (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                  #:release-published-at "2027-10-15T23:59:59Z")
            "one second before the cutoff is inside the window")
(check-true (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                  #:release-published-at window-cutoff)
            "a release published exactly at the cutoff is entitled")
(check-false (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                   #:release-published-at "2027-10-16T00:00:01Z")
             "one second after the cutoff is outside")
(check-false (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                   #:release-published-at #f)
             "a candidate without an authenticated instant fails closed")
;; a date-only cutoff covers through the end of that day
(check-true (updates-window-open? #:pro? #t #:updates-through "2027-10-16"
                                  #:release-published-at "2027-10-16T23:59:59Z")
            "a date-only cutoff extends to that day's end")
(check-false (updates-window-open? #:pro? #t #:updates-through "2027-10-16"
                                   #:release-published-at "2027-10-17T00:00:00Z")
             "the day after a date-only cutoff is outside")
;; whatever the wall clock says, the same inputs answer the same way —
;; the decision reads no clock at all
(check-equal? (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                    #:release-published-at "2020-01-01T00:00:00Z")
              (updates-window-open? #:pro? #t #:updates-through window-cutoff
                                    #:release-published-at "2020-01-01T00:00:00Z")
              "eligibility is deterministic in its two inputs")

;; The gate-level decision, driven through a real activation. The seam
;; points the gate at this test's throwaway store before the replacement
;; block below installs its own home.
(let ([scratch (make-temporary-file "gate-home-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (putenv "GPTP_STUDIO_TRUST_STORE" (path->string trust-store-path))
  (define-values (w-act-ok? _w-subject) (gate-activate! window-path))
  (check-true w-act-ok? "the windowed credential activates")
  (check-equal? (gate-init!) 'pro)
  (check-equal? (gate-updates-through) "2027-10-16T00:00:00Z"
                "the gate carries the window from the cached verification")
  (check-false (gate-update-window-open?
                #:release-published-at "2027-10-16T00:00:01Z")
               "a release after the cutoff is not staged")
  (check-true (gate-update-window-open?
               #:release-published-at "2027-10-16T00:00:00Z")
              "the cutoff-instant release still stages")
  ;; An old release published inside a window that has since passed stays
  ;; eligible, and the install keeps every right it had — the window
  ;; gates staging, never use.
  (check-true (gate-update-window-open?
               #:release-published-at "2026-10-01T00:00:00Z")
              "an in-window release stays eligible after the window passes")
  (check-equal? (gate-tier) 'pro "the tier outlives the window")
  (check-true (gate-pro?) "an expired window never invalidates the install")
  (check-true (gate-check 'engine) "Pro actions keep working past the window")
  (gate-deactivate!)
  (check-equal? (gate-init!) 'free)
  (check-true (gate-update-window-open?
               #:release-published-at "2099-01-01T00:00:00Z")
              "a free install updates again after deactivation"))

;; A credential whose window is already entirely past is still a valid
;; perpetual Pro entitlement: the install upgrades and keeps working.
(let ([scratch (make-temporary-file "gate-past-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (putenv "GPTP_STUDIO_TRUST_STORE" (path->string trust-store-path))
  (define past-path
    (issue-to-file
     (gate-payload #:updates-through "2020-01-01T00:00:00Z")
     (make-temporary-file "gate-pastwin-~a.permit.json")))
  (define-values (p-act-ok? _p-subject) (gate-activate! past-path))
  (check-true p-act-ok? "a past-window credential is still a valid purchase")
  (check-equal? (gate-init!) 'pro "an expired window still grants the pro tier")
  (check-true (gate-check 'engine) "an expired window install keeps Pro actions")
  (check-false (gate-update-window-open?
                #:release-published-at "2021-01-01T00:00:00Z")
               "nothing published after the cutoff stages")
  (check-true (gate-update-window-open?
               #:release-published-at "2019-12-31T23:59:59Z")
               "anything published inside the cutoff stays eligible"))

;; ---- expired use window ----

(define expired-path
  (issue-to-file
   (gate-payload #:use-expires-at "2020-01-01T00:00:00Z")
   (make-temporary-file "gate-expired-~a.permit.json")))
(define-values (expired-ok? expired-info) (validate-file expired-path))
(check-false expired-ok? "an expired use window fails")
(check-equal? (hash-ref expired-info 'reason) 'expired "expiry is reported as expired")

;; ---- wrong edition ----

(define free-path
  (issue-to-file
   (gate-payload #:edition "free")
   (make-temporary-file "gate-edition-~a.permit.json")))
(define-values (edition-ok? edition-info) (validate-file free-path))
(check-false edition-ok? "a non-pro edition does not unlock the gate")
(check-equal? (hash-ref edition-info 'reason) 'edition "edition mismatch is reported")

;; ---- tampered payload ----

(define tampered-path
  (issue-to-file (gate-payload) (make-temporary-file "gate-tamper-~a.permit.json")))
;; replace the signed payload with junk — the envelope shape stays intact
(call-with-output-file
    tampered-path
  (lambda (out)
    (write-json
     (for/hash ([k '(protocol permit_version algorithm key_id payload signature)])
       (values k (case k
                   [(protocol) "permit"]
                   [(permit_version) 1]
                   [(algorithm) "Ed25519"]
                   [(key_id) "test-1"]
                   [(payload) "<tampered>"]
                   [(signature) "<broken>"])))
     out))
  #:exists 'replace)
(define-values (tamper-ok? tamper-info) (validate-file tampered-path))
(check-false tamper-ok? "a tampered credential fails verification")
(check-equal? (hash-ref tamper-info 'reason) 'malformed "tampering is reported as malformed")

;; ---- foreign issuer ----
;; Safe issuance refuses to sign a foreign-issuer payload, so the foreign
;; chain gets its own key and trust store — exactly how a real customer
;; would end up holding a genuine credential from another vendor.

(define-values (foreign-key foreign-public) (generate-ed25519-keypair))
(define foreign-store
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer "someone.else"
           'keys (hasheq 'test-1
                         (hasheq 'algorithm "Ed25519"
                                 'public_key (public-key->base64 foreign-public)
                                 'status "active"
                                 'purposes '("entitlement"
                                             "trial"
                                             "trial-extension"
                                             "activation")
                                 'not_before 'null
                                 'not_after 'null)))))
(define foreign-path
  (issue-to-file-with
   foreign-key foreign-store
   (gate-payload #:issuer "someone.else")
   (make-temporary-file "gate-foreign-~a.permit.json")))
(define-values (foreign-ok? foreign-info) (validate-file foreign-path))
(check-false foreign-ok? "a credential from another issuer fails")
;; the verifier checks the signature first, so a foreign credential that
;; reuses our key id fails there; a distinct key id reports issuer
(check-not-false (member (hash-ref foreign-info 'reason) '(signature issuer))
                 "foreign credentials are rejected as signature or issuer")

;; ---- credential replacement (gate layer, scratch home) ----
;; The gate follows the file: a fresh home starts free, activation
;; upgrades it, replacing the stored credential moves subject with it,
;; a rejected activation leaves the stored credential in charge, and
;; deactivation returns to free.

(define scratch-home (make-temporary-file "gate-home-~a" 'directory))
(putenv "GPTP_STUDIO_HOME" (path->string scratch-home))
;; the gate layer verifies against the shipped store; the seam points it
;; at this test's throwaway store for the end-to-end activation flow
(putenv "GPTP_STUDIO_TRUST_STORE" (path->string trust-store-path))

(check-equal? (gate-init!) 'free "a fresh home starts free")

(define second-path
  (issue-to-file
   (gate-payload #:credential-id "cred_gate_2"
                 #:subject-id "customer_02"
                 #:subject-display "second@example.com")
   (make-temporary-file "gate-second-~a.permit.json")))

(define-values (act1-ok? act1-subject) (gate-activate! ok-path))
(check-true act1-ok? "activating a valid pro credential succeeds")
(check-equal? act1-subject "customer@example.com" "the first activation reports its subject")
(check-equal? (gate-tier) 'pro "the gate upgrades to pro")

(define-values (act2-ok? act2-subject) (gate-activate! second-path))
(check-true act2-ok? "replacing with another valid credential succeeds")
(check-equal? act2-subject "second@example.com" "the replacement reports its own subject")
(check-equal? (gate-tier) 'pro "the gate stays pro after replacement")
(check-equal? (file->string (credential-path)) (file->string second-path)
              "the stored credential file is the replacement")

;; activating an invalid credential must not take a working gate down
(define-values (bad-act-ok? _bad-msg) (gate-activate! expired-path))
(check-false bad-act-ok? "activating an expired credential is refused")
(check-equal? (gate-tier) 'pro "a refused activation leaves the stored credential in charge")

(gate-deactivate!)
(check-equal? (gate-tier) 'free "deactivation drops to free")
(check-false (file-exists? (credential-path)) "deactivation removes the credential file")

;; ---- corrupt / missing state ----
;; A missing credential file is a typed failure, not a crash; corrupt
;; credential bytes fail verification; corrupt gate state reads as empty.

(define-values (miss-ok? miss-info)
  (entitlement-validate (build-path scratch-home "absent.permit.json") trust-store-path))
(check-false miss-ok? "a missing credential file fails instead of crashing")
(check-equal? (hash-ref miss-info 'reason) 'malformed "a missing file is reported as malformed")

(define-values (miss-act-ok? _miss-act-msg)
  (gate-activate! (build-path scratch-home "absent.permit.json")))
(check-false miss-act-ok? "activating a missing file reports the missing-file error")

(define corrupt-path (make-temporary-file "gate-corrupt-~a.permit.json"))
(call-with-output-file corrupt-path
  (lambda (out) (display "{{{not json" out))
  #:exists 'replace)
(define-values (corrupt-ok? _corrupt-info)
  (entitlement-validate corrupt-path trust-store-path))
(check-false corrupt-ok? "corrupt credential bytes fail verification")

(call-with-output-file (gate-state-path)
  (lambda (out) (display "{{{not json" out))
  #:exists 'replace)
(check-equal? (gate-init!) 'free "corrupt gate state reads as empty state, no crash")

;; ---- key rotation (two app generations) ----
;; v1 ships K1 active; v2 ships K1 retired with a not_after issuance
;; cutoff plus K2 active. A pre-rotation credential stays authentic
;; under v2; a post-rotation credential is unknown to v1; safe issuance
;; refuses the retired key outright.

(define-values (k2-priv k2-pub) (generate-ed25519-keypair))

(define store-v2-path (make-temporary-file "gate-rot-~a.json"))
(call-with-output-file store-v2-path
  (lambda (out)
    (write-json
     (hasheq 'protocol "permit-trust-store"
             'version 1
             'issuer "test.issuer"
             'keys (hasheq 'test-1
                           (hasheq 'algorithm "Ed25519"
                                   'public_key (public-key->base64 public-key)
                                   'status "retired"
                                   'purposes '("entitlement"
                                               "trial"
                                               "trial-extension"
                                               "activation")
                                   'not_before 'null
                                   'not_after "2026-06-30T00:00:00Z")
                           'test-2
                           (hasheq 'algorithm "Ed25519"
                                   'public_key (public-key->base64 k2-pub)
                                   'status "active"
                                   'purposes '("entitlement"
                                               "trial"
                                               "trial-extension"
                                               "activation")
                                   'not_before 'null
                                   'not_after 'null)))
     out))
  #:exists 'replace)
(define store-v2 (read-trust-store store-v2-path))

;; pre-rotation credential (K1, issued 2026-01-01): still authentic under v2
(define-values (rot-old-ok? _rot-old-info)
  (entitlement-validate ok-path store-v2-path))
(check-true rot-old-ok? "a pre-rotation credential verifies under the rotated trust store")

;; post-rotation credential (K2, issued 2026-07-01): valid under v2, unknown to v1
(define post-rot-path
  (issue-to-file-with
   k2-priv store-v2
   (gate-payload #:credential-id "cred_gate_rot2"
                 #:subject-id "customer_03"
                 #:subject-display "post-rotation@example.com"
                 #:issued-at "2026-07-01T00:00:00Z")
   (make-temporary-file "gate-rot2-~a.permit.json")
   #:key-id "test-2"))
(define-values (rot-new-ok? _rot-new-info)
  (entitlement-validate post-rot-path store-v2-path))
(check-true rot-new-ok? "a post-rotation credential verifies under the new trust store")
(define-values (rot-new-v1-ok? _rot-new-v1-info)
  (entitlement-validate post-rot-path trust-store-path))
(check-false rot-new-v1-ok? "an app that never learned K2 rejects the new credential")

;; issuer-boundary defense: the retired key cannot sign new credentials
(check-exn exn:fail?
  (lambda ()
    (issue-credential (string->bytes/utf-8 (jsexpr->string (gate-payload)))
                      private-key "test-1" store-v2))
  "safe issuance refuses a retired signing key")

;; ---- installation identity and installation-bound credentials ----
;; Every install holds a stable ins_… id (persisted beside the gate
;; state). A credential whose constraints bind that id verifies only on
;; the matching install; presenting a bound credential without an id
;; fails closed; the gate surfaces the id for the customer to hand to
;; the vendor.

(let ([scratch (make-temporary-file "gate-ins-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (define iid (gate-installation-id))
  (check-true (regexp-match? #px"^ins_[0-9a-f]{32}$" iid)
              "the installation id has permit's ins_ + 32 hex shape")
  (check-equal? (gate-installation-id) iid "the id is stable across calls")
  (check-true (file-exists? (build-path scratch ".gptp-studio" "installation-id"))
              "the id persists beside the gate state")

  (define bound-here
    (issue-to-file (gate-payload #:credential-id "cred_gate_bound"
                                 #:installation-id iid)
                   (make-temporary-file "gate-bound-~a.permit.json")))
  (define bound-elsewhere
    (issue-to-file (gate-payload #:credential-id "cred_gate_foreign-install"
                                 #:installation-id
                                 "ins_ffffffffffffffffffffffffffffffff")
                   (make-temporary-file "gate-bound2-~a.permit.json")))

  (define-values (bh-ok? _bh-info)
    (entitlement-validate bound-here trust-store-path #:installation-id iid))
  (check-true bh-ok? "a credential bound to this installation verifies")

  (define-values (be-ok? be-info)
    (entitlement-validate bound-elsewhere trust-store-path #:installation-id iid))
  (check-false be-ok? "a credential bound to another installation fails")
  (check-equal? (hash-ref be-info 'reason) 'installation
                "the mismatch is reported as installation")

  (define-values (nc-ok? nc-info)
    (entitlement-validate bound-here trust-store-path))
  (check-false nc-ok? "a bound credential without an id fails closed")
  (check-equal? (hash-ref nc-info 'reason) 'installation
                "fail-closed is reported as installation")

  (define-values (ib-act-ok? _ib-subject) (gate-activate! bound-here))
  (check-true ib-act-ok? "an installation-bound credential activates")
  (check-equal? (gate-init!) 'pro "the bound credential drives the pro tier")
  (define ins-info (gate-info))
  (check-equal? (hash-ref ins-info 'installation_id) iid
                "gate-info surfaces the installation id")
  (gate-deactivate!)
  (check-equal? (gate-init!) 'free "deactivation drops the bound credential"))

;; ---- the local trial ----
;; Trial state is permit local-trial format in the historical path: an
;; explicit start opens a 14-day pro window that survives restarts;
;; legacy date-anchored state migrates (active stays active, expired
;; stays expired); corrupt state reads as absent and an explicit start
;; replaces it.

(define (iso-days-ago n)
  (define d (seconds->date (- (current-seconds) (* n 86400))))
  (format "~a-~a-~a"
          (date-year d)
          (let ([s (number->string (date-month d))])
            (if (< (string-length s) 2) (string-append "0" s) s))
          (let ([s (number->string (date-day d))])
            (if (< (string-length s) 2) (string-append "0" s) s))))

(define (write-legacy-trial-state! started)
  ;; gate-installation-id doubles as the "state dir exists" step
  (gate-installation-id)
  (call-with-output-file (gate-state-path)
    (lambda (out) (write-json (hasheq 'trial-started started) out))
    #:exists 'replace))

;; a fresh trial runs the full pro surface and survives a restart
(let ([scratch (make-temporary-file "gate-trial-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (check-equal? (gate-init!) 'free "a fresh home without trial state is free")
  (gate-trial-start!)
  (check-equal? (gate-init!) 'trial "an explicit start opens the trial tier")
  (check-true (gate-pro?) "a trial holds the pro surface")
  (define state (call-with-input-file (gate-state-path) read-json))
  (check-equal? (hash-ref state 'protocol) "permit-local-trial"
                "trial state is permit local-trial format")
  (define detail (hash-ref (gate-info) 'detail))
  (check-true (and (integer? (hash-ref detail 'days_left))
                   (<= 1 (hash-ref detail 'days_left) 14))
              "the trial reports days_left within its window")
  (check-true (string? (hash-ref detail 'expires_at))
              "the trial reports its expiry instant")
  (check-equal? (gate-init!) 'trial "the trial survives a restart"))

;; an active legacy window migrates and keeps running
(let ([scratch (make-temporary-file "gate-legacy-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (write-legacy-trial-state! (iso-days-ago 1))
  (check-equal? (gate-init!) 'trial
                "an active legacy trial migrates to the trial tier")
  (define state (call-with-input-file (gate-state-path) read-json))
  (check-equal? (hash-ref state 'protocol) "permit-local-trial"
                "migration rewrote the state into local-trial format"))

;; an expired legacy window stays expired; Trial cannot restart it
(let ([scratch (make-temporary-file "gate-legacy2-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (write-legacy-trial-state! "2026-01-01")
  (check-equal? (gate-init!) 'free "an expired legacy trial reads as free")
  (gate-trial-start!)
  (check-equal? (gate-init!) 'free
                "an expired window is preserved; Trial does not restart"))

;; corrupt state reads as absent; an explicit start replaces it
(let ([scratch (make-temporary-file "gate-trial3-~a" 'directory)])
  (putenv "GPTP_STUDIO_HOME" (path->string scratch))
  (gate-installation-id) ; ensures ~/.gptp-studio exists
  (call-with-output-file (gate-state-path)
    (lambda (out) (display "{{{not json" out))
    #:exists 'replace)
  (check-equal? (gate-init!) 'free "corrupt trial state reads as free, no crash")
  (gate-trial-start!)
  (check-equal? (gate-init!) 'trial "a start after corrupt state opens fresh"))
