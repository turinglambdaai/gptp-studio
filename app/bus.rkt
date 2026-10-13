#lang racket/base

;; Local broadcast bus for engine -> presentation events.
;;
;; The engine (supervisor, capture manager) emits semantic events without
;; knowing who renders them. Under Glaze this was the SSE bus; under Rivet
;; the backend subscribes once and forwards each event into a typed RVT1
;; event, whose delivery, ordering, and backpressure the protocol runtime
;; already owns. The bus is therefore a plain synchronous fan-out now: no
;; backlog policy of its own to get right twice.

(require racket/list)

(provide make-event-bus
         event-bus?
         bus-broadcast!
         bus-subscribe!
         bus-unsubscribe!
         bus-subscriber-count)

(struct event-bus (lock subscribers) #:transparent #:mutable)

(define (make-event-bus)
  (event-bus (make-semaphore 1) '()))

(define (bus-subscribe! bus receiver)
  (call-with-semaphore
   (event-bus-lock bus)
   (lambda ()
     (set-event-bus-subscribers!
      bus (append (event-bus-subscribers bus) (list receiver)))))
  (lambda () (bus-unsubscribe! bus receiver)))

(define (bus-unsubscribe! bus receiver)
  (call-with-semaphore
   (event-bus-lock bus)
   (lambda ()
     (set-event-bus-subscribers!
      bus (remove receiver (event-bus-subscribers bus) eq?)))))

(define (bus-subscriber-count bus)
  (length (event-bus-subscribers bus)))

;; Handlers run synchronously on the emitting thread (engine thread), the
;; same delivery context the Glaze bus used; the Rivet forwarding layer
;; only encodes and hands the frame to the writer, which owns queueing.
(define (bus-broadcast! bus name data)
  (define receivers
    (call-with-semaphore (event-bus-lock bus) (lambda () (event-bus-subscribers bus))))
  (for ([receiver (in-list receivers)])
    (with-handlers ([exn:fail? (lambda (e)
                                 (fprintf (current-error-port)
                                          "[bus] receiver failed on ~a: ~a\n"
                                          name (exn-message e)))])
      (receiver name data))))
