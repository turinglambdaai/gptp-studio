#lang racket/base

;; Engine supervisor: owns the gPTP engine lifecycle behind the UI.
;;
;;   mode:  #f (idle) | 'real (linuxptp subprocesses) | 'sim (simulator)
;;   role:  'grandmaster | 'slave | 'listener
;;
;; The timing-critical work stays in linuxptp/kernel/PHC. This module owns
;; lifecycle, state, logs and SSE only. Real-engine startup is intentionally
;; hardware-timestamp-first; passive Listener capture is the software-timestamp
;; fallback path.

(require racket/format
         racket/file
         racket/list
         racket/match
         racket/port
         racket/string
         racket/system
         glaze/events
         "config.rkt"
         "detect.rkt"
         "failure-diagnosis.rkt"
         "ptp4l.rkt"
         "pmc-tuning.rkt"
         "process-runtime.rkt"
         "qualification.rkt"
         "runtime-config.rkt"
         "simulator.rkt"
         "../data/series.rkt"
         "../data/logstore.rkt"
         "../capture/store.rkt"
         "../proto/decode.rkt")

(provide (struct-out supervisor)
         make-supervisor
         sup-start
         sup-stop
         sup-status
         sup-update-params
         sup-set-reference
         sup-check-offsets
         sup-gm-settings
         sup-gm-settings-set!
         sup-set-faults!
         linuxptp-available?)

(struct supervisor (sema
                    state
                    bus
                    logs
                    offset-series
                    delay-series
                    packets
                    run-dir))

(define (make-supervisor #:bus bus
                         #:logs logs
                         #:offset-series offset-series
                         #:delay-series delay-series
                         #:packets packets
                         #:run-dir run-dir)
  (supervisor (make-semaphore 1)
              (box (hasheq 'mode #f
                           'role 'listener
                           'iface #f
                           'params (default-params-for-role 'listener)
                           'reference 'system
                           'reference-status "idle"
                           'port-state #f
                           'gm-id #f
                           'offset-ns #f
                           'delay-ns #f
                           'freq-ppb #f
                           'started-at #f
                           'processes '()
                           'launch-mode #f
                           'last-failure #f
                           'restarts 0
                           'offset-warn-ns 100000
                           'auto-restart #t
                           'faults empty-faults))
              bus logs offset-series delay-series packets run-dir))

;; ---- state / logging helpers -------------------------------------------------

(define (mutate-state! sup k v)
  (define b (supervisor-state sup))
  (set-box! b (hash-set (unbox b) k v)))

(define (state-ref sup k [default #f])
  (hash-ref (unbox (supervisor-state sup)) k default))

(define (now-ms) (current-inexact-milliseconds))

(define (log! sup source level message)
  (log-add! (supervisor-logs sup) source level message))

(define (emit! sup name payload)
  (bus-broadcast! (supervisor-bus sup) name payload))

(define (linuxptp-available?)
  (and (find-executable-path "ptp4l") #t))

(define (real-start-preflight sup role iface)
  (qualify-interface #:platform (platform-name)
                     #:nics (detect-interfaces)
                     #:iface iface
                     #:role (symbol->string role)
                     #:reference (symbol->string (state-ref sup 'reference 'system))))

(define (preflight-block-message qualification)
  (define fail-actions
    (for/list ([c (in-list (hash-ref qualification 'checks '()))]
               #:when (and (string=? (hash-ref c 'state "") "fail")
                           (not (string=? (hash-ref c 'action "") ""))))
      (hash-ref c 'action)))
  (string-append
   "Preflight 阻止真实引擎启动："
   (hash-ref qualification 'summary "存在未满足的真实引擎前置条件。")
   (if (null? fail-actions)
       ""
       (format " 建议：~a" (string-join fail-actions "；")))))

;; One application owns one supervisor, so one worker registry is sufficient.
(define worker-threads (box '()))

(define (register-worker! th)
  (set-box! worker-threads (cons th (unbox worker-threads)))
  th)

(define (kill-workers! [except #f])
  (define survivors '())
  (for ([th (in-list (unbox worker-threads))])
    (cond
      [(and except (eq? th except))
       (set! survivors (cons th survivors))]
      [else
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (kill-thread th))]))
  (set-box! worker-threads (reverse survivors)))

(define (process-entry-name entry) (car entry))
(define (process-entry-proc entry) (cdr entry))

(define (process-by-name sup name)
  (assoc name (state-ref sup 'processes '())))

(define (add-process! sup name p)
  (define rest
    (filter (lambda (entry) (not (eq? (process-entry-name entry) name)))
            (state-ref sup 'processes '())))
  (mutate-state! sup 'processes (cons (cons name p) rest)))

(define (stop-processes! sup)
  (define procs (state-ref sup 'processes '()))
  (for ([entry (in-list procs)])
    (unless (stop-process-entry! entry)
      (log! sup 'app 'warn
            (format "无法确认进程 ~a 已停止" (process-entry-name entry)))))
  (mutate-state! sup 'processes '())
  procs)

(define (start-pump! sup source port level-or-parser)
  (register-worker!
   (thread
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (for ([line (in-lines port)])
          (cond
            [(procedure? level-or-parser)
             (define ev (level-or-parser line))
             (when ev (handle-ptp4l-event! sup ev))]
            [else (log! sup source level-or-parser line)])))))))

;; Capture a short startup stderr tail while still logging every line normally.
;; The tail is intentionally local to one process start so stale errors from a
;; previous session can never contaminate a diagnosis.
(define (start-error-pump! sup source port [limit 20])
  (define tail (box '()))
  (register-worker!
   (thread
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (for ([line (in-lines port)])
          (define current (append (unbox tail) (list line)))
          (set-box! tail
                    (if (> (length current) limit)
                        (drop current (- (length current) limit))
                        current))
          (log! sup source 'error line))))))
  tail)

(define (error-tail->string tail)
  (string-join (unbox tail) "\n"))

(define (spawn-managed! sup name executable args required-caps)
  (define-values (argv launch-mode)
    (launch-plan executable args #:required-capabilities required-caps))
  (define-values (p out in err)
    (apply subprocess #f #f #f argv))
  (close-output-port in)
  (add-process! sup name p)
  (log! sup name 'info
        (format "~a 已启动（pid=~a，方式=~a）" name (subprocess-pid p) launch-mode))
  (values p out err launch-mode))

(define (record-start-failure! sup process stderr-text exit-code launch-mode)
  (define d
    (diagnose-linuxptp-failure
     (if (symbol? process) (symbol->string process) (format "~a" process))
     stderr-text
     exit-code
     launch-mode))
  (mutate-state! sup 'last-failure d)
  d)

(define (abort-real-start! sup message)
  ;; If called from an auto-restart watcher, do not kill that watcher before it
  ;; can finish the failure transition.
  (kill-workers! (current-thread))
  (stop-processes! sup)
  (cleanup-runtime-sockets! (supervisor-run-dir sup))
  (mutate-state! sup 'mode #f)
  (mutate-state! sup 'reference-status "error")
  (log! sup 'app 'error message)
  (emit! sup 'state-changed (sup-status sup))
  (values #f message))

;; ---- public API --------------------------------------------------------------

;; Returns (values ok? error-string).
(define (sup-start sup role iface params mode)
  ;; Validate the requested session before stopping an already-running one.
  ;; A rejected switch must never destroy a healthy existing session.
  (define (launch!)
    (sup-stop sup)
    (mutate-state! sup 'role role)
    (mutate-state! sup 'iface iface)
    (mutate-state! sup 'params params)
    (mutate-state! sup 'mode mode)
    (mutate-state! sup 'started-at (now-ms))
    (mutate-state! sup 'restarts 0)
    (mutate-state! sup 'last-failure #f)
    (mutate-state! sup 'reference-status (if (eq? mode 'sim) "simulated" "starting"))
    (if (eq? mode 'sim)
        (begin (sim-start! sup role) (values #t #f))
        (real-start! sup role iface params)))
  (cond
    [(and (eq? mode 'real) (not (supported-platform?)))
     (values #f "真实引擎仅支持 Linux timing host（需要 sysfs、SO_TIMESTAMPING、PHC 与 linuxptp）。")]
    [(and (eq? mode 'real) (eq? role 'listener))
     (values #f "真实 Listener 是被动抓包角色，不启动 ptp4l。请使用“开始会话”或报文分析页开始抓包。")]
    [(and (eq? mode 'real) (not (linuxptp-available?)))
     (values #f "未找到 ptp4l。请先安装 linuxptp：sudo apt install linuxptp")]
    [(and (eq? mode 'real) (not iface))
     (values #f "真实引擎需要选择物理网卡")]
    [(eq? mode 'real)
     (define qualification (real-start-preflight sup role iface))
     (cond
       [(qualification-blocking? qualification)
        (define msg (preflight-block-message qualification))
        (log! sup 'app 'error msg)
        (values #f msg)]
       [else
        (when (positive? (hash-ref qualification 'warn_count 0))
          (log! sup 'app 'warn
                (format "Preflight=VERIFY：~a" (hash-ref qualification 'summary "存在待确认项"))))
        (launch!)])]
    [else (launch!)]))

(define (sup-stop sup)
  ;; Mark idle before terminating subprocesses so exit watchers can distinguish
  ;; an intentional stop from an unexpected crash and never restart on Stop.
  (define was-mode (state-ref sup 'mode))
  (mutate-state! sup 'mode #f)
  (kill-workers!)
  (define procs (stop-processes! sup))
  (cleanup-runtime-sockets! (supervisor-run-dir sup))
  (mutate-state! sup 'reference-status "idle")
  (mutate-state! sup 'port-state #f)
  (mutate-state! sup 'gm-id #f)
  (mutate-state! sup 'offset-ns #f)
  (mutate-state! sup 'delay-ns #f)
  (mutate-state! sup 'freq-ppb #f)
  (when (and was-mode (pair? procs))
    (log! sup 'app 'info "引擎已停止"))
  (emit! sup 'state-changed (sup-status sup)))

(define (sup-status sup)
  (define s (unbox (supervisor-state sup)))
  (hasheq 'mode (let ([m (hash-ref s 'mode)]) (and m (symbol->string m)))
          'role (symbol->string (hash-ref s 'role))
          'iface (hash-ref s 'iface)
          'reference (symbol->string (hash-ref s 'reference))
          'reference_status (hash-ref s 'reference-status "idle")
          'launch_mode (let ([m (hash-ref s 'launch-mode #f)])
                         (and m (symbol->string m)))
          'last_failure (hash-ref s 'last-failure #f)
          'port_state (hash-ref s 'port-state)
          'gm_id (hash-ref s 'gm-id)
          'offset_ns (hash-ref s 'offset-ns)
          'delay_ns (hash-ref s 'delay-ns)
          'freq_ppb (hash-ref s 'freq-ppb)
          'uptime_ms (let ([t0 (hash-ref s 'started-at)])
                       (and t0 (inexact->exact (floor (- (now-ms) t0)))))
          'faults (hash-ref s 'faults empty-faults)
          'processes
          (for/list ([entry (in-list (hash-ref s 'processes '()))])
            (hasheq 'name (symbol->string (process-entry-name entry))
                    'running (process-entry-running? entry)))))

(define (sup-update-params sup params)
  (define mode (state-ref sup 'mode))
  (define role (state-ref sup 'role))
  (define iface (state-ref sup 'iface))
  (mutate-state! sup 'params params)
  (when mode
    (log! sup 'app 'info "参数变更，重启引擎以生效")
    (sup-start sup role iface params mode)))

(define (sup-set-reference sup ref)
  (unless (memq ref '(system none))
    (raise-argument-error 'sup-set-reference "(or/c 'system 'none)" ref))
  (mutate-state! sup 'reference ref)
  (mutate-state! sup 'reference-status
                 (if (eq? ref 'system) "pending-restart" "disabled"))
  (log! sup 'app 'info (format "参考源切换为 ~a（下次启动真实 GM 引擎时生效）" ref))
  (emit! sup 'state-changed (sup-status sup)))

;; One-shot pmc cross-check using the same per-user management socket as ptp4l.
(define (sup-check-offsets sup)
  (unless (eq? (state-ref sup 'mode) 'real)
    (raise-user-error 'sup-check-offsets "仅真实引擎支持 pmc 对照查询"))
  (define args
    (pmc-current-data-set-args (supervisor-run-dir sup)
                               (state-ref sup 'params)))
  (define out (apply run-out (cons "pmc" args)))
  (define blocks (if out (parse-pmc-output out) '()))
  (log! sup 'pmc 'info (format "pmc 对照查询返回 ~a 块" (length blocks)))
  blocks)

;; ---- GM runtime tuning --------------------------------------------------------

;; Raises unless a real linuxptp session owns the management socket.
(define (require-real-engine! sup who)
  (unless (eq? (state-ref sup 'mode) 'real)
    (raise-user-error who "仅真实引擎支持 GM 运行时调优（模拟器与空闲状态不可用）")))

(define (pmc-block sup who args #:want want-key #:what what)
  (define out (apply run-out (cons "pmc" args)))
  (cond
    [(not out)
     (raise-user-error who (format "pmc 查询 ~a 失败：引擎可能未就绪、socket 不可用或权限不足" what))])
  (define block
    (findf (lambda (b) (hash-has-key? b want-key)) (parse-pmc-output out)))
  (unless block
    (raise-user-error who (format "pmc 未返回 ~a 数据" what)))
  block)

;; Current GM settings plus BMCA priorities, normalized from pmc output.
;; Both linuxptp 3.1.x (gm-prefixed fields + gmFlags) and newer formats parse.
(define (sup-gm-settings sup)
  (require-real-engine! sup 'sup-gm-settings)
  (define params (state-ref sup 'params))
  (define run-dir (supervisor-run-dir sup))
  (define gm-block
    (pmc-block sup 'sup-gm-settings (gm-settings-get-args run-dir params)
               #:want 'clockClass #:what "GRANDMASTER_SETTINGS_NP"))
  (define settings (parse-gm-settings-block gm-block))
  (define (priority which)
    (define b (pmc-block sup 'sup-gm-settings (priority-get-args run-dir params which)
                         #:want which #:what (format "~a" which)))
    (hash-ref b which 128))
  (hash-set* settings
             'priority1 (priority 'priority1)
             'priority2 (priority 'priority2)))

;; Apply a partial settings overlay: current values are read first so pmc's
;; positional 11-value SET always receives a complete field set. Returns
;; (values ok? result-or-error).
(define (sup-gm-settings-set! sup provided)
  (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
    (require-real-engine! sup 'sup-gm-settings-set!)
    (define-values (checked check-err) (validate-gm-settings provided))
    (cond
      [check-err (values #f check-err)]
      [else
       (define params (state-ref sup 'params))
       (define run-dir (supervisor-run-dir sup))
       (define current (sup-gm-settings sup))
       (define merged (merge-gm-settings current checked))
       ;; GRANDMASTER_SETTINGS_NP
       (define out (apply run-out
                          (cons "pmc" (gm-settings-set-args run-dir params merged))))
       (unless (and out
                    (findf (lambda (b) (hash-has-key? b 'clockClass))
                           (parse-pmc-output out)))
         (raise-user-error 'sup-gm-settings-set!
                           "pmc SET GRANDMASTER_SETTINGS_NP 未被确认：引擎可能未进入可调状态"))
       ;; Priorities only when the operator asked to change them.
       (for ([which '(priority1 priority2)]
             #:when (hash-has-key? checked which))
         (define p-out
           (apply run-out
                  (cons "pmc" (priority-set-args run-dir params which
                                                 (hash-ref merged which)))))
         (unless (and p-out
                      (findf (lambda (b) (hash-has-key? b which))
                             (parse-pmc-output p-out)))
           (raise-user-error 'sup-gm-settings-set!
                             (format "pmc SET ~a 未被确认" which))))
       (define changed
         (for/list ([k (in-list (hash-keys checked))])
           (format "~a: ~a → ~a"
                   k (hash-ref current k '—) (hash-ref merged k '—))))
       (log! sup 'pmc 'info
             (string-append "GM 运行时调优已应用（"
                            (string-join changed "，")
                            "）；调试用途，非校准声明"))
       (values #t merged)])))


;; Session-level simulator fault profile (negative testing). Applies only to
;; the simulated pipeline; never to a real linuxptp session.
(define (sup-set-faults! sup provided)
  (define merged (merge-faults (state-ref sup 'faults empty-faults) provided))
  (define-values (clean err) (sanitize-faults merged))
  (cond
    [err (values #f err)]
    [else
     (mutate-state! sup 'faults clean)
     (define active
       (for/list ([(k v) (in-hash clean)] #:when (> v 0)) (format "~a=~a" k v)))
     (log! sup 'sim 'info
           (if (null? active)
               "Fault injection 已清除（模拟器恢复正常波形）"
               (format "Fault injection 生效：~a" (string-join active "，"))))
     (emit! sup 'state-changed (sup-status sup))
     (values #t clean)]))

(define (run-out . args)
  (define exe (find-executable-path (car args)))
  (and exe
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define out (open-output-string))
         (parameterize ([current-output-port out]
                        [current-error-port (open-output-nowhere)]
                        [current-input-port (open-input-string "")])
           (define rc (apply system*/exit-code exe (cdr args)))
           (and (zero? rc) (get-output-string out))))))

;; ---- simulator ---------------------------------------------------------------

(define (sim-start! sup role)
  (log! sup 'sim 'info (format "模拟器启动：role=~a" role))
  (emit! sup 'state-changed (sup-status sup))
  (register-worker!
   (thread
    (lambda ()
      (let loop ([tick 0])
        (define running (state-ref sup 'mode))
        (when (eq? running 'sim)
          (with-handlers ([exn:fail? (lambda (e) (log! sup 'sim 'error (exn-message e)))])
            (define t (* tick 0.125))
            (sim-tick! sup role t tick))
          (sleep 0.125)
          (loop (add1 tick))))))))

(define (sim-tick! sup role t tick)
  (case role
    [(slave)
     (define off (sim-offset-ns t #:faults (state-ref sup 'faults empty-faults)))
     (series-push! (supervisor-offset-series sup) t off)
     (mutate-state! sup 'offset-ns off)
     (define dl (sim-path-delay-ns t))
     (series-push! (supervisor-delay-series sup) t dl)
     (mutate-state! sup 'delay-ns dl)
     (maybe-alarm! sup off)]
    [(grandmaster)
     (define dl (sim-path-delay-ns t))
     (series-push! (supervisor-delay-series sup) t dl)
     (mutate-state! sup 'delay-ns dl)
     (mutate-state! sup 'offset-ns 0)]
    [else (void)])
  (define new-state (sim-state-at role t))
  (unless (equal? new-state (state-ref sup 'port-state))
    (mutate-state! sup 'port-state new-state)
    (log! sup 'ptp4l 'info (format "port 1: 状态 → ~a（模拟）" new-state))
    (when (or (string=? new-state "SLAVE") (string=? new-state "GRAND_MASTER"))
      (mutate-state! sup 'gm-id
                     (if (eq? role 'grandmaster)
                         "b6:2f:08:11:22:33:44:55"
                         "a0:0b:1c:2d:3e:4f:50:61")))
    (emit! sup 'state-changed (sup-status sup)))
  (define frames (make-sim-frames role t tick #:faults (state-ref sup 'faults empty-faults)))
  (define decoded
    (for/list ([raw (in-list frames)])
      (decode-frame raw #:ts (+ (current-seconds) (- t (floor t)))
                    #:iface "sim" #:source "simulator")))
  (for ([d (in-list decoded)])
    (packet-store-push! (supervisor-packets sup) d))
  (emit! sup 'packets decoded)
  (emit! sup 'series (hasheq 't t
                             'offset_ns (state-ref sup 'offset-ns)
                             'delay_ns (state-ref sup 'delay-ns))))

(define (maybe-alarm! sup offset-ns)
  (define warn (state-ref sup 'offset-warn-ns))
  (when (and warn (> (abs offset-ns) warn))
    (define last (state-ref sup 'last-alarm-at 0))
    (when (> (- (now-ms) last) 5000)
      (mutate-state! sup 'last-alarm-at (now-ms))
      (log! sup 'app 'warn (format "offset 超阈值：~a ns（阈值 ±~a ns）"
                                   (~r offset-ns #:precision 0)
                                   (~r warn #:precision 0)))
      (emit! sup 'alarm (hasheq 'kind "offset"
                                'value offset-ns
                                'threshold warn
                                'message (format "offset 超阈值 ±~a µs" (/ warn 1000)))))))

;; ---- real engine -------------------------------------------------------------

(define (real-start! sup role iface params)
  (define run-dir (supervisor-run-dir sup))
  (make-directory* run-dir)
  (cleanup-runtime-sockets! run-dir)
  (define conf-path (build-path run-dir "ptp4l.conf"))
  (define base-conf (params->conf params #:role (role-name role) #:iface iface))
  (display-to-file (runtime-conf base-conf run-dir)
                   conf-path #:mode 'text #:exists 'replace)
  (log! sup 'app
        'info
        (format "生成配置 ~a；management socket=~a"
                (path->string conf-path)
                (path->string (runtime-uds-path run-dir))))

  (define ptp4l-path (find-executable-path "ptp4l"))
  (cond
    [(not ptp4l-path)
     (abort-real-start! sup "未找到 ptp4l。请先安装 linuxptp。")] 
    [else
     (define ptp4l-exe (path->string ptp4l-path))
     (define-values (p out err launch-mode)
       (spawn-managed! sup 'ptp4l ptp4l-exe
                       (list "-f" (path->string conf-path) "-i" iface "-m")
                       '("cap_net_raw" "cap_net_admin")))
     (mutate-state! sup 'launch-mode launch-mode)
     (start-pump! sup 'ptp4l out parse-ptp4l-line)
     (define error-tail (start-error-pump! sup 'ptp4l err))

     ;; Catch permissions/config/NIC failures before registering restart watchers.
     (sleep 0.65)
     (cond
       [(not (process-entry-running? (cons 'ptp4l p)))
        (define code (subprocess-status p))
        (define d
          (record-start-failure!
           sup 'ptp4l (error-tail->string error-tail) code launch-mode))
        (abort-real-start! sup (failure-diagnosis->message d))]
       [else
        (define-values (ref-ok? ref-err phc-process)
          (start-reference-clock! sup role iface params))
        (cond
          [(not ref-ok?) (abort-real-start! sup ref-err)]
          [else
           (register-exit-watcher! sup 'ptp4l p)
           (when phc-process (register-exit-watcher! sup 'phc2sys phc-process))
           (emit! sup 'state-changed (sup-status sup))
           (values #t #f)])])]))

(define (start-reference-clock! sup role iface params)
  (cond
    [(not (eq? role 'grandmaster))
     (mutate-state! sup 'reference-status "not-applicable")
     (values #t #f #f)]
    [(eq? (state-ref sup 'reference) 'none)
     (mutate-state! sup 'reference-status "disabled")
     (values #t #f #f)]
    [else
     (define phc-path (find-executable-path "phc2sys"))
     (cond
       [(not phc-path)
        (values #f "参考源选择了系统时钟，但未找到 phc2sys。请安装 linuxptp 或选择“不使用外部参考”。" #f)]
       [else
        (define phc-exe (path->string phc-path))
        ;; Domain-server direction: CLOCK_REALTIME (UTC) -> PHC (PTP timescale).
        ;; -w waits for ptp4l and obtains currentUtcOffset from the same UDS.
        (define args
          (phc2sys-reference-args (supervisor-run-dir sup) iface params))
        (define-values (p out err launch-mode)
          (spawn-managed! sup 'phc2sys phc-exe args '("cap_sys_time")))
        (start-pump! sup 'phc2sys out 'info)
        (define error-tail (start-error-pump! sup 'phc2sys err))
        (sleep 0.20)
        (if (process-entry-running? (cons 'phc2sys p))
            (begin
              (mutate-state! sup 'reference-status "running")
              (log! sup 'phc2sys 'info
                    (format "参考源生效：CLOCK_REALTIME → ~a（UDS=~a，等待 ptp4l 提供 UTC/PTP offset，方式=~a）"
                            iface
                            (path->string (runtime-uds-path (supervisor-run-dir sup)))
                            launch-mode))
              (values #t #f p))
            (let* ([code (subprocess-status p)]
                   [d (record-start-failure!
                       sup 'phc2sys (error-tail->string error-tail) code launch-mode)])
              (values #f (failure-diagnosis->message d) p)))])]))

(define (register-exit-watcher! sup name p)
  (register-worker!
   (thread
    (lambda ()
      (define code (wait-process-exit-code p))
      (when (and (eq? (state-ref sup 'mode) 'real)
                 (let ([entry (process-by-name sup name)])
                   (and entry (eq? (process-entry-proc entry) p))))
        (handle-unexpected-exit! sup name code))))))

(define (handle-unexpected-exit! sup name code)
  (log! sup name 'error (format "~a 异常退出（rc=~a）" name code))
  (define tries (add1 (state-ref sup 'restarts 0)))
  (mutate-state! sup 'restarts tries)
  (cond
    [(and (state-ref sup 'auto-restart #t) (< tries 3))
     (define role (state-ref sup 'role))
     (define iface (state-ref sup 'iface))
     (define params (state-ref sup 'params))
     (log! sup 'app 'warn (format "运行时进程异常，第 ~a 次重启完整 linuxptp 会话" tries))
     ;; Kill sibling pumps/watchers but never the watcher currently executing.
     (kill-workers! (current-thread))
     (stop-processes! sup)
     (cleanup-runtime-sockets! (supervisor-run-dir sup))
     (mutate-state! sup 'reference-status "restarting")
     (sleep 1)
     (when (eq? (state-ref sup 'mode) 'real)
       (define-values (ok? err) (real-start! sup role iface params))
       (unless ok?
         (finalize-runtime-failure! sup name code (or err "自动重启失败"))))]
    [else
     (finalize-runtime-failure!
      sup name code
      (format "~a 反复退出。请检查权限、网卡硬件时间戳、PHC 与 linuxptp 配置。" name))]))

(define (finalize-runtime-failure! sup name code message)
  (kill-workers! (current-thread))
  (stop-processes! sup)
  (cleanup-runtime-sockets! (supervisor-run-dir sup))
  (mutate-state! sup 'mode #f)
  (mutate-state! sup 'port-state #f)
  (mutate-state! sup 'reference-status "error")
  (emit! sup 'alarm (hasheq 'kind "engine-exit"
                            'process (symbol->string name)
                            'exit-code code
                            'message message))
  (emit! sup 'state-changed (sup-status sup)))

;; ---- ptp4l event -> state/series/logs ---------------------------------------

(define (handle-ptp4l-event! sup ev)
  (match ev
    [(list 'offset ns freq delay)
     (series-push! (supervisor-offset-series sup) (/ (now-ms) 1000.0) ns)
     (series-push! (supervisor-delay-series sup) (/ (now-ms) 1000.0) delay)
     (mutate-state! sup 'offset-ns ns)
     (mutate-state! sup 'delay-ns delay)
     (mutate-state! sup 'freq-ppb freq)
     (maybe-alarm! sup ns)
     (emit! sup 'series (hasheq 't (/ (now-ms) 1000.0) 'offset_ns ns 'delay_ns delay))]
    [(list 'path-delay delay ratio)
     (series-push! (supervisor-delay-series sup) (/ (now-ms) 1000.0) delay)
     (mutate-state! sup 'delay-ns delay)
     (emit! sup 'series (hasheq 't (/ (now-ms) 1000.0)
                                   'offset_ns (state-ref sup 'offset-ns)
                                   'delay_ns delay))]
    [(list 'state port from to reason)
     (mutate-state! sup 'port-state to)
     (log! sup 'ptp4l 'info (format "port ~a: ~a → ~a（~a）" port from to reason))
     (emit! sup 'state-changed (sup-status sup))]
    [(list 'best-master id)
     (mutate-state! sup 'gm-id id)
     (log! sup 'ptp4l 'info (format "选择最优主时钟：~a" id))
     (emit! sup 'state-changed (sup-status sup))]
    [(list 'gm-role)
     (log! sup 'ptp4l 'info "本机接管 GrandMaster 角色")
     (emit! sup 'state-changed (sup-status sup))]
    [(list 'foreign-master id)
     (log! sup 'ptp4l 'info (format "发现外部主时钟 ~a" id))]
    [(list 'note level msg)
     (log! sup 'ptp4l (case level [(error) 'error] [(warn) 'warn] [else 'info]) msg)]
    [_ (void)]))
