#lang racket/base

;; Commercial tier gate built on Permit (github.com/turinglambdaai/permit)
;;
;;   free   — passive listening (capture+decode), offline pcap analysis,
;;            simulator, config editor/preview, presets (watch free)
;;   pro    — engine control (GM/slave), reference-source management,
;;            unlimited packet store, pcap/report exports (drive paid)
;;   trial  — 14 days of Pro from the moment the user starts it
;;
;; The tier never blocks the six pages, only the actions listed above.
;; A customer activates an offline Permit v1 entitlement credential
;; (.permit.json), verified against the Ed25519 trust store shipped with
;; the application.

(require json
         racket/date
         racket/file
         racket/string
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

;; persisted: trial-started ISO date, so the trial survives restarts
(define (read-gate-state)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (define v (call-with-input-file (gate-state-path) read-json))
    (if (hash? v) v (hasheq))))

(define (write-gate-state! h)
  (ensure-gate-dir!)
  (call-with-output-file (gate-state-path)
    (lambda (out) (write-json h out))
    #:exists 'replace))

(define (iso-today)
  (define d (current-date))
  (format "~a-~a-~a"
          (date-year d)
          (~r2 (date-month d))
          (~r2 (date-day d))))

(define (~r2 n)
  (define s (number->string n))
  (if (< (string-length s) 2) (string-append "0" s) s))

;; days until the ISO yyyy-mm-dd date's end; negative once it has passed
(define (days-until-expiry iso)
  (define m (regexp-match #rx"^([0-9]{4})-([0-9]{2})-([0-9]{2})$" iso))
  (unless m
    (raise-arguments-error 'days-until-expiry "not an ISO date" "date" iso))
  (define noon
    (find-seconds 0 0 12
                  (string->number (list-ref m 3))
                  (string->number (list-ref m 2))
                  (string->number (list-ref m 1))
                  #f))
  (inexact->exact (floor (- (/ noon 86400.0) (/ (current-seconds) 86400.0)))))

(define (days-since iso)
  (days-until-expiry iso)) ; negative == already past

(define (trial-days-left)
  (define started (hash-ref (read-gate-state) 'trial-started #f))
  (and started (+ trial-days (days-since started)))) ; days until expiry; negative = over

;; ---- public --------------------------------------------------------------------

;; Recompute the current tier from disk state. Call at startup and after
;; activation/trial changes.
(define (gate-init!)
  (define lic (credential-path))
  (define-values (tier info)
    (cond
      [(file-exists? lic)
       (define-values (ok? lic-info) (entitlement-validate lic (trust-store-path)))
       (if ok? (values 'pro lic-info) (values 'free #f))]
      [else
       (values (if (let ([left (trial-days-left)]) (and left (> left 0)))
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

;; Whether staging an official update is part of what this install holds.
;; Free and trial always update; a perpetual Pro install updates through
;; its entitlement's updates_through day.
(define (gate-update-window-open? [today (iso-today)])
  (updates-window-open? #:pro? (eq? (unbox gate-cache) 'pro)
                        #:updates-through (gate-updates-through)
                        #:today today))

;; Action-level check; returns #t or an error message string.
(define (gate-check action)
  (if (gate-pro?)
      #t
      (case action
        [(engine) "引擎控制（GM / 从钟）是 Pro 功能。可开始 14 天免费试用或输入许可证。"]
        [(export) "报文导出与报告生成是 Pro 功能。"]
        [(reference) "外接参考源管理是 Pro 功能。"]
        [else "此功能需要 Pro 许可证。"])))

(define (gate-trial-start!)
  (define st (read-gate-state))
  (unless (hash-ref st 'trial-started #f)
    (write-gate-state! (hash-set st 'trial-started (iso-today))))
  (gate-init!))

;; Activate from a credential file path (verified, then copied into place).
(define (gate-activate! path)
  (cond
    [(not (file-exists? path)) (values #f "许可证文件不存在")]
    [else
     (define-values (ok? info) (entitlement-validate path (trust-store-path)))
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
  (define lic (credential-path))
  (define detail
    (cond
      [(eq? tier 'pro)
       (define-values (_ok? info)
         (with-handlers ([exn:fail? (lambda (_) (values #f (hasheq)))])
           (entitlement-validate lic (trust-store-path))))
       (hasheq 'subject (hash-ref info 'subject #f)
               'expiry (hash-ref info 'expires #f)
               'updates_through (hash-ref info 'updates-through #f))]
      [(eq? tier 'trial) (hasheq 'days_left (trial-days-left))]
      [else (hasheq)]))
  (hasheq 'tier (symbol->string tier) 'pro (gate-pro?) 'trial_days trial-days 'detail detail))
