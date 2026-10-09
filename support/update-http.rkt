#lang racket/base

;; HTTP GET with redirect following for the update system. net/http-client's
;; http-sendrecv neither follows redirects nor offers a redirections keyword,
;; and releases/latest/download/<name> aliases answer 302 (CDN handoff) —
;; staging or parsing the empty 302 body would fail verification, so the
;; manifest fetch and the artifact download chase Location themselves.
;; Follows up to #:max-redirects across scheme/host changes; relative
;; locations resolve against the current request URL.

(require net/http-client
         racket/list
         racket/string)

(provide http-get)

;; -> (values scheme+authority-prefix host path port ssl?)
(define (split-url url)
  (define m (regexp-match #rx"^(https?)://([^/]+)(/.*)?$" url))
  (unless m (error 'update-http "bad url: ~a" url))
  (define scheme (string-downcase (list-ref m 1)))
  (define authority (list-ref m 2))
  (define ssl? (string=? scheme "https"))
  (when ssl? (dynamic-require 'openssl #f))
  (define port
    (or (let ([p (regexp-match #rx":([0-9]+)$" authority)])
          (and p (string->number (second p))))
        (if ssl? 443 80)))
  (values (string-append scheme "://" authority)
          (car (string-split authority ":"))
          (or (list-ref m 3) "/")
          port
          ssl?))

(define (as-string v)
  (cond [(string? v) v]
        [(bytes? v) (bytes->string/utf-8 v)]
        [else ""]))

(define (header-value headers name)
  (define prefix (string-downcase name))
  (for/first ([h (in-list headers)]
              #:when (string-prefix? (string-downcase (as-string h)) prefix))
    (string-trim (substring (as-string h) (string-length name)))))

(define (resolve-url base location)
  (cond
    [(regexp-match? #rx"^https?://" location) location]
    [(string-prefix? location "/")
     (define-values (prefix _host _path _port _ssl?) (split-url base))
     (string-append prefix location)]
    [else
     (define-values (prefix _host path _port _ssl?) (split-url base))
     (string-append prefix (regexp-replace #rx"/[^/]*$" path "/") location)]))

;; (http-get url) -> (values status-line headers input-port)
;; the caller owns (close-input-port in); redirects are followed
(define (http-get url #:max-redirects [max-redirects 10])
  (let loop ([url url] [left max-redirects])
    (define-values (_prefix host path port ssl?) (split-url url))
    (define-values (status headers in)
      (http-sendrecv host path
                     #:port port
                     #:ssl? (if ssl? 'auto #f)))
    (define code
      ;; #px: #rx has no {n} bounds, and this match must not silently fail
      (let ([m (regexp-match #px"^HTTP/[0-9.]+ +([0-9]{3})" (string-trim (as-string status)))])
        (and m (string->number (second m)))))
    (define location
      (and (member code '(301 302 303 307 308))
           (header-value headers "location:")))
    (cond
      [(not location) (values status headers in)]
      [(zero? left)
       (close-input-port in)
       (error 'update-http "too many redirects fetching ~a" url)]
      [else
       (close-input-port in)
       (loop (resolve-url url location) (- left 1))])))
