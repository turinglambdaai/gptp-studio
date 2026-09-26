#lang racket/base

;; Runtime-only linuxptp configuration.
;;
;; linuxptp defaults its management Unix sockets to /var/run/ptp4l and
;; /var/run/ptp4lro. That is fine for a root daemon, but it defeats Studio's
;; file-capability/direct non-root launch paths. Keep every process in one
;; per-user run directory and make ptp4l, phc2sys and pmc use the same socket.

(require racket/file
         racket/format
         racket/list
         racket/path
         "config.rkt")

(provide runtime-uds-path
         runtime-uds-ro-path
         runtime-conf
         cleanup-runtime-sockets!
         phc2sys-reference-args
         phc2sys-boundary-args
         ptp4l-iface-args
         pmc-current-data-set-args)

(define (runtime-uds-path run-dir)
  (build-path run-dir "ptp4l.sock"))

(define (runtime-uds-ro-path run-dir)
  (build-path run-dir "ptp4lro.sock"))

(define (runtime-conf base-conf run-dir)
  (string-append
   base-conf
   "\n# gPTP Studio runtime sockets (user-writable; shared by ptp4l/phc2sys/pmc)\n"
   (format "uds_address             ~a\n"
           (path->string (runtime-uds-path run-dir)))
   (format "uds_ro_address          ~a\n"
           (path->string (runtime-uds-ro-path run-dir)))))

;; Stale Unix-domain socket filesystem entries can survive an unclean shutdown.
;; delete-file works for socket path entries on Unix; failures are harmless
;; here because ptp4l will surface any real bind problem in its own stderr.
(define (cleanup-runtime-sockets! run-dir)
  (for ([p (in-list (list (runtime-uds-path run-dir)
                           (runtime-uds-ro-path run-dir)))])
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (delete-file p))))

(define (phc2sys-reference-args run-dir iface params)
  (list "-c" iface
        "-s" "CLOCK_REALTIME"
        "-w"
        "-z" (path->string (runtime-uds-path run-dir))
        "-n" (number->string (gptp-params-domain params))
        (format "--transportSpecific=~a"
                (gptp-params-transport-specific params))
        "-m"))

(define (pmc-current-data-set-args run-dir params)
  (list "-u"
        "-s" (path->string (runtime-uds-path run-dir))
        "-d" (number->string (gptp-params-domain params))
        "-t" (format "~x" (gptp-params-transport-specific params))
        "GET CURRENT_DATA_SET"))

;; Boundary-clock companion: -a reads the port/clock set from the running
;; ptp4l over the same per-user UDS and follows BMCA port-state changes;
;; -r also disciplines the system clock; -w waits for ptp4l.
(define (phc2sys-boundary-args run-dir)
  (list "-a" "-r" "-w"
        "-z" (path->string (runtime-uds-path run-dir))
        "-m"))

;; ptp4l takes one -i per port; since linuxptp 3.0 multiple ports imply a
;; boundary clock (boundary_clock_enabled was removed).
(define (ptp4l-iface-args conf-path ifaces)
  (append (list "-f" (path->string conf-path))
          (append* (for/list ([iface (in-list ifaces)]) (list "-i" iface)))
          (list "-m")))
