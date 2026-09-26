# gPTP Studio

**A Linux-native gPTP / IEEE 802.1AS debugging workstation for Automotive Ethernet.**

[![CI](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Linux-blue)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)
![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

**English** · [中文](README.zh-CN.md)

gPTP Studio is deliberately focused on Linux because professional gPTP work depends on Linux capabilities that matter in the measurement path: **PHC, hardware timestamping, `SO_TIMESTAMPING`, linuxptp, sysfs NIC introspection and explicit privilege control**. The product does not maintain reduced-function desktop ports that cannot provide the same timing path.

For AUTOSAR EthTSyn / IEEE 802.1AS debugging, one Linux workstation can act as **GrandMaster, Slave or passive Listener**, show sync convergence live, decode every gPTP frame and correlate timing jumps with the packets and engine state that caused them.

Built with [Racket](https://racket-lang.org/) + [Glaze](https://github.com/turinglambdaai/glaze), using WebKitGTK for the desktop UI and Linux-native timing/network facilities for the real engine path.

## Highlights

- **Three roles, one workstation** — GrandMaster, Slave and passive Listener with generated `ptp4l.conf`
- **linuxptp lifecycle management** — supervised `ptp4l`, `phc2sys` and `pmc`
- **Hardware timing qualification** — detects NIC HW timestamp support, mapped PHC and privilege path before starting a real engine
- **Real-time sync curves** — `offsetFromMaster` / `meanPathDelay`, alarms and engine state
- **gPTP packet capture & decode** — libpcap capture of EtherType `0x88f7`, full Sync / Follow_Up / Announce / PDelay_* / Signalling decode, exact sec+nsec timestamp metadata, hex view and pcap/pcapng workflows
- **Timing-path transparency** — NIC capability and actual capture timestamp source are shown separately; timestamp resolution is never presented as calibrated accuracy
- **Headless support Doctor** — `--doctor` / `--doctor-json` report NIC, PHC, linuxptp and privilege readiness without opening the GUI; MAC/IP are omitted by default
- **Built-in simulator with fault injection** — synthetic 802.1AS sessions flow through the same encode/decode/store pipeline as real traffic; inject Sync/Announce drops, Follow_Up delay, sequence gaps and offset spikes to negative-test your alerts, BMCA reading and reports
- **GM runtime tuning** — change clockClass, clockAccuracy, timeSource and BMCA priorities on a running engine via `pmc GRANDMASTER_SETTINGS_NP`, no restart (Pro)
- **Wireshark one-click** — live capture with a gPTP filter, or replay retained packets; engineering reports export to JSON/Markdown
- **Aggregated logs and presets** — engine, capture and application events in one place
- **Offline licensing** — signed offline license files; no cloud dependency required for protected environments

## Supported platform

The product contract is **Linux only**.

| Area | Support |
|---|---|
| Primary validated distributions | Ubuntu 22.04 LTS, Ubuntu 24.04 LTS |
| Desktop UI | GTK 3 + WebKitGTK 4.1 |
| Real GM / Slave engine | linuxptp (`ptp4l`, `phc2sys`, `pmc`) |
| Timing hardware | NIC hardware timestamping + PHC (`/dev/ptpN`) |
| Capture | libpcap, with runtime timestamp-source reporting |
| Packages | `.deb` and relocatable `.tar.gz` |
| Other operating systems | Unsupported by product design |

A NIC reporting hardware timestamping and `/dev/ptpN` means the host has the required capability for the linuxptp path. It does **not** by itself prove calibrated end-to-end timing accuracy. Studio keeps capability, runtime timestamp source and any future characterization results separate.

## Install

### Debian / Ubuntu package

```bash
sudo apt install ./gPTP-Studio-v1.1.0-linux-amd64.deb
gptp-studio --doctor
gptp-studio
```

The Debian package declares the Linux runtime dependencies and installs the desktop entry, icon and license notices. It intentionally does **not** grant `CAP_NET_ADMIN`, `CAP_NET_RAW` or `CAP_SYS_TIME` during installation. Doctor / Preflight show the privilege path explicitly so an operator controls security changes.

### Relocatable tarball

```bash
tar -xzf gPTP-Studio-v1.1.0-linux-x64.tar.gz
cd gptp-studio-distributed
./bin/gptp-studio --doctor
./bin/gptp-studio
```

### From source

```bash
sudo apt install linuxptp libpcap-dev ethtool iproute2 libcap2-bin \
  libgtk-3-dev libwebkit2gtk-4.1-dev

raco pkg install --auto --no-docs --link /path/to/glaze
raco make main.rkt
racket main.rkt --doctor
racket main.rkt --simulator
racket main.rkt
```

For real hardware work, start with `gptp-studio --doctor`, fix structural FAIL items, then use GUI Preflight on the exact interface before starting GM/Slave. See [docs/support-doctor.md](docs/support-doctor.md) and [docs/hardware-qualification.md](docs/hardware-qualification.md).

## Pages

| Page | What it does |
|---|---|
| Overview | Live offset/delay curves, port state, current GM, alarm threshold |
| Links & NICs | NIC HW timestamp / PHC capability and actual capture timestamp path |
| Role & Config | Role switch, gPTP parameters, generated `ptp4l.conf`, start/stop |
| Reference | Managed `phc2sys` reference-source lifecycle |
| Packets | Capture, packet table, decoded tree, exact timestamp metadata, hex, import/export |
| Runtime & Logs | Process state, logs, presets and license |

## Licensing

| | Official Free | Official Pro |
|---|---|---|
| Listener capture + packet decode | ✅ | ✅ |
| Offline pcap import | ✅ | ✅ |
| Simulator | ✅ | ✅ |
| Config editor + `ptp4l.conf` preview | ✅ | ✅ |
| GM / Slave engine control | — | ✅ |
| Reference source (`phc2sys`) | — | ✅ |
| pcap export | — | ✅ |
| Packet store | 2,000 frames | 50,000 frames |

The source code is Apache-2.0. Free/Pro describe the product experience, update entitlement and support attached to **official distributions**; they do not revoke rights already granted by Apache-2.0. Self-built or modified Apache-2.0 versions are not automatically official Pro builds and do not carry official update/support/validation commitments.

Every official install starts with a 14-day Pro trial. See [PRICING.md](PRICING.md) and [docs/licensing-model.md](docs/licensing-model.md).

## Architecture

One Racket process hosts the Glaze/WebKitGTK UI and application services. Real timing is delegated to Linux-native facilities: linuxptp child processes, PHC/hardware timestamps and libpcap. Timing-critical timestamps are produced below the Racket GUI/control layer; Studio focuses on orchestration, observability, analysis and safe qualification. Details: [docs/architecture.md](docs/architecture.md).

## License

gPTP Studio source and Apache-covered portions of official distributions remain licensed under Apache-2.0. [EULA.md](EULA.md) governs official Pro entitlements, license credentials, updates/support and official-brand terms without overriding applicable open-source rights. Third-party attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
