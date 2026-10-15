#lang racket/base

(require json
         racket/cmdline
         racket/format
         racket/random
         racket/string
         permit
         permit/issuer
         permit/envelope)

(define private-key-path #f)
(define trust-store-path "app/keys/permit-trust-store.json")
(define key-id #f)
(define subject-display #f)
(define subject-id #f)
(define entitlement-id #f)
(define credential-id #f)
(define revision 0)
(define use-expires-at #f)
(define updates-through #f)
(define features-through #f)
(define installation-id #f)
(define output-path #f)

(define (required name value)
  (unless value
    (raise-user-error 'issue-license (format "missing required option ~a" name)))
  value)

(define (parse-nonnegative name value)
  (define n (string->number value))
  (unless (and n (exact-integer? n) (>= n 0))
    (raise-user-error 'issue-license (format "~a must be a non-negative integer" name)))
  n)

(command-line
 #:program "racket scripts/issue-license.rkt"
 #:once-each
 [("--key") path "Ed25519 private key DER" (set! private-key-path path)]
 [("--trust-store") path "Permit trust store" (set! trust-store-path path)]
 [("--key-id") value "Active Permit signing key id" (set! key-id value)]
 [("--subject") value "Human-facing customer name/email" (set! subject-display value)]
 [("--subject-id") value "Stable customer id (generated when omitted)" (set! subject-id value)]
 [("--entitlement-id") value "Stable entitlement id (generated when omitted)" (set! entitlement-id value)]
 [("--credential-id") value "Unique credential id (generated when omitted)" (set! credential-id value)]
 [("--revision") value "Entitlement revision, default 0"
                   (set! revision (parse-nonnegative "--revision" value))]
 [("--use-expires-at") value "Subscription/use expiry RFC3339 UTC timestamp"
                        (set! use-expires-at value)]
 [("--updates-through") value "Final entitled release publication timestamp"
                        (set! updates-through value)]
 [("--features-through") value "Final entitled new-feature publication timestamp"
                         (set! features-through value)]
 [("--installation-id") value "Optional random installation binding"
                         (set! installation-id value)]
 [("--out") path "Output .license file" (set! output-path path)])

(required "--key" private-key-path)
(required "--key-id" key-id)
(required "--subject" subject-display)
(required "--out" output-path)

(define (random-id prefix)
  (string-append
   prefix
   (apply string-append
          (for/list ([byte (in-bytes (crypto-random-bytes 12))])
            (~r byte #:base 16 #:min-width 2 #:pad-string "0")))))

(define (pad n width)
  (~r n #:min-width width #:pad-string "0"))

(define (current-rfc3339)
  (define d (seconds->date (current-seconds) #f))
  (format "~a-~a-~aT~a:~a:~aZ"
          (pad (date-year d) 4)
          (pad (date-month d) 2)
          (pad (date-day d) 2)
          (pad (date-hour d) 2)
          (pad (date-minute d) 2)
          (pad (date-second d) 2)))

(define actual-subject-id (or subject-id (random-id "cus_")))
(define actual-entitlement-id (or entitlement-id (random-id "ent_")))
(define actual-credential-id (or credential-id (random-id "cred_")))

;; Commercial defaults:
;; - subscriptions get use/update/feature access through the same expiry;
;; - perpetual maintenance mirrors updates_through into features_through so
;;   copying a later binary cannot unlock post-maintenance paid features.
(define actual-updates-through
  (or updates-through use-expires-at #f))
(define actual-features-through
  (or features-through updates-through use-expires-at #f))

(define (nullable value)
  (or value 'null))

(define payload-jsexpr
  (hasheq
   'protocol "permit"
   'version 1
   'type "entitlement"
   'credential_id actual-credential-id
   'entitlement_id actual-entitlement-id
   'revision revision
   'issuer "site.jrtx.gptpstudio"
   'issued_at (current-rfc3339)
   'not_before 'null
   'subject
   (hasheq 'type "person"
           'id actual-subject-id
           'display subject-display)
   'channel "commercial"
   'grants
   (list
    (hasheq 'scope
            (hasheq 'products '("gptp-studio")
                    'product_families '())
            'edition "pro"
            'feature_policy "published-through"
            'features '()
            'addons '()
            'capabilities (hasheq)))
   'constraints
   (hasheq 'use_expires_at (nullable use-expires-at)
           'updates_through (nullable actual-updates-through)
           'features_through (nullable actual-features-through)
           'version_policy (hasheq 'min 'null 'max 'null)
           'limits (hasheq 'named_seats 'null
                           'device_activations 'null
                           'concurrent_seats 'null)
           'installation_id (nullable installation-id)
           'activation_required #f)
   'extensions
   (hasheq 'site.jrtx.gptpstudio/plan
           (if use-expires-at "subscription" "perpetual"))))

(define payload
  (call-with-output-bytes
   (lambda (out)
     (write-json payload-jsexpr out)
     (newline out))))

(define store (read-trust-store trust-store-path))
(define private-key (read-ed25519-private-key private-key-path))
(define envelope
  (issue-credential payload private-key key-id store))
(write-envelope envelope output-path)

(write-json
 (hasheq 'output output-path
         'credential_id actual-credential-id
         'entitlement_id actual-entitlement-id
         'revision revision
         'subject_id actual-subject-id
         'use_expires_at (nullable use-expires-at)
         'updates_through (nullable actual-updates-through)
         'features_through (nullable actual-features-through)
         'installation_id (nullable installation-id)))
(newline)
