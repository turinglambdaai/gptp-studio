# 验收指南 / ACCEPTANCE

> gPTP Studio 的产品验收只针对 Linux。推荐使用 Ubuntu 22.04 LTS 或 Ubuntu 24.04 LTS，并优先在带真实 PHC/HW timestamp 的网卡上执行真机项。

## 0. 环境

```bash
sudo apt update
sudo apt install linuxptp libpcap-dev ethtool iproute2 libcap2-bin \
  libgtk-3-0 libwebkit2gtk-4.1-0
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

- [ ] WebKitGTK 原生窗口正常打开；
- [ ] 六页导航与顶部状态栏正常；
- [ ] Overview 曲线持续更新；
- [ ] Packets 页面持续出现真实编码的模拟 gPTP 帧；
- [ ] 报文详情、解码树、hex 可用；
- [ ] Role & Config 修改 Domain/Sync 周期后 `ptp4l.conf` 立即变化；
- [ ] 角色切换、告警、日志、预设、语言切换正常。

## 2. 官方包

### Debian 包

```bash
sudo apt install ./gPTP-Studio-v1.0.0-linux-amd64.deb
command -v gptp-studio
gptp-studio --doctor
```

- [ ] `/usr/bin/gptp-studio` 可用；
- [ ] 桌面菜单存在 gPTP Studio；
- [ ] 图标正常；
- [ ] `/usr/share/doc/gptp-studio/` 包含 LICENSE / NOTICE / EULA / THIRD_PARTY_NOTICES；
- [ ] 安装动作没有自动修改 sudoers 或 file capabilities；
- [ ] 卸载软件不会删除 `~/.gptp-studio/` 用户数据。

### Relocatable tarball

```bash
tar -xzf gPTP-Studio-v1.0.0-linux-x64.tar.gz
cd gptp-studio-distributed
./bin/gptp-studio --version
./bin/gptp-studio --doctor
```

- [ ] 无需 Racket 源码环境即可运行；
- [ ] license payload 完整；
- [ ] Doctor 与安装版语义一致。

## 3. 真机 NIC / PHC

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

## 4. 权限路径

分别验证至少一种生产可接受路径：

- [ ] root；或
- [ ] `ptp4l` 的 `cap_net_raw,cap_net_admin`；必要时 `phc2sys` 的 `cap_sys_time`；或
- [ ] 明确配置的 passwordless `sudo -n`。

要求：

- [ ] Preflight/Doctor 能识别真实路径；
- [ ] 权限不足时给可执行建议，不无限等待 sudo 密码；
- [ ] GM + system reference 单独检查 `phc2sys` 时钟写权限；
- [ ] 被拒绝的新会话不会误停正在运行的健康会话。

## 5. 双机 / ECU 真机

- [ ] Studio GM → ECU/EthTSyn Slave 能进入同步；
- [ ] ECU/设备 GM → Studio Slave 曲线收敛；
- [ ] `pmc GET CURRENT_DATA_SET` 与 UI 关键状态一致；
- [ ] offset jump 时能回看同一时间附近的 Sync / Follow_Up / PDelay / Announce；
- [ ] 抓包 timestamp source 与 NIC capability 分开显示。

## 6. 工程质量

```bash
raco make main.rkt
raco test tests/
racket main.rkt --selfcheck
racket main.rkt --doctor-json | python3 -m json.tool >/dev/null
bash scripts/package-deb.sh 1.0.0 v1.0.0-local
```

GitHub Actions 必须在 **Ubuntu 22.04 + Ubuntu 24.04** 同时通过：

- Compile
- 全部测试
- selfcheck
- Doctor
- Linux relocatable tarball smoke
- Debian package metadata/extract/runtime smoke
- license payload smoke

## 7. 精度声明

任何对外精度数字必须来自固定 reference platform + 外部参考仪器 characterization。以下事实本身都不能被写成精度保证：

- `/dev/ptpN` 存在；
- 网卡支持 hardware timestamp；
- 时间戳分辨率为 ns；
- ptp4l offset 很小；
- Doctor 显示 READY。

对外发布 timing specification 前按 [docs/hardware-qualification.md](docs/hardware-qualification.md) 执行。
