# Glaze 反哺验证报告（gPTP Studio v1.0 实测）

> 本次用 Glaze 开发了一个完整的商业级桌面应用（约 4000 行 Racket + 1500 行前端 JS）。
> 这份报告记录 Glaze 在真实项目压力下的表现：哪些能力"开箱即用"，哪些踩了坑，哪些已回馈上游。

## 结论先行

**Glaze 不是玩具。** 六页工业 UI、实时 SSE 数据流、文件对话框、系统通知、离线 RSA 许可证、
打包签名——全部在一次开发迭代中落地，没有一行 C 代码。商业化所需的顶层设施
（license / build / sys / tray）是 glaze 区别于"又一个 UI 库"的关键。

## 开箱即用（零修改）

| 能力 | 实测 |
|---|---|
| `define-api-routes` | 一处声明生成过程+路由+JS 客户端；参数校验 400 带参数名；生成过程可直接 raco test（API 层无浏览器测试） |
| SSE 事件总线 | 4 秒 26 个 packets + 26 个 series 事件稳定推送；背压丢弃策略对 UI 事件正确 |
| `api-token` 引导流 | 一次性 `?glaze-token=` URL 换 HttpOnly cookie；Webview 内 fetch 自动携带；DNS-rebinding/Host 校验默认开 |
| `webview-title/url/capture!` | 验证三件套可用（见已知问题 #2 关于遮挡场景） |
| `glaze/license` | issue → copy → validate 全链路实测通过；canonical JSON 重排不破坏验签；机器绑定/过期 reason 稳定 |
| 文件对话框 | `pick-file` / `save-file-dialog` 带扩展名过滤，导入导出 pcap 直接用 |
| `notify!` / `single-instance?` / `webview-focus!` / `webview-navigate` | 全部即插即用 |
| `run-app` | 临时端口 + token + on-ready/on-error/on-close 组装一次到位；浏览器 fallback 可用 |

## 踩坑与已回馈（Issues）

1. **#1 build-app 打包后 launcher 静默失效**（严重）：assemble-macos-bundle 产出的
   `.app` 任何参数 exit 0 且程序体不执行；`raco exe` 裸 launcher 与 distribute 扁平布局
   均正常。gPTP Studio 的 workaround（手工组装，实测可用）：`scripts/package-macos.sh`。
2. **#2 遮挡窗口疑似 AppNap 暂停前端定时器**：监测类应用需要在 open-window 阶段做
   NSProcessInfo beginActivity 豁免，或至少文档化。

## 文档/工程改进建议（未开 issue 的顺手记录）

- `raco make` 不接受目录参数，AGENTS.md 的快速命令若被照抄会在 CI 翻车（本次已在
  gptp-studio CI 修正：只传模块文件）。
- `integer-bytes->integer` 的 start/end 是字节偏移而非长度——FFI 密集场景容易踩，
  glaze 文档如有 FFI 章节可加一条提醒。
- macOS libpcap 只有旧式符号 `pcap_setnonblock`（无下划线版不存在）；任何要绑
  libpcap 的 glaze 应用都会遇到，值得写进平台注记。

## 性能体感

- 155 项测试全量 < 10 s；raco make 增量编译秒级。
- 8 Hz 模拟帧流（Sync/Follow_Up/Announce/PDelay 每秒 ~11 帧）+ 解码 + JSON 序列化
  + SSE 推送，进程 CPU 个位数百分比，内存稳定（环形缓冲封顶）。
- WebView 窗口冷启动到可用 ~2 s（官方 Racket 发行版，M2）。

## 一句话

把 Racket 桌面应用从"能写"推进到了"能卖"——差的是市场，不是框架。
