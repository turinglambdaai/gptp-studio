#lang racket/base

;; The gPTP simulator: a synthetic 802.1AS session that flows through the
;; exact same pipeline as a real engine (encode -> decode -> store -> SSE).
;; Purposes: demo/trial mode without hardware, CI verification, and ECU-less
;; UI development. Deterministic-ish waveforms so screenshots are stable.

(require racket/hash
         racket/list
         racket/math
         "../proto/constants.rkt"
         "../proto/encode.rkt"
         "../proto/decode.rkt")

(provide sim-frame-tick
         sim-offset-ns
         sim-path-delay-ns
         sim-state-at
         make-sim-frames)

(define sim-local-id "b6:2f:08:11:22:33:44:55")   ; the laptop (simulated)
(define sim-remote-id "a0:0b:1c:2d:3e:4f:50:61")  ; the "ECU"

;; offset waveform (ns) for the slave role: converges from -5 ms to ~0
;; with residual noise and a periodic jump (ECU-like behaviour).
(define (sim-offset-ns t)
  (define base (* -5000000.0 (exp (- (/ t 14.0)))))
  (define ripple (* 1200.0 (sin (* t 0.7))))
  (define noise (+ (- (random 1600) 800)))
  (define jump (if (and (> t 5) (< (remainder (inexact->exact (floor t)) 37) 1))
                   250000.0 0.0))
  (+ base ripple noise jump))

(define (sim-path-delay-ns t)
  (+ 800.0 (* 60.0 (sin (* t 1.3))) (- (random 80) 40)))

;; port state at time t (seconds since start), per role
(define (sim-state-at role t)
  (cond
    [(< t 0.5) "INITIALIZING"]
    [(< t 2.5) "LISTENING"]
    [(memq role '(grandmaster slave)) (if (eq? role 'grandmaster) "GRAND_MASTER" "SLAVE")]
    [else "LISTENING"]))

;; Build the frame set for one tick (returns a list of decoded frames).
;; role: 'grandmaster | 'slave | 'listener ; t: seconds; tick: integer
(define (make-sim-frames role t tick)
  (define base-header
    (hasheq 'domain 0 'transport-specific #x1 'port-number 1))
  (define (hdr seq control flags log-int)
    (hash-set* base-header
               'sequence-id seq 'control control 'flags flags 'log-interval log-int
               'clock-id (if (eq? role 'grandmaster) sim-local-id sim-remote-id)))
  (append
   ;; Sync + Follow_Up pair every tick (125 ms = 8 Hz)
   (let ([seq (remainder tick 65536)]
         [ts-sec (floor t)]
         [ts-ns (inexact->exact (floor (* 1000000000 (- t (floor t)))))])
     (define sync
       (build-ethernet-frame
        (build-ptp-message #x00 (hdr seq 0 #x0800 -3)
                           (timestamp->bytes 0 0))            ; two-step: zero origin
        #:src-mac "02:11:22:33:44:01"))
     (define fu
       (build-ethernet-frame
        (build-ptp-message #x08 (hdr seq 2 0 -3)
                           (timestamp->bytes (inexact->exact ts-sec) ts-ns)
                           (build-follow-up-info-tlv #:cumulative-rate-offset 0
                                                     #:gm-time-base 1))
        #:src-mac "02:11:22:33:44:01"))
     (list sync fu))
   ;; Announce once per second
   (if (zero? (remainder tick 8))
       (let ([announce-body
              (bytes-append (bytes 0 37)                       ; currentUtcOffset 37
                            (bytes 0)                          ; reserved
                            (bytes 248)                        ; gm priority1
                            (bytes 248 #x21 #xFE #xFE)         ; class/accuracy/variance
                            (bytes 248)                        ; gm priority2
                            (clock-id-string->bytes
                             (if (eq? role 'grandmaster) sim-local-id sim-remote-id))
                            (bytes 0 0)                        ; stepsRemoved
                            (bytes #xA0))])                    ; INTERNAL_OSCILLATOR
         (list (build-ethernet-frame
                (build-ptp-message #x0B (hdr (remainder (quotient tick 8) 65536) 5 0 0)
                                   announce-body)
                #:src-mac "02:11:22:33:44:01")))
       '())
   ;; Pdelay_Req / Pdelay_Resp pair once per second
   (if (zero? (remainder tick 8))
       (let ([req (build-ethernet-frame
                   (build-ptp-message #x02 (hdr (remainder (quotient tick 8) 65536) 1 0 0)
                                      (timestamp->bytes 0 0))
                   #:src-mac "02:11:22:33:44:02")]
             [resp (build-ethernet-frame
                    (build-ptp-message #x03 (hdr (remainder (quotient tick 8) 65536) 2 0 0)
                                       (bytes-append (timestamp->bytes (inexact->exact (floor t))
                                                                      500000)
                                                     (clock-id-string->bytes "02:11:22:33:44:02")
                                                     (bytes 0 2)))
                    #:src-mac "02:11:22:33:44:01")])
         (list req resp))
       '())))

(define (sim-frame-tick t) (inexact->exact (floor (/ t 0.125))))
