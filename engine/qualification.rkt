#lang racket/base

;; Conservative preflight qualification for real gPTP workflows.
;;
;; This module intentionally distinguishes *capability/readiness* from timing
;; accuracy. Detecting HW timestamping, a PHC, or nanosecond timestamp
;; resolution is never converted into an accuracy claim. Accuracy requires a
;; separately calibrated/validated measurement setup.

(require racket/list
         racket/string)

(provide qualify-interface
         qualification-status-rank)

(define (qualification-status-rank status)
  (cond
    [(equal? status "ready") 3]
    [(equal? status "candidate") 2]
    [(equal? status "passive-only") 1]
    [else 0]))

(define (check id state title detail action)
  (hasheq 'id id
          'state state
          'title title
          'detail detail
          'action action))

(define (nic-ref nic key [default #f])
  (if (hash? nic) (hash-ref nic key default) default))

(define (find-nic nics iface)
  (cond
    [(and iface (not (string=? iface "")))
     (for/first ([n (in-list nics)]
                 #:when (string=? (nic-ref n 'name "") iface))
       n)]
    [(pair? nics) (car nics)]
    [else #f]))

(define (tool-check nic key id title install-hint #:required? [required? #t])
  (define ok? (nic-ref nic key #f))
  (check id
         (cond [ok? "pass"] [required? "fail"] [else "warn"])
         title
         (if ok? "available" "not detected")
         (if ok? "" install-hint)))

(define (qualification-summary status role iface)
  (case (string->symbol status)
    [(ready)
     (format "~a 已满足 ~a 真实引擎的已知前置条件；仍需用目标拓扑实测确认时间性能。" iface role)]
    [(candidate)
     (format "~a 当前没有已确认的硬阻断，但仍有待确认项；可以继续验证，不应据此宣称测量精度。" iface)]
    [(passive-only)
     (format "~a 适合被动抓包/协议分析，不满足当前 GM/Slave 真实引擎前置条件。" iface)]
    [else
     (format "~a 当前存在阻断项，先修复 Preflight 中的 FAIL 再启动真实引擎。" (or iface "当前主机"))]))

;; platform: "linux" | "macos" | "windows" | ...
;; role:     "grandmaster" | "slave" | "listener"
;; reference:"system" | "none"
;; capture-status is optional and lets Preflight report the *actual* libpcap
;; timestamp path when a live capture is already running on the same interface.
(define (qualify-interface #:platform platform
                           #:nics nics
                           #:iface [iface ""]
                           #:role [role "listener"]
                           #:reference [reference "system"]
                           #:capture-status [capture-status #f])
  (define nic (find-nic nics iface))
  (define selected-iface (and nic (nic-ref nic 'name #f)))
  (define real-clock-role? (member role '("grandmaster" "slave")))
  (define listener? (string=? role "listener"))
  (define linux? (string=? platform "linux"))

  (define checks '())
  (define (add! c) (set! checks (append checks (list c))))

  (add! (check "platform"
               (cond [listener? "pass"] [linux? "pass"] [else "fail"])
               "Host platform"
               (if linux?
                   "Linux timing control path available"
                   (format "~a has no Linux PHC/linuxptp control path" platform))
               (if (or listener? linux?) "" "Use a Linux debug host for real GM/Slave operation.")))

  (add! (check "interface"
               (if nic "pass" "fail")
               "Network interface"
               (if nic selected-iface "No matching interface detected")
               (if nic "" "Select or connect a physical Ethernet interface.")))

  (when nic
    (add! (check "link"
                 (if (nic-ref nic 'up #f) "pass" "fail")
                 "Link state"
                 (nic-ref nic 'operstate "unknown")
                 (if (nic-ref nic 'up #f) "" "Connect the DUT/switch and bring the link UP.")))

    (when real-clock-role?
      (define ethtool-available? (nic-ref nic 'ethtool_available #f))
      (define hw? (nic-ref nic 'hw_timestamping #f))
      (define phc (nic-ref nic 'phc_device #f))

      ;; If ethtool is missing, these capabilities are unknown rather than
      ;; proven absent. Treat that as VERIFY/WARN and ask the user to install
      ;; the probe tool before making a hardware support conclusion.
      (add! (check "hw-timestamp"
                   (cond [hw? "pass"] [ethtool-available? "fail"] [else "warn"])
                   "Hardware TX/RX timestamping"
                   (cond [hw? "NIC/driver reports hardware TX + RX timestamp capability"]
                         [ethtool-available? "ethtool did not report hardware TX + RX timestamp capability"]
                         [else "Unknown: ethtool is unavailable, so hardware timestamp capability was not verified"])
                   (cond [hw? ""]
                         [ethtool-available? "Use a NIC/driver that exposes IEEE 1588 hardware timestamping."]
                         [else "Install ethtool and rerun Preflight before concluding that the NIC is unsupported."])))
      (add! (check "phc"
                   (cond [phc "pass"] [ethtool-available? "fail"] [else "warn"])
                   "PTP Hardware Clock"
                   (cond [phc phc]
                         [ethtool-available? "No /dev/ptpN mapping was reported for this interface"]
                         [else "Unknown: PHC mapping could not be verified without ethtool"])
                   (cond [phc ""]
                         [ethtool-available? "Verify the NIC driver exposes a PHC and ethtool -T reports it."]
                         [else "Install ethtool and rerun Preflight to verify the PHC mapping."])))
      (add! (tool-check nic 'ptp4l_available "ptp4l" "ptp4l" "Install the linuxptp package."))
      (when (and (string=? role "grandmaster") (string=? reference "system"))
        (add! (tool-check nic 'phc2sys_available "phc2sys" "phc2sys reference clock" "Install the linuxptp package or select no external reference.")))
      (add! (tool-check nic 'pmc_available "pmc" "pmc cross-check" "Install the linuxptp package for management cross-checks." #:required? #f))
      (add! (tool-check nic 'ethtool_available "ethtool" "NIC capability probe" "Install ethtool; without it NIC timing capability detection remains incomplete." #:required? #f))
      (add! (tool-check nic 'ip_available "ip" "Interface metadata probe" "Install iproute2; without it interface metadata may be incomplete." #:required? #f))

      (define privilege (nic-ref nic 'privilege_mode "unknown"))
      (add! (check "privilege"
                   (if (member privilege '("root" "sudo-noninteractive")) "pass" "warn")
                   "Privilege path"
                   privilege
                   (if (member privilege '("root" "sudo-noninteractive"))
                       ""
                       "File capabilities or ambient capabilities may still work; verify by starting the real engine and inspect launch-mode/logs."))))

    (when listener?
      (add! (check "listener-mode"
                   "pass"
                   "Passive Listener semantics"
                   "Listener does not start ptp4l or discipline a host/PHC clock"
                   "")))

    (define capture-running? (and (hash? capture-status)
                                  (hash-ref capture-status 'running #f)))
    (define capture-iface (and (hash? capture-status)
                               (hash-ref capture-status 'iface #f)))
    (when (and capture-running? selected-iface (equal? capture-iface selected-iface))
      (define source (hash-ref capture-status 'timestamp_source "unknown"))
      (define precision (hash-ref capture-status 'timestamp_precision "unknown"))
      (add! (check "capture-source"
                   (if (string=? source "adapter") "pass" "warn")
                   "Actual libpcap timestamp path"
                   (format "~a / ~a" source precision)
                   (if (string=? source "adapter")
                       "Resolution/source are observations only; calibrated accuracy is still not established."
                       "Use ptp4l/PHC metrics for synchronization judgments; host/default capture timestamps are diagnostic only."))))))

  (define fails (count (lambda (c) (string=? (hash-ref c 'state) "fail")) checks))
  (define warns (count (lambda (c) (string=? (hash-ref c 'state) "warn")) checks))
  (define status
    (cond
      [listener? (if (zero? fails) (if (zero? warns) "ready" "candidate") "blocked")]
      [(positive? fails)
       (if (and nic (or (nic-ref nic 'hw_timestamping #f)
                        (nic-ref nic 'phc_device #f)))
           "blocked"
           "passive-only")]
      [(positive? warns) "candidate"]
      [else "ready"]))

  (hasheq 'status status
          'role role
          'reference reference
          'iface selected-iface
          'summary (qualification-summary status role selected-iface)
          'checks checks
          'fail_count fails
          'warn_count warns
          'accuracy_claim "not-calibrated"
          'accuracy_note "Preflight verifies prerequisites and observed timestamp paths only. It does not establish end-to-end timing accuracy."))
