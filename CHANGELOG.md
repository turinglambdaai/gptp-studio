# 更新日志 / Changelog

## 1.1.0 — 2026-10-09


### 新增

- **更新清单由 CI 自动签名发布**：Release 工作流在发布资产构建完成后，用本次构建的
  确切字节重新生成 `latest.json`（摘要 + Ed25519 签名），以 `feed: <版本>` 提交回主分支
  ——清单版本号最后落位，旧安装的更新检查由这一提交触发。签名私钥经 GitHub Actions
  加密密钥注入，作业内先校验其与仓库内置公钥同源，写入后再用固定公钥回验；
  新增 `scripts/make-latest-json.rkt`，CI 与手动重建清单共用同一签名实现。
- **控件文字随字型度量自适应**：语言选择器与按钮改用 `min-height` + 行内弹性居中，
  CJK 回退字体行高更大时，字形下半不再被固定高度裁切（同一样式的潜在隐患一并消除）。

### 修复

- **矮窗口下侧栏底部语言切换被裁切**：首次修复只让侧栏整体可滚动，导航内容一长，
  选择器仍悬在底边外只露一半。现在导航链接走独立滚动区域、footer 固定其下，
  任何窗口高度下语言切换完整可见（460-720px 高度逐一验证）。
- **更新清单摘要/签名与发布资产不一致**：清单一律由 CI 从发布的确切资产构建，
  不再依赖本地手工签名——v1.0.0 曾因此返工一次（本地构建与 CI 构建字节不同，
  摘要、签名对不上，更新器正确拒绝）。


## 1.0.0 — 2026-09-29


### 新增

- **在线更新检查**：启动后在后台线程取一次版本清单（`latest.json`，仓库主分支托管；
  `GPTP_UPDATE_MANIFEST_URL` 可指向自建清单），发现新版本时日志记录一条并在顶栏显示
  橙色 `⬇ 版本号` 胶囊（点击打开发布页）。产品是系统 deb，**不做自动安装**——装什么
  由操作者决定，与打包脚本"不在操作者背后动权限"的立场一致。`--no-update-check` 可
  完全关闭这一网络接触；检查失败静默降级，绝不阻塞启动。检查结果随 `/api/bootstrap`
  下发，页面刷新后胶囊不再丢失（SSE 广播是即发即忘的，不重放）。
- **Preflight 摘要随界面语言输出**：后端按当前语言设置生成摘要句
  （`qualify-interface`/`qualify-ports` 新增 `#:lang`），并同时返回双语文本
  （`summary_zh`/`summary_en`），前端切换语言时用缓存结果即时翻转，无需重跑 Preflight。

### 修复

- **语言选择器被窗口边缘裁切一半**：侧栏底部放的是中/英文切换，但侧栏没有滚动兜底、
  footer 又用 `margin-top:auto` 钉死在底边——内容一旦高过视口（原生 WebKitGTK 字体度量
  或窗口偏矮时），选择器就被齐边切掉且无法滚到。侧栏现在可滚动（`overflow-y:auto` +
  `min-height:0`），footer 增加 12px 底部留白。
- **切换语言后约 70 处界面文字不跟随**：语言切换只刷新 `data-i18n` 静态元素并重取字典，
  既不更新 `S.lang`（各功能模块的 `langZh()` 分支全部读旧值），也不通知 JS 生成的控件。
  现在切换时更新 `S.lang` 并广播 `gptp:lang` 事件，全部功能模块（时间证据、BMCA 时间线、
  会话按钮、参考源状态、报文工具）监听刷新；静态文案的 `data-i18n` 覆盖补齐到所有页面
  （状态卡、快捷键、调试快照、Preflight、参考平台、报文分析、运行与日志、许可证卡），
  JS 拼装的动态值（引擎模式、报文统计、NIC 评级、参考源状态机）同步走字典；
  页面导航时补一次字典应用（懒创建的卡片不再错过翻译）。
  常规操作路径的全部 toast（会话启动/停止、复制、错误提示）、悬停提示（NIC 评级、
  工具缺失、权限路径）与报文健康指标说明同步双语化。
  剩余 3 处为设计内/数据类：语言选择器自身的"中文"选项名，以及引擎日志原文
  （证据数据保持原样）。
- **`/api/debug/capture`（新增）**：走 glaze `webview-capture!` 输出原生窗口 PNG——
  浏览器回退的字体度量与原生窗口不同，headless 视觉验收必须拍原生窗口；本次两个
  UI 缺陷即由它定位。（注意：Wayland 会话下 gdk 抓屏返回全黑，需 `GDK_BACKEND=x11`
  运行；已按 glaze 的 agent 验证工作流使用。）

### 修复（上一批，随 v1.0.0 复审发现）

- **Ubuntu/Debian 上安装 deb 后无法启动**：`capture/live` 的 libpcap FFI 只尝试
  `libpcap.so.1`（Fedora/Arch 的 soname），而 Debian/Ubuntu 出于 ABI 历史原因提供
  `libpcap.so.0.8`——deb 声明的 `libpcap0.8` 依赖装了，加载仍然失败，且该 FFI 调用
  在模块顶层，连 `--version`/`--doctor` 都会崩溃。现在按候选序尝试多家族 soname
  （`1`/`0.8`/无版本），并把 libpcap 缺失降级为可诊断的能力缺口
  （`capture-supported?` = #f + `capture-unsupported-reason`），启动路径不再受影响。
- **原生窗口无法打开（deb 第二个缺陷）**：WebView 后端模块 `glaze/webview/webview-linux`
  只被 glaze 调度层在运行时 `dynamic-require`，`raco exe` 的静态分析看不到，打包时
  未被嵌入——应用能启动、headless 冒烟全过，但原生窗口报
  "collection not found"。构建脚本现在显式嵌入三个按平台调度的后端
  （webview/sys/tray），`--selfcheck` 新增 webview 后端模块加载检查作为回归门。
  （同样的机制性问题已在 glaze 上游修复：`build-app` 自动 `++lib`，
  见 glaze 仓库 CHANGELOG。）
- **首次改动配置即损坏 ptp4l.conf**：`api/params/merge` 用 `-999`/`""` 表示"字段未
  提供"，但这些哨兵值被直接写进参数模型——页面上第一次表单变更后 conf 预览即出现
  `transportSpecific 0x-3e7`、空 MAC 等，所有引擎启动被校验拒绝。哨兵值不再下发。
  `--selfcheck` 新增对应回归检查。
- **启动过引擎后 bootstrap 500、UI 丢失全部状态**：引擎状态的 `port_states`/`faults`
  以端口号（整数）为键，而 jsexpr 只接受符号键——一次引擎会话之后每个
  `/api/bootstrap` 都报 "expected legal JSON key value"。状态投影现在把键规范化为
  符号（JSON 传输层呈现为字符串），并以 equal 哈希返回（eq 哈希上的字符串键无法再
  查找）。supervisor 测试新增 jsexpr 合法性断言。
- **`--simulator` 引导路径静默失效**：boundary clock 支持加入后 `engine-start` 变为
  4 参数，引导代码仍按 3 参数调用——arity 错误只进了日志。已修复。


gPTP Studio 首个正式版：**Linux 原生 gPTP / IEEE 802.1AS 调试工作站**（Automotive Ethernet）。

产品契约为 Linux-only：专业 gPTP 工作依赖 PHC、硬件时间戳、`SO_TIMESTAMPING`、linuxptp、sysfs 网卡自省与显式权限控制，本产品不维护功能缩水的桌面移植。本版本即该方向下的第一个发布。

### 引擎

- 四角色：GrandMaster、从钟、双端口 Boundary Clock（`ptp4l -i <上游> -i <下游>` + `phc2sys -a -r -w` 共享 UDS、`boundary_clock_jbod 0`）、被动 Listener
- linuxptp 子进程监督：自动重启（限次）、参考源生命周期（GM: `phc2sys` CLOCK_REALTIME → PHC）
- 真实引擎强制 Preflight：硬件时间戳/PHC/权限路径逐口判定（BC 带端口号），不达标阻止启动；被拒会话不误伤运行中的健康会话
- 启动失败分类：从 ptp4l/phc2sys stderr 证据给出结构化原因与恢复建议
- GM 运行时调优：`pmc SET GRANDMASTER_SETTINGS_NP`（clockClass/clockAccuracy/offsetScaledLogVariance/currentUtcOffset/leap 标志/timeSource）+ PRIORITY1/PRIORITY2，不重启引擎；兼容 linuxptp 3.1.x 与 4.x 输出格式（Pro）

### 分析与诊断

- IEEE 1588-2008 / 802.1AS 全字段解码：Sync、Follow_Up（含 802.1AS follow-up info TLV）、Announce、PDelay_*、Signalling、Management；L2 与 UDPv4；VLAN；pcap/pcapng 导入
- libpcap 实时抓包（非阻塞轮询）+ 报文环形存储 + 批量 SSE；抓包时间戳来源与 NIC 能力分开显示
- 实时 offset / meanPathDelay 曲线、告警阈值、系统通知
- offset jump ↔ 报文 ↔ 引擎状态根因关联；观测性 BMCA 演化时间轴
- 工程报告导出：JSON / Markdown（同步统计、跳变观测、BMCA 候选、脱敏 NIC 清单、ptp4l.conf、日志；明确 not-calibrated / observational 声明）
- 无头 Doctor：`--doctor` / `--doctor-json`；Linux timing host 质量提示；可复现参考平台指纹（GUI 卡片 + 快照复制）
- Wireshark 一键联动：实时（gPTP 捕获过滤器并行抓包，Free）与回放（保留报文开临时 pcap，随 pcap 导出 Pro）；分离启动，关闭 Studio 不影响 Wireshark

### 模拟器与负向测试

- 内置 gPTP 模拟器（GM / 从钟 / 监听 / Boundary 四剧本）：真实编码帧走同一 encode/decode/store 管道
- 故障注入：Sync/Announce 按比例丢弃（孤儿 Follow_Up、BMCA 断档）、Follow_Up 时间戳延迟、sequenceId 跳变、offset 尖峰——负向验证告警、BMCA 判读与报告（Free）

### 商业化与打包

- RSA-2048 离线许可证（机器绑定）、14 天 Pro 试用、Free/Pro 功能门控
- 可复现构建：Debian 包 + relocatable tarball + sha256；Ubuntu 22.04 / 24.04 双 LTS CI（编译/测试/selfcheck/doctor 断言/包冒烟/安装卸载与用户数据保留）
- i18n 中/英双语；产品站 gptp-studio.jrtx.site

### 质量

- 440 项测试（协议 golden、配置生成、pcap 往返、诊断、逐口资格、报告、调优、Wireshark、故障注入、许可证门控）
- 源码 Apache-2.0；官方分发条款见 EULA

### 已知限制

- 角色切换仍需重启引擎（会话状态一致性优先）
- Wireshark 联动需要本机安装 wireshark（Doctor 与按钮给出安装指引）
- 真实引擎注入（delay/drop/corruption）与 TSN/Qbv 联动在 v2 专用硬件路线
