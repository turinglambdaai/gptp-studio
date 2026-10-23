#lang racket/base

;; Commercial tier gate built on Permit (github.com/turinglambdaai/permit)
;;
;;   free   — passive listening (capture+decode), offline pcap analysis,
;;            simulator, config editor/preview, presets, raw capture
;;            export and Wireshark replay
;;   pro    — engine control (GM/slave), reference-source management,
;;            unlimited packet store, engineering reports (drive paid)
;;   trial  — 14 days of Pro from the moment the user starts it, tracked
;;            as permit local-trial state (last_seen high-water mark)
;;
;; The tier never blocks the six pages, only the actions listed above.
;; A customer activates an offline Permit v1 entitlement credential
;; (.permit.json), verified against the Ed25519 trust store shipped with
;; the application. Each install also holds a stable installation id
;; (ins_ + 32 hex) so the vendor can issue credentials bound to it.

(require json
         racket/file
         racket/string
         permit
         "../support/entitlement.rkt"
         "../support/updates.rkt"
         racket/runtime-path)

(provide gate-init!
         gate-tier
         gate-pro?
         gate-updates-through
         gate-update-window-open?
         gate-trial-start!
         gate-activate!
         gate-deactivate!
         gate-info
         gate-check
         gate-state-path
         gate-installation-id
         credential-path)

(define-runtime-path shipped-trust-store "keys/trust-store.json")

;; Test seam: GPTP_STUDIO_TRUST_STORE points the gate at a test trust
;; store so activation flows can run against a throwaway issuer. The
;; shipped store answers in production.
(define (trust-store-path)
  (define override (getenv "GPTP_STUDIO_TRUST_STORE"))
  (if override (string->path override) shipped-trust-store))

(define trial-days 14)

(define gate-cache (box 'free))

;; The validated Pro credential's info (hasheq) or #f — cached at
;; gate-init! so the updates-window decision reads the same verification
;; the tier came from, never a second parse of the file.
(define gate-entitlement-box (box #f))

;; Test seam: GPTP_STUDIO_HOME redirects the per-user state directory so
;; tests can exercise activate/replace flows against a scratch home.
(define (gate-home-dir)
  (define override (getenv "GPTP_STUDIO_HOME"))
  (if override (string->path override) (find-system-path 'home-dir)))

(define (gate-state-path)
  (build-path (gate-home-dir) ".gptp-studio" "gate-state.json"))

(define (credential-path)
  (build-path (gate-home-dir) ".gptp-studio" "entitlement.permit.json"))

;; A fresh install has no ~/.gptp-studio yet; create it before any write.
(define (ensure-gate-dir!)
  (define d (build-path (gate-home-dir) ".gptp-studio"))
  (unless (directory-exists? d) (make-directory* d)))

;; Stable per-install identity (ins_ + 32 hex, permit's format): created
;; on first use, persisted beside the gate state, and surfaced on the
;; License page so a customer can hand it to the vendor for an
;; installation-bound credential.
(define (gate-installation-id)
  (define path (build-path (gate-home-dir) ".gptp-studio" "installation-id"))
  (define existing
    (and (file-exists? path)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (string-trim (file->string path)))))
  (if (and (string? existing) (regexp-match? #px"^ins_[0-9a-f]{32}$" existing))
      existing
      (let ([value (generate-installation-id)])
        (ensure-gate-dir!)
        (call-with-output-file path
          (lambda (out) (display value out) (newline out))
          #:exists 'truncate/replace)
        value)))

;; The trial is permit local-trial state in the historical gate-state.json
;; path: a fixed started/expires window plus a last_seen high-water mark
;; that survives restarts and rejects clock rollback (nuisance resistance,
;; not an anti-tamper boundary).

(define trial-duration-seconds (* trial-days 24 60 60))

;; local-trial, a legacy {"trial-started": date} hash, or #f for absent,
;; corrupt, or foreign state. jsexpr->local-trial raises on any wrong
;; shape, so every malformed byte reads as "no state", never a crash.
(define (read-trial-state path)
  (cond
    [(not (file-exists? path)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define v (call-with-input-file path read-json))
       (cond
         [(not (hash? v)) #f]
         [(hash-ref v 'trial-started #f) v]
         [else (jsexpr->local-trial v)]))]))

;; Legacy (pre-0.3.0) state anchored the 14-day window at the recorded
;; date's noon. Migration rewrites the file into local-trial form once:
;; an active legacy window keeps its remaining time, an expired one stays
;; expired so Trial cannot restart, and a malformed date reads as absent.
(define (current-trial!)
  (define path (gate-state-path))
  (define state (read-trial-state path))
  (cond
    [(local-trial? state) state]
    [(hash? state)
     (define started (hash-ref state 'trial-started #f))
     (define anchor
       (and (string? started)
            (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}$" started)
            (string-append started "T12:00:00Z")))
     (and anchor
          (let ([trial (make-local-trial #:duration-seconds trial-duration-seconds
                                         #:at anchor)])
            (write-local-trial trial path)
            trial))]
    [else #f]))

;; Evaluate the trial and persist the last_seen high-water mark after the
;; observation; #f when no trial state exists.
(define (trial-evaluation)
  (define trial (current-trial!))
  (and trial
       (let ([evaluation (evaluate-local-trial trial)])
         (write-local-trial (local-trial-evaluation-state evaluation)
                            (gate-state-path))
         evaluation)))

;; ---- public --------------------------------------------------------------------

;; Recompute the current tier from disk state. Call at startup and after
;; activation/trial changes.
(define (gate-init!)
  (define lic (credential-path))
  (define-values (tier info)
    (cond
      [(file-exists? lic)
       (define-values (ok? lic-info)
         (entitlement-validate lic (trust-store-path)
                               #:installation-id (gate-installation-id)))
       (if ok? (values 'pro lic-info) (values 'free #f))]
      [else
       (define evaluation (trial-evaluation))
       (values (if (and evaluation (local-trial-evaluation-active? evaluation))
                   'trial
                   'free)
               #f)]))
  (set-box! gate-cache tier)
  (set-box! gate-entitlement-box info)
  tier)

(define (gate-tier) (unbox gate-cache))

(define (gate-pro?) (not (eq? (unbox gate-cache) 'free)))

;; The validated credential's updates_through instant, or #f (Free/trial
;; or an entitlement without the constraint).
(define (gate-updates-through)
  (define info (unbox gate-entitlement-box))
  (and info (hash-ref info 'updates-through #f)))

;; Whether staging an official update with the given authenticated
;; release instant is part of what this install holds. Free and trial
;; always update; a perpetual Pro install stages releases published at or
;; before its entitlement's updates_through — the current date plays no
;; role (see updates-window-open?).
(define (gate-update-window-open? #:release-published-at published-at)
  (updates-window-open? #:pro? (eq? (unbox gate-cache) 'pro)
                        #:updates-through (gate-updates-through)
                        #:release-published-at published-at))

;; Action-level check; returns #t or an error message string.
(define (gate-check action)
  (if (gate-pro?)
      #t
      (case action
        [(engine) "引擎控制（GM / 从钟）是 Pro 功能。可开始 14 天免费试用或输入许可证。"]
        [(report) "工程报告生成是 Pro 功能。"]
        [(reference) "外接参考源管理是 Pro 功能。"]
        [else "此功能需要 Pro 许可证。"])))

(define (gate-trial-start!)
  ;; Only absent, corrupt, or malformed state starts a fresh window: a
  ;; valid state — active or already expired — is preserved so Trial
  ;; cannot restart itself.
  (unless (current-trial!)
    (ensure-gate-dir!)
    (write-local-trial
     (make-local-trial #:duration-seconds trial-duration-seconds)
     (gate-state-path)))
  (gate-init!))

;; Activate from a credential file path (verified, then copied into place).
(define (gate-activate! path)
  (cond
    [(not (file-exists? path)) (values #f "许可证文件不存在")]
    [else
     (define-values (ok? info)
       (entitlement-validate path (trust-store-path)
                             #:installation-id (gate-installation-id)))
     (if ok?
         (begin
           (ensure-gate-dir!)
           (copy-file path (credential-path) #t)
           (gate-init!)
           (values #t (or (hash-ref info 'subject #f) "已激活")))
         (values #f (case (hash-ref info 'reason "")
                       [(signature) "许可证签名无效"]
                       [(issuer) "许可证不适用于本产品"]
                       [(expired) "许可证已过期"]
                       [(not-yet-valid) "许可证尚未生效"]
                       [(edition) "许可证不包含 Pro 版授权"]
                       [(installation) "许可证绑定其他安装实例"]
                       [(type) "文件不是许可证凭据"]
                       [(key-revoked) "签发密钥已被吊销"]
                       [(key-window) "签发密钥不在有效签发期内"]
                       [else "许可证校验失败"])))]))

(define (gate-deactivate!)
  (define lic (credential-path))
  (when (file-exists? lic) (delete-file lic))
  (gate-init!))

(define (gate-info)
  (define tier (gate-tier))
  (define installation (gate-installation-id))
  (define lic (credential-path))
  (define detail
    (cond
      [(eq? tier 'pro)
       (define-values (_ok? info)
         (with-handlers ([exn:fail? (lambda (_) (values #f (hasheq)))])
           (entitlement-validate lic (trust-store-path)
                                 #:installation-id installation)))
       (hasheq 'subject (hash-ref info 'subject #f)
               'expiry (hash-ref info 'expires #f)
               'updates_through (hash-ref info 'updates-through #f))]
      [(eq? tier 'trial)
       (define evaluation (trial-evaluation))
       (hasheq 'days_left (and evaluation
                               (inexact->exact
                                (ceiling (/ (local-trial-evaluation-remaining-seconds
                                             evaluation)
                                            86400.0))))
               'expires_at (and evaluation
                                (local-trial-evaluation-expires-at evaluation)))]
      [else (hasheq)]))
  (hasheq 'tier (symbol->string tier)
          'pro (gate-pro?)
          'trial_days trial-days
          'installation_id installation
          'detail detail))
