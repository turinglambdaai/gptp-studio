#lang racket/base

;; NIC + PHC detection. Linux reads sysfs and shells out to `ethtool -T`
;; and `ip -j addr`; macOS uses ifconfig. Every failure degrades to
;; "unknown" fields — never blocks the UI.
;;
;; Linux tooling facts include the privilege paths used by process-runtime.
;; File capabilities are reported separately for ptp4l and phc2sys because
;; Slave and GM-without-system-reference do not require CAP_SYS_TIME.

(require json
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/system
         "process-runtime.rkt")

(provide detect-interfaces
         platform-name)

(define (platform-name)
  (case (system-type 'os)
    [(macosx) "macos"]
    [(unix) "linux"]
    [(windows) "windows"]
    [else "unknown"]))

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

;; ---- Linux -------------------------------------------------------------------

(define (detect-linux)
  (define sys-net "/sys/class/net")
  (define tooling (linux-tooling))
  (define names
    (if (directory-exists? sys-net)
        (sort
         (for/list ([p (in-list (directory-list sys-net #:build? #f))]
                    #:unless (string-prefix? (path->string p) "lo"))
           (path->string p))
         string<?)
        '()))
  (for/list ([name (in-list names)])
    (define sys-if (build-path sys-net name))
    (define mac
      (or (let ([m (file->string* (build-path sys-if "address"))])
            (and m (string-upcase (string-trim m))))
          ""))
    (define operstate (or (file->string* (build-path sys-if "operstate")) "unknown"))
    (define ethtool (or (run-out "ethtool" "-T" name) ""))
    (define hw-tx? (string-contains? ethtool "SOF_TIMESTAMPING_TX_HARDWARE"))
    (define hw-rx? (string-contains? ethtool "SOF_TIMESTAMPING_RX_HARDWARE"))
    (define phc
      (let ([m (regexp-match #px"PTP Hardware Clock:\\s*([0-9]+)" ethtool)])
        (and m (format "/dev/ptp~a" (second m)))))
    (define driver
      (or (let* ([out (or (run-out "ethtool" "-i" name) "")]
                 [m (regexp-match #px"driver:\\s*(\\S+)" out)])
            (and m (second m)))
          ""))
    (with-tooling
     (hasheq 'name name
             'mac (string-downcase mac)
             'operstate operstate
             'up (string=? operstate "up")
             'hw_timestamping (and hw-tx? hw-rx?)
             'phc_device phc
             'driver driver
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

;; ---- macOS -------------------------------------------------------------------

(define (detect-macos)
  (define names-list (or (run-out "ifconfig" "-l") ""))
  (define names (string-split names-list " "))
  (for/list ([name (in-list names)]
             ;; skip loopback; en/bridge/awdl are all physical-ish
             #:unless (string-prefix? name "lo"))
    (define info (or (run-out "ifconfig" name) ""))
    (define inet (regexp-match #px"inet ([0-9.]+)" info))
    (define status (regexp-match #px"status: (\\S+)" info))
    (define macm (regexp-match #px"ether\\s+([0-9a-f:]+)" info))
    (hasheq 'name name
            'mac (or (and macm (string-downcase (second macm))) "")
            'operstate (or (and status (second status)) "unknown")
            'up (and status (string=? (second status) "active"))
            ;; macOS exposes no PHC / SO_TIMESTAMPING control surface:
            ;; captures run with software timestamps only (documented limit)
            'hw_timestamping #f
            'phc_device #f
            'driver "apple"
            'ips (if inet (list (second inet)) '())
            'speed "unknown"
            'ptp4l_available #f
            'phc2sys_available #f
            'pmc_available #f
            'ethtool_available #f
            'ip_available #f
            'getcap_available #f
            'ptp4l_file_capabilities #f
            'phc2sys_file_capabilities #f
            'privilege_mode "n/a")))

(define (detect-interfaces)
  (case (system-type 'os)
    [(macosx) (detect-macos)]
    [(unix) (detect-linux)]
    [else '()]))