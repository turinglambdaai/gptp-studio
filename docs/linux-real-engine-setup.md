# Linux real-engine setup

This guide is for GrandMaster / Slave operation on the supported gPTP Studio
platform: Ubuntu 22.04 LTS or Ubuntu 24.04 LTS.

## 1. Prefer the official Debian package

```bash
sudo apt install ./gPTP-Studio-v1.0.0-linux-amd64.deb
gptp-studio --doctor
```

The package declares linuxptp, WebKitGTK, GTK, libpcap, ethtool, iproute2,
libcap2-bin and OpenSSL dependencies. It uses Debian alternatives for the GTK
and libpcap runtime package names so the same package can be installed on both
22.04 and 24.04 despite the 24.04 `t64` library transition.

The package intentionally does **not** modify sudoers or assign file
capabilities during installation.

## 2. Tarball / source host dependencies

For a tarball or source checkout, install the timing tools plus development
meta-packages that resolve to the correct runtime libraries on both supported
Ubuntu LTS releases:

```bash
sudo apt update
sudo apt install linuxptp ethtool iproute2 libcap2-bin openssl \
  libpcap-dev libgtk-3-dev libwebkit2gtk-4.1-dev
```

Verify the linuxptp tools:

```bash
ptp4l -v
phc2sys -v
pmc -v
```

## 3. Verify NIC hardware timing support

Choose the Ethernet interface connected to the DUT/switch and run:

```bash
ethtool -T <iface>
```

For a real GM/Slave role, gPTP Studio expects the driver/NIC to expose both TX
and RX hardware timestamping plus a PTP Hardware Clock. Typical output includes
hardware timestamp capability flags and a non-negative `PTP Hardware Clock`
index corresponding to `/dev/ptpN`.

Studio Preflight performs the same capability probe automatically. A successful
probe is a **capability** result, not a calibrated timing-accuracy claim.

## 4. Choose a privilege path

### Development / first validation: root or passwordless sudo

For initial hardware bring-up, a controlled lab host using root or explicitly
configured passwordless sudo can be the simplest way to separate permission
problems from NIC/driver problems.

Studio never opens an interactive sudo password prompt. It only uses `sudo -n`
when that path is already configured.

### Recommended non-root deployment: file capabilities

Grant only the capabilities needed by linuxptp:

```bash
sudo setcap cap_net_raw,cap_net_admin+ep "$(command -v ptp4l)"
```

When Studio manages GrandMaster reference time by disciplining the PHC from
`CLOCK_REALTIME`, `phc2sys` additionally needs:

```bash
sudo setcap cap_sys_time+ep "$(command -v phc2sys)"
```

Verify:

```bash
getcap "$(command -v ptp4l)"
getcap "$(command -v phc2sys)"
```

Studio detects these file capabilities and reports the resulting privilege path
in Preflight. A Slave, or a GM whose PHC is maintained by another reference
source, does not require Studio to start `phc2sys`.

Package upgrades can replace the linuxptp binaries and therefore remove file
capabilities. Re-run `getcap` after upgrading `linuxptp`.

## 5. Run Preflight before the first real session

In **链路与网卡 / Links & NICs**, run Preflight for the intended interface and
role.

- **READY**: known structural prerequisites are present.
- **VERIFY**: no hard blocker was found, but a non-fatal item remains (for
  example link down, optional tooling missing, or an unproven ambient
  capability path).
- **PASSIVE ONLY / BLOCKED**: real GM/Slave startup is prevented until the FAIL
  items are fixed.

The engine supervisor repeats this check automatically when a real GM/Slave
session is started. This prevents an API/CLI caller from bypassing the GUI's
hardware checks.

## 6. Link-down behavior

A link that is currently DOWN is intentionally a warning, not a hard failure.
Engine startup may be useful before the DUT or switch is powered. Synchronization
cannot occur until carrier is present.

## 7. Boundary clock (two-port) workflow

A boundary clock relays time between two segments: the **upstream port**
(listed first) synchronizes to the existing GM, and the **downstream port**
serves that time to the devices behind it.

Requirements on the Studio host:

- two physical NICs, each with hardware TX/RX timestamping and its own
  `/dev/ptpN` (Preflight qualifies every port and blocks the session when
  one port lacks hardware support);
- ptp4l and phc2sys installed; the phc2sys privilege path must be usable
  because a BC always runs `phc2sys -a -r` (clock set follows port states).

What Studio generates:

```ini
[global]
...
boundary_clock_jbod        0      # one discipline source across ports
...
```

and launches `ptp4l -f <conf> -i <upstream> -i <downstream> -m` plus
`phc2sys -a -r -w -z <shared-uds> -m`. Since linuxptp 3.0 multiple `-i`
ports imply a boundary clock (`boundary_clock_enabled` no longer exists).

Notes:

- Port numbering follows the `-i` order: port 1 = upstream. The status bar
  shows per-port states (`P1 SLAVE · P2 GRAND_MASTER`).
- `boundary_clock_jbod 0` keeps one clock across ports; per-port PHC islands
  (`jbod 1`) are out of scope for this workflow.
- GM runtime tuning (`pmc GRANDMASTER_SETTINGS_NP`) applies to what the BC
  announces on its master side.

## 8. Support workflow

If a real session still fails:

```bash
gptp-studio --doctor > doctor.txt
gptp-studio --doctor-json > doctor.json
```

Doctor removes MAC and IP addresses by default while retaining interface/driver,
PHC, linuxptp tooling, privilege and per-role qualification facts. The GUI NIC
page also exposes the same qualification model and recent runtime state/logs.

## 9. Timing claims

Do not infer end-to-end timing accuracy from any of the following alone:

- NIC model;
- existence of `/dev/ptpN`;
- nanosecond timestamp resolution;
- a READY Preflight result;
- successful `ptp4l` convergence.

Publish an accuracy number only after characterizing the pinned host/NIC/PHY/
software/topology against an appropriate independent timing reference. See
[`hardware-qualification.md`](hardware-qualification.md).
