# 架构 / Architecture

gPTP Studio 是一个 **Linux-only 的 gPTP / IEEE 802.1AS 专业调试工作站**。Racket + Glaze 负责控制面、可视化和工作流，真正的时间路径由 Linux 内核、NIC hardware timestamp、PHC 与 linuxptp 提供。

## 为什么只支持 Linux

这不是 GUI 技术限制，而是产品能力边界。真实 GM/Slave 调试依赖：

- `SO_TIMESTAMPING` 与网卡硬件时间戳；
- PTP Hardware Clock（`/dev/ptpN`）；
- linuxptp：`ptp4l` / `phc2sys` / `pmc`；
- `/sys/class/net`、`ethtool -T`、`ip` 等可观察接口；
- `CAP_NET_RAW`、`CAP_NET_ADMIN`、`CAP_SYS_TIME` 等 Linux 权限模型；
- 可重复的 Ubuntu LTS 参考平台。

因此项目不再维护“只能软时间戳/离线分析”的其他桌面平台分支。所有 CI、Release、安装与产品支持都围绕 Linux 收敛。

## 技术栈

| 层 | 选型 | 角色 |
|---|---|---|
| 桌面 UI | Glaze + WebKitGTK | 工业 UI、SSE、API、窗口生命周期 |
| 前端 | 手写 HTML/CSS/JS | 实时曲线、表格、配置、报文分析 |
| PTP 引擎 | linuxptp | `ptp4l` / `phc2sys` / `pmc` 的真实时钟控制 |
| 时间硬件 | NIC HW timestamp + PHC | 产生/承载时间戳；Racket 不参与时间戳生成 |
| 抓包 | libpcap FFI | gPTP 帧捕获与 timestamp source 观测 |
| 主机探测 | sysfs + ethtool + iproute2 | NIC、driver、link、PHC、HW timestamp 能力 |
| 权限 | root / file capabilities / sudo-n | 明确可观测的启动路径，不在安装时偷偷提权 |
| 包管理 | `.deb` + tar.gz | Ubuntu LTS 安装与可移植部署 |
| 许可证 | glaze/license + openssl CLI | 离线授权 |

## 进程与线程模型

```text
gptp-studio
├── Glaze HTTP server (127.0.0.1)
│   ├── static UI
│   ├── /api/*
│   └── SSE event bus
├── WebKitGTK window
├── engine supervisor
│   ├── ptp4l
│   ├── phc2sys
│   ├── pmc probes
│   └── simulator thread
├── libpcap capture manager
├── Linux qualification / Doctor
└── series / packets / logs / presets
```

## 数据流

```text
NIC/PHY hardware timestamp
        │
        ▼
       PHC ───────────────┐
        │                 │
     ptp4l             libpcap
        │                 │
 offset/delay/state     gPTP frames
        │                 │
        └──────┬──────────┘
               ▼
          Racket backend
               │
        stores / analysis / SSE
               │
               ▼
          WebKitGTK UI
```

这里最重要的边界是：**Racket/Glaze 不承担纳秒级时间戳生成任务**。它们负责配置、监督、解析、关联和展示；时间事实来自 NIC/PHC/linuxptp。

## 启动安全模型

真实 GM/Slave 启动前，Supervisor 必须重新执行 qualification：

1. 目标接口存在；
2. NIC 明确支持 TX/RX hardware timestamp；
3. PHC 存在；
4. `ptp4l` 等角色所需工具存在；
5. 角色需要的权限路径可解释；
6. GM 使用 system reference 时额外检查 `phc2sys` / `CAP_SYS_TIME`。

结构性 FAIL 在 spawn 之前阻止启动；link down 等现场状态只产生 VERIFY/WARN，允许先启动等待对端。

## 权限原则

官方包不会在 `postinst` 中自动执行 `setcap`、修改 sudoers 或授予时钟写权限。Doctor 与 GUI Preflight 显示当前路径：

- root；
- `ptp4l` / `phc2sys` file capabilities；
- passwordless `sudo -n`；
- direct-best-effort / VERIFY。

这样产品不会为了“安装方便”偷偷改变调试主机的安全边界。

## 分发与验证

- CI：Ubuntu 22.04 LTS + Ubuntu 24.04 LTS；
- Release 构建基线：Ubuntu 22.04，降低运行时兼容风险；
- 产物：relocatable tarball + Debian `.deb`；
- 两类产物都必须通过 `--version`、`--selfcheck`、`--doctor-json` 与许可材料 smoke test；
- `.deb` 还必须通过 metadata、desktop entry、icon 与 dependency 声明检查。

## 精度声明边界

`READY`、`/dev/ptpN`、hardware timestamp、1 ns resolution 都不是校准后的“精度指标”。产品必须区分：

1. **capability**：硬件/驱动是否支持；
2. **runtime path**：实际 timestamp source / PHC / linuxptp 是否正在使用；
3. **characterization**：在固定参考平台上经过外部仪器测得的统计结果；
4. **specification**：只有经过可重复校准/验证后才能发布的产品级指标。

参考 [hardware-qualification.md](hardware-qualification.md)。
