#lang racket/base

;; Pure parsing helpers for path parameters. Glaze intentionally captures
;; `:param` path segments as strings, so API routes must parse them explicitly
;; before passing values into numeric/domain code.

(provide parse-bounded-positive-integer)

(define (parse-bounded-positive-integer raw #:max [max-value 5000])
  (define n
    (cond
      [(exact-integer? raw) raw]
      [(string? raw)
       (define parsed (string->number raw))
       (and (exact-integer? parsed) parsed)]
      [else #f]))
  (and n
       (positive? n)
       (<= n max-value)
       n))
