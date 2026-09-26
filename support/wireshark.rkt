#lang racket/base

;; Wireshark one-click integration.
;;
;; Two entry points, both Linux-native and both explicit about what happens:
;;   live     — launch wireshark on the same interface with a gPTP capture
;;              filter; Studio keeps its own capture, Wireshark captures in
;;              parallel. Nothing is exported.
;;   retained — write the retained packet store to a temp pcap and open it in
;;              wireshark. This is an export of capture data (Pro-gated at the
;;              route layer).
;; Wireshark is started detached (nohup + shell &) so closing Studio never
;; kills the analyst's Wireshark session.

(require racket/file
         racket/format
         racket/string
         racket/system)

(provide wireshark-available?
         gptp-capture-filter
         wireshark-temp-pcap-path
         launch-wireshark-live!
         launch-wireshark-file!)

(define (wireshark-available?)
  (and (find-executable-path "wireshark") #t))

;; Capture filter strings for both gPTP transports. L2 is the 802.1AS-native
;; path (EtherType 0x88f7); UDPv4 uses the PTP event/general ports.
(define (gptp-capture-filter [network-transport "L2"])
  (cond
    [(string-ci=? network-transport "L2") "ether proto 0x88f7"]
    [(string-ci=? network-transport "UDPv4") "port 319 or port 320"]
    [else "ether proto 0x88f7 or (port 319 or port 320)"]))

(define (wireshark-temp-pcap-path)
  (build-path (find-system-path 'temp-dir)
              (format "gptp-studio-wireshark-~a.pcap"
                      (inexact->exact (current-inexact-milliseconds)))))

;; POSIX single-quote escaping; temp paths can contain spaces on some setups.
(define (shell-quote s)
  (string-append "'" (string-replace s "'" "'\\''") "'"))

;; Detached launch. The product contract is Linux: `nohup … &` fully releases
;; the child from Studio's process group and custodian lifecycle.
(define (launch-detached! exe args-list)
  (define cmdline
    (string-join (map shell-quote (cons exe args-list)) " "))
  (system (string-append "nohup " cmdline " >/dev/null 2>&1 &")))

(define (require-wireshark!)
  (define exe (find-executable-path "wireshark"))
  (unless exe
    (raise-user-error 'wireshark
                      "未找到 wireshark。请先安装：sudo apt install wireshark"))
  (path->string exe))

;; iface: interface name string; filter: capture filter string.
(define (launch-wireshark-live! iface filter)
  (define exe (require-wireshark!))
  (cond
    [(not (non-empty-string? iface))
     (raise-user-error 'wireshark "实时联动需要先选择网卡")]
    [(not (launch-detached! exe (list "-i" iface "-f" filter)))
     (raise-user-error 'wireshark "wireshark 启动失败")]
    [else (hasheq 'ok #t 'iface iface 'filter filter)]))

;; path: pcap file path string. Returns the path for logging/toasts.
(define (launch-wireshark-file! path)
  (define exe (require-wireshark!))
  (define file (if (path? path) (path->string path) path))
  (unless (file-exists? file)
    (raise-user-error 'wireshark (format "pcap 文件不存在：~a" file)))
  (cond
    [(not (launch-detached! exe (list file)))
     (raise-user-error 'wireshark "wireshark 启动失败")]
    [else (hasheq 'ok #t 'path file)]))
