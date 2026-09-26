#lang racket/base

;; Exportable engineering report model.
;;
;; The report is deliberately evidence-oriented and privacy-conservative:
;; MAC/IP data is removed by default, timing capability is not presented as
;; calibrated accuracy, and BMCA sections describe captured observations rather
;; than re-running IEEE 802.1AS winner selection.

(require json
         racket/file
         racket/format
         racket/hash
         racket/list
         racket/string
         "diagnostics.rkt")

(provide summarize-series
         offset-jump-observations
         summarize-packets
         make-engineering-report
         engineering-report->markdown
         write-engineering-report-json!
         write-engineering-report-markdown!)

(define announce-dataset-fields
  '(grandmaster_priority1
    grandmaster_clock_class
    grandmaster_clock_accuracy
    grandmaster_offset_scaled_log_variance
    grandmaster_priority2
    grandmaster_identity
    steps_removed
    time_source
    time_source_name))

(define (point-time pt)
  (cond
    [(pair? pt) (car pt)]
    [(and (list? pt) (>= (length pt) 2)) (first pt)]
    [else #f]))

(define (point-value pt)
  (cond
    [(pair? pt) (cdr pt)]
    [(and (list? pt) (>= (length pt) 2)) (second pt)]
    [else #f]))

(define (valid-point? pt)
  (and (real? (point-time pt))
       (real? (point-value pt))))

(define (normalized-points points)
  (sort (filter valid-point? points) < #:key point-time))

(define (summarize-series points)
  (define ps (normalized-points points))
  (cond
    [(null? ps)
     (hasheq 'count 0
             'first_ts #f
             'last_ts #f
             'last #f
             'min #f
             'max #f
             'abs_max #f)]
    [else
     (define values (map point-value ps))
     (hasheq 'count (length ps)
             'first_ts (point-time (first ps))
             'last_ts (point-time (last ps))
             'last (point-value (last ps))
             'min (apply min values)
             'max (apply max values)
             'abs_max (apply max (map abs values)))]))

(define (offset-jump-observations points threshold-ns [limit 10])
  (define ps (normalized-points points))
  (define threshold (max 1 (abs threshold-ns)))
  (define jumps
    (for/list ([before (in-list ps)]
               [after (in-list (if (null? ps) '() (cdr ps)))]
               #:do [(define delta (- (point-value after) (point-value before)))]
               #:when (>= (abs delta) threshold))
      (hasheq 'ts (point-time after)
              'previous_ts (point-time before)
              'before_ns (point-value before)
              'after_ns (point-value after)
              'delta_ns delta)))
  (define largest
    (sort jumps > #:key (lambda (j) (abs (hash-ref j 'delta_ns 0)))))
  (hasheq 'threshold_ns threshold
          'count (length jumps)
          'largest (take largest (min limit (length largest)))
          'interpretation "observational"
          'note "A large adjacent-sample delta identifies an offset jump observation; it does not establish root cause."))

(define (packet-ref packet key [default #f])
  (if (hash? packet) (hash-ref packet key default) default))

(define (nested-ref h keys [default #f])
  (let loop ([value h] [rest keys])
    (cond
      [(null? rest) value]
      [(hash? value) (loop (hash-ref value (car rest) default) (cdr rest))]
      [else default])))

(define (increment-count h key)
  (hash-set h key (add1 (hash-ref h key 0))))

(define (announce-dataset packet)
  (define body (packet-ref packet 'body (hasheq)))
  (for/fold ([out (hasheq)]) ([field (in-list announce-dataset-fields)])
    (if (and (hash? body) (hash-has-key? body field))
        (hash-set out field (hash-ref body field))
        out)))

(define (announce-candidate-key packet)
  (define domain (nested-ref packet '(ptp domain_number) #f))
  (define source (nested-ref packet '(ptp source_port_identity) #f))
  (define gm (nested-ref packet '(body grandmaster_identity) #f))
  (format "~a|~a|~a" (or domain "?") (or gm "unknown-gm") (or source "unknown-source")))

(define (announce-packet? packet)
  (and (packet-ref packet 'is_ptp #f)
       (equal? (nested-ref packet '(ptp message_type_name) #f) "Announce")))

(define (candidate-update candidates packet)
  (define key (announce-candidate-key packet))
  (define ts (packet-ref packet 'ts #f))
  (define previous (hash-ref candidates key #f))
  (define latest-ts (and previous (hash-ref previous 'last_seen #f)))
  (define replace-latest?
    (or (not previous)
        (and (real? ts)
             (or (not (real? latest-ts)) (>= ts latest-ts)))))
  (define dataset (announce-dataset packet))
  (define value
    (if previous
        (hash-set*
         previous
         'count (add1 (hash-ref previous 'count 0))
         'first_seen
         (let ([old (hash-ref previous 'first_seen #f)])
           (cond
             [(and (real? old) (real? ts)) (min old ts)]
             [(real? old) old]
             [else ts]))
         'last_seen
         (let ([old (hash-ref previous 'last_seen #f)])
           (cond
             [(and (real? old) (real? ts)) (max old ts)]
             [(real? old) old]
             [else ts]))
         'latest_dataset (if replace-latest? dataset (hash-ref previous 'latest_dataset (hasheq))))
        (hasheq 'domain (nested-ref packet '(ptp domain_number) #f)
                'announcing_source (nested-ref packet '(ptp source_port_identity) #f)
                'grandmaster_identity (nested-ref packet '(body grandmaster_identity) #f)
                'count 1
                'first_seen ts
                'last_seen ts
                'latest_dataset dataset)))
  (hash-set candidates key value))

(define (summarize-packets packets)
  (define ptp-packets
    (filter (lambda (p) (and (hash? p) (packet-ref p 'is_ptp #f))) packets))
  (define message-counts
    (for/fold ([h (hasheq)]) ([packet (in-list ptp-packets)])
      (define name (nested-ref packet '(ptp message_type_name) "unknown"))
      (increment-count h (string->symbol (if (string? name) name (~a name))))))
  (define domains
    (sort
     (remove-duplicates
      (filter exact-integer?
              (for/list ([packet (in-list ptp-packets)])
                (nested-ref packet '(ptp domain_number) #f))))
     <))
  (define timestamp-sources
    (sort
     (remove-duplicates
      (filter string?
              (for/list ([packet (in-list ptp-packets)])
                (packet-ref packet 'timestamp_source #f))))
     string<?))
  (define candidates
    (for/fold ([h (hash)]) ([packet (in-list ptp-packets)] #:when (announce-packet? packet))
      (candidate-update h packet)))
  (hasheq 'ptp_packet_count (length ptp-packets)
          'message_counts message-counts
          'domains domains
          'timestamp_sources timestamp-sources
          'announce_count (count announce-packet? ptp-packets)
          'observed_bmca_candidates
          (sort (hash-values candidates)
                >
                #:key (lambda (c)
                        (define ts (hash-ref c 'last_seen #f))
                        (if (real? ts) ts -inf.0)))
          'bmca_interpretation "observational"
          'bmca_note "Observed Announce candidates are capture evidence only; this report does not independently re-run IEEE 802.1AS BMCA."))

(define (make-engineering-report #:version version
                                 #:platform platform
                                 #:nics nics
                                 #:qualification qualification
                                 #:engine engine
                                 #:capture capture
                                 #:params params
                                 #:conf conf
                                 #:offset-points offset-points
                                 #:delay-points delay-points
                                 #:packets packets
                                 #:logs logs
                                 #:offset-jump-threshold-ns [threshold-ns 100000])
  (hasheq
   'schema_version 1
   'generated_at_unix_ms (inexact->exact (floor (current-inexact-milliseconds)))
   'app (hasheq 'name "gPTP Studio" 'version version 'platform platform)
   'privacy (hasheq 'network_identifiers_redacted #t
                    'note "MAC addresses and IP addresses are omitted from this engineering report by default.")
   'accuracy_claim "not-calibrated"
   'accuracy_note "This report summarizes observed capabilities and measurements; it does not establish end-to-end calibrated timing accuracy."
   'nics (map redact-nic nics)
   'qualification qualification
   'engine engine
   'capture capture
   'params params
   'ptp4l_conf conf
   'synchronization
   (hasheq 'offset_ns (summarize-series offset-points)
           'mean_path_delay_ns (summarize-series delay-points))
   'timing_observations (offset-jump-observations offset-points threshold-ns)
   'packet_observations (summarize-packets packets)
   'recent_logs logs))

(define (md-escape value)
  (string-replace
   (string-replace (~a value) "|" "\\|")
   "\n" " "))

(define (display-or-dash value)
  (if (or (not value) (equal? value "")) "—" (~a value)))

(define (bool-label value)
  (if value "yes" "no"))

(define (markdown-series name summary unit)
  (format "| ~a | ~a | ~a | ~a | ~a | ~a ~a |\n"
          name
          (hash-ref summary 'count 0)
          (display-or-dash (hash-ref summary 'min #f))
          (display-or-dash (hash-ref summary 'max #f))
          (display-or-dash (hash-ref summary 'abs_max #f))
          (display-or-dash (hash-ref summary 'last #f))
          unit))

(define (message-count-lines counts)
  (define pairs
    (sort (hash->list counts) string<? #:key (lambda (p) (symbol->string (car p)))))
  (if (null? pairs)
      "- none observed\n"
      (apply string-append
             (for/list ([p (in-list pairs)])
               (format "- `~a`: ~a\n" (car p) (cdr p))))))

(define (candidate-lines candidates)
  (if (null? candidates)
      "- none observed in the retained packet window\n"
      (apply string-append
             (for/list ([c (in-list candidates)])
               (define d (hash-ref c 'latest_dataset (hasheq)))
               (format
                (string-append
                 "- GM `~a` via `~a`, domain ~a, ~a Announce(s)\n"
                 "  - priority1=~a, class=~a, accuracy=~a, variance=~a, priority2=~a, stepsRemoved=~a, timeSource=~a\n")
                (md-escape (display-or-dash (hash-ref c 'grandmaster_identity #f)))
                (md-escape (display-or-dash (hash-ref c 'announcing_source #f)))
                (md-escape (display-or-dash (hash-ref c 'domain #f)))
                (hash-ref c 'count 0)
                (display-or-dash (hash-ref d 'grandmaster_priority1 #f))
                (display-or-dash (hash-ref d 'grandmaster_clock_class #f))
                (display-or-dash (hash-ref d 'grandmaster_clock_accuracy #f))
                (display-or-dash (hash-ref d 'grandmaster_offset_scaled_log_variance #f))
                (display-or-dash (hash-ref d 'grandmaster_priority2 #f))
                (display-or-dash (hash-ref d 'steps_removed #f))
                (display-or-dash (or (hash-ref d 'time_source_name #f)
                                     (hash-ref d 'time_source #f))))))))

(define (jump-lines observation)
  (define jumps (hash-ref observation 'largest '()))
  (if (null? jumps)
      "- no adjacent-sample offset jump exceeded the configured threshold\n"
      (apply string-append
             (for/list ([j (in-list jumps)])
               (format "- t=~a: ~a ns → ~a ns (Δ ~a ns)\n"
                       (display-or-dash (hash-ref j 'ts #f))
                       (display-or-dash (hash-ref j 'before_ns #f))
                       (display-or-dash (hash-ref j 'after_ns #f))
                       (display-or-dash (hash-ref j 'delta_ns #f)))))))

(define (nic-lines nics)
  (if (null? nics)
      "| — | — | — | — | — |\n"
      (apply string-append
             (for/list ([nic (in-list nics)])
               (format "| ~a | ~a | ~a | ~a | ~a |\n"
                       (md-escape (display-or-dash (hash-ref nic 'name #f)))
                       (md-escape (display-or-dash (hash-ref nic 'driver #f)))
                       (bool-label (hash-ref nic 'hw_timestamping #f))
                       (md-escape (display-or-dash (hash-ref nic 'phc_device #f)))
                       (md-escape (display-or-dash (hash-ref nic 'privilege_mode #f))))))))

(define (log-lines logs [limit 80])
  (define rows (take logs (min limit (length logs))))
  (if (null? rows)
      "_No recent logs._\n"
      (string-join
       (for/list ([entry (in-list rows)])
         (cond
           [(and (list? entry) (>= (length entry) 4))
            (format "- `~a` **~a/~a** ~a"
                    (list-ref entry 0)
                    (md-escape (list-ref entry 1))
                    (string-upcase (md-escape (list-ref entry 2)))
                    (md-escape (list-ref entry 3)))]
           [else (format "- ~a" (md-escape entry))]))
       "\n" #:after-last "\n")))

(define (engineering-report->markdown report)
  (define app (hash-ref report 'app (hasheq)))
  (define engine (hash-ref report 'engine (hasheq)))
  (define capture (hash-ref report 'capture (hasheq)))
  (define sync (hash-ref report 'synchronization (hasheq)))
  (define offset-summary (hash-ref sync 'offset_ns (hasheq)))
  (define delay-summary (hash-ref sync 'mean_path_delay_ns (hasheq)))
  (define timing (hash-ref report 'timing_observations (hasheq)))
  (define packets (hash-ref report 'packet_observations (hasheq)))
  (define qualification (hash-ref report 'qualification (hasheq)))
  (string-append
   "# gPTP Studio Engineering Report\n\n"
   (format "- Generated (Unix ms): `~a`\n" (hash-ref report 'generated_at_unix_ms "—"))
   (format "- Studio: `v~a` on `~a`\n" (hash-ref app 'version "—") (hash-ref app 'platform "—"))
   (format "- Accuracy claim: **~a**\n" (hash-ref report 'accuracy_claim "not-calibrated"))
   (format "- Privacy: MAC/IP redacted = **~a**\n\n"
           (bool-label (nested-ref report '(privacy network_identifiers_redacted) #t)))
   "> This report is evidence-oriented. Capability, PHC presence, hardware timestamping and observed offsets are not a calibrated end-to-end accuracy certificate.\n\n"
   "## Session\n\n"
   (format "- Engine: `~a` / role `~a` / interface `~a`\n"
           (display-or-dash (hash-ref engine 'mode #f))
           (display-or-dash (hash-ref engine 'role #f))
           (display-or-dash (hash-ref engine 'iface #f)))
   (format "- Port state: `~a`\n" (display-or-dash (hash-ref engine 'port_state #f)))
   (format "- Current GM: `~a`\n" (display-or-dash (hash-ref engine 'gm_id #f)))
   (format "- Frequency: `~a ppb`\n" (display-or-dash (hash-ref engine 'freq_ppb #f)))
   (format "- Capture: running=`~a`, iface=`~a`, timestamp=`~a/~a`\n"
           (bool-label (hash-ref capture 'running #f))
           (display-or-dash (hash-ref capture 'iface #f))
           (display-or-dash (hash-ref capture 'timestamp_source #f))
           (display-or-dash (hash-ref capture 'timestamp_precision #f)))
   (format "- Qualification: `~a` — ~a\n\n"
           (display-or-dash (hash-ref qualification 'status #f))
           (md-escape (display-or-dash (hash-ref qualification 'summary #f))))
   "## NIC / PHC inventory\n\n"
   "| Interface | Driver | HW timestamp | PHC | Privilege |\n"
   "| --- | --- | --- | --- | --- |\n"
   (nic-lines (hash-ref report 'nics '()))
   "\n## Synchronization summary\n\n"
   "| Series | Samples | Min | Max | Abs max | Last |\n"
   "| --- | ---: | ---: | ---: | ---: | ---: |\n"
   (markdown-series "offsetFromMaster" offset-summary "ns")
   (markdown-series "meanPathDelay" delay-summary "ns")
   "\n## Offset jump observations\n\n"
   (format "Threshold: `~a ns`; observations: **~a**.\n\n"
           (hash-ref timing 'threshold_ns "—")
           (hash-ref timing 'count 0))
   (jump-lines timing)
   "\n## Packet observations\n\n"
   (format "- Retained PTP packets analyzed: **~a**\n" (hash-ref packets 'ptp_packet_count 0))
   (format "- Domains observed: `~a`\n" (md-escape (hash-ref packets 'domains '())))
   (format "- Timestamp sources observed: `~a`\n\n" (md-escape (hash-ref packets 'timestamp_sources '())))
   "### Message counts\n\n"
   (message-count-lines (hash-ref packets 'message_counts (hasheq)))
   "\n### Observed Announce / BMCA candidates\n\n"
   (candidate-lines (hash-ref packets 'observed_bmca_candidates '()))
   "\n> Candidate rows are captured Announce observations. This report does not independently re-run BMCA or declare which candidate should win.\n\n"
   "## ptp4l.conf\n\n```ini\n"
   (hash-ref report 'ptp4l_conf "")
   "\n```\n\n"
   "## Recent logs\n\n"
   (log-lines (hash-ref report 'recent_logs '()))))

(define (write-engineering-report-json! path report)
  (call-with-output-file path
    (lambda (out)
      (write-json report out)
      (newline out))
    #:exists 'replace
    #:mode 'text)
  path)

(define (write-engineering-report-markdown! path report)
  (call-with-output-file path
    (lambda (out) (display (engineering-report->markdown report) out))
    #:exists 'replace
    #:mode 'text)
  path)
