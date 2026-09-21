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
   #:logs (list (list 1234.0 "app" "info" "test log"))))

(check-equal? (hash-ref snapshot 'schema_version) 1)
(check-true (hash-ref (hash-ref snapshot 'privacy) 'network_identifiers_redacted))
(define snapshot-nic (car (hash-ref snapshot 'nics)))
(check-false (hash-has-key? snapshot-nic 'mac))
(check-false (hash-has-key? snapshot-nic 'ips))
(check-equal? (hash-ref snapshot-nic 'name) "enp3s0")

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
    (define loaded-nic (car (hash-ref loaded 'nics)))
    (check-false (hash-has-key? loaded-nic 'mac))
    (check-false (hash-has-key? loaded-nic 'ips)))
  (lambda ()
    (when (file-exists? tmp) (delete-file tmp))))
