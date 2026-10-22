# 验收指南 / ACCEPTANCE

> gPTP Studio 的产品验收只针对 Linux。基线发行版是 Ubuntu 24.04 LTS（GTK4 宿主要求 GTK ≥ 4.10，22.04 的 4.6 低于下限），并优先在带真实 PHC/HW timestamp 的网卡上执行真机项。
>
> 可执行验收门以 `rivet-acceptance.rktd` 为准（`raco rivet acceptance --json`）：合同测试、RVT1 wire、GTK4 宿主构建、打包、AT-SPI 原生 UI 五个套件。本文件是其上的人工验收补充；涉及物理 NIC/PHC/精度的声明另见 §3–§5 与 `docs/hardware-qualification.md`。

## 0. 环境

```bash
sudo apt update
sudo apt install linuxptp libpcap-dev ethtool iproute2 libcap2-bin \
  libgtk-4-1 libsecret-1-0
```

先执行：

```bash
gptp-studio --version
gptp-studio --doctor
```

验收点：

- [ ] Doctor 正常退出；
- [ ] `platform: linux`；
- [ ] MAC/IP 默认脱敏；
- [ ] 每个非 loopback NIC 都显示 driver/link/speed/HW timestamp/PHC；
- [ ] Slave、GM(system reference)、GM(external PHC) 分别给出 READY / VERIFY / BLOCKED / PASSIVE-ONLY；
- [ ] 不把 hardware timestamp / PHC 显示成已校准精度。

## 1. GUI / 模拟器

```bash
gptp-studio --simulator
```

- [ ] GTK4 原生窗口正常打开；
- [ ] 六页导航（Engine / Qualification / Packets / Logs / GM Tuning / License & Reports）与顶部状态栏正常；
- [ ] Engine 页同步曲线持续更新；
- [ ] Packets 页面持续出现真实编码的模拟 gPTP 帧，报文详情、解码树、hex 可用；
- [ ] GM Tuning 修改优先级后 `pmc GRANDMASTER_SETTINGS_NP` 应用到运行中的引擎；
- [ ] 角色切换、告警、日志、预设、语言切换正常。

## 2. 许可证与更新

- [ ] License 页显示本机 Installation ID（`ins_` + 32 位十六进制），可选中复制，重启后不变；
- [ ] Start Trial 后档位变为 trial，剩余天数在 1–14 内；试用期间引擎控制/导出可用；
- [ ] 系统时钟回拨超过 5 分钟后试用判定失效（免费档），不崩溃；
- [ ] 试用到期后回到 free，引擎控制/导出重新被拒并给出 Pro 提示；
- [ ] 激活一份有效 `.permit.json` 后档位变为 Pro，detail 显示 subject 与 updates_through；激活绑定其他 Installation ID 的凭据被拒绝并提示；
- [ ] Deactivate 后回到 free，`~/.gptp-studio/entitlement.permit.json` 被删除；
- [ ] 「检查更新…」在有新版本的 feed 上给出同意对话框，全程错误文案可复制；
- [ ] Pro 永久授权在 `updates_through` 截止日当天仍可下载官方更新，次日起拒绝出网并说明续购；Free/试用不受限。

## 3. 官方包

每个发布资产都带 `.sha256` 侧车，发布附带聚合 `SHA256SUMS`（附 `sha256sum --check SHA256SUMS` 验证）。

### Debian 包

```bash
sudo apt install ./gptp-studio-linux-x64.deb
command -v gptp-studio
gptp-studio --doctor
```

- [ ] `/usr/bin/gptp-studio` 可用；
- [ ] 依赖声明为 GTK4 运行库（`libgtk-4-1`），不含 WebKitGTK；
- [ ] 桌面菜单存在 gPTP Studio，图标正常；
- [ ] `/usr/share/doc/gptp-studio/` 包含 LICENSE / NOTICE / EULA / THIRD_PARTY_NOTICES；
- [ ] 安装动作没有自动修改 sudoers 或 file capabilities；
- [ ] 卸载软件不会删除 `~/.gptp-studio/` 用户数据。

### RPM 包

```bash
sudo dnf install ./gptp-studio-<version>-<build>-linux-x86_64.rpm
gptp-studio --doctor
```

- [ ] `/usr/bin/gptp-studio` 可用，Doctor 与 deb 版语义一致；
- [ ] Requires 为 gtk4（≥ 4.10）/ libpcap / linuxptp / ethtool / iproute / libcap / libsecret，无 webkit2gtk。

### AppImage

```bash
chmod +x gptp-studio-linux-x64.AppImage
./gptp-studio-linux-x64.AppImage --doctor
./gptp-studio-linux-x64.AppImage
```

- [ ] 在比 Ubuntu 24.04 更老的宿主上可启动（AppImage 自带 GTK4 依赖闭包）；
- [ ] `--doctor` 无头面与安装版语义一致；
- [ ] GUI 正常打开，License 页 Installation ID 与安装版一致（同一 `~/.gptp-studio`）。

### Relocatable tarball

```bash
tar -xzf gptp-studio-linux-x64.tar.gz
cd gptp-studio-distributed
./bin/gptp-studio --version
./bin/gptp-studio --doctor
```

- [ ] 无需 Racket 源码环境即可运行；
- [ ] 应用内 `app/keys/trust-store.json`（Permit 信任库）随包分发；
- [ ] Doctor 与安装版语义一致。

## 4. 真机 NIC / PHC

在支持 IEEE 1588/PTP hardware timestamp 的网卡上：

```bash
ethtool -T <iface>
ls -l /dev/ptp*
gptp-studio --doctor
```

- [ ] Studio 识别 TX/RX HW timestamp；
- [ ] Studio 识别正确 `/dev/ptpN`；
- [ ] driver / link / speed 与系统工具一致；
- [ ] link DOWN 只产生 VERIFY/WARN，不作为结构性 FAIL；
- [ ] 明确没有 HW timestamp 或 PHC 时真实 GM/Slave 被阻止启动。

## 5. 权限路径

分别验证至少一种生产可接受路径：

- [ ] root；或
- [ ] `ptp4l` 的 `cap_net_raw,cap_net_admin`；必要时 `phc2sys` 的 `cap_sys_time`；或
- [ ] 明确配置的 passwordless `sudo -n`。

要求：

- [ ] Preflight/Doctor 能识别真实路径；
- [ ] 权限不足时给可执行建议，不无限等待 sudo 密码；
- [ ] GM + system reference 单独检查 `phc2sys` 时钟写权限；
- [ ] 被拒绝的新会话不会误停正在运行的健康会话。

## 6. 双机 / ECU 真机

- [ ] Studio GM → ECU/EthTSyn Slave 能进入同步；
- [ ] ECU/设备 GM → Studio Slave 曲线收敛；
- [ ] `pmc GET CURRENT_DATA_SET` 与 UI 关键状态一致；
- [ ] offset jump 时能回看同一时间附近的 Sync / Follow_Up / PDelay / Announce；
- [ ] 抓包 timestamp source 与 NIC capability 分开显示。

## 6b. Boundary Clock 双端口真机

在两张支持硬件时间戳的网卡上：

- [ ] Preflight 对每个端口单独列出 HW timestamp/PHC/权限检查（带端口号）；
- [ ] 只选一个端口、或重复选择同一网卡时启动被拒绝，且不影响运行中会话；
- [ ] 生成的 `ptp4l.conf` 包含 `boundary_clock_jbod 0`；上游端口为 port 1；
- [ ] 运行时有 `ptp4l -i <上游> -i <下游>` 与 `phc2sys -a -r -w`（共享 UDS）；
- [ ] 状态栏逐口显示（P1 SLAVE · P2 GRAND_MASTER）；
- [ ] 上游接真实 GM、下游接 DUT 时，DUT 能同步，`pmc GET CURRENT_DATA_SET` 与 UI 一致；
- [ ] 模拟器 Boundary 剧本双端口有流量且不影响其它角色。

## 7. 工程质量

```bash
raco test tests/
raco rivet build
raco rivet generate && test -s linux/GeneratedBackend.hpp
raco rivet acceptance --json   # 完整 Linux 产品门
```

GitHub Actions（ubuntu-24.04，amd64 + arm64）必须在 PR 与 main 上保持全绿：全部测试、GTK4 宿主构建、生成客户端存在性。发布流水线（tag 触发，rivet 按 `RIVET_PIN` 固定在发布 tag）额外执行：`raco rivet release --development` 的打包（deb + rpm + AppImage + tar.gz + zip + SBOM）+ 自检 + Doctor 冒烟、amd64 deb 实装冒烟、逐资产 `.sha256` + 聚合 `SHA256SUMS`、签名 feed 生成与自验。

## 8. 精度声明

任何对外精度数字必须来自固定 reference platform + 外部参考仪器 characterization。以下事实本身都不能被写成精度保证：

- `/dev/ptpN` 存在；
- 网卡支持 hardware timestamp；
- 时间戳分辨率为 ns；
- ptp4l offset 很小；
- Doctor 显示 READY。

对外发布 timing specification 前按 [docs/hardware-qualification.md](docs/hardware-qualification.md) 执行。
