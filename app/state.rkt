#lang racket/base

;; App-level shared state: the glaze event bus, data stores, supervisor and
;; capture manager singletons, user settings under ~/.gptp-studio/.

(require json
         racket/file
         racket/path
         glaze/events
         "../data/series.rkt"
         "../data/logstore.rkt"
         "../data/preset.rkt"
         "../capture/store.rkt"
         "../capture/manager.rkt"
         "../engine/config.rkt"
         "../engine/supervisor.rkt")

(provide app-wv-box
         app-bus
         app-logs
         app-offset-series
         app-delay-series
         app-packets
         app-supervisor
         app-capture
         app-dir
         app-settings-path
         app-run-dir
         app-state-path
         settings-load
         settings-save
         settings-ref
         settings-set!
         app-version)

(define app-version "1.1.0")

;; ---- stores (created once) -----------------------------------------------------

(define app-wv-box (box #f))  ; set by main on-ready; used by the dev screenshot API
(define app-bus (make-event-bus))
(define app-logs (make-logstore 8000))
(define app-offset-series (make-series 21600))
(define app-delay-series (make-series 21600))
(define app-packets (make-packet-store 2000))

(define app-supervisor
  (make-supervisor #:bus app-bus
                   #:logs app-logs
                   #:offset-series app-offset-series
                   #:delay-series app-delay-series
                   #:packets app-packets
                   #:run-dir (build-path (find-system-path 'home-dir)
                                         ".gptp-studio" "run")))

(define app-capture (make-capture-manager #:bus app-bus
                                          #:logs app-logs
                                          #:packets app-packets))

;; ---- directories ---------------------------------------------------------------

(define (app-dir)
  (define d (build-path (find-system-path 'home-dir) ".gptp-studio"))
  (make-directory* d)
  d)

(define (app-settings-path) (build-path (app-dir) "settings.json"))
(define (app-state-path) (build-path (app-dir) "state.json"))
(define (app-run-dir) (build-path (app-dir) "run"))

;; ---- settings ------------------------------------------------------------------

(define defaults
  (hasheq 'language "zh"
          'capture-iface #f
          'offset-warn-us 100
          'auto-restart #t))

(define settings-cache (box #f))

(define (settings-load)
  (define path (app-settings-path))
  (define from-disk
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (define v (call-with-input-file path read-json))
      (if (hash? v) v (hasheq))))
  (for/fold ([acc defaults])
            ([(k v) (in-hash from-disk)])
    (hash-set acc k v)))

(define (settings-ref key)
  (unless (unbox settings-cache) (set-box! settings-cache (settings-load)))
  (hash-ref (unbox settings-cache) key (hash-ref defaults key #f)))

(define (settings-set! key value)
  (unless (unbox settings-cache) (set-box! settings-cache (settings-load)))
  (set-box! settings-cache (hash-set (unbox settings-cache) key value))
  (call-with-output-file (app-settings-path)
    (lambda (out) (write-json (unbox settings-cache) out))
    #:exists 'replace)
  value)

(define (settings-save) (void)) ; writes are immediate; kept for API symmetry
