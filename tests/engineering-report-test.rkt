#lang racket/base

(require rackunit
         racket/list
         racket/string
         "../support/engineering-report.rkt")

(define offset-points
  (list (cons 1000.0 100)
        (cons 1000.1 200)
        (cons 1000.2 150000)
        (cons 1000.3 151000)
        (cons 1000.4 -50000)))

(define delay-points
  (list (cons 1000.0 10000)
        (cons 1000.1 10100)
        (cons 1000.2 9900)))

(define offset-summary (summarize-series offset-points))
(check-equal? (hash-ref offset-summary 'count) 5)
(check-equal? (hash-ref offset-summary 'min) -50000)
(check-equal? (hash-ref offset-summary 'max) 151000)
(check-equal? (hash-ref offset-summary 'abs_max) 151000)
(check-equal? (hash-ref offset-summary 'last) -50000)

(define jumps (offset-jump-observations offset-points 100000))
(check-equal? (hash-ref jumps 'count) 2)
(check-equal? (hash-ref jumps 'threshold_ns) 100000)
(check-equal? (length (hash-ref jumps 'largest)) 2)
(check-equal? (hash-ref (first (hash-ref jumps 'largest)) 'delta_ns) -201000)

(define (announce ts seq p1 gm source)
  (hasheq 'ts ts
          'is_ptp #t
          'timestamp_source "adapter"
          'ptp (hasheq 'message_type_name "Announce"
                       'domain_number 0
                       'sequence_id seq
                       'source_port_identity source)
          'body (hasheq 'grandmaster_priority1 p1
                        'grandmaster_clock_class 248
                        'grandmaster_clock_accuracy 34
                        'grandmaster_offset_scaled_log_variance 20061
                        'grandmaster_priority2 128
                        'grandmaster_identity gm
                        'steps_removed 1
                        'time_source 32
                        'time_source_name "GPS")))

(define packets
  (list
   (announce 1000.2 3 100 "gm-a" "src-a.1")
   (announce 1000.1 2 128 "gm-a" "src-a.1")
   (announce 1000.0 1 120 "gm-b" "src-b.1")
   (hasheq 'ts 1000.25
           'is_ptp #t
           'timestamp_source "host-high-precision"
           'ptp (hasheq 'message_type_name "Sync"
                        'domain_number 0
                        'sequence_id 5
                        'source_port_identity "src-a.1")
           'body (hasheq))))

(define packet-summary (summarize-packets packets))
(check-equal? (hash-ref packet-summary 'ptp_packet_count) 4)
(check-equal? (hash-ref packet-summary 'announce_count) 3)
(check-equal? (hash-ref (hash-ref packet-summary 'message_counts) 'Announce) 3)
(check-equal? (hash-ref (hash-ref packet-summary 'message_counts) 'Sync) 1)
(check-equal? (hash-ref packet-summary 'domains) '(0))
(check-equal? (hash-ref packet-summary 'timestamp_sources)
              '("adapter" "host-high-precision"))
(check-equal? (length (hash-ref packet-summary 'observed_bmca_candidates)) 2)
(define gm-a
  (for/first ([c (in-list (hash-ref packet-summary 'observed_bmca_candidates))]
              #:when (equal? (hash-ref c 'grandmaster_identity) "gm-a"))
    c))
(check-not-false gm-a)
(check-equal? (hash-ref gm-a 'count) 2)
(check-equal? (hash-ref (hash-ref gm-a 'latest_dataset) 'grandmaster_priority1) 100)

(define nic
  (hasheq 'name "enp3s0"
          'mac "aa:bb:cc:dd:ee:ff"
          'ips '("192.0.2.10")
          'driver "igb"
          'hw_timestamping #t
          'phc_device "/dev/ptp0"
          'privilege_mode "file-capabilities"))

(define report
  (make-engineering-report
   #:version "1.2.3-test"
   #:platform "linux"
   #:nics (list nic)
   #:qualification (hasheq 'status "ready" 'summary "ready for real-engine verification")
   #:engine (hasheq 'mode "real"
                    'role "slave"
                    'iface "enp3s0"
                    'port_state "SLAVE"
                    'gm_id "gm-a"
                    'freq_ppb 12)
   #:capture (hasheq 'running #t
                     'iface "enp3s0"
                     'timestamp_source "adapter"
                     'timestamp_precision "nano")
   #:params (hasheq 'domain 0)
   #:conf "[global]\ndomainNumber 0\n"
   #:offset-points offset-points
   #:delay-points delay-points
   #:packets packets
   #:logs (list (list 1000000 "ptp4l" "info" "port 1: LISTENING to SLAVE"))
   #:offset-jump-threshold-ns 100000))

(check-equal? (hash-ref report 'schema_version) 1)
(check-equal? (hash-ref report 'accuracy_claim) "not-calibrated")
(check-true (hash-ref (hash-ref report 'privacy) 'network_identifiers_redacted))
(define exported-nic (first (hash-ref report 'nics)))
(check-false (hash-has-key? exported-nic 'mac))
(check-false (hash-has-key? exported-nic 'ips))
(check-equal? (hash-ref (hash-ref report 'timing_observations) 'count) 2)
(check-equal? (length (hash-ref (hash-ref report 'packet_observations) 'observed_bmca_candidates)) 2)

(define markdown (engineering-report->markdown report))
(check-true (string-contains? markdown "# gPTP Studio Engineering Report"))
(check-true (string-contains? markdown "Accuracy claim: **not-calibrated**"))
(check-true (string-contains? markdown "Observed Announce / BMCA candidates"))
(check-true (string-contains? markdown "GM `gm-a`"))
(check-true (string-contains? markdown "Offset jump observations"))
(check-false (string-contains? markdown "aa:bb:cc:dd:ee:ff"))
(check-false (string-contains? markdown "192.0.2.10"))
