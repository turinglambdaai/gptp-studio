#lang info

(define collection "rtimeserver")
(define pkg-desc "gPTP (IEEE 802.1AS) cross-platform debugging tool")
(define version "0.2.0")
(define pkg-authors '("turinglambdaai"))
(define license 'Apache-2.0)

(define deps
  '("base"
    "gui-lib"
    "draw-lib"))

(define build-deps
  '("rackunit-lib"))

(define main-launcher '("main.rkt"))

(define categories '(devtools net))
