#lang racket/base

;; gPTP Studio entry point (Linux product platform only).
;;
;;   racket main.rkt               GUI (native WebKitGTK window)
;;   racket main.rkt --simulator   GUI with the simulator running (GM role)
;;   racket main.rkt --port N      fixed server port (default: free port)
;;   racket main.rkt --selfcheck   headless check: server + API, exit code
;;   racket main.rkt --doctor      headless human-readable support report
;;   racket main.rkt --doctor-json headless machine-readable support report
;;   racket main.rkt --version     print version

(require json
         racket/cmdline
         racket/format
         racket/list
         racket/runtime-path
         racket/string
         glaze
         glaze/update
         "app/api.rkt"
         "app/state.rkt"
         "app/gate.rkt"
         "app/i18n.rkt"
         "data/logstore.rkt"
         "engine/supervisor.rkt"
         "engine/detect.rkt"
         "capture/manager.rkt"
         "support/doctor.rkt"
         "support/updates.rkt")

(define-runtime-path public-dir "public")

(define version app-version)

(define (debug-log! msg)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (call-with-output-file "/tmp/gptp-bundle-debug.log"
      (lambda (out) (fprintf out "~a ~a\n" (current-seconds) msg))
      #:exists 'append)))

(define (require-linux!)
  (unless (supported-platform?)
    (fprintf (current-error-port)
             (string-append
              "gPTP Studio supports Linux only.\n"
              "The professional timing path requires Linux sysfs, PHC/SO_TIMESTAMPING, "
              "linuxptp, libpcap and Linux privilege controls.\n"))
    (exit 3)))

(define (run-doctor mode)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (fprintf (current-error-port)
                              "gPTP Studio doctor failed: ~a\n"
                              (exn-message e))
                     (exit 2))])
    (define report (collect-doctor-report version))
    (case mode
      [(json)
       (write-json report)
       (newline)]
      [else
       (displayln (doctor->text report))])
    (exit 0)))

(module+ main
  (define sim? #f)
  (define port-arg #f)
  (define selfcheck? #f)
  (define doctor-mode #f)
  (define token-arg #t)
  (define update-check? #t)

  (command-line
   #:program "gptp-studio"
   #:once-each
   [("--simulator") "start with the built-in gPTP simulator (grandmaster)"
    (set! sim? #t)]
   [("--port") p "server port (default: auto)"
    (set! port-arg (string->number p))]
   [("--token") t "fixed API token (for headless verification)"
    (set! token-arg t)]
   [("--selfcheck") "headless smoke test; prints status and exits"
    (set! selfcheck? #t)]
   [("--doctor") "headless support report (MAC/IP redacted)"
    (set! doctor-mode 'text)]
   [("--doctor-json") "headless JSON support report (MAC/IP redacted)"
    (set! doctor-mode 'json)]
   [("--no-update-check") "disable the startup update check (no network contact)"
    (set! update-check? #f)]
   [("--version") "print version"
    (displayln version)
    (exit 0)])

  ;; The application is deliberately Linux-only. Keep --version/--help usable
  ;; everywhere, but never present a partial-analysis mode as product support.
  (require-linux!)

  (debug-log! (format "launch: sim=~a port=~a selfcheck=~a doctor=~a"
                      sim? port-arg selfcheck? doctor-mode))
  (cond
    [doctor-mode
     (run-doctor doctor-mode)]
    [selfcheck?
     (selfcheck (or port-arg 18701))]
    [else
     (unless (single-instance? "gptp-studio")
       (displayln "[gptp-studio] 另一个实例已在运行")
       (exit 1))
     (gate-init!)
     (when update-check?
       ;; Background, fire-and-forget: a slow/blocked network must never
       ;; delay startup. On a newer release this broadcasts
       ;; 'update-available on the app bus (the UI shows a header pill +
       ;; toast) and logs one line. GPTP_UPDATE_MANIFEST_URL overrides the
       ;; manifest location (air-gapped hosts point it at a file server or
       ;; disable the check entirely with --no-update-check).
       (thread
        (lambda ()
          (sleep 2.5)
          (with-handlers ([exn:fail? (lambda (_) (void))])
            (define info (check-update
                          (or (getenv "GPTP_UPDATE_MANIFEST_URL")
                              update-manifest-url)
                          #:current-version version))
            (when info
              (define v (hash-ref info 'version))
              (set-box! update-info-box info)
              (log-add! app-logs 'app 'info
                        (format "新版本可用：~a（当前 ~a）" v version))
              (bus-broadcast! app-bus 'update-available info))))))
     (when sim?
       ;; seed the simulator through the same API path the UI uses
       (thread (lambda ()
                 (sleep 0.5)
                 (with-handlers ([exn:fail? (lambda (e)
                                              (log-add! app-logs 'app 'error
                                                        (exn-message e)))])
                   ;; engine-start gained the boundary-clock ifaces argument
                   ;; (4 arity); the seed still called the 3-arity shape and
                   ;; --simulator silently failed.
                   (engine-start "grandmaster" "sim" "" '())))))
     (log-add! app-logs 'app 'info
               (format "gPTP Studio ~a 启动（Linux / ~a 许可）"
                       version (gate-tier)))
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
                    (log-add! app-logs 'app 'info (format "窗口就绪 ~a" url))))))
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
       (printf "[FAIL] ~a (~a)\n"
               name
               (and body (substring body 0 (min 120 (string-length body)))))]))
  (check "static page" "/" "gPTP Studio")
  (check "bootstrap api" "/api/bootstrap" "\"version\"")
  (check "conf api" "/api/conf" "ptp4l.conf")
  (unless (check-merge-sentinel! actual-port) (set! ok #f))
  (unless (check-webview-backend!)
    (set! ok #f))
  (shutdown)
  (exit (if ok 0 1)))

;; api/params/merge is called on every config-form change with only the
;; visible fields; the endpoint's -999/"" sentinels for the rest must stay
;; out of the params model. Regression for the v1.0.0 bug where the first
;; merge corrupted the untouched advanced fields (transportSpecific 0x-3e7)
;; and validation rejected every engine start. Returns #t when healthy.
(define (check-merge-sentinel! port)
  (define body
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (http-post-as-string
       (format "http://127.0.0.1:~a/api/params/merge" port)
       "{\"domain\":5}")))
  (cond
    [(and body (string-contains? body "\"ok\":true")
          (regexp-match #rx"transportSpecific\\\\?[ \t]+0x1" body))
     (printf "[ok] params merge keeps sentinel values out of the conf\n")
     #t]
    [else
     (printf "[FAIL] params merge corrupted the conf (~a)\n"
             (and body (substring body 0 (min 120 (string-length body)))))
     #f]))

;; The distributed binary must carry the webview backend module: it is
;; reached only via runtime dispatch, so it is invisible to raco exe's
;; static walk and has to be embedded explicitly (see package-linux.sh).
;; The v1.0.0 deb shipped without it — every headless smoke test passed
;; while the native window failed with "collection not found". Loading the
;; module is headless-safe: its top-level FFI discovery degrades to #f, and
;; supported? only reports library presence (no window is opened here).
;; Returns #t when the backend module loads and #f otherwise.
(define (check-webview-backend!)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (printf "[FAIL] webview backend module (~a)\n"
                             (exn-message e))
                     #f)])
    (define supported?
      (with-handlers ([exn:fail? (lambda (_) #f)])
        ((dynamic-require 'glaze/webview/webview-linux 'supported?))))
    (printf "[ok] webview backend module loads (GTK/WebKitGTK present: ~a)\n"
            (if supported? "yes" "no"))
    #t))

(define (http-get-as-string url)
  (define-values (in _out) (tcp-connect* "127.0.0.1" url))
  (port->string in))

(define (http-post-as-string url body)
  (define m (regexp-match #px"^http://[^:]+:([0-9]+)(.*)$" url))
  (define port (string->number (second m)))
  (define path (if (string=? (third m) "") "/" (third m)))
  (define-values (in out)
    (tcp-connect "127.0.0.1" port))
  (fprintf out "POST ~a HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: ~a\r\n\r\n~a"
           path (bytes-length (string->bytes/utf-8 body)) body)
  (flush-output out)
  ;; skip the headers; the merge handler returns one JSON body
  (define everything (port->string in))
  (close-input-port in)
  (or (let ([m2 (regexp-match #rx"\r\n\r\n(.*)" everything)])
        (and m2 (second m2)))
      everything))

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
