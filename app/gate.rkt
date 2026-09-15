#lang racket/base

;; Commercial tier gate built on glaze/license.
;;
;;   free   — passive listening (capture+decode), offline pcap analysis,
;;            simulator, config editor/preview, presets (watch free)
;;   pro    — engine control (GM/slave), reference-source management,
;;            unlimited packet store, pcap/report exports (drive paid)
;;   trial  — 14 days of Pro from the moment the user starts it
;;
;; The tier never blocks the six pages, only the actions listed above.
;; Validation is offline RSA-2048 via the system openssl CLI (glaze/licence).

(require json
         racket/date
         racket/file
         racket/string
         glaze/license
         racket/runtime-path)

(provide gate-init!
         gate-tier
         gate-pro?
         gate-trial-start!
         gate-activate!
         gate-deactivate!
         gate-info
         gate-check
         gate-state-path)

(define-runtime-path public-key "keys/public.pem")

(define product-name "gPTP Studio")
(define trial-days 14)

(define gate-cache (box 'free))

(define (gate-state-path)
  (build-path (find-system-path 'home-dir) ".gptp-studio" "gate-state.json"))

(define (license-path)
  (build-path (find-system-path 'home-dir) ".gptp-studio" "license.lic"))

;; persisted: trial-started ISO date, so the trial survives restarts
(define (read-gate-state)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (define v (call-with-input-file (gate-state-path) read-json))
    (if (hash? v) v (hasheq))))

(define (write-gate-state! h)
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

;; days between two ISO dates (b - a), using glaze's helper arithmetic
(define (days-since iso)
  (days-until-expiry iso)) ; negative days-until-expiry == already past

(define (trial-days-left)
  (define started (hash-ref (read-gate-state) 'trial-started #f))
  (and started (+ trial-days (days-since started)))) ; days until expiry; negative = over

;; ---- public --------------------------------------------------------------------

;; Recompute the current tier from disk state. Call at startup and after
;; activation/trial changes.
(define (gate-init!)
  (define lic (license-path))
  (define tier
    (cond
      [(file-exists? lic)
       (define r (validate-license lic
                                   #:public-key public-key
                                   #:product product-name))
       (if (hash-ref r 'valid #f) 'pro 'free)]
      [else (if (let ([left (trial-days-left)]) (and left (> left 0))) 'trial 'free)]))
  (set-box! gate-cache tier)
  tier)

(define (gate-tier) (unbox gate-cache))

(define (gate-pro?) (not (eq? (unbox gate-cache) 'free)))

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

;; Activate from a license file path (validated, then copied into place).
(define (gate-activate! path)
  (cond
    [(not (file-exists? path)) (values #f "许可证文件不存在")]
    [else
     (define r (validate-license path
                                 #:public-key public-key
                                 #:product product-name))
     (if (hash-ref r 'valid #f)
         (begin
           (copy-file path (license-path) #t)
           (gate-init!)
           (values #t (hash-ref r 'subject "已激活")))
         (values #f (case (hash-ref r 'reason "")
                       [("signature") "许可证签名无效"]
                       [("product") "许可证不适用于本产品"]
                       [("expired") "许可证已过期"]
                       [("machine") "许可证绑定了其他机器"]
                       [("malformed") "许可证文件损坏"]
                       [else "许可证校验失败"])))]))

(define (gate-deactivate!)
  (define lic (license-path))
  (when (file-exists? lic) (delete-file lic))
  (gate-init!))

(define (gate-info)
  (define tier (gate-tier))
  (define lic (license-path))
  (define detail
    (cond
      [(eq? tier 'pro)
       (define r (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                   (validate-license lic
                                     #:public-key public-key
                                     #:product product-name)))
       (hasheq 'subject (hash-ref r 'subject #f)
               'expiry (hash-ref r 'expiry #f))]
      [(eq? tier 'trial) (hasheq 'days_left (trial-days-left))]
      [else (hasheq)]))
  (hasheq 'tier (symbol->string tier) 'pro (gate-pro?) 'trial_days trial-days 'detail detail))
