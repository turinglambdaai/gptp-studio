#lang racket/base

(require rackunit
         "../support/diagnostics.rkt")

(define nic
  (hasheq 'name "enp3s0"
          'mac "aa:bb:cc:dd:ee:ff"
          'ips '("192.168.1.10")
          'driver "igb"
          'phc_device "/dev/ptp0"))

(define redacted (redact-nic nic))
(check-false (hash-has-key? redacted 'mac))
(check-false (hash-has-key? redacted 'ips))
(check-equal? (hash-ref redacted 'driver) "igb")
(check-equal? (hash-ref redacted 'phc_device) "/dev/ptp0")

(define snapshot
  (make-diagnostic-snapshot
   #:version "0-test"
   #:platform "linux"
   #:nics (list nic)
   #:qualification (hasheq 'status "ready")
   #:engine (hasheq 'mode #f)
   #:capture (hasheq 'running #f)
   #:params (hasheq 'domain 0)
   #:conf "[global]\n"
   #:logs '()))

(check-equal? (hash-ref snapshot 'schema_version) 1)
(check-true (hash-ref (hash-ref snapshot 'privacy) 'network_identifiers_redacted))
(define snapshot-nic (car (hash-ref snapshot 'nics)))
(check-false (hash-has-key? snapshot-nic 'mac))
(check-false (hash-has-key? snapshot-nic 'ips))
(check-equal? (hash-ref snapshot-nic 'name) "enp3s0")
