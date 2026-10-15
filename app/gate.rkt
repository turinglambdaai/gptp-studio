#lang racket/base

;; Commercial product gate backed by Permit.
;;
;;   free   — passive listening, offline analysis, simulator, config preview
;;   pro    — official paid entitlement, evaluated per feature
;;   trial  — local 14-day Pro preview
;;
;; Permit verifies signed product rights locally. The first-run trial remains
;; local convenience state and intentionally makes no tamper-resistance claim.

(require racket/file
         racket/math
         racket/runtime-path
         racket/string
         permit
         "version.rkt")

(provide gate-init!
         gate-tier
         gate-pro?
         gate-trial-start!
         gate-activate!
         gate-deactivate!
         gate-info
         gate-check
         gate-state-path
         current-gate-data-dir
         current-gate-trust-store-path)

(define-runtime-path bundled-trust-store "keys/permit-trust-store.json")

(define product-id "gptp-studio")
(define pro-edition "pro")
(define trial-days 14)
(define trial-duration-seconds (* trial-days 24 60 60))

;; Existing Pro features all predate the Permit migration. New paid features
;; must get their own immutable publication timestamp here when introduced.
;; Maintenance-window entitlements use this timestamp through features_through.
(define existing-pro-feature-published-at "2026-09-22T00:00:00Z")
(define feature-specs
  (hasheq 'engine
          (cons "engine-control" existing-pro-feature-published-at)
          'export
          (cons "pcap-export" existing-pro-feature-published-at)
          'reference
          (cons "reference-source" existing-pro-feature-published-at)
          'packet-store
          (cons "large-packet-store" existing-pro-feature-published-at)))

(define current-gate-data-dir
  (make-parameter
   (build-path (find-system-path 'home-dir) ".gptp-studio")))

(define current-gate-trust-store-path
  (make-parameter bundled-trust-store))

(define gate-cache (box 'free))

(define (gate-dir)
  (define dir (current-gate-data-dir))
  (make-directory* dir)
  dir)

;; Kept as the public state-path helper used by older product code. The new
;; file contains Permit local-trial state rather than the old trial-start date.
(define (gate-state-path)
  (build-path (gate-dir) "gate-state.json"))

(define (license-path)
  ;; Preserve the historical on-disk name so existing support tooling keeps a
  ;; stable location; the contents are now a Permit credential envelope.
  (build-path (gate-dir) "license.lic"))

(define (installation-id-path)
  (build-path (gate-dir) "installation-id"))

(define (valid-installation-id? value)
  (and (string? value)
       (regexp-match? #px"^ins_[0-9a-f]{32}$" value)))

(define (installation-id)
  (define path (installation-id-path))
  (define existing
    (and (file-exists? path)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (string-trim (file->string path)))))
  (cond
    [(valid-installation-id? existing) existing]
    [else
     (define value (generate-installation-id))
     (call-with-output-file path
       (lambda (out)
         (display value out)
         (newline out))
       #:exists 'truncate/replace)
     value]))

(define (friendly-verification-error e)
  (define message (exn-message e))
  (cond
    [(regexp-match? #rx"invalid Ed25519 signature" message) "许可证签名无效"]
    [(regexp-match? #rx"unknown key_id" message) "许可证由未知签发密钥签名"]
    [(regexp-match? #rx"revoked" message) "许可证签发密钥已撤销"]
    [(regexp-match? #rx"issuer does not match" message) "许可证签发方不匹配"]
    [(regexp-match? #rx"issuance window" message) "许可证签发时间不在有效密钥窗口内"]
    [(regexp-match? #rx"not authorized for credential type" message) "签发密钥无权签发此类许可证"]
    [(regexp-match? #rx"keys must be a non-empty" message) "产品授权信任库尚未配置"]
    [else "许可证文件无效或损坏"]))

(define (verify-entitlement-file path)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (values #f (friendly-verification-error e)))])
    (define store (read-trust-store (current-gate-trust-store-path)))
    (define credential (verify-credential path store))
    (unless (member (verified-credential-type credential) '("entitlement" "trial"))
      (error 'gate-activate! "unsupported credential type"))
    (values credential #f)))

(define (load-installed-entitlement)
  (define path (license-path))
  (if (file-exists? path)
      (verify-entitlement-file path)
      (values #f #f)))

(define (trial-evaluation)
  (define path (gate-state-path))
  (and
   (file-exists? path)
   (with-handlers ([exn:fail? (lambda (_) #f)])
     (define trial (read-local-trial path))
     (define evaluation (evaluate-local-trial trial))
     ;; Persist the monotonic last_seen_at high-water mark after every policy
     ;; observation. This is nuisance resistance, not an anti-tamper boundary.
     (write-local-trial (local-trial-evaluation-state evaluation) path)
     evaluation)))

(define (trial-active?)
  (define evaluation (trial-evaluation))
  (and evaluation (local-trial-evaluation-active? evaluation)))

(define (paid-pro-entitlement?)
  (define-values (credential _) (load-installed-entitlement))
  (and credential
       (edition-entitled? credential
                          product-id
                          pro-edition
                          #:version app-version
                          #:installation-id (installation-id))))

(define (paid-feature-entitled? action)
  (define spec (hash-ref feature-specs action #f))
  (and spec
       (let-values ([(credential _) (load-installed-entitlement)])
         (and credential
              (feature-entitled? credential
                                 product-id
                                 (car spec)
                                 #:published-at (cdr spec)
                                 #:version app-version
                                 #:installation-id (installation-id))))))

(define (compute-tier)
  (cond
    [(paid-pro-entitlement?) 'pro]
    [(trial-active?) 'trial]
    [else 'free]))

(define (gate-init!)
  (define tier (compute-tier))
  (set-box! gate-cache tier)
  tier)

(define (gate-tier)
  (unbox gate-cache))

(define (gate-pro?)
  (not (eq? (gate-init!) 'free)))

(define (gate-check action)
  ;; A local trial intentionally previews the complete current Pro surface.
  ;; Paid rights are feature-specific so features_through keeps maintenance
  ;; windows meaningful even if a newer binary is copied manually.
  (cond
    [(trial-active?) #t]
    [(paid-feature-entitled? action) #t]
    [else
     (case action
       [(engine) "引擎控制（GM / 从钟）是 Pro 功能。可开始 14 天免费试用或导入 Permit 许可证。"]
       [(export) "报文导出与报告生成是 Pro 功能。"]
       [(reference) "外接参考源管理是 Pro 功能。"]
       [(packet-store) "大容量报文缓存是 Pro 功能。"]
       [else "此功能需要有效的 Pro 权益。"])]))

(define (gate-trial-start!)
  (define path (gate-state-path))
  (define existing
    (and (file-exists? path)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (read-local-trial path))))
  ;; A valid expired state is deliberately preserved; an old pre-Permit or
  ;; malformed state is replaced only when the user explicitly starts Trial.
  (unless existing
    (write-local-trial
     (make-local-trial #:duration-seconds trial-duration-seconds)
     path))
  (gate-init!))

(define (gate-activate! path)
  (cond
    [(not (file-exists? path)) (values #f "许可证文件不存在")]
    [else
     (define-values (credential error-message) (verify-entitlement-file path))
     (cond
       [(not credential) (values #f error-message)]
       [(not (edition-entitled? credential
                                product-id
                                pro-edition
                                #:version app-version
                                #:installation-id (installation-id)))
        (values #f "许可证当前已过期、版本不匹配或绑定了其他安装实例")]
       [else
        (define destination (license-path))
        (unless (equal? (path->complete-path path)
                        (path->complete-path destination))
          (copy-file path destination #t))
        (gate-init!)
        (values #t
                (or (verified-credential-subject-display credential)
                    (verified-credential-subject-id credential)
                    "已激活"))])]))

(define (gate-deactivate!)
  (define path (license-path))
  (when (file-exists? path)
    (delete-file path))
  (gate-init!))

(define (trial-days-left evaluation)
  (inexact->exact
   (ceiling (/ (local-trial-evaluation-remaining-seconds evaluation)
               86400.0))))

(define (gate-info)
  (define tier (gate-init!))
  (define iid (installation-id))
  (define detail
    (cond
      [(eq? tier 'pro)
       (define-values (credential error-message) (load-installed-entitlement))
       (if credential
           (hasheq 'credential_id (verified-credential-id credential)
                   'subject (or (verified-credential-subject-display credential)
                                (verified-credential-subject-id credential))
                   'expiry (verified-credential-use-expires-at credential)
                   'updates_through (verified-credential-updates-through credential)
                   'features_through (verified-credential-features-through credential)
                   'installation_id iid)
           (hasheq 'error error-message 'installation_id iid))]
      [(eq? tier 'trial)
       (define evaluation (trial-evaluation))
       (hasheq 'trial_id
               (and evaluation
                    (local-trial-id (local-trial-evaluation-state evaluation)))
               'days_left
               (if evaluation (trial-days-left evaluation) 0)
               'expires_at
               (and evaluation (local-trial-evaluation-expires-at evaluation))
               'installation_id
               iid)]
      [else
       (hasheq 'installation_id iid)]))
  (hasheq 'tier (symbol->string tier)
          'pro (not (eq? tier 'free))
          'trial_days trial-days
          'detail detail))
