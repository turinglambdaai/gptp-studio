#lang racket/base

;; Simulator fault injection: profile sanitization, frame-level effects and
;; offset spikes. Frame assertions decode through the real decode pipeline so
;; the injected frames stay valid gPTP by construction.

(require rackunit
         racket/list
         racket/string
         "../engine/simulator.rkt"
         "../proto/decode.rkt")

(define (decode-sim raw [t 0.0])
  (decode-frame raw #:ts t #:iface "sim" #:source "simulator"))

(define (types-of frames [t 0.0])
  (for/list ([raw (in-list frames)])
    (hash-ref (hash-ref (decode-sim raw t) 'ptp) 'message_type_name)))

(define (sync-seq frames)
  (for/list ([raw (in-list frames)]
             #:when (string=? (hash-ref (hash-ref (decode-sim raw) 'ptp) 'message_type_name) "Sync"))
    (hash-ref (hash-ref (decode-sim raw) 'ptp) 'sequence_id)))

;; ---- profile sanitization ------------------------------------------------------

(let-values ([(clean err) (sanitize-faults (hasheq 'sync_drop_pct 50 'unknown_field 9))])
  (check-false err)
  (check-equal? (hash-ref clean 'sync_drop_pct) 50)
  (check-false (hash-has-key? clean 'unknown_field)))

(let-values ([(clean err) (sanitize-faults (hasheq 'sync_drop_pct 101))])
  (check-true (and (string? err) (string-contains? err "sync_drop_pct")))
  (check-equal? (hash-ref clean 'sync_drop_pct) 0))

(let-values ([(clean err) (sanitize-faults (hasheq 'followup_delay_ms -5))])
  (check-true (string? err))
  (check-equal? (hash-ref clean 'followup_delay_ms) 0))

(test-equal?
 "merge overlays only provided fields"
 (hash-ref (merge-faults (hasheq 'sync_drop_pct 30 'announce_drop_pct 0)
                         (hasheq 'sync_drop_pct 0))
           'announce_drop_pct)
 0)

;; ---- Sync drops -----------------------------------------------------------------

(test-case "100% sync drop leaves orphaned Follow_Up, no Sync"
  (for ([tick (in-range 3)])
    (define types (types-of (make-sim-frames 'slave 1.0 tick
                                             #:faults (hasheq 'sync_drop_pct 100))))
    (check-false (member "Sync" types))
    (check-not-false (member "Follow_Up" types))))

(test-case "0% sync drop keeps the Sync/Follow_Up pair"
  (define types (types-of (make-sim-frames 'slave 1.0 0)))
  (check-not-false (member "Sync" types))
  (check-not-false (member "Follow_Up" types)))

;; ---- Announce drops (tick 8 = one per second) -----------------------------------

(test-case "100% announce drop removes Announce at the one-second tick"
  (define types (types-of (make-sim-frames 'slave 1.0 8
                                           #:faults (hasheq 'announce_drop_pct 100))))
  (check-false (member "Announce" types))
  (check-not-false (member "PDelay_Req" types)))

(test-case "no faults keeps Announce present"
  (define types (types-of (make-sim-frames 'slave 1.0 8)))
  (check-not-false (member "Announce" types)))

;; ---- sequence gaps ---------------------------------------------------------------

(test-case "sequence gap every 2 ticks skips one sequenceId at each period"
  (define seqs
    (for/list ([tick '(5 6 7 8)])
      (first (sync-seq (make-sim-frames 'slave 0.0 tick
                                        #:faults (hasheq 'sequence_gap_every 2))))))
  ;; tick5→7, tick6→9 (gap), tick7→10, tick8→12 (gap)
  (check-equal? seqs '(7 9 10 12)))

(test-case "no gap fault keeps sequence dense"
  (define seqs
    (for/list ([tick '(3 4 5)])
      (first (sync-seq (make-sim-frames 'slave 0.0 tick)))))
  (check-equal? seqs '(3 4 5)))

;; ---- Follow_Up delay --------------------------------------------------------------

(test-case "follow-up delay shifts preciseOriginTimestamp by the delay"
  (define frames (make-sim-frames 'slave 10.0 80 #:faults (hasheq 'followup_delay_ms 500)))
  (define fu
    (findf (lambda (raw)
             (string=? (hash-ref (hash-ref (decode-sim raw 10.0) 'ptp) 'message_type_name)
                       "Follow_Up"))
           frames))
  (check-true (and fu #t))
  (define ts
    (hash-ref (hash-ref (decode-sim fu 10.0) 'body) 'precise_origin_timestamp))
  (define total-ns
    (+ (* (hash-ref ts 'seconds 0) 1000000000) (hash-ref ts 'nanoseconds 0)))
  (check-true (< 10499000000 total-ns 10501000000))) ; 10 s + 0.5 s ± jitter

;; ---- offset spikes ----------------------------------------------------------------

(test-case "offset spike fires on the spike period and not elsewhere"
  (define faults (hasheq 'offset_spike_ns 5000000 'offset_spike_every_s 20))
  (define at-spike (sim-offset-ns 40.2 #:faults faults))   ; 40 % 20 == 0
  (define off-spike (sim-offset-ns 41.2 #:faults faults))
  (check-true (> at-spike 4000000) (format "at-spike=~a" at-spike))
  (check-true (< (abs off-spike) 300000) (format "off-spike=~a" off-spike)))

(test-case "no spike fault keeps the baseline waveform bounded"
  (define v (sim-offset-ns 41.2))
  (check-true (< (abs v) 300000) (format "v=~a" v)))
