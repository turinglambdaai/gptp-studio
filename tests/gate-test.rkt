#lang racket/base

;; Entitlement gate tests: the permit adapter answers the customer-visible
;; outcomes — a valid pro credential, an expired use window, a wrong
;; edition, a tampered file, and a foreign issuer — against a throwaway
;; issuer key, never the shipped trust store.

(require rackunit
         racket/file
         racket/runtime-path
         json
         permit
         (only-in permit/envelope write-envelope)
         (only-in permit/issuer
                  issue-credential
                  generate-ed25519-keypair
                  public-key->base64)
         "../support/entitlement.rkt")

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
                      #:issuer [issuer "test.issuer"])
  (hasheq 'protocol "permit"
          'version 1
          'type "entitlement"
          'credential_id "cred_gate_test"
          'entitlement_id "ent_gate_test"
          'revision 0
          'issuer issuer
          'issued_at "2026-01-01T00:00:00Z"
          'not_before 'null
          'subject (hasheq 'type "person"
                           'id "customer_01"
                           'display "customer@example.com")
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
                  'updates_through 'null
                  'features_through 'null
                  'version_policy (hasheq 'min 'null 'max 'null)
                  'limits (hasheq 'named_seats 'null
                                  'device_activations 'null
                                  'concurrent_seats 'null)
                  'installation_id 'null
                  'activation_required #f)
          'extensions (hasheq)))

(define (issue-to-file-with key key-store jsexpr path)
  (define envelope
    (issue-credential (string->bytes/utf-8 (jsexpr->string jsexpr))
                      key
                      "test-1"
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
(check-equal? (hash-ref ok-info 'issuer) "test.issuer" "issuer comes from the credential")

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
