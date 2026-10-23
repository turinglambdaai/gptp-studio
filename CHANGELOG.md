# 更新日志 / Changelog

## 0.4.0 - 2026-10-23

**授权决策 `2026-10-auth-1` 落地：原始数据导出回归免费，更新资格改由
发布时刻判定。**（issue #35 的仓内切片）

### Added

- **原始数据导出移出旧 Pro 门禁**：`pcap-export` 与 Wireshark 回放
  （retained）不再要求授权——免费层即可导出自己的捕获数据（PRICING
  免费范围的「raw-data export」落地）。工程报告生成（`report-export`）
  成为付费证据面：按付费范围的「带证据的报告」补上门禁（旧 UI 文案
  一直宣称 Pro，但实现从未门禁）。
- **更新资格 = 发布时刻语义**：候选版本的认证 `published_at`（签名
  feed 携带）与 entitlement 的 `updates_through` 判定，**当前日期不再
  是输入**——窗口内的版本永远可获取，窗口过期不使已装版本失效、
  不降级、不影响启动。此前按「今天 vs 窗口」判定，截止日次日连窗口
  内发布的最后一个版本也无法下载。日期粒度的截止扩展到当日结束；
  无可读发布时刻的候选对受门禁安装一律拒绝（fail-closed）。
  `docs/update-contract.md` 记录契约；固定 UTC 边界测试覆盖
  截止前 1 秒/恰在截止/截止后 1 秒与日期粒度截止。

### Changed

- 产品站（docs/index.html）补 AppImage 安装卡，对照实际发布资产；
  `gate-check` 的 `export` 动作由 `report` 取代（原始导出免费后报告
  是唯一付费导出面）。

## 0.3.1 - 2026-10-23

**Linux 分发面对齐 taskly 标杆 + 发布 rivet 切 pin。** 修复 v0.3.0 流水线
「构建了 rpm/AppImage 却没收集」的缺口，发布资产自此全面带校验和。

### Added

- **完整 Linux 包面**：`raco rivet release` 自此收集全部产出——deb、
  rpm（x86_64/aarch64）、AppImage（x86_64/aarch64，自带 GTK4 依赖闭包）、
  可移植 tar.gz 与 zip，双架构；`rivet.rktd` 显式声明
  `linux-formats ("deb" "rpm" "appimage")`。v0.3.0 的流水线其实已经构建了
  rpm 与 AppImage，但收集步骤的 find 模式把它们漏在了 dist 里。
- **校验和族**：每个发布资产带 `.sha256` 侧车，发布附带聚合
  `SHA256SUMS`（发布前 `sha256sum --check` 自验）；SBOM 定版名为
  `gptp-studio-<版本>-linux-<架构>.sbom.cdx.json`。AppImage 加入
  版本无关稳定别名（deb/tar.gz 别名延续）。
- README 双语补 rpm/AppImage 安装路径并把「源码运行」修到 rivet 命令
  （旧 `raco make main.rkt` 入口在 0.1.0 换栈时已不存在）；
  ACCEPTANCE 补 rpm/AppImage 验收项。

### Changed

- 发布流水线的 rivet 安装自此 pin 在 `RIVET_PIN`（当前 v0.12.0，与
  setup-embed-racket action 一致），落实「发布构建切 pin、开发跟最新」；
  打包工具链显式安装 `rpm`/`desktop-file-utils`。

### Removed

- `scripts/package-deb.sh` / `scripts/package-extras.sh`：glaze 时代
  的打包脚本，引用的 `scripts/package-linux.sh` 已不存在，能力自 0.1.0
  起由 rivet 原生 release 流程承担。

## 0.3.0 - 2026-10-23

**安装身份与本地试用落到 Permit 原语，官方更新窗完成收费闭环。** 安装
ID、试用状态机、凭据验证全部接上 permit 协议；deb/rpm 运行时依赖从
WebKitGTK 旧栈改为 GTK4 真实依赖。

### Added

- **安装身份**：每台安装持有稳定 Installation ID（`ins_` + 32 hex，首次
  使用时生成、持久于 `~/.gptp-studio/installation-id`）。凭据验证把本机
  ID 传给 permit 的安装绑定检查——`installation_id` 绑定的凭据自此可用，
  不匹配或未携带 ID 一律 fail-closed。License 页显示可复制的安装 ID
  （含获取绑定凭据的指引文案），类型化 `GateInfo` RPC 增加
  `installation_id` 字段；`docs/vendor-license-guide.md` 记录签发侧的
  绑定流程。
- **permit 本地试用**：14 天试用从自制日期状态改用 permit local-trial
  （固定起止窗口 + last_seen 高水位），时钟回拨超容差即失效、重启
  不重置；旧版 `trial-started` 日期状态在首次读取时自动迁移——未到期
  保留剩余窗口，已到期保持到期，Trial 不能重启已消费的窗口。
- **官方更新窗成为产品机制**（第一个收费范例的地基）：Pro 永久 entitlement
  的 `updates_through` 自此贯通发行链与产品——commerce 侧 offer
  （`gptp-studio-pro-perpetual` / `gptp-studio-pro-team-5`，定价见
  `PRICING.md` v1.1）按支付日 + 365 天推导窗口；产品侧 gate 缓存激活凭据的
  窗口（`gate-updates-through` / `gate-update-window-open?`），应用内
  「下载更新」在窗口关闭后拒绝出网并在流程中给出续购说明（`Free` /
  试用不受限；到期版本永久可用，不降级）。`gate-info` 增加
  `updates_through` 字段；`docs/update-contract.md` 记录该契约。
- `PRICING.md` v1.1.0：授权方式一节从 Permit 化之前的 RSA/license.lic 旧文
  改写为 Permit 凭据机制；价格表移除按月订阅（离线产品不可诚实执行月度
  时效），明示「续购更新窗即为续费」。
- `docs/vendor-license-guide.md` 新增正式发行路径：手工签发仅限测试与补发，
  正式销售走 commerce 的 offer/policy 映射与渠道 webhook。
- CI 并发守卫：同一 ref 的新推送自动取消排队中的旧运行（main 不取消）。

### Fixed

- **deb/rpm 运行时依赖**：从 `libgtk-3-0 + libwebkit2gtk-4.1-0`（0.1.0
  已整体移除的旧栈）改为 `libgtk-4-1 (>= 4.10) + libsecret-1-0`——宿主
  的真实链接面；rpm 的 `gtk3/webkit2gtk4.1` 同步改 `gtk4/libsecret`。
  此前在精简系统上安装会缺 GTK4 运行库、反而多装 WebKit。
- 宿主 License 页残留旧 `license.lic` 占位文案改为 `.permit.json`。
- ACCEPTANCE.md 与旧栈对齐的章节（GTK3/WebKit 环境依赖、WebKitGTK
  窗口、旧页名、glaze 时代入口命令、22.04 门）改写为 Rivet/GTK4 产品
  现状，并补许可证与更新的验收点。
- 凭据验证信息补齐 `updates-through` 字段（此前只暴露 `use_expires_at`），
  gate 测试覆盖窗口边界（截止日当天仍可更新、次日拒绝、Free 恒开）。

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
