# 架构 / Architecture

gPTP Studio v1.0 —— Racket + Glaze 单进程桌面应用。

## 技术栈与选型理由

| 层 | 选型 | 理由 |
|---|---|---|
| GUI 框架 | [Glaze](https://github.com/turinglambdaai/glaze)（Racket 后端 + 系统 WebView 窗口） | 无 C 工具链、三平台、SSE 推送、内置许可证/打包/对话框；PRD 中 Racket `racket/gui` 方案已被否决（样式与产品级 UI 难以达标），Qt 绑定（bezel）尚早，Web 前端 + Racket 逻辑是当前最契合产品级 UI 的 Racket 路线 |
| 前端 | 手写 HTML/CSS/JS（零 npm、零构建、可离线） | 数据密集型工业 UI（表格、表单、实时 canvas 曲线）恰是 Web 强项；避免前端构建链 |
| PTP 引擎 | linuxptp（ptp4l / phc2sys / pmc）子进程 | 内核时间戳与 PHC 的事实标准；进程隔离避免 GPL 传染 |
| 抓包 | libpcap FFI（非阻塞轮询） | Racket CS 协作调度器禁止 FFI 长阻塞，`pcap_setnonblock` + 12 ms 轮询保证其余线程持续运行 |
| 许可证 | glaze/license（RSA-2048 经系统 openssl CLI） | 离线验签、机器绑定、零 crypto 依赖 |

## 进程与线程模型

```
gptp-studio 进程
├── glaze HTTP server（127.0.0.1，随机端口，api-token 引导 cookie）
│   ├── /            静态 UI（public/）
│   ├── /api/*       define-api-routes 生成的 JSON API
│   └── /glaze/events SSE（事件总线 → 前端实时刷新）
├── WebView 窗口（macOS WKWebView / Linux WebKitGTK）
├── 引擎监督器（engine/supervisor.rkt）
│   ├── real 模式：ptp4l 子进程（sudo -n 策略）+ stdout 解析线程 + 退出自愈线程
│   ├── sim 模式：125 ms tick 线程，合成帧走真实解码管道
│   └── 状态机：mode × role × port-state × gm-id × offset/delay
├── 抓包管理器（capture/manager.rkt）：libpcap 句柄 + 轮询线程 + 批量 SSE
└── 数据层：series（21600 点环形）、packet store（2k/50k）、logstore（8000）
```

## 数据流（以从钟模式为例）

```
ptp4l -m stdout ──parse──▶ offset/delay 事件 ──▶ series 环形缓冲 ──▶ SSE 'series ──▶ canvas 曲线
                                             │
                                             └─▶ 状态机 / 告警
libpcap (0x88f7) ──decode──▶ 报文环形存储 ──批量──▶ SSE 'packets ──▶ 报文表 / 详情
pmc（手动对照）──parse──▶ CURRENT_DATA_SET 快照（与曲线逐项核对）
```

模拟器（sim 模式）从 `make-sim-frames` 编码真实以太网帧开始，进入同一条 decode → store → SSE 管线，保证演示数据与实测数据同构。

## 关键设计决策

1. **FFI 不阻塞**：libpcap 全部调用走非阻塞/立即返回（`pcap_setnonblock` + `pcap_next_ex` 轮询），任何 C 调用都在微秒级返回——协作调度器（Racket CS）下其余 Racket 线程持续运行。
2. **模拟器即测试装置**：编码器（proto/encode）与解码器（proto/decode）互为 golden test；模拟器帧就是编码器产物，无第二条数据通路。
3. **权限策略**：root 直启；否则 `sudo -n`（免密 sudo/CI 可用）；失败在 0.8 s 内快速失败并给出可操作指引（visudo 一行 / setcap）。polkit 提权在路线图。
4. **角色切换 = 引擎重启**（linuxptp 的 slaveOnly/gmCapable 是启动期配置）；GM 期的 priority/clockClass 运行时调优计划走 pmc `GRANDMASTER_SETTINGS_NP`。
5. **macOS 定位**（沿 PRD）：监听（软时间戳）/ 离线分析 / 模拟器；引擎控制仅 Linux。

## 平台矩阵

| 能力 | Linux | macOS | Windows |
|---|---|---|---|
| GM/从钟引擎 | ✅ | —（无 SO_TIMESTAMPING/PHC） | 计划：UI 层已就绪（glaze WebView2），引擎待评估 OpenAvnu |
| 监听抓包 | ✅ HW | ✅ SW | 待评估（npcap） |
| 离线分析 / 模拟器 | ✅ | ✅ | 待验证 |
