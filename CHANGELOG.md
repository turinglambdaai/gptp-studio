# 更新日志 / Changelog

## 1.1.0 — 2026-09-26

Linux 专业 timing 工作站版本：产品契约收敛为 Linux-only，v1.1 路线图（Linux 工程体验）全部交付。

### 新增 — 引擎可靠性与诊断

- 真实引擎强制 Preflight：硬件时间戳/PHC/权限路径未达标时阻止 ptp4l 启动；被拒会话不误伤运行中的健康会话
- 引擎启动失败分类：从 ptp4l/phc2sys stderr 证据给出结构化原因与恢复建议，运行页直接展示
- 无头支持 Doctor：`--doctor` / `--doctor-json` 报告 NIC/PHC/linuxptp/权限就绪度，MAC/IP 默认脱敏
- Linux timing host 质量提示（clocksource/虚拟化等，advisory）与可复现参考平台指纹（发行版/内核/驱动/固件/PCI）
- GUI 参考平台卡片：同一脱敏事实的界面化展示与快照复制

### 新增 — 专业分析

- offset jump ↔ 报文 ↔ 引擎状态根因关联：跳变时刻附近回看 Sync/Follow_Up/PDelay/Announce 证据
- 观测性 BMCA 演化时间轴：基于捕获 Announce 的候选 GM 演化，不替代协议本身判定
- 工程报告导出：JSON / Markdown，同步曲线统计、跳变观测、报文统计、BMCA 候选、脱敏 NIC 清单、ptp4l.conf 与日志（明确 not-calibrated 与 observational 声明）
- 报文快照路径限制解析与防护

### 新增 — 运行时调优与联动

- GM 运行时调优：`pmc SET GRANDMASTER_SETTINGS_NP`（clockClass/clockAccuracy/offsetScaledLogVariance/currentUtcOffset/leap 标志/timeSource）+ PRIORITY1/PRIORITY2，不重启引擎；GET 后覆盖式合并，兼容 linuxptp 3.1.x 与新版输出格式；Pro 功能
- Wireshark 一键联动：实时（同网卡 gPTP 捕获过滤器并行抓包）与回放（保留报文写临时 pcap 后打开，随 pcap 导出走 Pro 门控）；分离启动，关闭 Studio 不影响 Wireshark

### 打包与分发

- Linux-only 产品契约：不再维护功能缩水的桌面移植
- 可复现构建 + Debian 包 CI 安装实测（Ubuntu 22.04 / 24.04 双 LTS）；tarball 与 .deb 带 sha256
- 许可对齐：Apache-2.0 源码 / EULA 官方分发条款 / THIRD_PARTY_NOTICES

### 质量

- 测试 396 项（协议、配置、pcap 往返、诊断、资格判定、指纹、报告、调优、Wireshark、许可证门控）
- CI 双 LTS 全绿：编译 / 测试 / selfcheck / doctor 断言 / 包冒烟 / 安装卸载与用户数据保留验证

### 已知限制

- 角色切换仍需重启引擎（设计取舍：会话状态一致性优先）
- 报文/异常 fault injection 与多接口 Boundary Clock 工作流在 v1.2 路线图
- Wireshark 联动需要本机安装 wireshark（Doctor 与按钮都会给出安装指引）

## 1.0.0 — 2026-09-16

gPTP Studio 首个商业级版本。Racket + Glaze 全面重写（原型 v0.2 的 `racket/gui` 路线终止，代码保留于 `v0.2.0-racket-prototype` tag）。

### 新增

- 六页工业蓝 UI：同步总览 / 链路与网卡 / 角色与配置 / 参考源 / 报文分析 / 运行与日志
- IEEE 1588-2008 / 802.1AS 全字段解码器：Sync、Follow_Up（含 802.1AS follow-up info TLV）、Announce、PDelay_\*、Signalling、Management；L2 与 UDPv4 传输；VLAN；pcap/pcapng 离线导入
- 三角色引擎：GrandMaster / 从钟（linuxptp 子进程监督、`sudo -n` 快速失败、自动重启）/ 被动监听
- gPTP 参数表单 → `ptp4l.conf` 实时生成预览（对齐 linuxptp 官方 gPTP.cfg 剖面）
- libpcap FFI 实时抓包（非阻塞轮询，协作调度器安全）+ 报文环形存储 + 批量 SSE 推送
- 内置 gPTP 模拟器：真实编码帧走同一解码管道（GM / 从钟 / 监听三剧本）
- 实时 offset / meanPathDelay 曲线 + 告警阈值 + 系统通知
- 场景预设（保存/应用/删除）、聚合日志（过滤/导出）、pmc 对照查询
- 商业化层：RSA-2048 离线许可证（机器绑定）、14 天 Pro 试用、Free/Pro 功能门控
- 打包：macOS .app（含图标 + adhoc 签名）、Linux tarball；GitHub Actions CI + Release
- i18n 中/英双语

### 质量

- 155 项测试全绿（协议 golden、配置生成、pcap 往返、解析器、数据结构、许可证门控）
- 无头自检（`--selfcheck`）覆盖静态页 + bootstrap + conf API

### 已知限制

- macOS 无 GM/从钟引擎（linuxptp 依赖内核 SO_TIMESTAMPING/PHC，平台性质限制）
- 角色切换需重启引擎；GM 运行时调优（pmc GRANDMASTER_SETTINGS_NP）在路线图
- Windows：UI 栈已就绪，引擎与抓包待评估（npcap / OpenAvnu）
