#lang racket/base

;; Golden tests for linuxptp output parsers (formats match linuxptp 3.1 as
;; shipped by Ubuntu 22.04 / Debian 12).

(require rackunit
         racket/list
         "../engine/ptp4l.rkt")

;; ---- ptp4l lines ---------------------------------------------------------------

(check-equal?
 (parse-ptp4l-line "ptp4l[131.668]: master offset      -1234 s2 freq    -5679 path delay      8912")
 (list 'offset -1234 -5679 8912))

(check-equal?
 (parse-ptp4l-line "ptp4l[131.668]: master offset         12 s0 freq      100 path delay       500.0")
 (list 'offset 12 100 500.0))

(check-equal?
 (parse-ptp4l-line "ptp4l[133.700]: path delay      8812 neighbor rate ratio  -0.000000012")
 (list 'path-delay 8812 -0.000000012))

(check-equal?
 (parse-ptp4l-line "ptp4l[128.929]: port 1: INITIALIZING to LISTENING on INIT_COMPLETE")
 (list 'state 1 "INITIALIZING" "LISTENING" "INIT_COMPLETE"))

(check-equal?
 (parse-ptp4l-line "ptp4l[130.001]: port 1: LISTENING to SLAVE on MASTER_SELECTED")
 (list 'state 1 "LISTENING" "SLAVE" "MASTER_SELECTED"))

(check-equal?
 (parse-ptp4l-line "ptp4l[128.926]: selected local clock b62f08.fffe.1a2b3c as best master")
 (list 'best-master "b62f08.fffe.1a2b3c"))

(check-equal?
 (parse-ptp4l-line "ptp4l[129.000]: assuming the grand master role")
 (list 'gm-role))

(check-equal?
 (parse-ptp4l-line "ptp4l[130.500]: port 1: new foreign master a0b1c2.fffe.d3e4f5-1")
 (list 'foreign-master "a0b1c2.fffe.d3e4f5-1"))

(check-equal?
 (parse-ptp4l-line "ptp4l[140.000]: naughty: something failed badly")
 (list 'note 'error "naughty: something failed badly"))

;; non-ptp4l noise is dropped
(check-false (parse-ptp4l-line "random text from somewhere else"))
(check-false (parse-ptp4l-line ""))

;; full log
(define events
  (parse-ptp4l-log (string-append
                    "ptp4l[1.000]: port 1: INITIALIZING to LISTENING on INIT_COMPLETE\n"
                    "ptp4l[2.000]: selected local clock b62f08.fffe.1a2b3c as best master\n"
                    "ptp4l[3.000]: assuming the grand master role\n"
                    "ptp4l[4.000]: master offset        -100 s2 freq      -200 path delay      900\n"
                    "noise\n")))
(check-equal? (length events) 4)
(check-equal? (first events) (list 'state 1 "INITIALIZING" "LISTENING" "INIT_COMPLETE"))
(check-equal? (fourth events) (list 'offset -100 -200 900))

;; ---- pmc -----------------------------------------------------------------------

(define pmc-sample
  (string-append
   "\tsending: GET CURRENT_DATA_SET b62f08.fffe.1a2b3c-1\n"
   "\t993af6.fffe.0e11c2-1\t-1\t0\n"
   "\tresponses: 1\n"
   "\tportState                    SLAVE\n"
   "\toffsetFromMaster             -42.000000\n"
   "\tmeanPathDelay                512.000000\n"
   "\tstepsRemoved                 1\n"
   "\n"
   "\tsending: GET PARENT_DATA_SET b62f08.fffe.1a2b3c-1\n"
   "\tparentPortIdentity           a0b1c2.fffe.d3e4f5-1\n"
   "\tgrandmasterIdentity          a0b1c2ffd3e4f5\n"
   "\tgrandmasterClockClass        248\n"
   "\tparentStats                  0\n"))

(define blocks (parse-pmc-output pmc-sample))
(check-equal? (length blocks) 2)
(define cds (first blocks))
(check-equal? (hash-ref cds 'command) "CURRENT_DATA_SET")
(check-equal? (hash-ref cds 'portState) "SLAVE")
(check-equal? (hash-ref cds 'offsetFromMaster) -42.0)
(check-equal? (hash-ref cds 'meanPathDelay) 512.0)
(check-equal? (hash-ref cds 'stepsRemoved) 1)
(define pds (second blocks))
(check-equal? (hash-ref pds 'command) "PARENT_DATA_SET")
(check-equal? (hash-ref pds 'parentPortIdentity) "a0b1c2.fffe.d3e4f5-1")
(check-equal? (hash-ref pds 'grandmasterClockClass) 248)

;; garbage does not crash, returns empty
(check-equal? (parse-pmc-output "") '())
(check-equal? (parse-pmc-output "total garbage\nmore garbage") '())
