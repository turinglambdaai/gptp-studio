#lang racket/base

(require rackunit
         racket/hash
         "../engine/qualification.rkt")

(define ready-nic
  (hasheq 'name "enp3s0"
          'operstate "up"
          'up #t
          'hw_timestamping #t
          'phc_device "/dev/ptp0"
          'driver "igb"
          'ptp4l_available #t
          'phc2sys_available #t
          'pmc_available #t
          'ethtool_available #t
          'ip_available #t
          'ptp4l_file_capabilities #f
          'phc2sys_file_capabilities #f
          'privilege_mode "root"))

(define ready
  (qualify-interface #:platform "linux"
                     #:nics (list ready-nic)
                     #:iface "enp3s0"
                     #:role "grandmaster"
                     #:reference "system"))
(check-equal? (hash-ref ready 'status) "ready")
(check-equal? (hash-ref ready 'fail_count) 0)
(check-equal? (hash-ref ready 'warn_count) 0)
(check-false (qualification-blocking? ready))
(check-equal? (hash-ref ready 'accuracy_claim) "not-calibrated")

;; Unknown/direct-best-effort privilege is a warning, not a false hard failure:
;; ambient/container capabilities may still make the actual process start.
(define candidate-nic (hash-set ready-nic 'privilege_mode "direct-best-effort"))
(define candidate
  (qualify-interface #:platform "linux"
                     #:nics (list candidate-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref candidate 'status) "candidate")
(check-equal? (hash-ref candidate 'fail_count) 0)
(check-equal? (hash-ref candidate 'warn_count) 1)
(check-false (qualification-blocking? candidate))

;; A link may be down while an engineer starts ptp4l before connecting the DUT.
;; That is VERIFY/WARN, never a structural start blocker.
(define link-down-nic
  (hash-set* ready-nic 'up #f 'operstate "down"))
(define link-down
  (qualify-interface #:platform "linux"
                     #:nics (list link-down-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref link-down 'status) "candidate")
(check-equal? (hash-ref link-down 'fail_count) 0)
(check-false (qualification-blocking? link-down))

;; A complete setcap path is a proven non-root privilege path. GM + system
;; reference needs both ptp4l network caps and phc2sys CAP_SYS_TIME.
(define file-cap-nic
  (hash-set* ready-nic
             'privilege_mode "file-capabilities"
             'ptp4l_file_capabilities #t
             'phc2sys_file_capabilities #t))
(define file-cap-ready
  (qualify-interface #:platform "linux"
                     #:nics (list file-cap-nic)
                     #:iface "enp3s0"
                     #:role "grandmaster"
                     #:reference "system"))
(check-equal? (hash-ref file-cap-ready 'status) "ready")
(check-equal? (hash-ref file-cap-ready 'warn_count) 0)

(define missing-phc-cap-nic
  (hash-set file-cap-nic 'phc2sys_file_capabilities #f))
(define missing-phc-cap
  (qualify-interface #:platform "linux"
                     #:nics (list missing-phc-cap-nic)
                     #:iface "enp3s0"
                     #:role "grandmaster"
                     #:reference "system"))
(check-equal? (hash-ref missing-phc-cap 'status) "candidate")
(check-false (qualification-blocking? missing-phc-cap))

;; A generic NIC without HW timestamp/PHC, when ethtool is available and has
;; actually inspected it, is useful for passive analysis but not a real clock
;; role.
(define sw-nic
  (hash-set* ready-nic
             'hw_timestamping #f
             'phc_device #f
             'privilege_mode "direct-best-effort"))
(define passive
  (qualify-interface #:platform "linux"
                     #:nics (list sw-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref passive 'status) "passive-only")
(check-true (> (hash-ref passive 'fail_count) 0))
(check-true (qualification-blocking? passive))
(check-not-false (member "hw-timestamp" (hash-ref passive 'blocking_check_ids)))
(check-not-false (member "phc" (hash-ref passive 'blocking_check_ids)))

;; Missing ethtool means capability is unknown, not proven unsupported. The
;; result must stay VERIFY/candidate rather than PASSIVE ONLY.
(define unknown-probe-nic
  (hash-set* ready-nic
             'hw_timestamping #f
             'phc_device #f
             'ethtool_available #f))
(define unknown-probe
  (qualify-interface #:platform "linux"
                     #:nics (list unknown-probe-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref unknown-probe 'status) "candidate")
(check-equal? (hash-ref unknown-probe 'fail_count) 0)
(check-true (>= (hash-ref unknown-probe 'warn_count) 3))
(check-false (qualification-blocking? unknown-probe))

;; macOS Listener remains a legitimate passive workflow.
(define mac-nic
  (hasheq 'name "en0"
          'operstate "active"
          'up #t
          'hw_timestamping #f
          'phc_device #f
          'driver "apple"
          'privilege_mode "n/a"))
(define listener
  (qualify-interface #:platform "macos"
                     #:nics (list mac-nic)
                     #:iface "en0"
                     #:role "listener"))
(check-equal? (hash-ref listener 'status) "ready")
(check-equal? (hash-ref listener 'fail_count) 0)

;; Actual libpcap source is reported independently from NIC capability.
(define host-capture
  (hasheq 'running #t
          'iface "enp3s0"
          'timestamp_source "host"
          'timestamp_precision "nano"))
(define capture-warning
  (qualify-interface #:platform "linux"
                     #:nics (list ready-nic)
                     #:iface "enp3s0"
                     #:role "grandmaster"
                     #:capture-status host-capture))
(check-equal? (hash-ref capture-warning 'status) "candidate")
(check-equal? (hash-ref capture-warning 'accuracy_claim) "not-calibrated")