# 验收指南 / ACCEPTANCE

> 给明早的你。15 分钟走完全部验收点。所有后端事实已由 155 项测试 + 无头自检 + SSE 抓包验证；本文聚焦需要人眼的部分。

## 0. 环境（一次性，已完成）

- Racket 9.3（Homebrew）+ 官方发行版（`~/.zcode/toolchains/racket-9.3`，打包专用）
- glaze 本地链接包；`app/keys/` 已有密钥对（**private.pem 未入库，注意备份**）
- 仓库：`github.com/turinglambdaai/gptp-studio`（已由 rtimeserver 改名，旧 URL 自动重定向）

## 1. 源码态运行（2 分钟）

```bash
cd ~/.zcode/workspace/default/gptp-studio
racket main.rkt --simulator        # GUI + 内置模拟器（GM 剧本）
```

验收点：

- [ ] 窗口打开，MA-902 式蓝色工业风：左侧六页导航 + 顶部状态栏
- [ ] 总览页曲线开始绘制（offset 平线 + delay 橙线），右上角 FREE 徽章
- [ ] 状态栏：GM 角色、GRAND_MASTER 端口状态、offset/delay 实时数值
- [ ] 「报文分析」页：报文表 8Hz 增长，点任意行 → 解码树 + hex 双栏
- [ ] 「运行与日志」页：日志滚动（ptp4l/sim 来源、状态迁移）

## 2. 交互验收（5 分钟）

- [ ] 「角色与配置」：改 Domain/Sync 周期 → 右侧 `ptp4l.conf` 即时变化；Sync=-3 显示 125 ms 提示
- [ ] 角色切「从钟」→ priority1 自动 248、conf 变 slaveOnly 1；点启动（sim 模式）→ 曲线出现 -5ms → 0 收敛 + 周期性 250µs 跳变；offset 超 ±100µs 阈值时红色告警 toast
- [ ] 「报文分析」导入任意 pcap/pcapng（Wireshark 存的也行）；Free 版导出按钮 → 弹 Pro 提示
- [ ] 「运行与日志」保存一个预设 → 应用 → 参数/角色恢复
- [ ] 语言切换 zh/en 全局生效
- [ ] 「开始 14 天试用」→ 徽章变 TRIAL 14d

## 3. 商业化验收（3 分钟）

```bash
racket -e '(require glaze/license)
(issue-license #:private-key "app/keys/private.pem"
               #:product "gPTP Studio" #:subject "acceptance@test"
               #:out "/tmp/test.license")'
```

- [ ] GUI 激活该文件 → 徽章变 PRO；导出按钮可用、GM 引擎按钮不再拦
- [ ] 删除 `~/.gptp-studio/license.lic` → 回 FREE；篡改 license 内容 → 激活报"签名无效"

（以上全链路今晚已 curl 实测通过，重复一遍是为了看 UI 反馈。）

## 4. Linux 真机（可选，15 分钟）

```bash
sudo apt install linuxptp libpcap-dev
./gptp-studio   # CI Release 产物或源码
```

- [ ] 「链路与网卡」显示网卡 + HW/SW 时间戳徽章 + /dev/ptpN（有 PHC 的网卡）
- [ ] GM + 真实引擎启动：免密 sudo 或 root 时 ptp4l 拉起，`pmc GET CURRENT_DATA_SET` 对照按钮数值一致；无免密 sudo 时 0.8s 内给出 visudo 指引
- [ ] 双机对接 ECU：GM 喂时 → ECU 锁定；从钟模式 → 曲线收敛到 ECU 精度

## 5. 工程质量（已完成，供复核）

```bash
raco test tests/            # 155 tests passed
racket main.rkt --selfcheck # [ok] × 3
```

- GitHub Actions：ci.yml 双平台矩阵；release.yml 打 tag v1.0.0 出 DMG + Linux tarball
- 已知限制（如实告知）：macOS 无引擎（平台性质）；角色切换需重启引擎；本会话无录屏权限，`screenshots/` 待你截图后补进 README
