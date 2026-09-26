#lang racket/base

(require rackunit
         racket/string
         "../engine/failure-diagnosis.rkt")

(define (kind stderr [process "ptp4l"])
  (hash-ref
   (diagnose-linuxptp-failure process stderr 1 'file-capabilities)
   'kind))

(check-equal?
 (kind "ptp4l: ioctl SIOCSHWTSTAMP failed: Operation not permitted")
 "permission")

(check-equal?
 (kind (string-append
        "ptp4l[1.0]: interface 'enp8s0' does not support requested timestamping mode\n"
        "failed to create a clock\n"))
 "hardware-timestamping")

(check-equal?
 (kind "Cannot find device enp99s0\nNo such device")
 "interface")

(check-equal?
 (kind "failed to open /dev/ptp2: No such file or directory")
 "phc")

(check-equal?
 (kind "uds: bind failed: Address already in use")
 "ownership-conflict")

(check-equal?
 (kind "unknown option clientOnly")
 "configuration")

(check-equal?
 (kind "failed to create a clock")
 "clock-create")

(define unknown
  (diagnose-linuxptp-failure "ptp4l" "unexpected fatal state" 7 'sudo-noninteractive))
(check-equal? (hash-ref unknown 'kind) "unknown")
(check-equal? (hash-ref unknown 'exit_code) 7)
(check-equal? (hash-ref unknown 'launch_mode) "sudo-noninteractive")
(check-equal? (hash-ref unknown 'evidence) "unexpected fatal state")

(define timestamp-diagnosis
  (diagnose-linuxptp-failure
   "ptp4l"
   "interface 'eth0' does not support requested timestamping mode\nfailed to create a clock"
   255
   'direct-best-effort))
(define rendered (failure-diagnosis->message timestamp-diagnosis))
(check-true (string-contains? rendered "硬件时间戳模式不可用"))
(check-true (string-contains? rendered "ethtool -T"))
(check-true (string-contains? rendered "interface 'eth0'"))
(check-true (string-contains? rendered "rc=255"))
