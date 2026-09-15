#lang racket/base

;; gPTP Studio entry point.
;;
;;   racket main.rkt               GUI (native webview window)
;;   racket main.rkt --simulator   GUI with the simulator running (GM role)
;;   racket main.rkt --port N      fixed server port (default: free port)
;;   racket main.rkt --selfcheck   headless check: server + API, exit code
;;   racket main.rkt --version     print version

(require racket/cmdline
         racket/format
         racket/list
         racket/runtime-path
         racket/string
         glaze
         "app/api.rkt"
         "app/state.rkt"
         "app/gate.rkt"
         "app/i18n.rkt"
         "data/logstore.rkt"
         "engine/supervisor.rkt"
         "engine/detect.rkt"
         "capture/manager.rkt")

(define-runtime-path public-dir "public")

(define version app-version)

(define (debug-log! msg)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (call-with-output-file "/tmp/gptp-bundle-debug.log"
      (lambda (out) (fprintf out "~a ~a\n" (current-seconds) msg))
      #:exists 'append)))

(module+ main
  (define sim? #f)
  (define port-arg #f)
  (define selfcheck? #f)
  (define token-arg #t)

  (command-line
   #:program "gptp-studio"
   #:once-each
   [("--simulator") "start with the built-in gPTP simulator (grandmaster)"
    (set! sim? #t)]
   [("--port") p "server port (default: auto)"
    (set! port-arg (string->number p))]
   [("--token") t "fixed API token (for headless verification)"
    (set! token-arg t)]
   [("--selfcheck") "headless smoke test; prints JSON and exits"
    (set! selfcheck? #t)]
   [("--version") "print version"
    (displayln version)
    (exit 0)])

  (debug-log! (format "launch: sim=~a port=~a selfcheck=~a" sim? port-arg selfcheck?))
  (cond
    [selfcheck?
     (selfcheck (or port-arg 18701))]
    [else
     (unless (single-instance? "gptp-studio")
       (displayln "[gptp-studio] 另一个实例已在运行")
       (exit 1))
     (gate-init!)
     (when sim?
       ;; seed the simulator through the same API path the UI uses
       (thread (lambda ()
                 (sleep 0.5)
                 (with-handlers ([exn:fail? (lambda (e)
                                              (log-add! app-logs 'app 'error
                                                        (exn-message e)))])
                   (engine-start "grandmaster" "sim" "")))))
     (log-add! app-logs 'app 'info
               (format "gPTP Studio ~a 启动（~a / ~a 许可）"
                       version (platform-name) (gate-tier)))
     (define-values (kind shutdown)
       (with-handlers ([exn:fail? (lambda (e)
                                    (debug-log! (format "FATAL: ~a" (exn-message e)))
                                    (raise e))])
         (run-app #:public-dir public-dir
                #:api api-routes
                #:events app-bus
                #:api-token token-arg
                #:title "gPTP Studio"
                #:width 1280
                #:height 820
                #:port port-arg
                #:on-error
                (lambda (exn uri)
                  (log-add! app-logs 'app 'error
                            (format "~a (~a)" (exn-message exn) uri))
                  (bus-broadcast! app-bus 'backend-error
                                  (hasheq 'uri uri 'message (exn-message exn))))
                #:on-close
                (lambda ()
                  (sup-stop app-supervisor)
                  (cm-stop app-capture))
                  #:on-ready
                  (lambda (wv url)
                    (set-box! app-wv-box wv)
                    (debug-log! "window ready")
                    (log-add! app-logs 'app 'info (format "窗口就绪 ~a" url))
                    ;; WKWebView in a bare process occasionally stalls before
                    ;; first paint (same quirk glaze's showcase works around):
                    ;; detect via title and reload once.
                    (thread
                     (lambda ()
                       (sleep 4)
                       (define t1 (and wv (webview-title wv)))
                       (when (or (not t1) (string=? t1 ""))
                         (log-add! app-logs 'app 'warn "页面首帧卡住，重载一次")
                         (webview-navigate wv url))))))))
     (when (eq? kind 'browser)
       ;; browser fallback keeps the server alive; wait for Ctrl-C
       (sync never-evt))]))

;; ---- selfcheck -----------------------------------------------------------------

;; Headless smoke check used by CI: start the HTTP server, verify the static
;; page and the bootstrap API respond, then exit 0/1. No window required.
(define (selfcheck port)
  (define-values (actual-port shutdown)
    (start-server #:port port
                  #:public-dir public-dir
                  #:api api-routes
                  #:events app-bus))
  (define ok #t)
  (define (check name url expect-substring)
    (define body
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (http-get-as-string (format "http://127.0.0.1:~a~a" actual-port url))))
    (cond
      [(and body (string-contains? body expect-substring))
       (printf "[ok] ~a\n" name)]
      [else
       (set! ok #f)
       (printf "[FAIL] ~a (~a)\n" name (and body (substring body 0 (min 120 (string-length body)))))]))
  (check "static page" "/" "gPTP Studio")
  (check "bootstrap api" "/api/bootstrap" "\"version\"")
  (check "conf api" "/api/conf" "ptp4l.conf")
  (shutdown)
  (exit (if ok 0 1)))

(define (http-get-as-string url)
  (define-values (in _out) (tcp-connect* "127.0.0.1" url))
  (port->string in))

;; minimal HTTP/1.0 GET over raw TCP (no net-lib dependency)
(require racket/port
         racket/tcp)
(define (tcp-connect* host url)
  (define m (regexp-match #px"^http://[^:]+:([0-9]+)(.*)$" url))
  (define port (string->number (second m)))
  (define path (if (string=? (third m) "") "/" (third m)))
  (define-values (in out) (tcp-connect host port))
  (fprintf out "GET ~a HTTP/1.0\r\nHost: ~a:~a\r\n\r\n" path host port)
  (flush-output out)
  (values in out))
