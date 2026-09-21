#lang racket/base

(require rackunit
         racket/file
         racket/string
         "../engine/config.rkt"
         "../engine/runtime-config.rkt")

(define run-dir (build-path (find-system-path 'temp-dir) "gptp-studio-runtime-test"))
(define gm (default-params-for-role 'grandmaster))
(define base (params->conf gm #:role "grandmaster" #:iface "eth0"))
(define conf (runtime-conf base run-dir))
(define uds (path->string (runtime-uds-path run-dir)))
(define uds-ro (path->string (runtime-uds-ro-path run-dir)))

(check-true (string-contains? conf (string-append "uds_address             " uds)))
(check-true (string-contains? conf (string-append "uds_ro_address          " uds-ro)))

(check-equal?
 (phc2sys-reference-args run-dir "eth0" gm)
 (list "-c" "eth0"
       "-s" "CLOCK_REALTIME"
       "-w"
       "-z" uds
       "-n" "0"
       "--transportSpecific=1"
       "-m"))

(check-equal?
 (pmc-current-data-set-args run-dir gm)
 (list "-u"
       "-s" uds
       "-d" "0"
       "-t" "1"
       "GET CURRENT_DATA_SET"))

;; Cleanup is intentionally idempotent even when no socket entries exist.
(check-not-exn (lambda () (cleanup-runtime-sockets! run-dir)))
(check-not-exn (lambda () (cleanup-runtime-sockets! run-dir)))
