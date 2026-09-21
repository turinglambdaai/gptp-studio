#lang racket/base

;; Support-oriented diagnostic snapshots.
;;
;; Default snapshots deliberately remove MAC/IP data. Interface name, driver,
;; PHC/tooling capability, engine/capture state and recent logs are enough for
;; most support cases and avoid exporting customer network identifiers by
;; default.

(require json
         racket/file
         racket/hash)

(provide redact-nic
         make-diagnostic-snapshot
         write-diagnostic-snapshot!)

(define (hash-remove-many h keys)
  (for/fold ([out h]) ([k (in-list keys)])
    (hash-remove out k)))

(define (redact-nic nic)
  (if (hash? nic)
      (hash-remove-many nic '(mac ips))
      nic))

(define (make-diagnostic-snapshot #:version version
                                  #:platform platform
                                  #:nics nics
                                  #:qualification qualification
                                  #:engine engine
                                  #:capture capture
                                  #:params params
                                  #:conf conf
                                  #:logs logs
                                  #:redact-network? [redact-network? #t])
  (hasheq 'schema_version 1
          'generated_at_unix_ms (inexact->exact (floor (current-inexact-milliseconds)))
          'app (hasheq 'name "gPTP Studio"
                       'version version
                       'platform platform)
          'privacy (hasheq 'network_identifiers_redacted redact-network?)
          'nics (if redact-network?
                    (map redact-nic nics)
                    nics)
          'qualification qualification
          'engine engine
          'capture capture
          'params params
          'ptp4l_conf conf
          'recent_logs logs))

(define (write-diagnostic-snapshot! path snapshot)
  (call-with-output-file path
    (lambda (out)
      (write-json snapshot out)
      (newline out))
    #:exists 'replace
    #:mode 'text)
  path)
