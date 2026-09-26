#lang racket/base

;; zh / en string table. Chinese is the primary language (the PRD and the
;; author's audience are Chinese-first); English is fully covered. The
;; frontend fetches the whole table via /api/i18n and applies it with
;; data-i18n attributes.

(provide i18n-dict
         i18n-supported
         t)

(define (i18n-supported) '("zh" "en"))

;; key -> (cons zh en)
(define table
  (hasheq
   ;; product
   'app-name        (cons "gPTP Studio" "gPTP Studio")
   'app-subtitle    (cons "gPTP / IEEE 802.1AS 调试工作台" "gPTP / IEEE 802.1AS debugging workstation")
   ;; nav
   'nav-overview    (cons "同步总览" "Overview")
   'nav-nics        (cons "链路与网卡" "Links & NICs")
   'nav-config      (cons "角色与配置" "Role & Config")
   'nav-source      (cons "参考源" "Reference")
   'nav-packets     (cons "报文分析" "Packets")
   'nav-runtime     (cons "运行与日志" "Runtime & Logs")
   ;; roles
   'role-grandmaster (cons "GrandMaster" "GrandMaster")
   'role-slave      (cons "从钟" "Slave")
   'role-boundary   (cons "边界时钟" "Boundary Clock")
   'role-listener   (cons "被动监听" "Listener")
   'role            (cons "角色" "Role")
   ;; overview page
   'ov-offset       (cons "主从偏移 offsetFromMaster" "Offset from master")
   'ov-delay        (cons "路径延迟 meanPathDelay" "Mean path delay")
   'ov-port-state   (cons "端口状态" "Port state")
   'ov-gm           (cons "当前 GrandMaster" "Current GrandMaster")
   'ov-freq         (cons "频差 freq" "Freq offset")
   'ov-threshold    (cons "告警阈值" "Alarm threshold")
   'ov-engine       (cons "引擎" "Engine")
   'ov-capture      (cons "抓包" "Capture")
   'ov-nostart      (cons "尚未启动。到「角色与配置」页启动引擎，或在「报文分析」页开始抓包。" "Not running. Start the engine on Role & Config, or begin capture on Packets.")
   ;; config page
   'cfg-domain      (cons "Domain" "Domain")
   'cfg-priority1   (cons "Priority1" "Priority1")
   'cfg-priority2   (cons "Priority2" "Priority2")
   'cfg-announce    (cons "Announce 周期 (log₂ 秒)" "Announce interval (log₂ s)")
   'cfg-sync        (cons "Sync 周期 (log₂ 秒)" "Sync interval (log₂ s)")
   'cfg-transport   (cons "传输模式" "Transport")
   'cfg-delay       (cons "延迟机制" "Delay mechanism")
   'cfg-iface       (cons "网卡" "Interface")
   'cfg-iface2      (cons "下游端口" "Downstream port")
   'cfg-mode        (cons "运行方式" "Run mode")
   'mode-real       (cons "真实引擎 (linuxptp)" "Real engine (linuxptp)")
   'mode-sim        (cons "模拟器" "Simulator")
   'cfg-start       (cons "启动" "Start")
   'cfg-stop        (cons "停止" "Stop")
   'cfg-preview     (cons "ptp4l.conf 预览" "ptp4l.conf preview")
   'cfg-save-preset (cons "保存为预设" "Save as preset")
   'cfg-hint-sync   (cons "-3 = 125 ms（802.1AS 典型值），0 = 1 s" "-3 = 125 ms (802.1AS typical), 0 = 1 s")
   ;; nics page
   'nic-name        (cons "网卡" "Interface")
   'nic-mac         (cons "MAC" "MAC")
   'nic-state       (cons "状态" "State")
   'nic-hwts        (cons "硬件时间戳" "HW timestamping")
   'nic-phc         (cons "PHC 设备" "PHC device")
   'nic-driver      (cons "驱动" "Driver")
   'nic-refresh     (cons "重新扫描" "Rescan")
   'nic-none        (cons "未检测到网卡" "No interfaces detected")
   'nic-sw-note     (cons "软件时间戳（精度受限：百微秒级以上）" "Software timestamps (limited precision)")
   ;; source page
   'src-title       (cons "参考源管理" "Reference source")
   'src-system      (cons "本地系统时钟" "Local system clock")
   'src-none        (cons "不使用外部参考" "No external reference")
   'src-desc        (cons "GM 模式下可将系统时钟经 phc2sys 同步进 PHC，提高授时绝对精度。" "In GM mode the system clock can feed the PHC via phc2sys for better absolute accuracy.")
   ;; packets page
   'pk-iface        (cons "抓包网卡" "Capture interface")
   'pk-start        (cons "开始抓包" "Start capture")
   'pk-stop         (cons "停止抓包" "Stop capture")
   'pk-import       (cons "导入 pcap/pcapng" "Import pcap/pcapng")
   'pk-export       (cons "导出 pcap" "Export pcap")
   'pk-clear        (cons "清空" "Clear")
   'pk-no           (cons "#" "#")
   'pk-time         (cons "时间" "Time")
   'pk-type         (cons "类型" "Type")
   'pk-seq          (cons "Seq" "Seq")
   'pk-domain       (cons "Domain" "Domain")
   'pk-src          (cons "源端口" "Source port")
   'pk-len          (cons "长度" "Length")
   'pk-detail       (cons "报文详情" "Packet detail")
   'pk-hex          (cons "原始字节" "Raw bytes")
   'pk-empty        (cons "暂无报文。启动抓包或使用模拟器。" "No packets yet. Start a capture or the simulator.")
   ;; runtime page
   'rt-processes    (cons "进程" "Processes")
   'rt-logs         (cons "聚合日志" "Aggregated logs")
   'rt-level        (cons "级别" "Level")
   'rt-source       (cons "来源" "Source")
   'rt-search       (cons "搜索…" "Search…")
   'rt-export-logs  (cons "导出日志" "Export logs")
   'rt-presets      (cons "场景预设" "Presets")
   'rt-preset-name  (cons "预设名" "Preset name")
   'rt-apply        (cons "应用" "Apply")
   'rt-delete       (cons "删除" "Delete")
   'rt-about        (cons "关于 / 许可证" "About / License")
   ;; license
   'lic-tier-free   (cons "免费版" "Free")
   'lic-tier-pro    (cons "专业版" "Pro")
   'lic-tier-trial  (cons "专业版试用" "Pro Trial")
   'lic-activate    (cons "激活许可证" "Activate license")
   'lic-trial       (cons "开始 14 天 Pro 试用" "Start 14-day Pro trial")
   'lic-deactivate  (cons "移除许可证" "Remove license")
   'lic-buy         (cons "购买 Pro" "Buy Pro")
   ;; misc
   'ms              (cons "毫秒" "ms")
   'us              (cons "微秒" "µs")
   'ns              (cons "纳秒" "ns")
   'running         (cons "运行中" "Running")
   'stopped         (cons "已停止" "Stopped")
   'confirm         (cons "确认" "OK")
   'cancel          (cons "取消" "Cancel")))

(define (i18n-dict lang)
  (for/hasheq ([(k pair) (in-hash table)])
    (values k (if (equal? lang "en") (cdr pair) (car pair)))))

(define (t lang key)
  (define pair (hash-ref table key #f))
  (if pair
      (if (equal? lang "en") (cdr pair) (car pair))
      (symbol->string key)))
