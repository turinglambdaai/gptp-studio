#lang racket/base

;; Engine supervisor: owns the gPTP engine lifecycle behind the six UI
;; pages. One supervisor instance per app; it mutates an internal state
;; box, streams observations into the shared series/log/packet stores and
;; pushes SSE events over the glaze bus.
;;
;;   mode:  #f (idle) | 'real (linuxptp subprocesses) | 'sim (simulator)
;;   role:  'grandmaster | 'slave | 'listener
;;
;; Real mode only starts on Linux (linuxptp needs SO_TIMESTAMPING + PHC;
;; see the PRD platform matrix). The simulator runs everywhere and flows
;; through the same decode pipeline as live captures.
;;
;; Privileges: ptp4l needs root or CAP_NET_ADMIN/CAP_NET_RAW. Strategy:
;;   - running as root  -> spawn ptp4l directly
;;   - otherwise        -> `sudo -n ptp4l` (works for root users-in-sudo
;;   and passwordless-sudo setups); if it dies within 2 s we surface an
;;   actionable message instead of pretending to run.

(require racket/format
         racket/file
         racket/list
         racket/match
         racket/port
         racket/string
         racket/system
         glaze/events
         "config.rkt"
         "ptp4l.rkt"
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
         linuxptp-available?)

(struct supervisor (sema
                    state            ; box of hasheq
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
                           'port-state #f
                           'gm-id #f
                           'offset-ns #f
                           'delay-ns #f
                           'freq-ppb #f
                           'started-at #f
                           'processes '()
                           'restarts 0
                           'offset-warn-ns 100000
                           'auto-restart #t))
              bus logs offset-series delay-series packets run-dir))

;; ---- helpers -------------------------------------------------------------------

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

(define (running-as-root?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define out (open-output-string))
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (and (zero? (system*/exit-code (find-executable-path "id") "-u"))
           (string=? (string-trim (get-output-string out)) "0")))))

(define (linuxptp-available?)
  (and (find-executable-path "ptp4l") #t))

(define worker-threads (box '()))

(define (register-worker! th)
  (set-box! worker-threads (cons th (unbox worker-threads))))

(define (kill-workers!)
  (for ([th (in-list (unbox worker-threads))])
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (kill-thread th)))
  (set-box! worker-threads '()))

;; ---- public API ----------------------------------------------------------------

;; Returns (values ok? error-string).
(define (sup-start sup role iface params mode)
  (sup-stop sup)
  (cond
    [(and (eq? mode 'real) (not (eq? (system-type 'os) 'unix)))
     (values #f "真实引擎需要 Linux（linuxptp 依赖内核 SO_TIMESTAMPING 与 PHC 子系统）。macOS 上请使用模拟器模式或被动监听。")]
    [(and (eq? mode 'real) (not (linuxptp-available?)))
     (values #f "未找到 ptp4l。请先安装 linuxptp：sudo apt install linuxptp")]
    [(and (eq? mode 'real) (not iface))
     (values #f "真实引擎需要选择物理网卡")]
    [else
     (mutate-state! sup 'role role)
     (mutate-state! sup 'iface iface)
     (mutate-state! sup 'params params)
     (mutate-state! sup 'mode mode)
     (mutate-state! sup 'started-at (now-ms))
     (mutate-state! sup 'restarts 0)
     (if (eq? mode 'sim)
         (begin (sim-start! sup role) (values #t #f))
         (real-start! sup role iface params))]))

(define (sup-stop sup)
  (kill-workers!)
  (define procs (state-ref sup 'processes))
  (for ([p (in-list procs)])
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (subprocess-kill p #t)))
  (mutate-state! sup 'processes '())
  (mutate-state! sup 'mode #f)
  (mutate-state! sup 'port-state #f)
  (mutate-state! sup 'gm-id #f)
  (mutate-state! sup 'offset-ns #f)
  (mutate-state! sup 'delay-ns #f)
  (when (and (pair? procs) (not (eq? (state-ref sup 'role) 'listener)))
    (log! sup 'app 'info "引擎已停止"))
  (emit! sup 'state-changed (sup-status sup)))

(define (sup-status sup)
  (define s (unbox (supervisor-state sup)))
  ;; all values must be JSON-safe: mode/role/reference are symbols in the
  ;; internal state, strings on the wire
  (hasheq 'mode (let ([m (hash-ref s 'mode)]) (and m (symbol->string m)))
          'role (symbol->string (hash-ref s 'role))
          'iface (hash-ref s 'iface)
          'reference (symbol->string (hash-ref s 'reference))
          'port_state (hash-ref s 'port-state)
          'gm_id (hash-ref s 'gm-id)
          'offset_ns (hash-ref s 'offset-ns)
          'delay_ns (hash-ref s 'delay-ns)
          'freq_ppb (hash-ref s 'freq-ppb)
          'uptime_ms (let ([t0 (hash-ref s 'started-at)])
                       (and t0 (inexact->exact (floor (- (now-ms) t0)))))
          'processes
          (for/list ([p (in-list (hash-ref s 'processes '()))])
            (hasheq 'name (car p)
                    'running (with-handlers ([exn:fail? (lambda (_) #f)])
                               (eq? (subprocess-status (cdr p)) 'running))))))

(define (sup-update-params sup params)
  (define mode (state-ref sup 'mode))
  (define role (state-ref sup 'role))
  (define iface (state-ref sup 'iface))
  (mutate-state! sup 'params params)
  (when mode
    (log! sup 'app 'info "参数变更，重启引擎以生效")
    (sup-start sup role iface params mode)))

(define (sup-set-reference sup ref)
  (mutate-state! sup 'reference ref)
  (log! sup 'app 'info (format "参考源切换为 ~a（引擎重启后生效）" ref)))

;; PRD parity check: one-shot pmc query, returns parsed blocks.
(define (sup-check-offsets sup)
  (unless (eq? (state-ref sup 'mode) 'real)
    (raise-user-error 'sup-check-offsets "仅真实引擎支持 pmc 对照查询"))
  (define out (run-out "pmc" "-u" "-s" "/var/run/ptp4l" "GET CURRENT_DATA_SET"))
  (define blocks (if out (parse-pmc-output out) '()))
  (log! sup 'pmc 'info (format "pmc 对照查询返回 ~a 块" (length blocks)))
  blocks)

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

;; ---- simulator -----------------------------------------------------------------

(define (sim-start! sup role)
  (log! sup 'sim 'info (format "模拟器启动：role=~a" role))
  (emit! sup 'state-changed (sup-status sup))
  (define th
    (thread
     (lambda ()
       (let loop ([tick 0])
         (define running (state-ref sup 'mode))
         (when (eq? running 'sim)
           (with-handlers ([exn:fail? (lambda (e) (log! sup 'sim 'error (exn-message e)))])
             (define t (* tick 0.125))
             (sim-tick! sup role t tick))
           (sleep 0.125)
           (loop (add1 tick)))))))
  (register-worker! th))

(define (sim-tick! sup role t tick)
  ;; series
  (case role
    [(slave)
     (define off (sim-offset-ns t))
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
  ;; port-state transitions (role dependent)
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
  ;; frames: real bytes through the real decoder
  (define frames (make-sim-frames role t tick))
  (define decoded
    (for/list ([raw (in-list frames)])
      (decode-frame raw #:ts (+ (current-seconds) (- t (floor t))) #:iface "sim" #:source "simulator")))
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
    (when (> (- (now-ms) last) 5000) ; rate-limit alarms to one per 5 s
      (mutate-state! sup 'last-alarm-at (now-ms))
      (log! sup 'app 'warn (format "offset 超阈值：~a ns（阈值 ±~a ns）"
                                   (~r offset-ns #:precision 0)
                                   (~r warn #:precision 0)))
      (emit! sup 'alarm (hasheq 'kind "offset"
                                'value offset-ns
                                'threshold warn
                                'message (format "offset 超阈值 ±~a µs" (/ warn 1000)))))))

;; ---- real engine ---------------------------------------------------------------

(define (real-start! sup role iface params)
  (define run-dir (supervisor-run-dir sup))
  (make-directory* run-dir)
  (define conf-path (build-path run-dir "ptp4l.conf"))
  (display-to-file (params->conf params #:role (role-name role) #:iface iface)
                   conf-path #:mode 'text #:exists 'replace)
  (log! sup 'app 'info (format "生成配置 ~a" (path->string conf-path)))
  (define ptp4l-exe (path->string (find-executable-path "ptp4l")))
  ;; spawn: root -> direct; otherwise passwordless sudo
  (define as-root (running-as-root?))
  (define spawn-args
    (if as-root
        (list ptp4l-exe "-f" (path->string conf-path) "-i" iface "-m")
        (list "sudo" "-n" ptp4l-exe "-f" (path->string conf-path) "-i" iface "-m")))
  (define sudo-exe (if as-root #t (find-executable-path "sudo")))
  (define-values (p out in err)
    (if sudo-exe
        (apply subprocess #f #f #f spawn-args)
        (begin (log! sup 'app 'error "未找到 sudo，无法提权运行 ptp4l")
               (subprocess #f #f #f ptp4l-exe "-f" (path->string conf-path) "-i" iface "-m"))))
  (close-output-port in)
  (mutate-state! sup 'processes (list (cons 'ptp4l p)))
  (log! sup 'ptp4l 'info (format "ptp4l 已启动（iface=~a role=~a pid=~a）" iface role (subprocess-pid p)))
  (emit! sup 'state-changed (sup-status sup))
  ;; stdout pump: parse -m events into series/state/logs
  (register-worker!
   (thread
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (for ([line (in-lines out)])
          (define ev (parse-ptp4l-line line))
          (when ev (handle-ptp4l-event! sup ev)))))))
  ;; stderr pump: straight to logs
  (register-worker!
   (thread
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (for ([line (in-lines err)])
          (log! sup 'ptp4l 'error line))))))
  ;; exit watcher with auto-restart
  (register-worker!
   (thread
    (lambda ()
      (define code (subprocess-wait p))
      (when (eq? (state-ref sup 'mode) 'real)
        (log! sup 'ptp4l 'error (format "ptp4l 异常退出（rc=~a）" code))
        (define tries (add1 (state-ref sup 'restarts 0)))
        (mutate-state! sup 'restarts tries)
        (if (and (state-ref sup 'auto-restart) (< tries 3))
            (begin
              (log! sup 'app 'warn (format "第 ~a 次自动重启 ptp4l" tries))
              (sleep 1)
              (when (eq? (state-ref sup 'mode) 'real)
                (real-start! sup (state-ref sup 'role) iface (state-ref sup 'params))))
            (begin
              (kill-workers!)
              (mutate-state! sup 'mode #f)
              (mutate-state! sup 'port-state #f)
              (emit! sup 'alarm (hasheq 'kind "engine-exit"
                                        'exit-code code
                                        'message "ptp4l 反复退出。常见原因：缺少权限（需要 root 或免密 sudo）、网卡不支持硬件时间戳、配置错误。查看日志页获取细节。"))
              (emit! sup 'state-changed (sup-status sup))))))))
  ;; quick-fail: if sudo is not passwordless, ptp4l dies immediately
  (sleep 0.8)
  (unless (eq? (subprocess-status p) 'running)
    (kill-workers!)
    (subprocess-kill p #t)
    (mutate-state! sup 'processes '())
    (mutate-state! sup 'mode #f)
    (define msg
      (if as-root
          "ptp4l 启动失败（详情见日志）"
          "ptp4l 启动失败：需要 root 权限。请用 sudo 运行 gPTP Studio，或为当前用户配置免密 sudo（sudo visudo 加一行：user ALL=(ALL) NOPASSWD: /usr/sbin/ptp4l）。"))
    (log! sup 'app 'error msg)
    (emit! sup 'state-changed (sup-status sup))
    (values #f msg)))

;; event -> state/series/logs/SSE
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
     (emit! sup 'series (hasheq 't (/ (now-ms) 1000.0) 'offset_ns (state-ref sup 'offset-ns) 'delay_ns delay))]
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
