# Glaze 反哺验证报告（历史记录）

> 本文记录 gPTP Studio 早期使用 Glaze 验证桌面框架时的历史结果，其中包含当时对 macOS/WebKit 的实验记录。**它不再代表 gPTP Studio 的产品支持矩阵。当前产品只正式支持 Linux。**

> 本次用 Glaze 开发了一个完整的商业级桌面应用（约 4000 行 Racket + 1500 行前端 JS）。
> 这份报告记录 Glaze 在真实项目压力下的表现：哪些能力"开箱即用"，哪些踩了坑，哪些已回馈上游。

## 结论先行

**Glaze 不是玩具。** 六页工业 UI、实时 SSE 数据流、文件对话框、系统通知、离线 RSA 许可证、打包签名——全部在一次开发迭代中落地，没有一行 C 代码。商业化所需的顶层设施（license / build / sys / tray）是 glaze 区别于"又一个 UI 库"的关键。

对当前 gPTP Studio 而言，Glaze 的价值主要是 Linux WebKitGTK 上的产品 UI/控制面；时间戳、PHC、linuxptp 与硬件资格判断全部留在 Linux 原生路径。

## 开箱即用（零修改）

| 能力 | 实测 |
|---|---|
| `define-api-routes` | 一处声明生成过程+路由+JS 客户端；参数校验 400 带参数名；生成过程可直接 raco test |
| SSE 事件总线 | 实时 packets + series 稳定推送；背压策略适合 UI 事件 |
| `api-token` 引导流 | 一次性 token 换 HttpOnly cookie；WebView 内 fetch 自动携带；Host 校验默认开 |
| `webview-title/url/capture!` | 验证可用 |
| `glaze/license` | issue → copy → validate 全链路实测通过；机器绑定/过期 reason 稳定 |
| 文件对话框 | `pick-file` / `save-file-dialog` 带扩展名过滤，导入导出 pcap 直接使用 |
| `notify!` / `single-instance?` / `webview-focus!` / `webview-navigate` | 即插即用 |
| `run-app` | 临时端口 + token + on-ready/on-error/on-close 组装一次到位；浏览器 fallback 可用 |

## 历史踩坑与已回馈

1. **build-app 打包后 launcher 静默失效**：早期已定位并回馈 Glaze 上游。
2. **macOS WebView/App Nap 行为**：这是早期跨平台实验记录；gPTP Studio 当前不再维护 macOS 产品路径。

## 对当前 Linux 产品的结论

- Glaze 继续承担 WebKitGTK 桌面 UI、HTTP API、SSE、文件对话框和许可证等控制面能力。
- Linux 真正的时间路径完全由 NIC/PHC/linuxptp/libpcap 与 Linux 权限模型决定。
- 后续 Glaze 评估应优先关注 Linux WebKitGTK 稳定性、长时间运行、窗口恢复、HiDPI、桌面集成与 `.deb` 分发，而不是跨平台覆盖率。

## 一句话

Racket/Glaze 负责“把专业 Linux timing 工具做得好用”；Linux 原生时间栈负责“让 timing 数据可信”。
