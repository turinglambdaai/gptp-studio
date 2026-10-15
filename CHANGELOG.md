# 更新日志 / Changelog

## Unreleased

### Changed

- **商业权益迁移到 Permit**：删除产品内 RSA/OpenSSL 许可证实现与硬件 machine-id 绑定；官方 entitlement 改为 Permit Protocol v1 / Ed25519 本地验签，默认客户端只携带公钥 trust store。
- **功能级维护期**：Pro gate 不再只判断一个布尔档位；engine-control、reference-source、pcap-export 与大容量 packet store 按各自发布时间查询 `features_through`，防止维护期结束后手工复制新二进制获得未来付费功能。
- **本地 Trial**：14 天 Pro 试用改用 Permit storage-agnostic local-trial 状态与随机 installation id，不采集硬件指纹。
- **密钥职责隔离**：产品 entitlement key 与 updater signing key 明确分离；Release 在正式构建前验证生产 Permit trust store，空占位配置直接拒绝发布。

### Removed

- `support/license.rkt` RSA-2048/OpenSSL 授权模块与旧 `app/keys/public.pem`。

## 0.2.0 - 2026-10-15

**在线更新上线 + 反馈面对齐家族地基标准。** 签名更新频道（update-stable
feed）自此版本起发布；宿主补齐更新入口、About 与诊断复制；发布流水线接
签名 feed。0.1.0 已内置的更新引擎（Ed25519 验签、选择策略、下载看门狗）
在本版本接到 RPC、宿主与发布链路。

### Added

- **在线更新**：后端新增 `check-updates` / `start-download` /
  `apply-update` / `update-state` 四个类型化 RPC，接通 0.1.0 预置的
  `rivet/distribution` 更新引擎（Ed25519 签名清单、验签先于解析、
  SHA-256 + size 校验、进度百分比、下载看门狗：120 s 无进度 / 30 min
  硬顶）。形态分流：deb 安装 → 下载保留 + `apt-get` 指令 + 可选 pkexec
  授权安装；tarball 安装 → 原地换装（解压 → `<root>.old` 备份 → 原子
  换入 → 可执行位按整数位 `#o755` 落盘，失败自动回滚旧目录）。
- **更新入口与静默检查**：宿主头部菜单新增「检查更新…」（绕过节流）与
  「关于」；启动后 3 s 静默检查，host 持有的 4 h 节流戳
  （`~/.local/share/gptp-studio/last-update-check`）；发现新版本弹同意
  对话框，全程错误文案可选中复制；`--no-update-check` 整体关闭
  （契约见 `docs/update-contract.md`）。
- **签名 feed**：Release 流水线 publish 阶段用 `UPDATER_PRIVATE_KEY`
  签出 `update-stable.json`（x64/arm64 的 deb + tar.gz 四个条目，URL 钉
  在具体 tag）并提交回 main（`feed: x.y.z`），写前用
  `app/keys/updater/public.pem` 自验，私钥不匹配即拒绝发布；另附
  版本无关的稳定别名资产。key-id `gptp-studio-2026-10`。
- **About 对话框**：版本号（与 bootstrap/rivet.rktd 单源）、官网
  gptp-studio.jrtx.site、GitHub Issues、许可证行（Apache-2.0 源码 /
  官方分发商业条款，按 EULA 措辞）。
- **诊断复制**：About 内「复制诊断信息」一键把脱敏诊断文本放进剪贴板
  （版本、发行版、内核、Racket 运行时、许可档位、逐网卡 PHC/linuxptp
  判定、日志尾行），对齐 issue 模板字段，MAC/IP 与主机标识默认不采集。
- **Issue 模板三件套**：bug_report（Ubuntu 24.04 基线、gPTP 网卡环境
  引导、诊断粘贴位）、feature_request、config.yml（文档站 / 更新契约 /
  Pro 支持渠道，商业用户指到 PRICING.md/EULA）。

### Changed

- **更新测试**：换装全链路红绿测试落位（资产派生 → 本地 TCP 服务器下载
  → `#o755` 整数位校验 → 落盘 + `.old` 备份），deb「下载保留 + 指引」
  路径、arm64 feed 条目与 feed 脚本（PEM/DER/错钥拒绝）全覆盖；暂存名
  改为从 feed 资产 URL 基名派生（发布资产名含版本）。
- **版本单源**：rivet.rktd 0.2.0 / build 2，与 info.rkt、app/state.rkt、
  CHANGELOG 对齐（`scripts/check-release-version.sh` 校验）。

## 0.1.0

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
  0.1.0 首发无存量安装，不带更新 feed；签名频道自后续版本起发布。
- **无头支持面**：`--doctor` / `--doctor-json` 保留，经类型化 RPC 从内嵌
  后端取报告，不开窗口。

### Removed

- WebKitGTK 窗口、web 前端（public/）、HTTP/SSE API 层与浏览器回退路径。
