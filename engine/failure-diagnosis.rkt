#lang racket/base

;; Classify startup failures from linuxptp stderr. This module is pure and
;; deliberately evidence-driven: it never guesses from exit code alone when a
;; recognizable stderr signature is available.

(require racket/list
         racket/string)

(provide diagnose-linuxptp-failure
         failure-diagnosis->message)

(define (normalized-lines text)
  (for/list ([line (in-list (string-split (or text "") "\n"))]
             #:when (not (string=? (string-trim line) "")))
    (string-trim line)))

(define (first-matching-line lines patterns)
  (for*/first ([line (in-list lines)]
               [rx (in-list patterns)]
               #:when (regexp-match? rx line))
    line))

(define (diagnosis kind title summary actions evidence exit-code launch-mode)
  (hasheq 'kind kind
          'title title
          'summary summary
          'actions actions
          'evidence (or evidence "")
          'exit_code exit-code
          'launch_mode (if (symbol? launch-mode)
                           (symbol->string launch-mode)
                           (format "~a" launch-mode))))

(define permission-patterns
  (list #px"(?i:operation not permitted)"
        #px"(?i:permission denied)"
        #px"(?i:not permitted)"))

(define timestamp-patterns
  (list #px"(?i:does not support requested timestamping mode)"
        #px"(?i:hardware time stamping.*not supported)"
        #px"(?i:SIOCSHWTSTAMP.*(invalid argument|not supported))"
        #px"(?i:timestamping mode.*not supported)"))

(define interface-patterns
  (list #px"(?i:no such device)"
        #px"(?i:cannot find device)"
        #px"(?i:interface .* (not found|does not exist))"
        #px"(?i:failed to get interface index)"))

(define phc-patterns
  (list #px"(?i:ptp device not specified)"
        #px"(?i:bad ptp device string)"
        #px"(?i:failed to open .*ptp[0-9]+)"
        #px"(?i:cannot open .*ptp[0-9]+)"
        #px"(?i:clock_open.*failed)"))

(define socket-patterns
  (list #px"(?i:address already in use)"
        #px"(?i:bind.*failed)"
        #px"(?i:failed to bind)"
        #px"(?i:uds.*(busy|in use|bind))"))

(define config-patterns
  (list #px"(?i:unknown option)"
        #px"(?i:bad value)"
        #px"(?i:failed to parse)"
        #px"(?i:configuration.*(invalid|error))"
        #px"(?i:config item.*(invalid|bad))"))

(define clock-create-patterns
  (list #px"(?i:failed to create a clock)"
        #px"(?i:failed to generate a clock identity)"))

(define (diagnose-linuxptp-failure process stderr-text exit-code launch-mode)
  (define lines (normalized-lines stderr-text))
  (define (match patterns) (first-matching-line lines patterns))
  (define permission (match permission-patterns))
  (define timestamp (match timestamp-patterns))
  (define interface (match interface-patterns))
  (define phc (match phc-patterns))
  (define socket (match socket-patterns))
  (define config (match config-patterns))
  (define clock-create (match clock-create-patterns))
  (cond
    [permission
     (diagnosis
      "permission"
      "权限不足"
      (format "~a 无法获得当前时钟/网络操作所需权限。" process)
      (list "先运行 gptp-studio --doctor 确认实际 privilege path。"
            "检查 ptp4l/phc2sys 的 file capability，或使用明确的 root / sudo-n 策略重试。"
            "不要通过安装脚本自动扩大权限；应由调试主机管理员显式配置。")
      permission exit-code launch-mode)]
    [timestamp
     (diagnosis
      "hardware-timestamping"
      "硬件时间戳模式不可用"
      "网卡/驱动拒绝了 linuxptp 请求的硬件时间戳模式。"
      (list "运行 ethtool -T <iface>，确认同时存在 TX_HARDWARE、RX_HARDWARE 与 PHC。"
            "在 Studio 的 Links & NICs / Preflight 中确认当前接口不是软件时间戳路径。"
            "核对驱动、固件和 PCI/subsystem ID；相同营销型号不代表时间戳能力相同。")
      timestamp exit-code launch-mode)]
    [interface
     (diagnosis
      "interface"
      "网卡不存在或已变化"
      "linuxptp 无法打开所选网络接口。"
      (list "重新扫描 Links & NICs，并重新选择当前存在的物理接口。"
            "检查接口是否因 USB/PCI 热插拔、重命名或 NetworkManager 规则发生变化。")
      interface exit-code launch-mode)]
    [phc
     (diagnosis
      "phc"
      "PHC 不可用"
      "linuxptp 无法解析或打开所需的 PTP Hardware Clock。"
      (list "运行 ethtool -T <iface> 并确认 PTP Hardware Clock 映射。"
            "确认对应 /dev/ptpN 存在，并用 Doctor 对比 driver/firmware/PHC clock_name。"
            "如果 PHC 编号在重启或换卡后改变，请重新扫描接口，不要缓存 /dev/ptpN。")
      phc exit-code launch-mode)]
    [socket
     (diagnosis
      "ownership-conflict"
      "已有进程占用 timing 资源"
      "linuxptp 创建管理 socket 或绑定资源时发生冲突。"
      (list "运行 gptp-studio --doctor 查看 active ptp4l/phc2sys/timemaster 服务。"
            "检查是否已有 Studio 实例、systemd PTP 服务或手工启动的 linuxptp 进程。"
            "确认没有两个控制器同时管理同一 NIC/PHC 后再启动。")
      socket exit-code launch-mode)]
    [config
     (diagnosis
      "configuration"
      "linuxptp 配置无效"
      "ptp4l/phc2sys 拒绝了生成的配置或参数。"
      (list "复制并保存 Studio 生成的 ptp4l.conf 与诊断包。"
            "记录 linuxptp 版本；不同发行版版本可能支持不同配置项。"
            "把 stderr evidence 与配置一起提交问题，避免只提供退出码。")
      config exit-code launch-mode)]
    [clock-create
     (diagnosis
      "clock-create"
      "PTP 时钟实例创建失败"
      "ptp4l 在创建本地 PTP clock 时失败；该信息通常是前置错误的汇总。"
      (list "向前查看同一启动阶段更早的 stderr，优先处理 timestamping/PHC/permission 错误。"
            "运行 gptp-studio --doctor 并保存网卡 driver/firmware/PHC 指纹。")
      clock-create exit-code launch-mode)]
    [else
     (diagnosis
      "unknown"
      "linuxptp 启动失败"
      (format "~a 在启动阶段退出，但 stderr 没有命中已知分类。" process)
      (list "导出诊断快照，并附上本次启动的 stderr 与退出码。"
            "运行 gptp-studio --doctor，对比另一台可工作的 Linux 主机。")
      (and (pair? lines) (last lines)) exit-code launch-mode)]))

(define (failure-diagnosis->message d)
  (define evidence (hash-ref d 'evidence ""))
  (define actions (hash-ref d 'actions '()))
  (string-append
   (format "~a：~a"
           (hash-ref d 'title "linuxptp 启动失败")
           (hash-ref d 'summary ""))
   (format "（rc=~a，方式=~a）"
           (hash-ref d 'exit_code "unknown")
           (hash-ref d 'launch_mode "unknown"))
   (if (string=? evidence "") "" (format " 证据：~a" evidence))
   (if (null? actions)
       ""
       (format " 建议：~a" (string-join actions "；")))))
