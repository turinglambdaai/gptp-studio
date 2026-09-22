#lang racket/base

;; Stable, redacted Linux host inventory for support and reference-platform
;; qualification. Deliberately excludes hostname, machine-id, DMI serials,
;; UUIDs, MAC addresses and IP addresses.

(require racket/file
         racket/list
         racket/port
         racket/string
         racket/system)

(provide collect-platform-fingerprint)

(define (run-out . args)
  (define exe (find-executable-path (car args)))
  (and exe
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define out (open-output-string))
         (parameterize ([current-output-port out]
                        [current-error-port (open-output-nowhere)]
                        [current-input-port (open-input-string "")])
           (define rc (apply system*/exit-code exe (cdr args)))
           (and (zero? rc) (string-trim (get-output-string out)))))))

(define (read-text path [default #f])
  (with-handlers ([exn:fail? (lambda (_) default)])
    (if (file-exists? path)
        (string-trim (file->string path))
        default)))

(define (unquote-os-release v)
  (define s (string-trim v))
  (if (and (>= (string-length s) 2)
           (or (and (char=? (string-ref s 0) #\")
                    (char=? (string-ref s (sub1 (string-length s))) #\"))
               (and (char=? (string-ref s 0) #\')
                    (char=? (string-ref s (sub1 (string-length s))) #\'))))
      (substring s 1 (sub1 (string-length s)))
      s))

(define (read-os-release)
  (define path "/etc/os-release")
  (if (file-exists? path)
      (for/fold ([h (hasheq)]) ([line (in-list (file->lines path))])
        (define m (regexp-match #px"^([A-Z0-9_]+)=(.*)$" line))
        (if m
            (hash-set h (string->symbol (second m))
                      (unquote-os-release (third m)))
            h))
      (hasheq)))

(define (first-line s)
  (and s
       (let ([lines (string-split s "\n")])
         (and (pair? lines) (string-trim (car lines))))))

(define (tool-version name args)
  (first-line (apply run-out name args)))

(define (dpkg-version package)
  (run-out "dpkg-query" "-W" "-f=${Version}" package))

(define (first-installed-package-version names)
  (for/or ([name (in-list names)])
    (define v (dpkg-version name))
    (and v (hasheq 'package name 'version v))))

(define (virtualization)
  (define v (run-out "systemd-detect-virt"))
  (cond
    [(or (not v) (string=? v "")) "unknown"]
    [else v]))

(define (collect-platform-fingerprint)
  (define osr (read-os-release))
  (define tools
    (hasheq 'ptp4l (tool-version "ptp4l" '("-v"))
            'phc2sys (tool-version "phc2sys" '("-v"))
            'pmc (tool-version "pmc" '("-v"))
            'ethtool (tool-version "ethtool" '("--version"))
            'openssl (tool-version "openssl" '("version"))))
  (define packages
    (hasheq 'linuxptp (first-installed-package-version '("linuxptp"))
            'libpcap (first-installed-package-version '("libpcap0.8" "libpcap0.8t64"))
            'webkitgtk (first-installed-package-version '("libwebkit2gtk-4.1-0"))
            'gtk3 (first-installed-package-version '("libgtk-3-0" "libgtk-3-0t64"))))
  (hasheq
   'fingerprint_schema_version 1
   'distro (hasheq 'id (hash-ref osr 'ID "unknown")
                   'version_id (hash-ref osr 'VERSION_ID "unknown")
                   'pretty_name (hash-ref osr 'PRETTY_NAME "unknown"))
   'kernel (hasheq 'release (or (run-out "uname" "-r") "unknown")
                   'version (or (run-out "uname" "-v") "unknown")
                   'architecture (or (run-out "uname" "-m") "unknown"))
   'system (hasheq 'vendor (or (read-text "/sys/class/dmi/id/sys_vendor") "unknown")
                   'product_name (or (read-text "/sys/class/dmi/id/product_name") "unknown")
                   'board_name (or (read-text "/sys/class/dmi/id/board_name") "unknown")
                   'virtualization (virtualization)
                   'clocksource (or (read-text "/sys/devices/system/clocksource/clocksource0/current_clocksource")
                                    "unknown"))
   'runtime (hasheq 'racket_version (version))
   'tools tools
   'packages packages
   'privacy (hasheq 'hostname_omitted #t
                    'machine_id_omitted #t
                    'hardware_serials_omitted #t
                    'network_identifiers_omitted #t)))
