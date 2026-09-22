#lang racket/base

;; Conservative Linux host-context diagnostics for timing work.
;;
;; These checks are intentionally advisory. They describe conditions that can
;; make timing experiments less reproducible or can cause ownership conflicts,
;; but they NEVER establish timing accuracy and NEVER block the real engine.

(require racket/file
         racket/list
         racket/string
         racket/system)

(provide empty-host-runtime-context
         collect-host-runtime-context
         assess-host-quality
         collect-host-quality)

(define (run-exit-code . args)
  (define exe (find-executable-path (car args)))
  (and exe
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)]
                        [current-input-port (open-input-string "")])
           (apply system*/exit-code exe (cdr args))))))

(define (read-text path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (file-exists? path)
         (string-trim (file->string path)))))

(define (cpu-governors)
  (define root "/sys/devices/system/cpu")
  (if (directory-exists? root)
      (sort
       (remove-duplicates
        (for/list ([entry (in-list (directory-list root #:build? #f))]
                   #:when (regexp-match? #px"^cpu[0-9]+$" (path->string entry))
                   #:do [(define governor
                            (read-text
                             (build-path root entry "cpufreq" "scaling_governor")))]
                   #:when (and governor (not (string=? governor ""))))
          governor)
        string=?)
       string<?)
      '()))

(define (service-active? unit)
  (define rc (run-exit-code "systemctl" "is-active" "--quiet" unit))
  (and (exact-integer? rc) (zero? rc)))

(define ptp-service-units
  '("ptp4l.service" "phc2sys.service" "timemaster.service"))

(define time-service-units
  '("chrony.service" "chronyd.service" "systemd-timesyncd.service"
    "ntp.service" "ntpd.service"))

(define (active-units units)
  (for/list ([unit (in-list units)]
             #:when (service-active? unit))
    unit))

(define (empty-host-runtime-context)
  (hasheq 'cpu_governors '()
          'active_ptp_services '()
          'active_time_services '()
          'irqbalance_active #f))

(define (collect-host-runtime-context)
  (hasheq 'cpu_governors (cpu-governors)
          'active_ptp_services (active-units ptp-service-units)
          'active_time_services (active-units time-service-units)
          'irqbalance_active (service-active? "irqbalance.service")))

(define (nested-ref h keys [default "unknown"])
  (let loop ([value h] [rest keys])
    (cond
      [(null? rest) value]
      [(hash? value) (loop (hash-ref value (car rest) default) (cdr rest))]
      [else default])))

(define (advisory-check id state title detail action)
  (hasheq 'id id
          'state state
          'title title
          'detail detail
          'action action))

(define (join-or-none values)
  (if (pair? values) (string-join values ", ") "none detected"))

(define (assess-host-quality host runtime-context)
  (define virtualization (nested-ref host '(system virtualization) "unknown"))
  (define clocksource (nested-ref host '(system clocksource) "unknown"))
  (define governors (hash-ref runtime-context 'cpu_governors '()))
  (define ptp-services (hash-ref runtime-context 'active_ptp_services '()))
  (define time-services (hash-ref runtime-context 'active_time_services '()))
  (define irqbalance? (hash-ref runtime-context 'irqbalance_active #f))

  (define checks
    (list
     (cond
       [(string=? virtualization "none")
        (advisory-check
         "virtualization" "info" "Execution environment"
         "systemd-detect-virt reports bare metal"
         "")]
       [(string=? virtualization "unknown")
        (advisory-check
         "virtualization" "info" "Execution environment"
         "virtualization state could not be determined"
         "Record the host type manually when comparing timing results across machines.")]
       [else
        (advisory-check
         "virtualization" "warn" "Execution environment"
         (format "virtualized environment detected: ~a" virtualization)
         (string-append
          "For reference-platform characterization, prefer a validated bare-metal host or "
          "explicitly validate this virtual platform. Protocol analysis remains useful."))])

     (cond
       [(null? governors)
        (advisory-check
         "cpu-governor" "info" "CPU frequency policy"
         "CPU scaling governor was not exposed by sysfs"
         "Treat CPU power policy as unknown when comparing hosts.")]
       [(member "powersave" governors)
        (advisory-check
         "cpu-governor" "warn" "CPU frequency policy"
         (format "active governor set includes powersave: ~a" (string-join governors ", "))
         (string-append
          "For repeatability studies, document the governor and compare against a validated "
          "reference-host policy before attributing timing changes to the DUT."))]
       [else
        (advisory-check
         "cpu-governor" "info" "CPU frequency policy"
         (format "governor(s): ~a" (string-join governors ", "))
         "")])

     (advisory-check
      "clocksource" "info" "Kernel clocksource"
      (format "current clocksource: ~a" clocksource)
      "Clocksource is recorded as context only; Studio does not infer timing accuracy from its name.")

     (if (pair? ptp-services)
         (advisory-check
          "external-ptp-services" "warn" "Existing PTP services"
          (format "active system-managed service(s): ~a" (string-join ptp-services ", "))
          (string-append
           "Before starting a Studio real engine, verify these services are not controlling the same "
           "NIC/PHC or management socket. Stop or explicitly coordinate duplicate owners."))
         (advisory-check
          "external-ptp-services" "info" "Existing PTP services"
          "no active system-managed ptp4l/phc2sys/timemaster service detected"
          ""))

     (advisory-check
      "system-time-services" "info" "System time source context"
      (format "active NTP/system-time service(s): ~a" (join-or-none time-services))
      (if (pair? time-services)
          (string-append
           "For GM system-reference workflows, record which service disciplines CLOCK_REALTIME; "
           "this can be an intentional reference source and is not automatically a conflict.")
          ""))

     (advisory-check
      "irqbalance" "info" "IRQ balancing"
      (if irqbalance? "irqbalance.service is active" "irqbalance.service is not active or not detected")
      "IRQ state is recorded for reproducibility only; no timing-grade conclusion is inferred.")))

  (define warnings
    (count (lambda (c) (string=? (hash-ref c 'state "") "warn")) checks))
  (hasheq 'schema_version 1
          'status (if (positive? warnings) "attention" "context")
          'warning_count warnings
          'checks checks
          'observations runtime-context
          'accuracy_claim "not-calibrated"
          'note
          "Host-quality checks are advisory reproducibility context. They do not establish end-to-end timing accuracy and never block engine startup."))

(define (collect-host-quality host)
  (assess-host-quality host (collect-host-runtime-context)))
