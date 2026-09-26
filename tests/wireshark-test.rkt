#lang racket/base

;; Wireshark integration: pure parts only (filter strings, shell quoting).
;; Launching spawns a detached GUI process and is covered by acceptance on a
;; real Linux host.

(require rackunit
         racket/string
         "../support/wireshark.rkt")

(test-equal? "L2 filter" (gptp-capture-filter "L2") "ether proto 0x88f7")
(test-equal? "UDPv4 filter" (gptp-capture-filter "UDPv4") "port 319 or port 320")
(test-equal? "both-transport fallback" (gptp-capture-filter "weird")
             "ether proto 0x88f7 or (port 319 or port 320)")
(test-equal? "default is L2" (gptp-capture-filter) "ether proto 0x88f7")

(test-case "temp pcap path lands in the system temp dir with .pcap suffix"
  (define p (wireshark-temp-pcap-path))
  (check-true (string-suffix? (path->string p) ".pcap"))
  (check-true (string-contains? (path->string p) "gptp-studio-wireshark-")))

(test-case "wireshark missing raises an actionable error"
  (check-exn
   exn:fail?
   (lambda ()
     (parameterize ([current-environment-variables
                     (make-environment-variables)]) ; empty PATH
       (launch-wireshark-file! "/nonexistent/x.pcap")))))

(test-case "live launch raises a user error without wireshark on PATH"
  (check-exn
   exn:fail:user?
   (lambda ()
     (parameterize ([current-environment-variables
                     (make-environment-variables)]) ; empty PATH
       (launch-wireshark-live! "" "ether proto 0x88f7")))))
