#lang racket/base

;; NIC + PHC detection for the supported Linux product platform.
;;
;; gPTP Studio intentionally targets Linux because the real product path
;; depends on sysfs, SO_TIMESTAMPING/PHC, linuxptp and Linux capability
;; semantics. Unsupported hosts are rejected by main.rkt instead of being
;; presented as partially supported analysis-only platforms.
;;
;; Every probe failure degrades to an "unknown" field so transient host state
;; does not crash the UI. Structural qualification is handled separately.

(require json
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/system
         "process-runtime.rkt")

(provide detect-interfaces
         platform-name
         supported-platform?)

(define (supported-platform?)
  (and (eq? (system-type 'os) 'unix)
       (directory-exists? "/sys/class/net")))

(define (platform-name)
  (if (supported-platform?) "linux" "unsupported"))

(define (run-out . args)
  (define exe (find-executable-path (car args)))
  (if (not exe)
      #f
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define out (open-output-string))
        (parameterize ([current-output-port out]
                       [current-error-port (open-output-nowhere)]
                       [current-input-port (open-input-string "")])
          (define rc (apply system*/exit-code exe (cdr args)))
          (and (zero? rc) (get-output-string out))))))

(define (executable-available? name)
  (and (find-executable-path name) #t))

(define (exe-string name)
  (define p (find-executable-path name))
  (and p (path->string p)))

(define (has-all-file-caps? executable caps)
  (and executable
       (for/and ([cap (in-list caps)])
         (executable-has-capability? executable cap))))

(define (linux-tooling)
  (define uid-out (run-out "id" "-u"))
  (define root?
    (and uid-out (string=? (string-trim uid-out) "0")))
  (define sudo-ok?
    (and (not root?) (run-out "sudo" "-n" "true") #t))
  (define ptp4l (exe-string "ptp4l"))
  (define phc2sys (exe-string "phc2sys"))
  (define ptp4l-caps?
    (has-all-file-caps? ptp4l '("cap_net_raw" "cap_net_admin")))
  (define phc2sys-caps?
    (has-all-file-caps? phc2sys '("cap_sys_time")))
  (hasheq 'ptp4l_available (and ptp4l #t)
          'phc2sys_available (and phc2sys #t)
          'pmc_available (executable-available? "pmc")
          'ethtool_available (executable-available? "ethtool")
          'ip_available (executable-available? "ip")
          'getcap_available (executable-available? "getcap")
          'ptp4l_file_capabilities ptp4l-caps?
          'phc2sys_file_capabilities phc2sys-caps?
          'privilege_mode (cond [root? "root"]
                                [sudo-ok? "sudo-noninteractive"]
                                [ptp4l-caps? "file-capabilities"]
                                [else "direct-best-effort"])))

(define (with-tooling h tooling)
  (for/fold ([out h]) ([(k v) (in-hash tooling)])
    (hash-set out k v)))

(define (ethtool-field text key [default ""])
  (define prefix (string-append key ":"))
  (or (for/first ([line (in-list (string-split text "\n"))]
                  #:when (string-prefix? (string-trim line) prefix))
        (string-trim
         (substring (string-trim line) (string-length prefix))))
      default))

(define (phc-clock-name phc)
  (cond
    [(not phc) #f]
    [else
     (define m (regexp-match #px"/dev/(ptp[0-9]+)$" phc))
     (and m
          (file->string* (build-path "/sys/class/ptp" (second m) "clock_name")))]))

(define (device-attribute sys-if name)
  (or (file->string* (build-path sys-if "device" name)) "unknown"))

(define (detect-linux)
  (define sys-net "/sys/class/net")
  (define tooling (linux-tooling))
  (define names
    (sort
     (for/list ([p (in-list (directory-list sys-net #:build? #f))]
                #:unless (string-prefix? (path->string p) "lo"))
       (path->string p))
     string<?))
  (for/list ([name (in-list names)])
    (define sys-if (build-path sys-net name))
    (define mac
      (or (let ([m (file->string* (build-path sys-if "address"))])
            (and m (string-upcase (string-trim m))))
          ""))
    (define operstate (or (file->string* (build-path sys-if "operstate")) "unknown"))
    (define timestamp-info (or (run-out "ethtool" "-T" name) ""))
    (define driver-info (or (run-out "ethtool" "-i" name) ""))
    (define hw-tx? (string-contains? timestamp-info "SOF_TIMESTAMPING_TX_HARDWARE"))
    (define hw-rx? (string-contains? timestamp-info "SOF_TIMESTAMPING_RX_HARDWARE"))
    (define phc
      (let ([m (regexp-match #px"PTP Hardware Clock:\\s*([0-9]+)" timestamp-info)])
        (and m (format "/dev/ptp~a" (second m)))))
    (with-tooling
     (hasheq 'name name
             'mac (string-downcase mac)
             'operstate operstate
             'up (string=? operstate "up")
             'hw_timestamping (and hw-tx? hw-rx?)
             'phc_device phc
             'phc_clock_name (or (phc-clock-name phc) "unknown")
             'driver (ethtool-field driver-info "driver")
             'driver_version (ethtool-field driver-info "version")
             'firmware_version (ethtool-field driver-info "firmware-version")
             'bus_info (ethtool-field driver-info "bus-info")
             'pci_vendor_id (device-attribute sys-if "vendor")
             'pci_device_id (device-attribute sys-if "device")
             'subsystem_vendor_id (device-attribute sys-if "subsystem_vendor")
             'subsystem_device_id (device-attribute sys-if "subsystem_device")
             'numa_node (device-attribute sys-if "numa_node")
             'ips (linux-ips name)
             'speed (or (file->string* (build-path sys-if "speed")) "unknown"))
     tooling)))

(define (linux-ips name)
  (define out (run-out "ip" "-j" "-o" "addr" "show" "dev" name))
  (cond
    [out
     (with-handlers ([exn:fail? (lambda (_) '())])
       (define data (read-json (open-input-string out)))
       (for/list ([entry (in-list (if (list? data) data '()))]
                  #:when (hash? entry))
         (hash-ref entry 'local "")))]
    [else '()]))

(define (file->string* p)
  (with-handlers ([exn:fail? (lambda (_) #f)]
                  [exn:break? (lambda (_) #f)])
    (and (file-exists? p) (string-trim (file->string p)))))

(define (detect-interfaces)
  (if (supported-platform?)
      (detect-linux)
      '()))
