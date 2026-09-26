#lang racket/base

;; The gPTP simulator: a synthetic 802.1AS session that flows through the
;; exact same pipeline as a real engine (encode -> decode -> store -> SSE).
;; Purposes: demo/trial mode without hardware, CI verification, and ECU-less
;; UI development. Deterministic-ish waveforms so screenshots are stable.
;;
;; Fault injection (#:faults) is part of the product: negative testing of the
;; analyst's own tooling — alarms, BMCA timeline, timing-evidence correlation
;; and engineering reports — without touching real hardware. Injected frames
;; stay syntactically valid gPTP and flow through the same decode pipeline;
;; faults model what a misbehaving ECU would put on the wire, never a
;; Studio-side measurement error.

(require racket/hash
         racket/list
         racket/match
         racket/math
         racket/string
         "../proto/constants.rkt"
         "../proto/encode.rkt"
         "../proto/decode.rkt")

(provide sim-frame-tick
         sim-offset-ns
         sim-path-delay-ns
         sim-state-at
         sim-bc-port-states
         empty-faults
         sanitize-faults
         merge-faults
         make-sim-frames)

;; Session fault profile. All keys optional; absent/zero means "no fault".
;;   sync_drop_pct         — drop probability (%) for each Sync (Follow_Up stays)
;;   announce_drop_pct     — drop probability (%) for each Announce
;;   followup_delay_ms     — shift Follow_Up preciseOriginTimestamp by this much
;;   sequence_gap_every    — inject a sequenceId gap every N Sync pairs (0=off)
;;   offset_spike_ns       — periodic slave offset spike amplitude (0=off)
;;   offset_spike_every_s  — spike period in seconds (default 37)
(define empty-faults (hasheq))

(define fault-fields
  '((sync_drop_pct 0 100)
    (announce_drop_pct 0 100)
    (followup_delay_ms 0 10000)
    (sequence_gap_every 0 10000)
    (offset_spike_ns 0 1000000000)
    (offset_spike_every_s 1 3600)))

;; Returns (values clean error-string). Unknown keys are dropped so a stale
;; UI can never poison a session.
(define (sanitize-faults faults)
  (cond
    [(not (hash? faults)) (values empty-faults "faults 必须是对象")]
    [else
     (define errs '())
     (define clean
       (for/hasheq ([entry (in-list fault-fields)])
         (match-define (list k lo hi) entry)
         (define v (hash-ref faults k lo))
         (cond
           [(not (real? v)) (set! errs (cons (format "~a 必须是数字" k) errs)) (values k lo)]
           [(or (< v lo) (> v hi))
            (set! errs (cons (format "~a 超出范围 ~a–~a" k lo hi) errs))
            (values k lo)]
           [else (values k (inexact->exact (floor v)))])))
     (values clean (and (pair? errs) (string-join (reverse errs) "；")))]))

;; Overlay provided fields onto current faults (for partial updates).
(define (merge-faults current provided)
  (define-values (clean _) (sanitize-faults provided))
  (for/hasheq ([entry (in-list fault-fields)])
    (match-define (list k _lo _hi) entry)
    (values k (hash-ref clean k (hash-ref current k 0)))))

(define (fault-ref faults k [default 0])
  (if (hash? faults) (hash-ref faults k default) default))

(define (percent-hit? pct)
  (and (>= pct 1) (< (random 100) pct)))

(define sim-local-id "b6:2f:08:11:22:33:44:55")   ; the laptop (simulated)
(define sim-remote-id "a0:0b:1c:2d:3e:4f:50:61")  ; the "ECU"

;; offset waveform (ns) for the slave role: converges from -5 ms to ~0
;; with residual noise and a periodic jump (ECU-like behaviour).
;; The optional spike fault adds a deterministic periodic excursion.
(define (sim-offset-ns t #:faults [faults empty-faults])
  (define base (* -5000000.0 (exp (- (/ t 14.0)))))
  (define ripple (* 1200.0 (sin (* t 0.7))))
  (define noise (+ (- (random 1600) 800)))
  (define jump (if (and (> t 5) (< (remainder (inexact->exact (floor t)) 37) 1))
                   250000.0 0.0))
  (define spike-ns (fault-ref faults 'offset_spike_ns))
  (define spike-every (max 1 (fault-ref faults 'offset_spike_every_s 37)))
  (define spike
    (if (and (> spike-ns 0) (> t 5)
             (< (remainder (inexact->exact (floor t)) (inexact->exact spike-every)) 1))
        (exact->inexact spike-ns) 0.0))
  (+ base ripple noise jump spike))

(define (sim-path-delay-ns t)
  (+ 800.0 (* 60.0 (sin (* t 1.3))) (- (random 80) 40)))

;; port state at time t (seconds since start), per role
;; For a boundary clock both ports are reported: port 1 follows the remote
;; GM (upstream/slave side), port 2 holds GM downstream.
(define (sim-state-at role t)
  (cond
    [(< t 0.5) "INITIALIZING"]
    [(< t 2.5) "LISTENING"]
    [(memq role '(grandmaster slave boundary))
     (if (memq role '(grandmaster boundary)) "GRAND_MASTER" "SLAVE")]
    [else "LISTENING"]))

(define (sim-bc-port-states t)
  (cond
    [(< t 0.5) (hasheq 1 "INITIALIZING" 2 "INITIALIZING")]
    [(< t 2.5) (hasheq 1 "LISTENING" 2 "LISTENING")]
    [else (hasheq 1 "SLAVE" 2 "GRAND_MASTER")]))

;; Build the frame set for one tick (returns a list of ethernet frames).
;; role: 'grandmaster | 'slave | 'listener ; t: seconds; tick: integer
(define (make-sim-frames role t tick #:faults [faults empty-faults])
  (define base-header
    (hasheq 'domain 0 'transport-specific #x1 'port-number 1))
  (define (hdr seq control flags log-int)
    (hash-set* base-header
               'sequence-id seq 'control control 'flags flags 'log-interval log-int
               'clock-id (if (eq? role 'grandmaster) sim-local-id sim-remote-id)))

  ;; sequenceId with an injected gap: every `every` ticks one id is skipped,
  ;; so a decoder sees a +2 step in the Sync sequence. Stateless: the skipped
  ;; count is just the number of multiples of `every` up to this tick.
  (define gap-every (fault-ref faults 'sequence_gap_every))
  (define seq
    (remainder (if (> gap-every 0)
                   (+ tick (quotient tick gap-every))
                   tick)
               65536))

  ;; Follow_Up preciseOriginTimestamp shifted by the configured delay,
  ;; modelling a master that publishes its follow-up late.
  (define fu-delay-ms (fault-ref faults 'followup_delay_ms))
  (define-values (ts-sec ts-ns)
    (let* ([delayed (+ t (/ fu-delay-ms 1000.0))]
           [sec (floor delayed)]
           [ns (inexact->exact (floor (* 1000000000 (- delayed sec))))])
      (values (inexact->exact sec) ns)))

  (append
   ;; Sync + Follow_Up pair every tick (125 ms = 8 Hz); Sync may be dropped.
   (let ()
     (define sync
       (build-ethernet-frame
        (build-ptp-message #x00 (hdr seq 0 #x0800 -3)
                           (timestamp->bytes 0 0))            ; two-step: zero origin
        #:src-mac "02:11:22:33:44:01"))
     (define fu
       (build-ethernet-frame
        (build-ptp-message #x08 (hdr seq 2 0 -3)
                           (timestamp->bytes ts-sec ts-ns)
                           (build-follow-up-info-tlv #:cumulative-rate-offset 0
                                                     #:gm-time-base 1))
        #:src-mac "02:11:22:33:44:01"))
     (if (percent-hit? (fault-ref faults 'sync_drop_pct))
         (list fu)                                            ; orphaned Follow_Up
         (list sync fu)))
   ;; Announce once per second; may be dropped (BMCA candidate gaps).
   (if (and (zero? (remainder tick 8))
            (not (percent-hit? (fault-ref faults 'announce_drop_pct))))
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
