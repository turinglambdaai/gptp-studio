#lang racket/base

(require json
         rackunit
         racket/file
         racket/port
         permit
         permit/issuer
         permit/envelope
         "../app/gate.rkt")

(define temp-dir (make-temporary-file "gptp-permit-gate-~a" 'directory))
(define trust-path (build-path temp-dir "trust-store.json"))
(define source-license (build-path temp-dir "customer.license"))

(define-values (private-key public-key) (generate-ed25519-keypair))

(define trust-jsexpr
  (hasheq 'protocol "permit-trust-store"
          'version 1
          'issuer "site.jrtx.gptpstudio"
          'keys
          (hasheq 'license-test
                  (hasheq 'algorithm "Ed25519"
                          'public_key (public-key->base64 public-key)
                          'status "active"
                          'purposes '("entitlement")
                          'not_before 'null
                          'not_after 'null))))

(call-with-output-file trust-path
  (lambda (out)
    (write-json trust-jsexpr out)
    (newline out))
  #:exists 'truncate/replace)

(define store (jsexpr->trust-store trust-jsexpr))

(define entitlement
  (hasheq
   'protocol "permit"
   'version 1
   'type "entitlement"
   'credential_id "cred_gate_test"
   'entitlement_id "ent_gate_test"
   'revision 0
   'issuer "site.jrtx.gptpstudio"
   'issued_at "2026-10-15T00:00:00Z"
   'not_before 'null
   'subject (hasheq 'type "person"
                    'id "customer_01"
                    'display "customer@example.com")
   'channel "commercial"
   'grants
   (list
    (hasheq 'scope (hasheq 'products '("gptp-studio")
                           'product_families '())
            'edition "pro"
            'feature_policy "explicit"
            'features '("engine-control")
            'addons '()
            'capabilities (hasheq)))
   'constraints
   (hasheq 'use_expires_at 'null
           'updates_through 'null
           'features_through 'null
           'version_policy (hasheq 'min 'null 'max 'null)
           'limits (hasheq 'named_seats 'null
                           'device_activations 'null
                           'concurrent_seats 'null)
           'installation_id 'null
           'activation_required #f)
   'extensions
   (hasheq)))

(define payload
  (call-with-output-bytes
   (lambda (out) (write-json entitlement out))))

(write-envelope
 (issue-credential payload private-key "license-test" store)
 source-license)

(dynamic-wind
 void
 (lambda ()
   (parameterize ([current-gate-data-dir (build-path temp-dir "app-data")]
                  [current-gate-trust-store-path trust-path])
     ;; No paid credential and no trial starts Free.
     (check-equal? (gate-init!) 'free)
     (check-false (gate-pro?))
     (check-not-equal? (gate-check 'engine) #t)

     ;; A signed Pro entitlement may still be feature-specific.
     (define-values (ok? subject) (gate-activate! source-license))
     (check-true ok?)
     (check-equal? subject "customer@example.com")
     (check-equal? (gate-tier) 'pro)
     (check-true (gate-pro?))
     (check-equal? (gate-check 'engine) #t)
     (check-not-equal? (gate-check 'export) #t)
     (check-not-equal? (gate-check 'reference) #t)
     (check-not-equal? (gate-check 'packet-store) #t)

     (define info (gate-info))
     (check-equal? (hash-ref info 'tier) "pro")
     (check-true (regexp-match?
                  #px"^ins_[0-9a-f]{32}$"
                  (hash-ref (hash-ref info 'detail) 'installation_id)))

     ;; Removing the entitlement returns to Free, then the local trial previews
     ;; the whole current Pro surface without a server round trip.
     (gate-deactivate!)
     (check-equal? (gate-tier) 'free)
     (gate-trial-start!)
     (check-equal? (gate-tier) 'trial)
     (check-equal? (gate-check 'engine) #t)
     (check-equal? (gate-check 'export) #t)
     (check-equal? (gate-check 'reference) #t)
     (check-equal? (gate-check 'packet-store) #t)))
 (lambda ()
   (delete-directory/files temp-dir)))
