#lang racket/base

(require rackunit
         racket/list
         "../support/host-quality.rkt")

(define (host virtualization clocksource)
  (hasheq 'system
          (hasheq 'virtualization virtualization
                  'clocksource clocksource)))

(define clean-context
  (hasheq 'cpu_governors '("performance")
          'active_ptp_services '()
          'active_time_services '("chrony.service")
          'irqbalance_active #t))

(define clean
  (assess-host-quality (host "none" "tsc") clean-context))

(check-equal? (hash-ref clean 'schema_version) 1)
(check-equal? (hash-ref clean 'status) "context")
(check-equal? (hash-ref clean 'warning_count) 0)
(check-equal? (hash-ref clean 'accuracy_claim) "not-calibrated")
(check-equal? (hash-ref (hash-ref clean 'observations) 'active_time_services)
              '("chrony.service"))

(define risky-context
  (hasheq 'cpu_governors '("powersave" "performance")
          'active_ptp_services '("ptp4l.service" "phc2sys.service")
          'active_time_services '("systemd-timesyncd.service")
          'irqbalance_active #f))

(define risky
  (assess-host-quality (host "kvm" "kvm-clock") risky-context))

(check-equal? (hash-ref risky 'status) "attention")
(check-equal? (hash-ref risky 'warning_count) 3)
(check-equal? (hash-ref risky 'accuracy_claim) "not-calibrated")

(define checks (hash-ref risky 'checks))
(define (check-by-id id)
  (for/first ([c (in-list checks)]
              #:when (string=? (hash-ref c 'id) id))
    c))

(check-equal? (hash-ref (check-by-id "virtualization") 'state) "warn")
(check-equal? (hash-ref (check-by-id "cpu-governor") 'state) "warn")
(check-equal? (hash-ref (check-by-id "external-ptp-services") 'state) "warn")
(check-equal? (hash-ref (check-by-id "system-time-services") 'state) "info")
(check-equal? (hash-ref (check-by-id "clocksource") 'state) "info")
(check-equal? (hash-ref (check-by-id "irqbalance") 'state) "info")

;; Missing sysfs/systemd observations are context-only, never a hard failure.
(define unknown
  (assess-host-quality
   (host "unknown" "unknown")
   (empty-host-runtime-context)))
(check-equal? (hash-ref unknown 'warning_count) 0)
(check-equal? (hash-ref unknown 'status) "context")
(check-true
 (for/and ([c (in-list (hash-ref unknown 'checks))])
   (member (hash-ref c 'state) '("info" "warn"))))
