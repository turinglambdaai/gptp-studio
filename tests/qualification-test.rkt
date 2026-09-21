#lang racket/base

(require rackunit
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
(check-equal? (hash-ref ready 'accuracy_claim) "not-calibrated")

;; Unknown privilege is a warning, not a false hard failure: setcap/ambient
;; capability paths are only proven when the real process actually starts.
(define candidate-nic (hash-set ready-nic 'privilege_mode "unknown"))
(define candidate
  (qualify-interface #:platform "linux"
                     #:nics (list candidate-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref candidate 'status) "candidate")
(check-equal? (hash-ref candidate 'fail_count) 0)
(check-equal? (hash-ref candidate 'warn_count) 1)

;; A generic NIC without HW timestamp/PHC is still useful for passive analysis,
;; but must never be represented as a timing-validation platform.
(define sw-nic
  (hash-set* ready-nic
             'hw_timestamping #f
             'phc_device #f
             'privilege_mode "unknown"))
(define passive
  (qualify-interface #:platform "linux"
                     #:nics (list sw-nic)
                     #:iface "enp3s0"
                     #:role "slave"))
(check-equal? (hash-ref passive 'status) "passive-only")
(check-true (> (hash-ref passive 'fail_count) 0))

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
