#lang racket/base

;; Runtime GM tuning through pmc over the per-user management socket.
;;
;; linuxptp's `SET GRANDMASTER_SETTINGS_NP` is positional: pmc_common.c
;; sscanf-matches the literal key names in fixed order, so the command string
;; must contain every field. Values: clockClass decimal, clockAccuracy /
;; offsetScaledLogVariance / timeSource hex, currentUtcOffset signed decimal,
;; six 0/1 flags. Ubuntu LTS ships linuxptp 3.1.x, whose GET prints gm-prefixed
;; fields with a gmFlags bitmask; newer upstream prints the flags separately.
;; Both shapes are parsed here. Tuning is a debugging action: it changes what
;; this station announces, it is not a calibration of the local clock.

(require racket/format
         racket/list
         racket/match
         racket/string
         "config.rkt"
         "ptp4l.rkt"
         "runtime-config.rkt")

(provide gm-settings-get-args
         gm-settings-set-args
         priority-get-args
         priority-set-args
         gm-settings-command
         validate-gm-settings
         merge-gm-settings
         parse-gm-settings-block
         gm-settings-field-order)

;; Canonical field order — must match pmc's sscanf literal order exactly.
(define gm-settings-field-order
  '(clock_class clock_accuracy offset_scaled_log_variance
    current_utc_offset leap61 leap59 current_utc_offset_valid
    ptp_timescale time_traceable frequency_traceable time_source))

(define (flag-field? k) (memq k '(leap61 leap59 current_utc_offset_valid
                                  ptp_timescale time_traceable frequency_traceable)))

(define (validated-field k v)
  (cond
    [(not (exact-integer? v)) (format "~a 必须是整数" (field-label k))]
    [(flag-field? k)
     (if (or (= v 0) (= v 1)) #f (format "~a 必须是 0 或 1" (field-label k)))]
    [(memq k '(clock_class clock_accuracy offset_scaled_log_variance
               time_source priority1 priority2))
     (define max-v (if (eq? k 'offset_scaled_log_variance) 65535 255))
     (if (<= 0 v max-v) #f (format "~a 超出范围 0–~a" (field-label k) max-v))]
    [(eq? k 'current_utc_offset)
     (if (<= -1000 v 1000) #f (format "~a 超出合理范围 ±1000 s" (field-label k)))]
    [else #f]))

(define (field-label k)
  (case k
    [(clock_class) "clockClass"]
    [(clock_accuracy) "clockAccuracy"]
    [(offset_scaled_log_variance) "offsetScaledLogVariance"]
    [(current_utc_offset) "currentUtcOffset"]
    [(current_utc_offset_valid) "currentUtcOffsetValid"]
    [(leap59) "leap59"]
    [(ptp_timescale) "ptpTimescale"]
    [(time_traceable) "timeTraceable"]
    [(frequency_traceable) "frequencyTraceable"]
    [(priority1) "priority1"]
    [(priority2) "priority2"]
    [(time_source) "timeSource"]
    [else (symbol->string k)]))

;; Returns (values settings error-string). Accepts a partial hash; missing
;; fields are irrelevant here because callers merge onto current values first
;; and pass the full set to the command builder.
(define (validate-gm-settings settings)
  (define errs
    (for/list ([(k v) (in-hash settings)]
               #:do [(define err (validated-field k v))]
               #:when err)
      err))
  (if (null? errs)
      (values (for/hasheq ([(k v) (in-hash settings)]
                           #:when (memq k (append gm-settings-field-order '(priority1 priority2))))
                (values k v))
              #f)
      (values #f (string-join errs "；"))))

;; Overlay provided fields onto the engine's current settings so a one-field
;; change still produces the complete positional SET command pmc requires.
(define (merge-gm-settings current provided)
  (for/hasheq ([k (in-list (append gm-settings-field-order '(priority1 priority2)))])
    (values k (hash-ref provided k (hash-ref current k 0)))))

;; pmc expects hex for these fields regardless of input notation.
(define (field-value->string k v)
  (cond
    [(memq k '(clock_accuracy time_source)) (format "0x~x" v)]
    [(eq? k 'offset_scaled_log_variance) (format "0x~x" v)]
    [else (~a v)]))

(define (gm-settings-command settings)
  (define body
    (string-join
     (for/list ([k (in-list gm-settings-field-order)])
       (format "~a ~a" (field-label k)
               (field-value->string k (hash-ref settings k 0))))
     " "))
  (string-append "SET GRANDMASTER_SETTINGS_NP " body))

(define (pmc-base-args run-dir params)
  (list "-u"
        "-s" (path->string (runtime-uds-path run-dir))
        "-d" (number->string (gptp-params-domain params))
        "-t" (format "~x" (gptp-params-transport-specific params))))

(define (gm-settings-get-args run-dir params)
  (append (pmc-base-args run-dir params) '("GET GRANDMASTER_SETTINGS_NP")))

(define (gm-settings-set-args run-dir params settings)
  (append (pmc-base-args run-dir params)
          (list (gm-settings-command settings))))

(define (priority-get-args run-dir params which)
  (append (pmc-base-args run-dir params)
          (list (format "GET PRIORITY~a" (if (eq? which 'priority2) 2 1)))))

(define (priority-set-args run-dir params which value)
  (append (pmc-base-args run-dir params)
          (list (format "SET PRIORITY~a ~a" (if (eq? which 'priority2) 2 1) value))))

;; gmFlags bit layout from linuxptp msg.h (flagField[1] bits):
;;   LEAP_61=0x01 LEAP_59=0x02 UTC_OFF_VALID=0x04 PTP_TIMESCALE=0x08
;;   TIME_TRACEABLE=0x10 FREQ_TRACEABLE=0x20 SYNC_UNCERTAIN=0x40 (ignored)
(define leap61-bit #x01)
(define leap59-bit #x02)
(define utc-offset-valid-bit #x04)
(define ptp-timescale-bit #x08)
(define time-traceable-bit #x10)
(define frequency-traceable-bit #x20)

(define (time-flags->bits s key)
  (define flags
    (match (hash-ref s 'gmFlags 0)
      [(? string? v) (or (string->number v) 0)]
      [(? number? v) v]
      [_ 0]))
  (define mask
    (case key
      [(leap61) leap61-bit]
      [(leap59) leap59-bit]
      [(current_utc_offset_valid) utc-offset-valid-bit]
      [(ptp_timescale) ptp-timescale-bit]
      [(time_traceable) time-traceable-bit]
      [(frequency_traceable) frequency-traceable-bit]))
  (if (positive? (bitwise-and flags mask)) 1 0))

;; Hex-looking values ("0xfe") survive parse-pmc-output as strings; numeric
;; fields arrive as numbers. Both are integers by the time we validate.
(define (block-int block key [default 0])
  (define v (hash-ref block key #f))
  (cond
    [(number? v) v]
    [(string? v)
     (define n (string->number (string-replace (string-downcase v) "0x" "#x")))
     (or n default)]
    [else default]))

;; Normalize one parsed pmc block into the canonical settings hash, accepting
;; both the linuxptp 3.1.x gm-prefixed/gmFlags shape and the newer upstream
;; shape that prints each flag on its own line.
(define (parse-gm-settings-block block)
  (define legacy? (hash-has-key? block 'gmClockClass))
  (define (okey k)
    (case k
      [(clock_class) (if legacy? 'gmClockClass 'clockClass)]
      [(clock_accuracy) (if legacy? 'gmClockAccuracy 'clockAccuracy)]
      [(offset_scaled_log_variance)
       (if legacy? 'gmOffsetScaledLogVariance 'offsetScaledLogVariance)]
      [(current_utc_offset) (if legacy? 'gmCurrentUtcOffset 'currentUtcOffset)]
      [(time_source) (if legacy? 'gmTimeSource 'timeSource)]
      [(current_utc_offset_valid) (if legacy? 'gmFlags 'currentUtcOffsetValid)]
      [(ptp_timescale) (if legacy? 'gmFlags 'ptpTimescale)]
      [(time_traceable) (if legacy? 'gmFlags 'timeTraceable)]
      [(frequency_traceable) (if legacy? 'gmFlags 'frequencyTraceable)]
      [else k]))
  (for/hasheq ([k (in-list gm-settings-field-order)])
    (values
     k
     (cond
       [(flag-field? k)
        (if legacy?
            (time-flags->bits block k)
            (if (= 1 (block-int block (okey k))) 1 0))]
       [else (block-int block (okey k))]))))
