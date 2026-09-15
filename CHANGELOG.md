# 更新日志 / Changelog

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
