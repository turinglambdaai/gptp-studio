# Linux real-engine setup

This guide is for GrandMaster / Slave operation on a Linux debug host. Passive
capture, offline analysis and the simulator have fewer requirements.

## 1. Runtime packages

On Debian / Ubuntu, install the timing and NIC inspection tools:

```bash
sudo apt update
sudo apt install linuxptp ethtool iproute2 libcap2-bin libpcap0.8
```

A source build also needs development headers (for example `libpcap-dev` and the
WebKitGTK development package used by Glaze). A distributed GUI still relies on
the host WebKitGTK runtime supplied by the distribution; gPTP Studio's tarball
does not attempt to bundle kernel-facing/system GUI libraries.

Verify the linuxptp tools:

```bash
ptp4l -v
phc2sys -v
pmc -v
```

## 2. Verify NIC hardware timing support

Choose the Ethernet interface connected to the DUT/switch and run:

```bash
ethtool -T <iface>
```

For a real GM/Slave role, gPTP Studio expects the driver/NIC to expose both TX
and RX hardware timestamping plus a PTP Hardware Clock. Typical output includes
hardware timestamp capability flags and a non-negative `PTP Hardware Clock`
index corresponding to `/dev/ptpN`.

Studio's Preflight page performs the same capability probe automatically. A
successful probe is a **capability** result, not a calibrated timing-accuracy
claim.

## 3. Choose a privilege path

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

## 4. Run Preflight before the first real session

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

## 5. Link-down behavior

A link that is currently DOWN is intentionally a warning, not a hard failure.
Engine startup may be useful before the DUT or switch is powered. Synchronization
cannot occur until carrier is present.

## 6. Support bundle

If a real session still fails, export the diagnostic snapshot from the NIC page.
By default it removes MAC and IP addresses while retaining the information
needed for support: interface/driver, PHC, linuxptp tooling, Preflight result,
engine/capture state, current configuration and recent logs.

## 7. Timing claims

Do not infer end-to-end timing accuracy from any of the following alone:

- NIC model;
- existence of `/dev/ptpN`;
- nanosecond timestamp resolution;
- a READY Preflight result;
- successful `ptp4l` convergence.

Publish an accuracy number only after characterizing the pinned host/NIC/PHY/
software/topology against an appropriate independent timing reference. See
[`hardware-qualification.md`](hardware-qualification.md).
