# gPTP Studio

**面向 Automotive Ethernet 的 Linux 原生 gPTP / IEEE 802.1AS 专业调试工作站。**

[![CI](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Linux-blue)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)
![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

[English](README.md) · **中文**

gPTP Studio 现在明确定位为 **Linux-only 产品**。原因不是 UI 能不能跨平台，而是专业 gPTP 调试真正依赖的能力集中在 Linux：**PHC、硬件时间戳、`SO_TIMESTAMPING`、linuxptp、sysfs 网卡信息以及明确可控的权限模型**。如果一个平台只能做软时间戳或离线分析，就不应该与真实 GM/Slave 调试放在同一个“正式支持平台”里。

针对 AUTOSAR EthTSyn / IEEE 802.1AS 场景，一台 Linux 工作站可以在 **GrandMaster / 从钟 / 被动监听** 三种角色之间切换，实时显示同步收敛、解码线上每一条 gPTP 报文，并把 offset 突跳与对应报文和引擎状态关联起来。

项目使用 [Racket](https://racket-lang.org/) + [Glaze](https://github.com/turinglambdaai/glaze)，桌面 UI 走 WebKitGTK，真实时间路径则交给 Linux 原生 PHC / hardware timestamp / linuxptp。

## 核心能力

- **四角色一台工作站**：GrandMaster、从钟、双端口 Boundary Clock（多接口 `ptp4l` + `phc2sys -a -r`）、被动监听，自动生成 `ptp4l.conf`
- **linuxptp 生命周期管理**：统一监督 `ptp4l`、`phc2sys`、`pmc`
- **硬件时钟资格检查**：启动真实引擎前检查 HW timestamp、PHC、驱动和权限路径
- **实时同步曲线**：`offsetFromMaster` / `meanPathDelay`、告警、端口状态
- **gPTP 抓包与完整解码**：libpcap 抓取 EtherType `0x88f7`，支持 Sync / Follow_Up / Announce / PDelay_* / Signalling、精确 sec+nsec 元数据、hex、pcap/pcapng
- **时间路径透明**：网卡“能力”与当前抓包“实际 timestamp source”分开显示，不把纳秒分辨率包装成已校准精度
- **无头 Doctor**：`--doctor` / `--doctor-json` 不打开 GUI 就能输出 NIC、PHC、linuxptp、权限和角色就绪状态，默认不输出 MAC/IP
- **内置模拟器 + 故障注入**：合成 802.1AS 帧继续走真实 encode/decode/store 管线；可注入 Sync/Announce 丢弃、Follow_Up 延迟、sequenceId 跳变与 offset 尖峰，对告警、BMCA 判读与报告做负向测试
- **GM 运行时调优**：经 `pmc GRANDMASTER_SETTINGS_NP` 在线修改 clockClass、clockAccuracy、timeSource 与 BMCA 优先级，无需重启引擎（Pro）
- **Wireshark 一键联动**：实时（gPTP 捕获过滤器）或回放保留报文；工程报告导出 JSON/Markdown
- **聚合日志与预设**：引擎、抓包、应用事件统一观察
- **离线授权**：适合内网和保密研发环境，不依赖云端许可服务

## 正式支持平台

产品契约现在只有 **Linux**。

| 项目 | 支持范围 |
|---|---|
| 首要验证发行版 | Ubuntu 22.04 LTS、Ubuntu 24.04 LTS |
| 桌面 UI | GTK 3 + WebKitGTK 4.1 |
| 真实 GM / 从钟引擎 | linuxptp（`ptp4l`、`phc2sys`、`pmc`） |
| 时间硬件 | 支持 hardware timestamp 的 NIC + PHC（`/dev/ptpN`） |
| 抓包 | libpcap，并显示运行时实际时间戳来源 |
| 官方包 | `.deb` + 可移植 `.tar.gz` |
| 其他操作系统 | 产品层面不支持 |

网卡报告支持硬件时间戳并存在 `/dev/ptpN`，只代表它具备 linuxptp 所需能力；这**不等于**已经证明端到端时间测量精度。Studio 会把硬件能力、运行时 timestamp source 与未来参考平台校准结果分别管理。

## 安装

### Debian / Ubuntu 包

```bash
sudo apt install ./gPTP-Studio-v1.2.0-linux-amd64.deb
gptp-studio --doctor
gptp-studio
```

`.deb` 会声明 Linux 运行依赖，并安装桌面入口、图标和许可证材料。安装过程**不会偷偷执行 `setcap`**，也不会自动授予 `CAP_NET_ADMIN`、`CAP_NET_RAW`、`CAP_SYS_TIME`。Doctor / Preflight 会明确告诉用户当前权限路径，由工程师自己决定系统安全配置。

### 可移植 tarball

```bash
tar -xzf gPTP-Studio-v1.2.0-linux-x64.tar.gz
cd gptp-studio-distributed
./bin/gptp-studio --doctor
./bin/gptp-studio
```

### 源码运行

```bash
sudo apt install linuxptp libpcap-dev ethtool iproute2 libcap2-bin \
  libgtk-3-dev libwebkit2gtk-4.1-dev

raco pkg install --auto --no-docs --link /path/to/glaze
raco make main.rkt
racket main.rkt --doctor
racket main.rkt --simulator
racket main.rkt
```

真机调试建议固定流程：先跑 `gptp-studio --doctor`，处理结构性 FAIL，再在 GUI 对目标接口执行 Preflight，最后才启动真实 GM/Slave。详见 [docs/support-doctor.md](docs/support-doctor.md) 与 [docs/hardware-qualification.md](docs/hardware-qualification.md)。

## 六页工作区

| 页面 | 功能 |
|---|---|
| 同步总览 | 实时 offset/delay 曲线、端口状态、当前 GM、告警阈值 |
| 链路与网卡 | NIC HW timestamp / PHC 能力 + 实际抓包 timestamp path |
| 角色与配置 | 角色切换、gPTP 参数、生成 `ptp4l.conf`、启动/停止 |
| 参考源 | `phc2sys` 参考源生命周期管理 |
| 报文分析 | 抓包、报文表、解码树、精确时间戳元数据、hex、导入导出 |
| 运行与日志 | 进程状态、日志、预设、许可证 |

## 版本与授权

| | 官方 Free | 官方 Pro |
|---|---|---|
| 监听抓包 + 报文解码 | ✅ | ✅ |
| 离线 pcap 导入 | ✅ | ✅ |
| 模拟器 | ✅ | ✅ |
| 配置编辑 + `ptp4l.conf` 预览 | ✅ | ✅ |
| GM / 从钟引擎控制 | — | ✅ |
| 参考源（`phc2sys`） | — | ✅ |
| pcap 导出 | — | ✅ |
| 报文存储 | 2,000 帧 | 50,000 帧 |

源码采用 Apache-2.0。Free / Pro 描述的是**官方分发版本**中的产品体验、更新 entitlement 与支持服务，不会撤销或缩小 Apache-2.0 已经授予的权利。自行构建或修改的 Apache-2.0 版本不自动成为官方 Pro 构建，也不附带官方更新、支持和参考平台验证承诺。

每个官方安装包自带 14 天 Pro 试用。定价见 [PRICING.md](PRICING.md)，许可模型见 [docs/licensing-model.md](docs/licensing-model.md)。

## 架构原则

一个 Racket 进程负责 Glaze/WebKitGTK UI 与产品逻辑；真正的时间路径交给 Linux 原生能力：linuxptp 子进程、PHC/hardware timestamp、libpcap。Racket/GUI 是控制面与分析面，不是纳秒时间戳产生源。详见 [docs/architecture.md](docs/architecture.md)。

## 许可证

gPTP Studio 源码以及官方分发物中受 Apache-2.0 覆盖的部分继续适用 Apache-2.0。[EULA.md](EULA.md) 约束官方 Pro entitlement、许可证凭据、官方更新/支持和官方身份关系，但不会覆盖或撤销适用的开源权利。第三方归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
