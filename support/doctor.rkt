#lang racket/base

;; Headless support report used by `gptp-studio --doctor` and --doctor-json.
;;
;; The report is deliberately safe to paste into a support ticket: MAC/IP,
;; hostname, machine-id and hardware serials are omitted. It evaluates each NIC
;; for real clock workflows and records enough non-unique platform identity to
;; compare two Linux debug hosts reproducibly.

(require racket/format
         racket/list
         racket/string
         "../engine/detect.rkt"
         "../engine/qualification.rkt"
         "platform-fingerprint.rkt"
         "host-quality.rkt")

(provide make-doctor-report
         collect-doctor-report
         doctor->text)

(define (nic-ref nic key [default #f])
  (if (hash? nic) (hash-ref nic key default) default))

(define (support-nic nic)
  (hasheq 'name (nic-ref nic 'name "")
          'driver (nic-ref nic 'driver "")
          'driver_version (nic-ref nic 'driver_version "")
          'firmware_version (nic-ref nic 'firmware_version "")
          'bus_info (nic-ref nic 'bus_info "")
          'pci_vendor_id (nic-ref nic 'pci_vendor_id "unknown")
          'pci_device_id (nic-ref nic 'pci_device_id "unknown")
          'subsystem_vendor_id (nic-ref nic 'subsystem_vendor_id "unknown")
          'subsystem_device_id (nic-ref nic 'subsystem_device_id "unknown")
          'numa_node (nic-ref nic 'numa_node "unknown")
          'operstate (nic-ref nic 'operstate "unknown")
          'up (and (nic-ref nic 'up #f) #t)
          'speed (nic-ref nic 'speed "unknown")
          'hw_timestamping (and (nic-ref nic 'hw_timestamping #f) #t)
          'phc_device (nic-ref nic 'phc_device #f)
          'phc_clock_name (nic-ref nic 'phc_clock_name "unknown")
          'ptp4l_available (and (nic-ref nic 'ptp4l_available #f) #t)
          'phc2sys_available (and (nic-ref nic 'phc2sys_available #f) #t)
          'pmc_available (and (nic-ref nic 'pmc_available #f) #t)
          'ethtool_available (and (nic-ref nic 'ethtool_available #f) #t)
          'ip_available (and (nic-ref nic 'ip_available #f) #t)
          'getcap_available (and (nic-ref nic 'getcap_available #f) #t)
          'ptp4l_file_capabilities (and (nic-ref nic 'ptp4l_file_capabilities #f) #t)
          'phc2sys_file_capabilities (and (nic-ref nic 'phc2sys_file_capabilities #f) #t)
          'privilege_mode (nic-ref nic 'privilege_mode "unknown")))

(define (qualification-for platform nic role reference)
  (qualify-interface #:platform platform
                     #:nics (list nic)
                     #:iface (nic-ref nic 'name "")
                     #:role role
                     #:reference reference))

(define (interface-report platform nic)
  (hasheq 'nic (support-nic nic)
          'slave (qualification-for platform nic "slave" "none")
          'grandmaster_system (qualification-for platform nic "grandmaster" "system")
          'grandmaster_external (qualification-for platform nic "grandmaster" "none")))

(define (real-candidate? iface-report)
  (or (not (qualification-blocking? (hash-ref iface-report 'slave)))
      (not (qualification-blocking? (hash-ref iface-report 'grandmaster_system)))
      (not (qualification-blocking? (hash-ref iface-report 'grandmaster_external)))))

(define (make-doctor-report #:version version
                            #:platform platform
                            #:nics nics
                            #:host [host (hasheq)]
                            #:host-quality
                            [host-quality
                             (assess-host-quality host (empty-host-runtime-context))])
  (define interfaces
    (for/list ([nic (in-list nics)])
      (interface-report platform nic)))
  (define candidates (count real-candidate? interfaces))
  (hasheq 'schema_version 1
          'product "gPTP Studio"
          'version version
          'platform platform
          'host host
          'host_quality host-quality
          'privacy (hasheq 'network_identifiers_redacted #t
                           'host_identifiers_redacted #t
                           'note "MAC/IP, hostname, machine-id and hardware serials are intentionally omitted.")
          'interface_count (length interfaces)
          'real_engine_candidate_count candidates
          'summary
          (cond
            [(null? interfaces)
             "No non-loopback network interface was detected."]
            [(zero? candidates)
             "No detected interface can currently proceed with a real GM/Slave workflow without a known structural blocker."]
            [else
             (format "~a of ~a detected interface(s) can proceed to real-engine verification without a known structural blocker."
                     candidates (length interfaces))])
          'interfaces interfaces
          'accuracy_claim "not-calibrated"
          'accuracy_note
          "Doctor reports prerequisites, host context and observed capabilities only; it does not establish end-to-end timing accuracy."))

(define (collect-doctor-report version)
  (define host (collect-platform-fingerprint))
  (make-doctor-report #:version version
                      #:platform (platform-name)
                      #:host host
                      #:host-quality (collect-host-quality host)
                      #:nics (detect-interfaces)))

(define (bool-label v) (if v "yes" "no"))

(define (status-label q)
  (string-upcase (hash-ref q 'status "blocked")))

(define (blocking-actions q)
  (for/list ([c (in-list (hash-ref q 'checks '()))]
             #:when (and (string=? (hash-ref c 'state "") "fail")
                         (not (string=? (hash-ref c 'action "") ""))))
    (hash-ref c 'action)))

(define (warnings q)
  (for/list ([c (in-list (hash-ref q 'checks '()))]
             #:when (string=? (hash-ref c 'state "") "warn"))
    (format "~a: ~a"
            (hash-ref c 'title (hash-ref c 'id "check"))
            (hash-ref c 'detail ""))))

(define (nested-ref h keys [default "unknown"])
  (let loop ([v h] [rest keys])
    (cond
      [(null? rest) v]
      [(hash? v) (loop (hash-ref v (car rest) default) (cdr rest))]
      [else default])))

(define (tool-label host tool)
  (define v (nested-ref host (list 'tools tool) #f))
  (if (and v (not (string=? v ""))) v "not detected"))

(define (host-quality-lines report)
  (define quality (hash-ref report 'host_quality (hasheq)))
  (define checks (hash-ref quality 'checks '()))
  (append
   (list ""
         (format "Timing host context: ~a (~a advisory warning(s))"
                 (string-upcase (hash-ref quality 'status "context"))
                 (hash-ref quality 'warning_count 0)))
   (for/list ([c (in-list checks)])
     (define state (string-upcase (hash-ref c 'state "info")))
     (define action (hash-ref c 'action ""))
     (format "  [~a] ~a: ~a~a"
             state
             (hash-ref c 'title (hash-ref c 'id "check"))
             (hash-ref c 'detail "")
             (if (string=? action "") "" (format " | ~a" action))))
   (list "  Host-quality checks are context only and never block engine startup.")))

(define (doctor->text report)
  (define host (hash-ref report 'host (hasheq)))
  (define header
    (list (format "gPTP Studio Doctor ~a" (hash-ref report 'version "unknown"))
          (format "Platform: ~a" (hash-ref report 'platform "unknown"))
          (format "Host: ~a ~a | kernel ~a | ~a"
                  (nested-ref host '(distro pretty_name))
                  (nested-ref host '(kernel architecture))
                  (nested-ref host '(kernel release))
                  (nested-ref host '(system virtualization)))
          (format "System: ~a / ~a / board ~a | clocksource=~a"
                  (nested-ref host '(system vendor))
                  (nested-ref host '(system product_name))
                  (nested-ref host '(system board_name))
                  (nested-ref host '(system clocksource)))
          (format "Tools: ~a | ~a | ~a"
                  (tool-label host 'ptp4l)
                  (tool-label host 'phc2sys)
                  (tool-label host 'pmc))
          "Privacy: network + unique host identifiers omitted"
          (format "Summary: ~a" (hash-ref report 'summary ""))))
  (define interface-lines
    (apply append
           (for/list ([entry (in-list (hash-ref report 'interfaces '()))])
             (define nic (hash-ref entry 'nic))
             (define slave (hash-ref entry 'slave))
             (define gm-system (hash-ref entry 'grandmaster_system))
             (define gm-external (hash-ref entry 'grandmaster_external))
             (define actions
               (remove-duplicates
                (append (blocking-actions slave)
                        (blocking-actions gm-system)
                        (blocking-actions gm-external))
                string=?))
             (define warns
               (remove-duplicates
                (append (warnings slave)
                        (warnings gm-system)
                        (warnings gm-external))
                string=?))
             (append
              (list ""
                    (format "Interface: ~a" (hash-ref nic 'name "unknown"))
                    (format "  driver=~a version=~a firmware=~a bus=~a"
                            (hash-ref nic 'driver "")
                            (hash-ref nic 'driver_version "")
                            (hash-ref nic 'firmware_version "")
                            (hash-ref nic 'bus_info ""))
                    (format "  pci=~a:~a subsystem=~a:~a numa=~a"
                            (hash-ref nic 'pci_vendor_id "unknown")
                            (hash-ref nic 'pci_device_id "unknown")
                            (hash-ref nic 'subsystem_vendor_id "unknown")
                            (hash-ref nic 'subsystem_device_id "unknown")
                            (hash-ref nic 'numa_node "unknown"))
                    (format "  link=~a speed=~a"
                            (hash-ref nic 'operstate "unknown")
                            (hash-ref nic 'speed "unknown"))
                    (format "  hw_timestamping=~a phc=~a phc_clock=~a"
                            (bool-label (hash-ref nic 'hw_timestamping #f))
                            (or (hash-ref nic 'phc_device #f) "none")
                            (hash-ref nic 'phc_clock_name "unknown"))
                    (format "  ptp4l=~a phc2sys=~a pmc=~a privilege=~a"
                            (bool-label (hash-ref nic 'ptp4l_available #f))
                            (bool-label (hash-ref nic 'phc2sys_available #f))
                            (bool-label (hash-ref nic 'pmc_available #f))
                            (hash-ref nic 'privilege_mode "unknown"))
                    (format "  Slave: ~a" (status-label slave))
                    (format "  GM (system reference): ~a" (status-label gm-system))
                    (format "  GM (external/managed PHC): ~a" (status-label gm-external)))
              (if (null? actions)
                  '()
                  (cons "  Blocking actions:"
                        (for/list ([a (in-list actions)])
                          (format "    - ~a" a))))
              (if (null? warns)
                  '()
                  (cons "  Verify/warnings:"
                        (for/list ([w (in-list warns)])
                          (format "    - ~a" w))))))))
  (string-join
   (append header
           (host-quality-lines report)
           interface-lines
           (list ""
                 (format "Timing note: ~a" (hash-ref report 'accuracy_note ""))))
   "\n"))
