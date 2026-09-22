#lang racket/base

(require json
         rackunit
         racket/hash
         racket/port
         racket/string
         "../support/doctor.rkt")

(define ready-nic
  (hasheq 'name "enp3s0"
          'mac "aa:bb:cc:dd:ee:ff"
          'ips '("192.0.2.10")
          'driver "igb"
          'driver_version "6.8.0-test"
          'firmware_version "3.25"
          'bus_info "0000:03:00.0"
          'pci_vendor_id "0x8086"
          'pci_device_id "0x1533"
          'subsystem_vendor_id "0x8086"
          'subsystem_device_id "0x0001"
          'numa_node "0"
          'operstate "up"
          'up #t
          'speed "1000"
          'hw_timestamping #t
          'phc_device "/dev/ptp0"
          'phc_clock_name "i210-ptp"
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
             'phc_device #f
             'phc_clock_name "unknown"))

(define host
  (hasheq 'fingerprint_schema_version 1
          'distro (hasheq 'id "ubuntu"
                          'version_id "24.04"
                          'pretty_name "Ubuntu 24.04 LTS")
          'kernel (hasheq 'release "6.8.0-test"
                          'version "#1 PREEMPT_DYNAMIC"
                          'architecture "x86_64")
          'system (hasheq 'vendor "ExampleVendor"
                          'product_name "ReferenceHost"
                          'board_name "ReferenceBoard"
                          'virtualization "none"
                          'clocksource "tsc")
          'runtime (hasheq 'racket_version "9.3")
          'tools (hasheq 'ptp4l "4.0"
                         'phc2sys "4.0"
                         'pmc "4.0"
                         'ethtool "ethtool version 6.7"
                         'openssl "OpenSSL test")
          'packages (hasheq)
          'privacy (hasheq 'hostname_omitted #t
                           'machine_id_omitted #t
                           'hardware_serials_omitted #t
                           'network_identifiers_omitted #t)))

(define report
  (make-doctor-report #:version "1.2.3-test"
                      #:platform "linux"
                      #:host host
                      #:nics (list ready-nic generic-nic)))

(check-equal? (hash-ref report 'schema_version) 1)
(check-equal? (hash-ref report 'interface_count) 2)
(check-equal? (hash-ref report 'real_engine_candidate_count) 1)
(check-equal? (hash-ref report 'accuracy_claim) "not-calibrated")
(check-equal? (hash-ref (hash-ref report 'host) 'fingerprint_schema_version) 1)
(check-true (hash-ref (hash-ref report 'privacy) 'host_identifiers_redacted))

(define interfaces (hash-ref report 'interfaces))
(define first-nic (hash-ref (car interfaces) 'nic))
(check-equal? (hash-ref first-nic 'name) "enp3s0")
(check-equal? (hash-ref first-nic 'driver) "igb")
(check-equal? (hash-ref first-nic 'driver_version) "6.8.0-test")
(check-equal? (hash-ref first-nic 'firmware_version) "3.25")
(check-equal? (hash-ref first-nic 'pci_vendor_id) "0x8086")
(check-equal? (hash-ref first-nic 'phc_clock_name) "i210-ptp")
(check-false (hash-has-key? first-nic 'mac))
(check-false (hash-has-key? first-nic 'ips))
(check-equal? (hash-ref (hash-ref (car interfaces) 'slave) 'status) "ready")
(check-equal? (hash-ref (hash-ref (cadr interfaces) 'slave) 'status) "passive-only")

;; A serialized support report must remain free of supplied network identifiers.
(define out (open-output-string))
(write-json report out)
(define json-text (get-output-string out))
(check-false (string-contains? json-text "aa:bb:cc:dd:ee:ff"))
(check-false (string-contains? json-text "192.0.2.10"))
(check-false (string-contains? json-text "11:22:33:44:55:66"))
(check-false (string-contains? json-text "198.51.100.20"))

(define text (doctor->text report))
(check-true (string-contains? text "gPTP Studio Doctor 1.2.3-test"))
(check-true (string-contains? text "Ubuntu 24.04 LTS x86_64"))
(check-true (string-contains? text "ReferenceHost"))
(check-true (string-contains? text "Interface: enp3s0"))
(check-true (string-contains? text "driver=igb version=6.8.0-test firmware=3.25"))
(check-true (string-contains? text "pci=0x8086:0x1533"))
(check-true (string-contains? text "phc_clock=i210-ptp"))
(check-true (string-contains? text "Slave: READY"))
(check-true (string-contains? text "Interface: eth1"))
(check-true (string-contains? text "Slave: PASSIVE-ONLY"))
(check-false (string-contains? text "192.0.2.10"))
