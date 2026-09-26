#lang racket/base

(require rackunit
         "../app/api-input.rkt")

(check-equal? (parse-bounded-positive-integer "1") 1)
(check-equal? (parse-bounded-positive-integer "200") 200)
(check-equal? (parse-bounded-positive-integer 5000) 5000)
(check-equal? (parse-bounded-positive-integer "5000") 5000)

(check-false (parse-bounded-positive-integer "0"))
(check-false (parse-bounded-positive-integer "-1"))
(check-false (parse-bounded-positive-integer "5001"))
(check-false (parse-bounded-positive-integer "1.5"))
(check-false (parse-bounded-positive-integer "abc"))
(check-false (parse-bounded-positive-integer ""))
(check-false (parse-bounded-positive-integer #f))

(check-equal? (parse-bounded-positive-integer "42" #:max 100) 42)
(check-false (parse-bounded-positive-integer "101" #:max 100))
