# 更新日志 / Changelog

## 1.0.0 — 2026-09-27

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
