#lang racket/base

;; GM runtime tuning: pmc command encoding, validation, legacy/new output
;; parsing and overlay merging. The pmc SET syntax is positional and literal
;; (pmc_common.c sscanf), so the command strings are asserted verbatim.

(require rackunit
         racket/list
         racket/string
         "../engine/config.rkt"
         "../engine/ptp4l.rkt"
         "../engine/pmc-tuning.rkt")

;; domain=1, transportSpecific=1; the other fields never reach pmc args.
(define params
  (struct-copy gptp-params (default-params-for-role 'grandmaster)
               [domain 1]
               [transport-specific 1]))

(define run-dir (find-system-path 'temp-dir))

;; ---- command encoding ---------------------------------------------------------

(test-equal?
 "set command carries all 11 fields in pmc's literal order"
 (gm-settings-command
  (hasheq 'clock_class 6
          'clock_accuracy 33
          'offset_scaled_log_variance 20061
          'current_utc_offset 37
          'leap61 0
          'leap59 0
          'current_utc_offset_valid 1
          'ptp_timescale 1
          'time_traceable 1
          'frequency_traceable 0
          'time_source 16))
 (string-append
  "SET GRANDMASTER_SETTINGS_NP "
  "clockClass 6 clockAccuracy 0x21 offsetScaledLogVariance 0x4e5d "
  "currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 "
  "ptpTimescale 1 timeTraceable 1 frequencyTraceable 0 timeSource 0x10"))

(test-equal?
 "set args target the shared UDS with domain and transportSpecific"
 (gm-settings-set-args run-dir params (hasheq 'clock_class 248))
 (list "-u" "-s" (path->string (build-path run-dir "ptp4l.sock"))
       "-d" "1" "-t" "1"
       "SET GRANDMASTER_SETTINGS_NP clockClass 248 clockAccuracy 0x0 offsetScaledLogVariance 0x0 currentUtcOffset 0 leap61 0 leap59 0 currentUtcOffsetValid 0 ptpTimescale 0 timeTraceable 0 frequencyTraceable 0 timeSource 0x0"))

(test-equal?
 "get args request GRANDMASTER_SETTINGS_NP"
 (gm-settings-get-args run-dir params)
 (list "-u" "-s" (path->string (build-path run-dir "ptp4l.sock"))
       "-d" "1" "-t" "1" "GET GRANDMASTER_SETTINGS_NP"))

(test-equal? "priority1 set" (priority-set-args run-dir params 'priority1 128)
             (list "-u" "-s" (path->string (build-path run-dir "ptp4l.sock"))
                   "-d" "1" "-t" "1" "SET PRIORITY1 128"))
(test-equal? "priority2 get" (priority-get-args run-dir params 'priority2)
             (list "-u" "-s" (path->string (build-path run-dir "ptp4l.sock"))
                   "-d" "1" "-t" "1" "GET PRIORITY2"))

;; ---- validation ----------------------------------------------------------------

(let-values ([(s err) (validate-gm-settings (hasheq 'clock_class 6 'leap61 0 'priority1 10))])
  (check-true (and (hash? s) (not err)))
  (check-equal? (hash-ref s 'clock_class) 6)
  (check-false (hash-has-key? s 'unknown_field)))

(let-values ([(s err) (validate-gm-settings (hasheq 'clock_class 256))])
  (check-false s)
  (check-true (string-contains? err "clockClass")))

(let-values ([(s err) (validate-gm-settings (hasheq 'offset_scaled_log_variance 65536))])
  (check-false s)
  (check-true (string-contains? err "offsetScaledLogVariance")))

(let-values ([(s err) (validate-gm-settings (hasheq 'leap61 2))])
  (check-false s)
  (check-true (string-contains? err "leap61")))

(let-values ([(s err) (validate-gm-settings (hasheq 'current_utc_offset 5000))])
  (check-false s)
  (check-true (string-contains? err "currentUtcOffset")))

;; ---- merge ---------------------------------------------------------------------

(test-equal?
 "overlay keeps untouched current values"
 (hash-ref (merge-gm-settings
            (hasheq 'clock_class 248 'clock_accuracy 254 'offset_scaled_log_variance 65535
                    'current_utc_offset 0 'leap61 0 'leap59 0 'current_utc_offset_valid 0
                    'ptp_timescale 0 'time_traceable 0 'frequency_traceable 0
                    'time_source 160 'priority1 248 'priority2 248)
            (hasheq 'clock_class 6))
           'clock_class)
 6)

(test-equal?
 "overlay preserves current clockAccuracy"
 (hash-ref (merge-gm-settings
            (hasheq 'clock_class 248 'clock_accuracy 254 'offset_scaled_log_variance 65535
                    'current_utc_offset 0 'leap61 0 'leap59 0 'current_utc_offset_valid 0
                    'ptp_timescale 0 'time_traceable 0 'frequency_traceable 0
                    'time_source 160 'priority1 248 'priority2 248)
            (hasheq 'clock_class 6))
           'clock_accuracy)
 254)

;; ---- parsing: linuxptp 3.1.x (Ubuntu LTS) gm-prefixed + gmFlags ------------------

(define legacy-output
  "\tsending: GET GRANDMASTER_SETTINGS_NP 0
\tb62f08.fffe.1a2b3c-1\t
\tgmClockClass                 248
\tgmClockAccuracy              0xfe
\tgmOffsetScaledLogVariance    0xffff
\tgmCurrentUtcOffset           0
\tgmFlags                      0x58
\tgmTimeSource                 0xa0
")

(test-case "legacy gm block parses with flags decomposed"
  (define blocks (parse-pmc-output legacy-output))
  (check-equal? (length blocks) 1)
  (define b (first blocks))
  (check-equal? (hash-ref b 'gmClockClass) 248)
  (check-equal? (hash-ref b 'gmClockAccuracy) 254)
  (check-equal? (hash-ref b 'gmFlags) 88)
  (define s (parse-gm-settings-block b))
  (check-equal? (hash-ref s 'clock_class) 248)
  (check-equal? (hash-ref s 'clock_accuracy) 254)
  (check-equal? (hash-ref s 'offset_scaled_log_variance) 65535)
  (check-equal? (hash-ref s 'time_source) 160)
  ;; gmFlags 0x58 = PTP_TIMESCALE(0x08) | TIME_TRACEABLE(0x10) | 0x40 (ignored)
  (check-equal? (hash-ref s 'leap61) 0)
  (check-equal? (hash-ref s 'ptp_timescale) 1)
  (check-equal? (hash-ref s 'time_traceable) 1)
  (check-equal? (hash-ref s 'current_utc_offset_valid) 0))

;; ---- parsing: newer upstream per-flag output ------------------------------------

(define modern-output
  "\tsending: GET GRANDMASTER_SETTINGS_NP 0
\tclockClass              6
\tclockAccuracy           33
\toffsetScaledLogVariance 20061
\tcurrentUtcOffset        37
\tleap61                  0
\tleap59                  0
\tcurrentUtcOffsetValid   1
\tptpTimescale            1
\ttimeTraceable           1
\tfrequencyTraceable      1
\ttimeSource              0x10
")

(test-case "modern gm block parses flag fields directly"
  (define blocks (parse-pmc-output modern-output))
  (check-equal? (length blocks) 1)
  (define s (parse-gm-settings-block (first blocks)))
  (check-equal? (hash-ref s 'clock_class) 6)
  (check-equal? (hash-ref s 'clock_accuracy) 33)
  (check-equal? (hash-ref s 'current_utc_offset) 37)
  (check-equal? (hash-ref s 'current_utc_offset_valid) 1)
  (check-equal? (hash-ref s 'ptp_timescale) 1)
  (check-equal? (hash-ref s 'time_traceable) 1)
  (check-equal? (hash-ref s 'frequency_traceable) 1)
  (check-equal? (hash-ref s 'time_source) 16))

;; ---- parsing: SET confirmation blocks flush separately --------------------------

(test-case "set sending line flushes a new block"
  (define blocks
    (parse-pmc-output
     (string-append legacy-output "\tsending: SET GRANDMASTER_SETTINGS_NP 0\n\tgmClockClass 6\n")))
  (check-equal? (length blocks) 2)
  (check-equal? (hash-ref (second blocks) 'gmClockClass) 6))

;; ---- priority blocks -------------------------------------------------------------

(test-case "priority1 block parses"
  (define blocks
    (parse-pmc-output "\tsending: GET PRIORITY1 0\n\tb62f08.fffe.1a2b3c-1\t\n\tpriority1                 248\n"))
  (check-equal? (length blocks) 1)
  (check-equal? (hash-ref (first blocks) 'priority1) 248))
