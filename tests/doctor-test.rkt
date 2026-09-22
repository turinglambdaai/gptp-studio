#lang racket/base

(require json
         rackunit
         racket/port
         racket/string
         "../support/doctor.rkt")

(define ready-nic
  (hasheq 'name "enp3s0"
          'mac "aa:bb:cc:dd:ee:ff"
          'ips '("192.0.2.10")
          'driver "igb"
          'operstate "up"
          'up #t
          'speed "1000"
          'hw_timestamping #t
          'phc_device "/dev/ptp0"
          'ptp4l_available #t
          'phc2sys_available #t
          'pmc_available #t
          'ethtool_available #t
          'ip_available #t
          'getcap_available #t
          'ptp4l_file_capabilities #t
          'phc2sys_file_capabilities #t
          'privilege_mode "file-capabilities"))

(define generic-nic
  (hash-set* ready-nic
             'name "eth1"
             'driver "r8169"
             'mac "11:22:33:44:55:66"
             'ips '("198.51.100.20")
             'hw_timestamping #f
             'phc_device #f))

(define report
  (make-doctor-report #:version "1.2.3-test"
                      #:platform "linux"
                      #:nics (list ready-nic generic-nic)))

(check-equal? (hash-ref report 'schema_version) 1)
(check-equal? (hash-ref report 'interface_count) 2)
(check-equal? (hash-ref report 'real_engine_candidate_count) 1)
(check-equal? (hash-ref report 'accuracy_claim) "not-calibrated")

(define interfaces (hash-ref report 'interfaces))
(define first-nic (hash-ref (car interfaces) 'nic))
(check-equal? (hash-ref first-nic 'name) "enp3s0")
(check-equal? (hash-ref first-nic 'driver) "igb")
(check-false (hash-has-key? first-nic 'mac))
(check-false (hash-has-key? first-nic 'ips))
(check-equal? (hash-ref (hash-ref (car interfaces) 'slave) 'status) "ready")
(check-equal? (hash-ref (hash-ref (cadr interfaces) 'slave) 'status) "passive-only")

;; A serialized support report must remain free of the supplied MAC/IP values.
(define out (open-output-string))
(write-json report out)
(define json-text (get-output-string out))
(check-false (string-contains? json-text "aa:bb:cc:dd:ee:ff"))
(check-false (string-contains? json-text "192.0.2.10"))
(check-false (string-contains? json-text "11:22:33:44:55:66"))
(check-false (string-contains? json-text "198.51.100.20"))

(define text (doctor->text report))
(check-true (string-contains? text "gPTP Studio Doctor 1.2.3-test"))
(check-true (string-contains? text "Interface: enp3s0"))
(check-true (string-contains? text "Slave: READY"))
(check-true (string-contains? text "Interface: eth1"))
(check-true (string-contains? text "Slave: PASSIVE-ONLY"))
(check-false (string-contains? text "192.0.2.10"))
