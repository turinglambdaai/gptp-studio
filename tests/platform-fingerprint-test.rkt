#lang racket/base

(require rackunit
         "../support/platform-fingerprint.rkt")

(define fp (collect-platform-fingerprint))

(check-equal? (hash-ref fp 'fingerprint_schema_version) 1)
(check-true (hash? (hash-ref fp 'distro)))
(check-true (hash? (hash-ref fp 'kernel)))
(check-true (hash? (hash-ref fp 'system)))
(check-true (hash? (hash-ref fp 'runtime)))
(check-true (hash? (hash-ref fp 'tools)))
(check-true (hash? (hash-ref fp 'packages)))

(define privacy (hash-ref fp 'privacy))
(check-true (hash-ref privacy 'hostname_omitted))
(check-true (hash-ref privacy 'machine_id_omitted))
(check-true (hash-ref privacy 'hardware_serials_omitted))
(check-true (hash-ref privacy 'network_identifiers_omitted))

;; The data model must not grow fields containing unique host/network identity.
;; *_omitted privacy declarations are intentionally allowed.
(define forbidden-keys
  '(hostname machine_id machine-id serial serial_number serial-number
             product_uuid product-uuid board_serial chassis_serial
             mac mac_address ip ips ip_address))

(define (walk v)
  (cond
    [(hash? v)
     (for ([(k child) (in-hash v)])
       (unless (and (symbol? k)
                    (regexp-match? #px"_omitted$" (symbol->string k)))
         (check-false (member k forbidden-keys)))
       (walk child))]
    [(list? v)
     (for ([child (in-list v)]) (walk child))]
    [else (void)]))

(walk fp)
