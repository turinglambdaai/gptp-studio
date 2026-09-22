#lang racket/base

;; Headless support report used by `gptp-studio --doctor` and --doctor-json.
;;
;; The report is deliberately safe to paste into a support ticket: MAC and IP
;; addresses are omitted. It evaluates each detected NIC for the three real
;; clock workflows engineers most commonly need, while preserving the same
;; conservative rule as GUI Preflight: readiness is not calibrated accuracy.

(require racket/format
         racket/list
         racket/string
         "../engine/detect.rkt"
         "../engine/qualification.rkt")

(provide make-doctor-report
         collect-doctor-report
         doctor->text)

(define (nic-ref nic key [default #f])
  (if (hash? nic) (hash-ref nic key default) default))

(define (support-nic nic)
  (hasheq 'name (nic-ref nic 'name "")
          'driver (nic-ref nic 'driver "")
          'operstate (nic-ref nic 'operstate "unknown")
          'up (and (nic-ref nic 'up #f) #t)
          'speed (nic-ref nic 'speed "unknown")
          'hw_timestamping (and (nic-ref nic 'hw_timestamping #f) #t)
          'phc_device (nic-ref nic 'phc_device #f)
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

(define (make-doctor-report #:version version #:platform platform #:nics nics)
  (define interfaces
    (for/list ([nic (in-list nics)])
      (interface-report platform nic)))
  (define candidates (count real-candidate? interfaces))
  (hasheq 'schema_version 1
          'product "gPTP Studio"
          'version version
          'platform platform
          'privacy (hasheq 'network_identifiers_redacted #t
                           'note "MAC and IP addresses are intentionally omitted.")
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
          "Doctor reports prerequisites and observed capabilities only; it does not establish end-to-end timing accuracy."))

(define (collect-doctor-report version)
  (make-doctor-report #:version version
                      #:platform (platform-name)
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

(define (doctor->text report)
  (define header
    (list (format "gPTP Studio Doctor ~a" (hash-ref report 'version "unknown"))
          (format "Platform: ~a" (hash-ref report 'platform "unknown"))
          "Privacy: MAC/IP omitted"
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
                    (format "  driver=~a link=~a speed=~a"
                            (hash-ref nic 'driver "")
                            (hash-ref nic 'operstate "unknown")
                            (hash-ref nic 'speed "unknown"))
                    (format "  hw_timestamping=~a phc=~a"
                            (bool-label (hash-ref nic 'hw_timestamping #f))
                            (or (hash-ref nic 'phc_device #f) "none"))
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
           interface-lines
           (list ""
                 (format "Timing note: ~a" (hash-ref report 'accuracy_note ""))))
   "\n"))
