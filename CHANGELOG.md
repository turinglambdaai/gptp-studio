# 更新日志 / Changelog

## Unreleased

## 1.0.0

**Rivet 线首发。** 桌面壳从 Glaze/WebKitGTK（GTK3 + WebView + SSE + 手写 JS
前端）整体迁移到 Rivet（GTK4 原生宿主 + 内嵌 Racket 后端 + 类型化 RPC/事件
契约）。产品能力边界不变：仍是 Linux-only 的 gPTP/IEEE 802.1AS 专业调试工作
站，真实时间路径（PHC / SO_TIMESTAMPING / linuxptp / libpcap）与许可证模型
（离线签名、Free/Pro 分层）原样保留。按家族换栈政策清空全部旧版本，本版本
为 Rivet 线 1.0.0 首发。

### Changed

- **桌面栈**：六页 GTK4 原生界面（Engine + 实时曲线、Qualification、
  Packets + 报文详情/hex、Logs、GM Tuning、License & Reports）替换六页
  WebKitGTK web 前端。同步收敛曲线由 Rivet 共享图表数据面渲染
  （`rivet/chart` 环形缓冲 + 带间隙检测的二进制批次 + 窗口拉取恢复）。
- **后端契约**：约 40 个类型化 RPC 与 7 个类型化事件替换 HTTP API +
  SSE 总线；文件对话框收归宿主（导出/导入 RPC 只收路径）。协议细节树
  （PTP 解码、参数、i18n）以 Any 叶子搭在 typed 脊柱上传输。
- **序列存储**：offset/delay 环形缓冲底层换 `rivet/chart`（墙钟 ns 单调
  时间戳 + 精确整数值），模拟与真实引擎两条采样路径统一经同一缓冲排放。
- **许可证模块**：离线签名验证收编为产品内模块（原 glaze/license）。
- **更新链路（为 1.0.1 准备）**：更新检查/下载全程走 `rivet/distribution`
  家族标准（Ed25519 签名清单、验签先于解析、SHA-256 + size 校验、看门狗）。
  1.0.0 首发无存量安装，不带更新 feed；签名频道自 1.0.1 起发布。
- **无头支持面**：`--doctor` / `--doctor-json` 保留，经类型化 RPC 从内嵌
  后端取报告，不开窗口。

### Removed

- WebKitGTK 窗口、web 前端（public/）、HTTP/SSE API 层与浏览器回退路径。
