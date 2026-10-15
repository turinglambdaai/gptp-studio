---
name: Bug report
about: Something in gPTP Studio is broken or behaves differently from the docs
title: ''
labels: bug
assignees: ''
---

**Describe the bug**

A clear description of what happened and what you expected instead.
中文描述完全没问题 — 写清楚即可。

**To reproduce**

Steps that trigger the behavior (role/mode, interface, capture path):

```
/opt/gptp-studio/gptp-studio --doctor
```

**Environment**

- Distribution: Ubuntu 24.04 LTS is the validated floor (other distros: note the exact release)
- gPTP Studio version: (menu ▸ About, or `gptp-studio --doctor` header line)
- Install shape: deb (`/opt/gptp-studio`) / relocatable tarball
- Desktop session: X11 / Wayland

**gPTP / NIC context (if the problem involves timing, sync or capture)**

- Which NIC(s) and whether hardware timestamping is reported (`ethtool -T <iface>`)
- `ptp4l` / `phc2sys` / `pmc` availability (`ptp4l -v`)
- The gPTP network topology (DUT / switch / GM source), if relevant

**Diagnostics**

Fastest path: in the app open menu ▸ About ▸ **复制诊断信息 / Copy
Diagnostics**, then paste the clipboard contents here. It carries the
version, distro, kernel, Racket runtime, license tier, per-NIC PHC/linuxptp
verdicts and the recent log tail — with MAC/IP and host identifiers
redacted.

**Update context (if this happened during an update)**

- The exact error text — in the app you can select and copy it from the
  update dialog, or grab the staged file name under
  `~/.local/share/gptp-studio/updates/`.

**Screenshots / logs**

If applicable, add screenshots or console output.
