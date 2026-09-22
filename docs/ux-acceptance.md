# UX / 调试工作流验收清单

本清单只针对 Linux 产品平台。协议解码、linuxptp 引擎和抓包核心由自动化测试覆盖；WebKitGTK 交互项需要 Ubuntu 22.04 / 24.04 真机人工走查。

## 1. 模拟器快速验收

```bash
gptp-studio --simulator
```

- [ ] 应用正常打开，无初始化错误 toast。
- [ ] 默认角色为「被动监听」，避免启动后意外参与 BMCA。
- [ ] 切换到 GrandMaster 后，预览里 `gmCapable=1`、`slaveOnly=0`；切回 Slave/Listener 后恢复对应约束。
- [ ] 顶部状态栏显示 timing capability 徽章。
- [ ] 「同步总览」曲线显示 offset 告警阈值虚线。
- [ ] 显示最近样本 RMS、Mean、Peak-to-peak、Max |offset|。
- [ ] 统计值随模拟器数据持续更新，不阻塞曲线刷新。
- [ ] 「复制调试快照」能复制 Linux 平台、网卡、PHC、当前同步状态和 `ptp4l.conf`。
- [ ] 「开始会话」能启动当前模拟角色；「停止全部」结束会话。

## 2. 链路与网卡

### 支持 PTP Hardware Timestamp 的网卡

- [ ] Timing Capability 卡片显示网卡、驱动、链路和 timestamp path。
- [ ] 同时检测到 TX/RX hardware timestamp 与 PHC 时显示真实 timing-capable 状态。
- [ ] link DOWN 只显示 WARN / VERIFY，不误判为结构性 FAIL。
- [ ] 仅 hardware timestamp、无 PHC 时明确显示 `NO PHC`。
- [ ] 仅软件时间戳时显示 `SW ONLY`，并明确只建议协议调试，不用于 ns/µs 精度判断。
- [ ] 显示 `ptp4l / phc2sys / pmc` 安装状态以及 root / file capabilities / `sudo -n` / direct-best-effort 路径。
- [ ] 缺少 linuxptp 核心工具时，即使网卡具备 HW+PHC，也不会显示为完全 READY。
- [ ] 缺少 `ethtool` / `ip` 时明确提示能力检测不完整。
- [ ] 点击「重新扫描」后 Timing Capability、工具状态与表格同步刷新。

## 3. 真实调试会话

- [ ] 选择真实引擎后，配置页出现当前网卡 timing path 提示。
- [ ] 切换网卡后资格结果立即更新。
- [ ] 软件时间戳网卡不会被描述为 instrument-grade / timing-ready。
- [ ] GM / Slave 点击「开始会话」时由 Supervisor 再次执行 Preflight，不能绕过后端保护。
- [ ] Listener 点击「开始会话」时只启动抓包，不为了监听改变本机时钟角色。
- [ ] 「停止全部」同时停止抓包和引擎。
- [ ] 从 Listener 切换到 GM 后立即点击开始，不会因参数合并竞态带着 `slaveOnly=1` 启动。
- [ ] 新配置被 Preflight 拒绝时，不会误停已经运行的健康会话。

## 4. 报文分析工作流

- [ ] 类型过滤可分别查看 Sync / Follow_Up / Announce / PDelay_* / Signalling。
- [ ] 搜索框可按 Seq、Domain、sourcePortIdentity、MAC 等文本过滤。
- [ ] `/` 在报文页且焦点不在输入控件时聚焦搜索框。
- [ ] 点击「冻结视图」后表格停止跳动，但底层抓包继续。
- [ ] 冻结状态显示 `FROZEN`；恢复后切回 `LIVE`。
- [ ] Space 在报文页且焦点不在输入控件时切换冻结/恢复。
- [ ] 与当前配置 Domain 不同的报文只做醒目标记，不直接判定为错误。
- [ ] 报文健康条显示样本速率、Domain 数量、时钟源数量、序号异常和 two-step 配对情况。
- [ ] sequenceId 重复/跳号有醒目标记，但提示抓包窗口边界/过滤也可能造成假阳性。
- [ ] two-step Sync 缺对应 Follow_Up 时给观察提示，不武断判定 DUT 故障。
- [ ] 打开报文详情后对应行有选中态；Esc 可以关闭详情。
- [ ] ↑/↓ 或 J/K 可以在当前可见报文中上下浏览。
- [ ] 报文摘要与 Raw Hex 均可一键复制。

## 5. Linux 快捷键与复制

- [ ] Ctrl + 1：同步总览
- [ ] Ctrl + 2：链路与网卡
- [ ] Ctrl + 3：角色与配置
- [ ] Ctrl + 4：参考源
- [ ] Ctrl + 5：报文分析
- [ ] Ctrl + 6：运行与日志
- [ ] 输入框/下拉框获得焦点时，Space、J/K 等快捷键不会抢占正常输入。
- [ ] `ptp4l.conf` 可以一键复制。
- [ ] 日志页可以复制当前过滤后的可见日志。

## 6. Doctor / Preflight 一致性

- [ ] `gptp-studio --doctor` 与 GUI Preflight 对同一 NIC 的结构性判断一致。
- [ ] `--doctor-json` 默认不包含 MAC/IP。
- [ ] READY 不显示任何“已校准精度”表述。
- [ ] GM + system reference 与 GM + externally managed PHC 的资格结果独立。
- [ ] `ptp4l` / `phc2sys` file capabilities 分开识别。

## 7. 回归检查

- [ ] 角色切换、参数合并和 `ptp4l.conf` 预览正常。
- [ ] 场景预设应用后，角色、网卡、参数和隐藏约束一致。
- [ ] pcap/pcapng 导入正常。
- [ ] 实时抓包开始/停止正常。
- [ ] pcap 导出 Pro gate 行为未改变。
- [ ] 日志过滤和导出正常。
- [ ] 场景预设保存/应用/删除正常。
- [ ] Free / Trial / Pro 显示与原逻辑一致。
- [ ] 中英文切换不会导致新增 UI 报错。

## 8. 自动化回归

```bash
raco make main.rkt
raco test tests/
racket main.rkt --selfcheck
racket main.rkt --doctor-json | python3 -m json.tool >/dev/null
bash scripts/package-deb.sh 1.0.0 v1.0.0-local
```

CI 必须在 Ubuntu 22.04 和 Ubuntu 24.04 同时通过。
