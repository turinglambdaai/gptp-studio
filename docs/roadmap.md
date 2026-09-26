# 路线图 / Roadmap

路线图只围绕 **Linux 平台上的专业 gPTP / TSN 调试与验证能力** 展开。不会再投入 Windows/macOS 桌面端兼容工作。

## v1.1 — Linux 工程体验（已交付，v1.1.0）

- ✅ `.deb` 安装与 Ubuntu 22.04 / 24.04 双 LTS 验证
- ✅ GM 运行时调优：`pmc GRANDMASTER_SETTINGS_NP` + PRIORITY1/PRIORITY2
- ✅ 权限路径：Doctor / Preflight 识别 root / file capability / sudo-n 并给出可执行建议，安装动作不自动提权
- ✅ Wireshark 一键联动（实时 + 回放）
- ✅ Doctor 支持包导出与参考平台指纹
- ✅ 真实引擎启动失败分类与恢复建议

## v1.2 — 专业分析与负向测试（进行中）

- 报文 / 异常 / fault injection
- ✅ BMCA 演化时间轴
- ✅ offset jump ↔ packet ↔ engine-state 根因关联
- ✅ 测试报告导出（JSON / Markdown，后续 PDF）
- 多接口与 Boundary Clock 工作流

## v1.x — 参考平台与可重复性

- Certified NIC / driver / kernel matrix
- 固定 Ubuntu LTS reference image
- 主动 timing capability benchmark
- 参考平台 characterization 数据库
- 自动更新通道与签名发布
- systemd/udev/polkit 是否值得引入，以安全性和可维护性为前提评估

## v2 — Linux + 专用硬件

- TSN 802.1Qbv / Qbu 联动分析
- 双端口 inline measurement
- packet delay/drop/corruption injection
- PPS / 10 MHz 外部参考
- Automotive Ethernet 100BASE-T1 / 1000BASE-T1
- `gPTP Studio Box`：Linux appliance + 专用 HW timestamp / PHC，桌面 Studio 作为控制与分析界面

## 明确不做

- 为了“跨平台”维护功能缩水的 macOS/Windows 版本
- 用软件时间戳冒充 timing validation
- 在未经 characterization 的通用 PC/NIC 上承诺固定纳秒级精度
- 把产品扩成全功能 CANoe 替代品
