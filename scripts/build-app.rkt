#lang racket/base

;; Build the macOS .app (and platform launcher) via glaze's build-app.
;; Run from the repo root: racket scripts/build-app.rkt

(require racket/path
         racket/runtime-path
         glaze)

(define-runtime-path this-file "build-app.rkt")
(define root (simplify-path (build-path (path-only this-file) 'up)))
(define icon (build-path root "assets" "icon.png"))
(define out (build-path root "dist"))

(build-app #:entry (path->string (build-path root "main.rkt"))
           #:name "gPTP Studio"
           #:version "1.0.0"
           #:icon (if (file-exists? icon) (path->string icon) #f)
           #:out-dir (path->string out))
