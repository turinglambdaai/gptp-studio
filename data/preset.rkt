#lang racket/base

;; Scenario presets: role + gPTP params + target interface, stored as JSON
;; files under ~/.gptp-studio/presets/. One-click apply-and-start per PRD
;; scenario four (repeatable, shareable test configurations).

(require json
         racket/file
         racket/list
         racket/path
         racket/string
         "../engine/config.rkt")

(provide presets-dir
         preset-names
         preset-save
         preset-load
         preset-delete)

;; The app state module sets this to the real home before first use; the
;; default keeps the module testable in isolation.
(define presets-dir (make-parameter (build-path (find-system-path 'home-dir)
                                                ".gptp-studio" "presets")))

(define (safe-name name)
  ;; filesystem-safe: ASCII letters/digits, dash, underscore, dot, space,
  ;; and any non-ASCII character (CJK preset names are common here)
  (define cleaned
    (list->string
     (for/list ([c (in-string name)]
                #:when (or (char<=? #\a c #\z)
                           (char<=? #\A c #\Z)
                           (char<=? #\0 c #\9)
                           (member c '(#\- #\_ #\. #\space))
                           (> (char->integer c) 127)))
       c)))
  (define trimmed (string-trim cleaned))
  (if (string=? trimmed "") "preset" trimmed))

(define (preset-path name)
  (build-path (presets-dir) (string-append (safe-name name) ".json")))

(define (preset-names)
  (define dir (presets-dir))
  (if (directory-exists? dir)
      (sort
       (for/list ([p (in-directory dir)]
                  #:when (regexp-match? #rx"\\.json$" (path->string (file-name-from-path p))))
         (path-replace-extension (file-name-from-path p) ""))
       string<? #:key path->string)
      '()))

(define (preset-save name role params iface)
  (define dir (presets-dir))
  (make-directory* dir)
  (call-with-output-file
      (preset-path name)
    (lambda (out)
      (write-json
       (hasheq 'name name
               'role (role-name role)
               'iface iface
               'params (params->jsexpr params))
       out))
    #:exists 'replace)
  (preset-path name))

(define (preset-load name)
  (define path (preset-path name))
  (and (file-exists? path)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define data (call-with-input-file path read-json))
         (and (hash? data)
              (hasheq 'name (hash-ref data 'name name)
                      'role (hash-ref data 'role "listener")
                      'iface (hash-ref data 'iface #f)
                      'params (jsexpr->params (hash-ref data 'params (hasheq))))))))

(define (preset-delete name)
  (define path (preset-path name))
  (when (file-exists? path) (delete-file path))
  (not (file-exists? path)))
