#lang info

(define collection "gptp-studio")
(define pkg-desc "gPTP Studio - gPTP / IEEE 802.1AS debugging workstation (Racket + Glaze)")
(define version "1.2.0")
(define pkg-authors '("turinglambdaai"))
(define license 'Apache-2.0)

(define deps
  '("base"
    "gui-lib"
    "rackunit-lib"))

(define build-deps '())

(define main-launcher '("main.rkt"))

(define categories '(devtools net))
