# gPTP Studio

**gPTP / IEEE 802.1AS 调试工作台——一台笔记本，三种角色，全部可见。**

[![CI](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

[English](README.md) · **中文**

调试 AUTOSAR ECU 的 gPTP（IEEE 802.1AS，EthTSyn 模块实现）今天意味着三件套拼凑：固定角色的授时仪、Wireshark、裸 `ptp4l`/`pmc` 终端。**gPTP Studio** 把它们收进一个窗口：笔记本在 **GrandMaster / 从钟 / 被动监听** 间一键切换，同步收敛过程实时成图，线上每一条 gPTP 报文就地解码——offset 突跳的那一刻，相关报文就在眼前。

基于 [Racket](https://racket-lang.org/) + [Glaze](https://github.com/turinglambdaai/glaze)（Racket 后端、原生 WebView 窗口，无 Node、无原生工具链）。

## 核心能力

- **三角色一键切换**——GrandMaster（喂时间给 ECU）、从钟（验证 ECU 的 GM 实现）、监听（纯观察）；角色与参数在表单里改，`ptp4l.conf` 实时生成可预览
- **实时同步曲线**——`offsetFromMaster` / `meanPathDelay` 跟随 Sync 速率（gPTP 约 8 Hz）刷新，超阈值红色告警 + 系统通知
- **gPTP 抓包解码**——libpcap 实时抓包（`ether proto 0x88f7`），Sync / Follow_Up / Announce / PDelay\_\* / Signalling 全字段解码（含 802.1AS follow-up info TLV），内部保留精确 sec+nsec 时间戳元数据，支持 hex、pcap/pcapng 导入和 pcap 导出
- **时间路径透明**——“网卡支持硬件时间戳 + PHC”和“当前 libpcap 实际拿到的时间戳来源”分开显示；时间戳分辨率不会被包装成已经校准过的测量精度
- **无头支持 Doctor**——`--doctor` / `--doctor-json` 无需打开 GUI 即可报告网卡、PHC、linuxptp 和权限路径，默认不输出 MAC/IP
- **内置模拟器**——合成 802.1AS 会话（真实编码帧走同一解码管道），无硬件甚至无 Linux 也能演示、测试、学习
- **场景预设**——保存角色 + 参数 + 网卡组合，一键应用；`ptp4l.conf` 一键导出
- **聚合日志**——ptp4l、phc2sys、抓包、应用事件同窗展示，级别/来源过滤，可导出
- **离线许可证**——RSA-2048 签名许可证文件，14 天 Pro 试用，机器绑定；校验走系统 `openssl` CLI（零额外依赖）

## 六页布局

| 页面 | 功能 |
|------|------|
| 同步总览 | 实时 offset/delay 曲线、端口状态、当前 GM、告警阈值 |
| 链路与网卡 | 网卡 HW timestamp / PHC 能力探测（`ethtool -T`）+ 实际抓包 timestamp path |
| 角色与配置 | 角色切换、gPTP 参数表单、`ptp4l.conf` 实时预览、启动/停止 |
| 参考源 | 系统时钟经受控 `phc2sys` 生命周期写入 PHC（Pro） |
| 报文分析 | 抓包控制、实时报文表、解码树 + 精确时间戳元数据 + hex、导入导出 |
| 运行与日志 | 进程状态、聚合日志、预设、许可证 |

## 平台支持

| 能力 | Linux | macOS |
|---|---|---|
| GM / 从钟引擎（linuxptp） | ✅ | —（无 Linux PHC / `SO_TIMESTAMPING` 控制路径） |
| 监听抓包 | ✅；运行时显示 libpcap 实际 timestamp source | 软件/主机时间戳路径 |
| 离线 pcap / pcapng 分析 | ✅ | ✅ |
| 模拟器 | ✅ | ✅ |

网卡报告支持硬件时间戳且存在 `/dev/ptpN`，只代表这台机器具备 linuxptp 所需的**能力条件**，并不等于当前 libpcap 抓包已经在使用硬件/adapter 时间戳。gPTP Studio 会把这两件事分别显示，避免误判。

## 快速开始

```bash
# Linux（调试主机）
sudo apt install linuxptp libpcap-dev ethtool iproute2
./gptp-studio                            # 启动 GUI
./gptp-studio --doctor                   # 无头环境/支持报告
./gptp-studio --doctor-json > doctor.json

# macOS（分析 + 模拟器）
open "gPTP Studio.app"
```

第一次做真机验证时，建议先在专用 Linux 调试机上使用明确的权限方式，保证 `ptp4l`、`phc2sys` 和抓包路径都能访问对应 NIC/PHC。Studio 会区分 root、文件 capability、免密 `sudo -n` 与 direct-best-effort，并在运行状态/日志中显示实际启动方式。

文件 capability 可以作为后续部署优化，但不要假定“给 `ptp4l` 执行一条固定 setcap 命令”就能覆盖所有 GM / Slave / 参考源组合；请以目标主机上真实 `ptp4l` / `phc2sys` 启动结果和日志为准。

如果一台主机与另一台表现不一致，优先运行无头 Doctor，并把默认脱敏的输出附到支持工单。详见 [docs/support-doctor.md](docs/support-doctor.md)。

从源码运行：

```bash
raco pkg install --auto --no-docs --link /path/to/glaze   # 框架依赖
raco make main.rkt
racket main.rkt                # GUI
racket main.rkt --simulator    # GUI + 合成 gPTP 会话（无需硬件）
racket main.rkt --doctor       # 无头环境/支持报告
racket main.rkt --doctor-json  # 机器可读的默认脱敏报告
racket main.rkt --selfcheck    # 无头冒烟测试（CI）
raco test tests/
```

## 版本与授权

| | 免费版 | 专业版 |
|---|---|---|
| 监听抓包 + 报文解码 | ✅ | ✅ |
| 离线 pcap 导入 | ✅ | ✅ |
| 模拟器 | ✅ | ✅ |
| 配置编辑 + `ptp4l.conf` 预览 | ✅ | ✅ |
| GM / 从钟引擎控制 | — | ✅ |
| 参考源（phc2sys） | — | ✅ |
| pcap 导出 | — | ✅ |
| 报文存储 | 2 000 帧 | 50 000 帧 |

每次安装自带 14 天 Pro 试用。定价见 [PRICING.md](PRICING.md)。

## 架构

单 Racket 进程：Glaze 经回环 HTTP 把 UI 送进原生 WebView；Linux 上的引擎监督器负责完整 `ptp4l` / `phc2sys` 生命周期，并根据环境选择 root、合适的文件 capability、免密 sudo 或 direct-best-effort 启动路径。libpcap FFI 采用非阻塞轮询，同时记录实际抓包时间戳来源/分辨率并保留精确 sec+nsec 元数据；模拟器后端继续走同一解码管道。详见 [docs/architecture.md](docs/architecture.md)，802.1AS 字段图见 [docs/protocol-reference.md](docs/protocol-reference.md)。

## 许可证

源码 Apache-2.0；分发二进制适用 [EULA.md](EULA.md)。商业授权与技术支持见 [PRICING.md](PRICING.md)。
