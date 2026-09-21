# UX / 调试工作流验收清单

本清单用于验证 `chatgpt/ux-diagnostics-pass` 引入的上位机工作流增强。它只覆盖 UI/交互层；协议解码、linuxptp 引擎和抓包核心仍由现有自动化测试覆盖。

## 1. 模拟器快速验收

```bash
racket main.rkt --simulator
```

- [ ] 应用正常打开，无初始化错误 toast。
- [ ] 顶部状态栏除角色/端口/GM/offset/delay 外，出现 timing capability 徽章。
- [ ] 「同步总览」曲线显示 ±offset 告警阈值虚线。
- [ ] 「同步总览」显示最近 64 个 offset 样本的 RMS、Mean、Peak-to-peak、Max |offset|。
- [ ] 统计值随模拟器数据持续更新，不阻塞曲线刷新。

## 2. 链路与网卡

### Linux + 支持 PTP Hardware Timestamp 的网卡

- [ ] Timing Capability 卡片显示当前平台、网卡、驱动、链路和 timestamp path。
- [ ] 同时检测到 TX/RX hardware timestamp、PHC、链路 UP 时显示 `HW + PHC / Timing ready`。
- [ ] 有 PHC 但链路 DOWN 时显示 `LINK DOWN`，而不是误报为 ready。
- [ ] 仅 hardware timestamp、无 PHC 时显示 `HW / NO PHC`。
- [ ] 仅软件时间戳时显示 `SW ONLY`，并明确说明只建议协议调试，不用于 ns/µs 精度判断。
- [ ] 点击「重新扫描」后 Timing Capability 与表格同步刷新。

### macOS

- [ ] 网卡显示 `SW` timing capability。
- [ ] 文案明确 macOS 适合监听/协议分析/离线分析，不作为硬件时间戳精度验证依据。
- [ ] 「真实引擎 (linuxptp)」选项不可选，模拟器仍可正常使用。

## 3. 真实引擎前置提示

Linux 上：

- [ ] 选择真实引擎后，配置页出现当前网卡 timing path 提示。
- [ ] 切换网卡后提示同步变化。
- [ ] 软件时间戳网卡不会被描述为 instrument-grade / timing-ready。
- [ ] 提示不阻止用户做协议级调试；真正是否能启动仍由现有后端引擎决定。

## 4. 报文分析工作流

- [ ] 类型过滤可分别查看 Sync / Follow_Up / Announce / PDelay_* / Signalling。
- [ ] 搜索框可按 Seq、Domain、sourcePortIdentity、MAC 等文本过滤。
- [ ] `/` 在报文页且焦点不在输入控件时，会聚焦搜索框。
- [ ] 点击「冻结视图」后表格停止跳动，但底层抓包继续；总计数仍可反映后端新增数据。
- [ ] 冻结状态显示 `FROZEN`；恢复后显示最新快照并切回 `LIVE`。
- [ ] Space 在报文页且焦点不在输入控件时切换冻结/恢复。
- [ ] 与当前配置 Domain 不同的报文只做醒目标记，不直接判定为错误。
- [ ] 打开报文详情后对应行有选中态；Esc 可以关闭详情。

## 5. 快捷键

- [ ] Ctrl/Cmd + 1：同步总览
- [ ] Ctrl/Cmd + 2：链路与网卡
- [ ] Ctrl/Cmd + 3：角色与配置
- [ ] Ctrl/Cmd + 4：参考源
- [ ] Ctrl/Cmd + 5：报文分析
- [ ] Ctrl/Cmd + 6：运行与日志
- [ ] 输入框/下拉框获得焦点时，Space 等快捷键不会抢占正常输入。

## 6. 回归检查

- [ ] 现有角色切换、参数合并和 `ptp4l.conf` 预览正常。
- [ ] pcap/pcapng 导入正常。
- [ ] 实时抓包开始/停止正常。
- [ ] pcap 导出 Pro gate 行为未改变。
- [ ] 日志过滤和导出正常。
- [ ] 场景预设保存/应用/删除正常。
- [ ] Free / Trial / Pro 显示与原逻辑一致。
- [ ] 中英文切换不会导致新增 UI 报错；新增工程诊断文案当前允许暂时保持中文/英文术语混排，后续统一纳入 i18n。

## 7. 自动化回归

```bash
raco make main.rkt
raco test tests/
racket main.rkt --selfcheck
```

三条都应通过。当前自动化主要覆盖 Racket 后端，因此本文件中的 WebView 交互项仍需在实际 GUI 中人工走查。