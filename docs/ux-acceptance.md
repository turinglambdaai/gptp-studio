# UX / 调试工作流验收清单

本清单用于验证 `chatgpt/ux-diagnostics-pass` 引入的上位机工作流增强。协议解码、linuxptp 引擎和抓包核心仍由现有自动化测试覆盖；WebView 交互项需要真机人工走查。

## 1. 模拟器快速验收

```bash
racket main.rkt --simulator
```

- [ ] 应用正常打开，无初始化错误 toast。
- [ ] 默认角色为「被动监听」，与后端初始 `slaveOnly=1 / gmCapable=0` 一致，避免启动后意外参与 BMCA。
- [ ] 切换到 GrandMaster 后，预览里 `gmCapable=1`、`slaveOnly=0`；切回 Slave/Listener 后恢复 `gmCapable=0`、`slaveOnly=1`。
- [ ] 顶部状态栏除角色/端口/GM/offset/delay 外，出现 timing capability 徽章。
- [ ] 「同步总览」曲线显示 ±offset 告警阈值虚线。
- [ ] 「同步总览」显示最近 64 个 offset 样本的 RMS、Mean、Peak-to-peak、Max |offset|。
- [ ] 统计值随模拟器数据持续更新，不阻塞曲线刷新。
- [ ] 「复制调试快照」能复制平台、网卡、PHC、当前同步状态和 `ptp4l.conf`。
- [ ] 「开始会话」能直接启动当前模拟角色；「停止全部」结束会话。

## 2. 链路与网卡

### Linux + 支持 PTP Hardware Timestamp 的网卡

- [ ] Timing Capability 卡片显示当前平台、网卡、驱动、链路和 timestamp path。
- [ ] 同时检测到 TX/RX hardware timestamp、PHC、链路 UP 时显示 `HW + PHC / Timing ready`。
- [ ] 有 PHC 但链路 DOWN 时显示 `LINK DOWN`，而不是误报为 ready。
- [ ] 仅 hardware timestamp、无 PHC 时显示 `HW / NO PHC`。
- [ ] 仅软件时间戳时显示 `SW ONLY`，并明确说明只建议协议调试，不用于 ns/µs 精度判断。
- [ ] 显示 `ptp4l / phc2sys / pmc` 安装状态以及 root / `sudo -n` / custom privilege 路径。
- [ ] 缺少 linuxptp 核心工具时，即使网卡具备 HW+PHC，也不会显示成完全 ready。
- [ ] 缺少 `ethtool` / `ip` 时明确提示能力检测可能不完整。
- [ ] 点击「重新扫描」后 Timing Capability、工具状态与表格同步刷新。

### macOS

- [ ] 网卡显示 `SW` timing capability。
- [ ] 文案明确 macOS 适合监听/协议分析/离线分析，不作为硬件时间戳精度验证依据。
- [ ] 「真实引擎 (linuxptp)」选项不可选，模拟器仍可正常使用。

## 3. 真实调试会话

Linux 上：

- [ ] 选择真实引擎后，配置页出现当前网卡 timing path 提示。
- [ ] 切换网卡后提示同步变化。
- [ ] 软件时间戳网卡不会被描述为 instrument-grade / timing-ready。
- [ ] 提示不阻止用户做协议级调试；真正是否能启动仍由现有后端引擎决定。
- [ ] GM / Slave 点击「开始会话」时自动启动引擎与对应网卡抓包。
- [ ] Listener 点击「开始会话」时只启动抓包，不为了“监听”去改变本机时钟角色。
- [ ] 「停止全部」同时停止抓包和引擎。
- [ ] 从 Listener 切换到 GM 后立即点击开始，也不会因参数合并竞态而带着 `slaveOnly=1` 启动。

## 4. 报文分析工作流

- [ ] 类型过滤可分别查看 Sync / Follow_Up / Announce / PDelay_* / Signalling。
- [ ] 搜索框可按 Seq、Domain、sourcePortIdentity、MAC 等文本过滤。
- [ ] `/` 在报文页且焦点不在输入控件时，会聚焦搜索框。
- [ ] 点击「冻结视图」后表格停止跳动，但底层抓包继续；总计数仍可反映后端新增数据。
- [ ] 冻结状态显示 `FROZEN`；恢复后显示最新快照并切回 `LIVE`。
- [ ] Space 在报文页且焦点不在输入控件时切换冻结/恢复。
- [ ] 与当前配置 Domain 不同的报文只做醒目标记，不直接判定为错误。
- [ ] 报文健康条显示样本速率、Domain 数量、时钟源数量、序号异常和 two-step 配对情况。
- [ ] Sync / Follow_Up / Announce 同源 sequenceId 重复或跳号时会标记对应行，但提示说明抓包窗口边界/过滤也可能造成假阳性。
- [ ] two-step Sync 缺同 Seq/Domain/Source 的 Follow_Up 时给出观察提示，不武断判定 DUT 故障。
- [ ] 打开报文详情后对应行有选中态；Esc 可以关闭详情。
- [ ] ↑/↓ 或 J/K 可以在当前可见报文中上下浏览。
- [ ] 报文摘要与 Raw Hex 均可一键复制。

## 5. 快捷键与复制

- [ ] Ctrl/Cmd + 1：同步总览
- [ ] Ctrl/Cmd + 2：链路与网卡
- [ ] Ctrl/Cmd + 3：角色与配置
- [ ] Ctrl/Cmd + 4：参考源
- [ ] Ctrl/Cmd + 5：报文分析
- [ ] Ctrl/Cmd + 6：运行与日志
- [ ] 输入框/下拉框获得焦点时，Space、J/K 等快捷键不会抢占正常输入。
- [ ] `ptp4l.conf` 可以一键复制。
- [ ] 日志页可以复制当前过滤后的可见日志。

## 6. 回归检查

- [ ] 现有角色切换、参数合并和 `ptp4l.conf` 预览正常。
- [ ] 场景预设应用后，角色、网卡、参数和隐藏的 GM/Slave 约束仍保持一致。
- [ ] pcap/pcapng 导入正常。
- [ ] 实时抓包开始/停止正常。
- [ ] pcap 导出 Pro gate 行为未改变。
- [ ] 日志过滤和导出正常。
- [ ] 场景预设保存/应用/删除正常。
- [ ] Free / Trial / Pro 显示与原逻辑一致。
- [ ] 中英文切换不会导致新增 UI 报错；新增工程诊断文案当前允许暂时保持中文/英文术语混排，后续统一纳入 i18n。

> 注意：当前「参考源」页的 `phc2sys` 生命周期将在独立核心修复中处理，不把它与本 UX PR 混在一起。验收时不要把页面提示文案误当成已经启动 `phc2sys` 的证据。

## 7. 自动化回归

```bash
raco make main.rkt
raco test tests/
racket main.rkt --selfcheck
```

CI 还会执行 `node --check` 覆盖所有浏览器端脚本，避免 Racket 后端全绿但 WebView 因 JavaScript 语法错误启动失败。