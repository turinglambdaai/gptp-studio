#lang racket/base

;; ptp4l.conf generator golden tests. The expected outputs are the exact
;; strings the GUI shows as a preview and hands to ptp4l.

(require rackunit
         racket/list
         racket/string
         "../engine/config.rkt")

;; GM defaults from the PRD example: priority1 0, gPTP profile values.
(define gm (default-params-for-role 'grandmaster))
(check-equal? (gptp-params-priority1 gm) 0)
(check-equal? (gptp-params-gm-capable gm) 1)
(check-equal? (gptp-params-slave-only gm) 0)

(define slave (default-params-for-role 'slave))
(check-equal? (gptp-params-slave-only slave) 1)
(check-equal? (gptp-params-gm-capable slave) 0)

(define conf (params->conf gm #:role "grandmaster" #:iface "enp3s0"))

;; helper: read one key's value out of a generated conf
(define (conf-get conf key)
  (for/first ([line (in-list (string-split conf "\n"))]
              #:when (string-prefix? line (string-append key " ")))
    (string-trim (substring line (string-length key)))))

(define (kv-pad key) (string-append key " "))

;; the load-bearing lines
(check-true (string-contains? conf "# role: grandmaster   iface: enp3s0\n"))
(check-true (string-contains? conf "[global]\n"))
(check-equal? (conf-get conf "priority1") "0")
(check-equal? (conf-get conf "slaveOnly") "0")
(check-equal? (conf-get conf "gmCapable") "1")
(check-equal? (conf-get conf "domainNumber") "0")
(check-equal? (conf-get conf "logSyncInterval") "-3")   ; 125ms, gPTP
(check-equal? (conf-get conf "logAnnounceInterval") "0")
(check-equal? (conf-get conf "transportSpecific") "0x1")
(check-equal? (conf-get conf "network_transport") "L2")
(check-equal? (conf-get conf "delay_mechanism") "P2P")
(check-equal? (conf-get conf "ptp_dst_mac") "01:80:c2:00:00:0e")
(check-equal? (conf-get conf "p2p_dst_mac") "01:80:c2:00:00:0e")
(check-equal? (conf-get conf "assume_two_step") "1")
(check-equal? (conf-get conf "follow_up_info") "1")
(check-equal? (conf-get conf "neighborPropDelayThresh") "800")

;; slave conf flips the role bits
(define slave-conf (params->conf slave #:role "slave"))
(check-equal? (conf-get slave-conf "slaveOnly") "1")
(check-equal? (conf-get slave-conf "priority1") "248")

;; validation catches out-of-range edits
(check = 0 (length (validate-params gm)))
(check = 1 (length (validate-params (struct-copy gptp-params gm [domain 200]))))
(check = 1 (length (validate-params (struct-copy gptp-params gm [priority1 300]))))
(check = 1 (length (validate-params (struct-copy gptp-params gm [log-sync-interval 99]))))
(check = 1 (length (validate-params (struct-copy gptp-params gm [ptp-dst-mac "not-a-mac"]))))

;; JSON roundtrip: partial merge keeps unspecified fields
(define merged (update-params-from-json gm (hasheq 'domain 5 'log_sync_interval -4)))
(check-equal? (gptp-params-domain merged) 5)
(check-equal? (gptp-params-log-sync-interval merged) -4)
(check-equal? (gptp-params-priority1 merged) 0)          ; untouched
(check-equal? (gptp-params-network-transport merged) 'L2) ; untouched

;; unknown keys ignored, bad values ignored
(define merged2 (update-params-from-json gm (hasheq 'domain 6 'evil "x" 'network_transport "Nonsense")))
(check-equal? (gptp-params-domain merged2) 6)
(check-equal? (gptp-params-network-transport merged2) 'L2)

;; UDPv4 + E2E variant emits the documented strings
(define udp (update-params-from-json gm (hasheq 'network_transport "UDPv4" 'delay_mechanism "E2E")))
(check-equal? (conf-get (params->conf udp #:role "grandmaster") "network_transport") "UDPv4")
(check-equal? (conf-get (params->conf udp #:role "grandmaster") "delay_mechanism") "E2E")

;; jsexpr view is JSON-safe
(check-equal? (hash-ref (params->jsexpr slave) 'slave_only) 1)
(check-equal? (hash-ref (params->jsexpr slave) 'network_transport) "L2")
