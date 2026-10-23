# gPTP Studio user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Inspect and debug gPTP / IEEE 802.1AS behavior on a Linux workstation.

## Availability

Engineering preview. An official professional edition is planned, but no purchase or hardware-accuracy guarantee is offered here.

## Platforms and installation

Linux only, with x64 and arm64 release assets. Windows and macOS are not product targets. Physical capture and PHC work require compatible hardware and appropriate privileges.

Use [official Releases](https://github.com/turinglambdaai/gptp-studio/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Start with the deterministic simulator and confirm the GTK window shows the sample clock/session.
2. Review the real-engine setup and hardware qualification before choosing a NIC or enabling capture.
3. Keep the interface, driver, clock source, tool version and capture settings with every result so another engineer can reproduce it.

## Data, backup and recovery

Preserve original capture/session inputs and exports separately from application binaries. Stop capture before copying active files. Packet captures and diagnostics can disclose MAC/IP addresses, topology and equipment identifiers; use synthetic samples for public reports.

## Network, keys and privacy

Capture interacts with the selected network interface. Update/download operations use external services. Do not grant capture or clock-control privileges merely to view a simulation.

## Known limits

Simulator/CI evidence does not qualify a NIC, hardware timestamps, linuxptp interoperability or timing accuracy. Raw capture export and Wireshark replay are free from 0.4.0; engineering reports remain gated. Older builds retain their own behavior.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turinglambdaai/gptp-studio/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Real-engine setup](../docs/linux-real-engine-setup.md)
- [Hardware qualification](../docs/hardware-qualification.md)
- [Diagnostics](../docs/support-doctor.md)
- [Update contract](../docs/update-contract.md)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
