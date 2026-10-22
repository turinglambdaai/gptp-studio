#lang racket/base

;; Entitlement gate support on the Permit protocol
;; (github.com/turinglambdaai/permit). The gate verifies a Protocol v1
;; entitlement credential against the trust store shipped with the
;; application and answers one question: does this customer hold the pro
;; edition of gptp-studio?
;;
;; Vendor workflow (docs/vendor-license-guide.md): `raco permit keygen`
;; creates the key pair and trust store once — only trust-store.json is
;; shipped, the private key never leaves the vendor; `raco permit issue`
;; signs an entitlement payload; the customer activates the issued
;; .permit.json file inside the application.

(require racket/file
         racket/string
         permit)

(provide entitlement-product
         entitlement-pro-edition
         entitlement-validate)

(define entitlement-product "gptp-studio")
(define entitlement-pro-edition "pro")

;; path trust-store-path [#:installation-id] -> (values ok? info)
;; info on success: subject / expires (use_expires_at or #f) /
;; updates-through (updates_through or #f) / issuer.
;; info on failure: reason (a stable symbol for messaging) / detail.
;; Verification failures are results here, not errors: an invalid file is
;; a customer-input condition, so every failure from the permit layer is
;; mapped onto a typed reason. Signature and trust decisions raise inside
;; verify-credential; time and grant decisions come back as status reasons.
;; Callers that hold an installation identity must pass it: a credential
;; whose constraints bind installation_id only verifies on the matching
;; install, and fail-closed (#f) rejects every bound credential.
(define (entitlement-validate path trust-store-path
                              #:installation-id [installation-id #f])
  ;; A verified credential on success; on any verification failure a
  ;; three-element list ('verify-failed reason detail). Failures travel as
  ;; plain values so the single-value body never sees multiple values.
  (define result
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (define msg (exn-message e))
            (list 'verify-failed
                  (cond
                    [(string-contains? msg "invalid Ed25519 signature") 'signature]
                    [(string-contains? msg "issuer does not match") 'issuer]
                    [(string-contains? msg "revoked") 'key-revoked]
                    [(string-contains? msg "not_before") 'key-window]
                    [(string-contains? msg "retired") 'key-window]
                    [else 'malformed])
                  msg))])
      (define store (read-trust-store trust-store-path))
      (define credential (verify-credential path store))
      (if (equal? (verified-credential-type credential) "entitlement")
          credential
          (list 'verify-failed 'type "credential is not an entitlement"))))
  (cond
    [(verified-credential? result)
     (define status (credential-status result #:installation-id installation-id))
     (cond
       [(not (hash-ref status 'usable?))
        (values #f
                (hasheq 'reason
                        (case (car (hash-ref status 'reasons))
                          [(use-expired) 'expired]
                          [(not-active-yet) 'not-yet-valid]
                          [(installation-mismatch) 'installation]
                          [else 'unusable])
                        'detail (format "~a" (hash-ref status 'reasons))))]
       [(not (edition-entitled? result
                                entitlement-product
                                entitlement-pro-edition
                                #:installation-id installation-id))
        (values #f (hasheq 'reason 'edition
                           'detail "credential does not grant the pro edition"))]
       [else
        (values #t
                (hasheq 'subject (verified-credential-subject-display result)
                        'expires (verified-credential-use-expires-at result)
                        'updates-through
                        (verified-credential-updates-through result)
                        'issuer (verified-credential-issuer result)))])]
    [else
     (values #f (hasheq 'reason (cadr result)
                        'detail (caddr result)))]))
