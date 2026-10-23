# gPTP Studio

**A Linux-native gPTP / IEEE 802.1AS debugging workstation for Automotive Ethernet.**

[![CI](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/gptp-studio/actions/workflows/ci.yml) ![Platform](https://img.shields.io/badge/platform-Linux-blue) ![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

gPTP Studio is deliberately focused on Linux because professional gPTP work depends on Linux capabilities that matter in the measurement path: **PHC, hardware timestamping, `SO_TIMESTAMPING`, linuxptp, sysfs NIC introspection and explicit privilege control**. The product does not maintain reduced-function desktop ports that cannot provide the same timing path.

For AUTOSAR EthTSyn / IEEE 802.1AS debugging, one Linux workstation can act as **GrandMaster, Slave or passive Listener**, show sync convergence live, decode every gPTP frame and correlate timing jumps with the packets and engine state that caused them.

Built with [Racket](https://racket-lang.org/) + [Rivet](https://github.com/turinglambdaai/rivet): a first-party GTK4 desktop host over an embedded Racket backend through a typed RPC/event contract, with Linux-native timing/network facilities for the real engine path. Live sync convergence renders through Rivet's shared real-time chart data plane.

## Highlights

- **Four roles, one workstation** — GrandMaster, Slave, two-port Boundary Clock (multi-interface `ptp4l` + `phc2sys -a -r`) and passive Listener with generated `ptp4l.conf`
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
| Primary validated distribution | Ubuntu 24.04 LTS (the GTK4 host requires GTK 4.10+; 22.04's 4.6 is below the floor) |
| Desktop UI | Rivet host on GTK4 (first-party widgets, no WebView) |
| Real GM / Slave engine | linuxptp (`ptp4l`, `phc2sys`, `pmc`) |
| Timing hardware | NIC hardware timestamping + PHC (`/dev/ptpN`) |
| Capture | libpcap, with runtime timestamp-source reporting |
| Packages | `.deb` / `.rpm` / `.AppImage` and relocatable `.tar.gz` (+ portable `.zip`); every asset ships a `.sha256` sidecar and releases carry an aggregate `SHA256SUMS` |
| Other operating systems | Unsupported by product design |

A NIC reporting hardware timestamping and `/dev/ptpN` means the host has the required capability for the linuxptp path. It does **not** by itself prove calibrated end-to-end timing accuracy. Studio keeps capability, runtime timestamp source and any future characterization results separate.

## Install

### Debian / Ubuntu package

```bash
curl -LO https://github.com/turinglambdaai/gptp-studio/releases/latest/download/gptp-studio-linux-amd64.deb
sudo apt install ./gptp-studio-linux-amd64.deb
/opt/gptp-studio/gptp-studio --doctor
/opt/gptp-studio/gptp-studio
```

The deb installs under `/opt/gptp-studio` with a desktop entry; the
commands above are the headless and direct-launch forms.

The Debian package declares the Linux runtime dependencies and installs the desktop entry, icon and license notices. It intentionally does **not** grant `CAP_NET_ADMIN`, `CAP_NET_RAW` or `CAP_SYS_TIME` during installation. Doctor / Preflight show the privilege path explicitly so an operator controls security changes.

### Relocatable tarball

```bash
curl -LO https://github.com/turinglambdaai/gptp-studio/releases/latest/download/gptp-studio-linux-x64.tar.gz
tar -xzf gptp-studio-linux-x64.tar.gz
cd gptp-studio-distributed
./bin/gptp-studio --doctor
./bin/gptp-studio
```

### RPM-based distributions

Download `gptp-studio-<version>-<build>-linux-x86_64.rpm` (or
`-aarch64.rpm`) from the
[releases page](https://github.com/turinglambdaai/gptp-studio/releases/latest)
and install it:

```bash
sudo dnf install ./gptp-studio-<version>-<build>-linux-x86_64.rpm
gptp-studio --doctor
```

### AppImage (any distribution, no install)

The AppImage bundles its GTK4 dependency closure, so it runs on older
hosts than the deb/rpm require; the same `--doctor` headless surface
works before any GUI session:

```bash
curl -LO https://github.com/turinglambdaai/gptp-studio/releases/latest/download/gptp-studio-linux-x64.AppImage
chmod +x gptp-studio-linux-x64.AppImage
./gptp-studio-linux-x64.AppImage --doctor
./gptp-studio-linux-x64.AppImage
```

### From source

```bash
sudo apt install linuxptp libpcap-dev ethtool iproute2 libcap2-bin \
  libgtk-4-dev libglib2.0-dev libsecret-1-dev libncurses-dev zlib1g-dev liblz4-dev \
  rpm desktop-file-utils

raco pkg install --auto --no-docs https://github.com/turinglambdaai/rivet.git
raco pkg install --auto --no-docs https://github.com/turinglambdaai/permit.git
raco rivet generate
raco rivet build          # builds the GTK4 host (binary lands in .rivet/build/linux/)
raco test tests/          # backend test suite
raco rivet dev            # run the app; the built binary also answers --doctor
```

For real hardware work, start with `gptp-studio --doctor`, fix structural FAIL items, then use GUI Preflight on the exact interface before starting GM/Slave. See [docs/support-doctor.md](docs/support-doctor.md) and [docs/hardware-qualification.md](docs/hardware-qualification.md).

### Update check

About 2.5s after startup the app fetches the Ed25519-signed update feed once in the background (`update-stable.json`, hosted on this repository's main branch; the signature is verified against the key pinned in the binary before anything else looks at the feed). On a newer release an `⬇ version` pill appears in the header and links to the releases page. **Nothing is installed automatically** — staging the update downloads the artifact under the signed manifest's size/digest bounds, and applying runs `apt-get install` through `pkexec`, so what gets installed stays with the operator. Installs from before the signed-feed switch (≤ 1.2.0) fetched the retired unsigned `latest.json` and must update once manually (download the .deb from Releases). Air-gapped hosts can disable the network contact entirely with `--no-update-check`, or point `GPTP_UPDATE_MANIFEST_URL` at their own HTTPS mirror of the feed (plain HTTP is refused by design).

## Pages

| Page | What it does |
|---|---|
| Overview | Live offset/delay curves, port state, current GM, alarm threshold |
| Links & NICs | NIC HW timestamp / PHC capability and actual capture timestamp path |
| Role & Config | Role switch (incl. Boundary Clock port set), gPTP parameters, generated `ptp4l.conf`, start/stop |
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
| GM / Slave / Boundary Clock engine control | — | ✅ |
| Reference source (`phc2sys`) | — | ✅ |
| pcap export | — | ✅ |
| Packet store | 2,000 frames | 50,000 frames |

The source code is Apache-2.0. Free/Pro describe the product experience, update entitlement and support attached to **official distributions**; they do not revoke rights already granted by Apache-2.0. Self-built or modified Apache-2.0 versions are not automatically official Pro builds and do not carry official update/support/validation commitments.

Every official install starts with a 14-day Pro trial. See [PRICING.md](PRICING.md) and [docs/licensing-model.md](docs/licensing-model.md).

## Architecture

One Racket backend process serves a typed RPC/event contract to the native GTK4 host; real timing is delegated to Linux-native facilities: linuxptp child processes, PHC/hardware timestamps and libpcap. Timing-critical timestamps are produced below the Racket GUI/control layer; Studio focuses on orchestration, observability, analysis and safe qualification. Details: [docs/architecture.md](docs/architecture.md).

## License

gPTP Studio source and Apache-covered portions of official distributions remain licensed under Apache-2.0. [EULA.md](EULA.md) governs official Pro entitlements, license credentials, updates/support and official-brand terms without overriding applicable open-source rights. Third-party attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Feedback and diagnostics

Report reproducible bugs and feature requests through [GitHub Issues](https://github.com/turinglambdaai/gptp-studio/issues). Include the release, OS/architecture and steps; inspect and redact diagnostics before sharing. Do not post API keys, license files, vault contents or private documents. For sensitive security reports, follow SECURITY.md when present; otherwise request a private contact route without disclosing sensitive details. Nothing is uploaded automatically.

## Product & pricing

Linux professional tool; purchase of the official Pro product. Read the complete [English pricing and product policy](PRICING.md) or [简体中文](PRICING.zh-CN.md) for target prices, free/paid boundaries and launch gates. This is a launch design, not a live offer; this documentation does not add payment restrictions to current development builds.
