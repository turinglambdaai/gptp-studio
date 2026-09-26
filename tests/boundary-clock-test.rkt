#lang racket/base

;; Boundary clock: configuration generation, process arguments, per-port
;; qualification and supervisor session validation. ptp4l BC facts verified
;; against linuxptp sources: since 3.0 multiple -i ports imply a boundary
;; clock (boundary_clock_enabled was removed); phc2sys -a -r is the documented
;; companion; slaveOnly is the only client-only key valid on both 3.1.1
;; (Ubuntu 22.04) and 4.x.

(require rackunit
         racket/file
         racket/list
         racket/string
         glaze/events
         "../engine/config.rkt"
         "../engine/qualification.rkt"
         "../engine/runtime-config.rkt"
         "../engine/supervisor.rkt"
         "../data/logstore.rkt"
         "../data/series.rkt"
         "../capture/store.rkt")

;; ---- configuration --------------------------------------------------------------

(define bc-conf
  (params->conf (default-params-for-role 'boundary)
                #:role "boundary"
                #:ifaces '("enp3s0" "enp4s0")))

(check-true (regexp-match? #px"boundary_clock_jbod\\s+0" bc-conf))
(check-true (regexp-match? #px"slaveOnly\\s+0" bc-conf))
(check-false (string-contains? bc-conf "clientOnly"))
(check-true (string-contains? bc-conf "enp3s0,enp4s0"))
(check-true (string-contains? bc-conf "# boundary clock: 2 ports"))

;; Single-port roles keep the plain profile: no jbod line, no BC header.
(define oc-conf (params->conf (default-params-for-role 'grandmaster) #:role "grandmaster"))
(check-false (string-contains? oc-conf "boundary_clock_jbod"))
(check-false (string-contains? oc-conf "# boundary clock"))

;; Role constraints: a BC can never be client-only, whatever stale form state.
(define forced (apply-role-constraints (default-params-for-role 'slave) 'boundary))
(check-equal? (gptp-params-slave-only forced) 0)
(check-equal? (gptp-params-gm-capable forced) 1)

;; ---- process arguments -----------------------------------------------------------

(define run-dir (find-system-path 'temp-dir))

(test-case "phc2sys boundary companion follows ptp4l via the shared UDS"
  (check-equal?
   (phc2sys-boundary-args run-dir)
   (list "-a" "-r" "-w"
         "-z" (path->string (build-path run-dir "ptp4l.sock"))
         "-m")))

(test-case "ptp4l takes one -i per port, in order, after the config"
  (check-equal?
   (ptp4l-iface-args (build-path run-dir "ptp4l.conf") '("enp3s0" "enp4s0"))
   (list "-f" (path->string (build-path run-dir "ptp4l.conf"))
         "-i" "enp3s0" "-i" "enp4s0" "-m")))

;; ---- qualification ----------------------------------------------------------------

(define (make-nic name hw phc)
  (hasheq 'name name
          'up #t 'operstate "up"
          'driver "igb" 'hw_timestamping hw 'phc_device phc
          'privilege_mode "root"
          'ethtool_available #t 'ptp4l_available #t 'phc2sys_available #t
          'pmc_available #t 'ip_available #t))

(define nics
  (list (make-nic "enp3s0" #t "/dev/ptp0")
        (make-nic "enp4s0" #t "/dev/ptp1")
        (make-nic "enp5s0" #f #f)))

(test-case "two hardware-qualified ports are ready"
  (define q (qualify-ports #:platform "linux" #:nics nics
                           #:ifaces '("enp3s0" "enp4s0")))
  (check-equal? (hash-ref q 'status) "ready")
  (check-false (hash-ref q 'blocking))
  (check-equal? (hash-ref q 'iface) "enp3s0")
  (check-equal? (length (hash-ref q 'ports)) 2))

(test-case "a software-timestamp port blocks the whole set"
  (define q (qualify-ports #:platform "linux" #:nics nics
                           #:ifaces '("enp3s0" "enp5s0")))
  (check-equal? (hash-ref q 'status) "blocked")
  (check-true (hash-ref q 'blocking))
  (check-not-false (member "hw-timestamp" (hash-ref q 'blocking_check_ids))))

(test-case "a duplicated port selection is a structural failure"
  (define q (qualify-ports #:platform "linux" #:nics nics
                           #:ifaces '("enp3s0" "enp3s0")))
  (check-equal? (hash-ref q 'status) "blocked")
  (check-not-false (member "bc-ports" (hash-ref q 'blocking_check_ids))))

(test-case "an empty port set never reaches per-port qualification"
  (define q (qualify-ports #:platform "linux" #:nics nics #:ifaces '()))
  (check-equal? (hash-ref q 'status) "blocked")
  (check-not-false (member "bc-ports" (hash-ref q 'blocking_check_ids))))

(test-case "per-port checks carry the port number for the UI"
  (define q (qualify-ports #:platform "linux" #:nics nics
                           #:ifaces '("enp3s0" "enp4s0")))
  (define port-ids
    (for/list ([c (in-list (hash-ref q 'checks))]
               #:when (hash-has-key? c 'port))
      (hash-ref c 'port)))
  (check-not-false (member 1 port-ids))
  (check-not-false (member 2 port-ids)))

;; ---- supervisor session validation -------------------------------------------------

(define tmp (make-temporary-file "gptp-studio-bc~a" 'directory))
(define sup
  (make-supervisor #:bus (make-event-bus)
                   #:logs (make-logstore 200)
                   #:offset-series (make-series 200)
                   #:delay-series (make-series 200)
                   #:packets (make-packet-store 200)
                   #:run-dir tmp))

(dynamic-wind
  void
  (lambda ()
    ;; Sim-mode boundary session: port states per port, both sides simulated.
    (define-values (sim-ok? sim-err)
      (sup-start sup 'boundary "enp3s0"
                 (default-params-for-role 'boundary) 'sim
                 #:ifaces '("enp3s0" "enp4s0")))
    (check-true sim-ok? sim-err)
    (sleep 2.8)
    (define st (sup-status sup))
    (check-equal? (hash-ref st 'role) "boundary")
    (check-equal? (hash-ref st 'ifaces) '("enp3s0" "enp4s0"))
    (define port-states (hash-ref st 'port_states))
    (check-true (hash? port-states))
    (check-equal? (hash-ref port-states 1 #f) "SLAVE")
    (check-equal? (hash-ref port-states 2 #f) "GRAND_MASTER")

    ;; Rejected BC session (one port only) must not tear down the running one.
    (define-values (bad-ok? bad-err)
      (sup-start sup 'boundary "enp3s0"
                 (default-params-for-role 'boundary) 'sim
                 #:ifaces '("enp3s0")))
    (check-false bad-ok?)
    (check-true (string-contains? (or bad-err "") "至少两个"))
    (check-equal? (hash-ref (sup-status sup) 'role) "boundary")
    (check-equal? (hash-ref (sup-status sup) 'mode) "sim"))
  (lambda ()
    (sup-stop sup)
    (delete-directory/files tmp)))
