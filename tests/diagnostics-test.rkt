#lang racket/base

(require json
         rackunit
         racket/file
         "../support/diagnostics.rkt")

(define nic
  (hasheq 'name "enp3s0"
          'mac "aa:bb:cc:dd:ee:ff"
          'ips '("192.168.1.10")
          'driver "igb"
          'driver_version "6.8-test"
          'firmware_version "3.25"
          'bus_info "0000:03:00.0"
          'phc_device "/dev/ptp0"
          'phc_clock_name "i210-ptp"))

(define host
  (hasheq 'fingerprint_schema_version 1
          'distro (hasheq 'pretty_name "Ubuntu 24.04 LTS")
          'kernel (hasheq 'release "6.8.0-test" 'architecture "x86_64")
          'system (hasheq 'vendor "Example" 'product_name "LabHost"
                          'board_name "Board" 'virtualization "none"
                          'clocksource "tsc")
          'privacy (hasheq 'hostname_omitted #t
                           'machine_id_omitted #t
                           'hardware_serials_omitted #t
                           'network_identifiers_omitted #t)))

(define redacted (redact-nic nic))
(check-false (hash-has-key? redacted 'mac))
(check-false (hash-has-key? redacted 'ips))
(check-equal? (hash-ref redacted 'driver) "igb")
(check-equal? (hash-ref redacted 'driver_version) "6.8-test")
(check-equal? (hash-ref redacted 'phc_device) "/dev/ptp0")

(define snapshot
  (make-diagnostic-snapshot
   #:version "0-test"
   #:platform "linux"
   #:host host
   #:nics (list nic)
   #:qualification (hasheq 'status "ready")
   #:engine (hasheq 'mode #f)
   #:capture (hasheq 'running #f)
   #:params (hasheq 'domain 0)
   #:conf "[global]\n"
   #:logs (list (list 1234.0 "app" "info" "test log"))))

(check-equal? (hash-ref snapshot 'schema_version) 1)
(define privacy (hash-ref snapshot 'privacy))
(check-true (hash-ref privacy 'network_identifiers_redacted))
(check-true (hash-ref privacy 'host_identifiers_redacted))
(check-equal? (hash-ref (hash-ref snapshot 'host) 'fingerprint_schema_version) 1)
(define snapshot-nic (car (hash-ref snapshot 'nics)))
(check-false (hash-has-key? snapshot-nic 'mac))
(check-false (hash-has-key? snapshot-nic 'ips))
(check-equal? (hash-ref snapshot-nic 'name) "enp3s0")
(check-equal? (hash-ref snapshot-nic 'firmware_version) "3.25")

;; The support path must prove not only that the structure looks right in
;; memory, but that Racket's JSON writer can serialize the real shape.
(define tmp (make-temporary-file "gptp-studio-diagnostics-~a.json"))
(dynamic-wind
  void
  (lambda ()
    (write-diagnostic-snapshot! tmp snapshot)
    (define loaded (call-with-input-file tmp read-json))
    (check-equal? (hash-ref loaded 'schema_version) 1)
    (check-equal? (hash-ref (hash-ref loaded 'app) 'name) "gPTP Studio")
    (check-equal? (hash-ref (hash-ref loaded 'host) 'fingerprint_schema_version) 1)
    (check-true (hash-ref (hash-ref loaded 'privacy) 'host_identifiers_redacted))
    (define loaded-nic (car (hash-ref loaded 'nics)))
    (check-false (hash-has-key? loaded-nic 'mac))
    (check-false (hash-has-key? loaded-nic 'ips)))
  (lambda ()
    (when (file-exists? tmp) (delete-file tmp))))
