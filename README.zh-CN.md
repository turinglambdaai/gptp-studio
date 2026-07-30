# RTimeServer

基于 [Racket](https://racket-lang.org/) 开发的跨平台 gPTP (IEEE 802.1AS) 调试工具。提供图形化界面，用于配置 PTP 参数、监控时间同步状态、抓取和分析 PTP 报文，以及查看运行日志与同步精度统计。

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

[English](README.md) · **中文**

## 功能特性

- **参数配置** — 传输模式（IEEE 802.3 / UDP IPv4）、Profile（gPTP / PTPv2）、Domain 编号、Announce/Sync 发送周期
- **同步监控** — 实时显示 Master-Slave 同步状态、时钟偏移量、路径延迟、邻居速率比
- **报文分析** — 抓取并解析 PTP 报文（Sync、Follow_Up、Announce、PDelay、Signalling），逐字段展示
- **日志统计** — 运行日志记录、同步精度滑动窗口统计（均值 / 极值 / 标准差）
- **中英双语界面** — 支持中文和英文切换

## 架构

```
+-------------------------------------------+
|              GUI (Racket/gui)              |
|  配置   |  监控   |  抓包   |  日志       |
+-------------------------------------------+
|              核心引擎                      |
|  状态  |  定时器  |  统计  |  国际化      |
+---------------------+---------------------+
|     协议层          |      网络层          |
|  类型 / 解析器      |  Socket / 抓包       |
|  常量               |  网卡 / 发送器       |
+---------------------+---------------------+
```

详细架构设计见 [docs/architecture.md](docs/architecture.md)。

## 项目结构

```
rtimeserver/
├── main.rkt                 应用入口
├── info.rkt                 包元数据
├── rtimeserver/
│   ├── config.rkt           全局配置
│   ├── i18n.rkt             国际化（中/英）
│   ├── gui/
│   │   ├── main-frame.rkt   主窗口
│   │   ├── config-panel.rkt PTP 参数设置
│   │   ├── monitor-panel.rkt 同步监控
│   │   ├── capture-panel.rkt 报文抓取
│   │   ├── log-panel.rkt    日志查看
│   │   ├── nav-panel.rkt    导航
│   │   └── settings-panel.rkt 应用设置
│   ├── protocol/
│   │   ├── constants.rkt    IEEE 1588 / 802.1AS 常量
│   │   ├── types.rkt        PTP 数据类型与时间戳
│   │   ├── header.rkt       公共头解析
│   │   ├── parser.rkt       报文解析分发器
│   │   ├── sync.rkt         Sync 报文
│   │   ├── follow-up.rkt    Follow_Up 报文
│   │   ├── announce.rkt     Announce 报文
│   │   ├── pdelay.rkt       PDelay 报文
│   │   └── signalling.rkt   Signalling 报文
│   ├── network/
│   │   ├── socket.rkt       Raw socket 抽象
│   │   ├── capture.rkt      报文抓取（libpcap/Npcap）
│   │   ├── interface.rkt    网卡检测
│   │   └── sender.rkt       PTP 报文发送
│   └── core/
│       ├── engine.rkt       PTP 引擎（配置、状态、启动）
│       ├── state.rkt        全局状态管理
│       ├── timer.rkt        PTP 定时
│       └── stats.rkt        同步精度统计
├── tests/
│   ├── test-config.rkt
│   ├── test-i18n.rkt
│   └── test-protocol.rkt
└── docs/
    ├── architecture.md
    ├── development.md
    ├── protocol-reference.md
    └── roadmap.md
```

## 环境要求

| 依赖 | 用途 |
|------|------|
| [Racket](https://download.racket-lang.org/) 8.x | 语言运行时 / 构建工具链 |
| **Windows**：[Npcap](https://npcap.com/) | 报文抓取 |
| **Linux**：`libpcap-dev`（`sudo apt install libpcap-dev`） | 报文抓取 |
| **macOS**：libpcap（系统自带） | 报文抓取 |

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/turinglambdaai/rtimeserver.git
cd rtimeserver
```

### 2. 运行

```bash
racket main.rkt
```

### 安装为 Racket 包

```bash
raco pkg install ./rtimeserver
```

### 运行测试

```bash
raco test tests/
```

## 开发

参见 [docs/development.md](docs/development.md) 了解开发环境搭建、模块接口规范和贡献流程。

## 路线图

参见 [docs/roadmap.md](docs/roadmap.md)。

## 许可证

基于 [Apache License 2.0](LICENSE) 开源。
