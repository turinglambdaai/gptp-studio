# gPTP Studio

**The gPTP / IEEE 802.1AS debugging workstation — one laptop, three roles, full visibility.**

[![CI](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

**English** · [中文](README.zh-CN.md)

Debugging gPTP (IEEE 802.1AS, implemented by AUTOSAR EthTSyn) on an ECU today means juggling a fixed-role master clock, Wireshark and raw `ptp4l`/`pmc` terminals. **gPTP Studio** collapses that into one window: your laptop switches between **GrandMaster / Slave / passive Listener**, the sync convergence is drawn live, and every gPTP message on the wire is decoded in place — at the moment the offset jumps, you see the packet that caused it.

Built with [Racket](https://racket-lang.org/) + [Glaze](https://github.com/turinglambdaai/glaze) (Racket backend, native WebView window, no Node, no native toolchain).

## Highlights

- **Three roles, one click** — GrandMaster (feed the ECU), Slave (validate the ECU's GM), Listener (pure observation), each a `ptp4l` config generated and previewed live from the GUI form
- **Real-time sync curves** — `offsetFromMaster` / `meanPathDelay` at the Sync rate (8 Hz for gPTP), alarm threshold with red banner + system notification
- **gPTP packet capture & decode** — libpcap live capture (`ether proto 0x88f7`), full field decode of Sync / Follow_Up / Announce / PDelay\_\* / Signalling incl. the 802.1AS follow-up info TLV, hex view, pcap + pcapng import, pcap export
- **Built-in simulator** — a synthetic 802.1AS session (real encoded frames through the same decoder) so you can demo, test and learn without hardware or even a Linux box
- **Scenario presets** — save role + parameter + interface combos, apply-and-go; export the generated `ptp4l.conf`
- **Aggregated logs** — ptp4l, phc2sys, capture, app events in one view with level/source filters and export
- **Offline licensing** — RSA-2048 signed license files, 14-day Pro trial, machine binding; verification via the system `openssl` CLI (zero extra dependencies)

## Pages

| Page | What it does |
|------|--------------|
| Overview | Live offset/delay curves, port state, current GM, alarm threshold |
| Links & NICs | Interface list with HW-timestamp/PHC detection (`ethtool -T`), SW-timestamp warning |
| Role & Config | Role switch, gPTP parameter form, live `ptp4l.conf` preview, start/stop |
| Reference | System clock → PHC via `phc2sys` (Pro) |
| Packets | Capture control, live packet table, decoded tree + hex, import/export |
| Runtime & Logs | Process states, aggregated logs, presets, license |

## Platforms

| Capability | Linux | macOS |
|---|---|---|
| GrandMaster / Slave engine (linuxptp) | ✅ | — (no `SO_TIMESTAMPING`/PHC; by design, see PRD) |
| Listener capture (HW timestamps) | ✅ | software timestamps only |
| Offline pcap analysis | ✅ | ✅ |
| Simulator | ✅ | ✅ |

## Quick start

```bash
# Linux (debug host)
sudo apt install linuxptp libpcap-dev   # engine + capture
./gptp-studio                            # GUI opens
# or: sudo setcap cap_net_admin+ep $(which ptp4l) to avoid sudo

# macOS (analysis + simulator)
open "gPTP Studio.app"
```

From source:

```bash
raco pkg install --auto --no-docs --link /path/to/glaze   # framework dependency
raco make main.rkt
racket main.rkt                # GUI
racket main.rkt --simulator    # GUI + synthetic gPTP session (no hardware needed)
racket main.rkt --selfcheck    # headless smoke test (CI)
raco test tests/               # 155 tests
```

## Licensing

| | Free | Pro |
|---|---|---|
| Listener capture + packet decode | ✅ | ✅ |
| Offline pcap import | ✅ | ✅ |
| Simulator | ✅ | ✅ |
| Config editor + `ptp4l.conf` preview | ✅ | ✅ |
| GM / Slave engine control | — | ✅ |
| Reference source (phc2sys) | — | ✅ |
| pcap export | — | ✅ |
| Packet store | 2 000 frames | 50 000 |

Every install starts with a 14-day Pro trial. See [PRICING.md](PRICING.md).

## Architecture

One Racket process: glaze serves the UI over loopback HTTP into a native WebView window; the engine supervisor spawns `ptp4l`/`phc2sys` (Linux, `sudo -n` strategy) and a non-blocking libpcap FFI poll loop (cooperative-scheduler safe); a simulator backend drives the same decode pipeline for hardware-free runs. Details in [docs/architecture.md](docs/architecture.md), the 802.1AS field maps in [docs/protocol-reference.md](docs/protocol-reference.md).

## License

Apache-2.0 for the source; the distributed binaries are governed by [EULA.md](EULA.md). Commercial licensing and support: see [PRICING.md](PRICING.md).
