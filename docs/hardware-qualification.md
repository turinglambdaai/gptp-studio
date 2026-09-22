# Hardware qualification and reference platforms

This document defines what gPTP Studio is allowed to claim about a host/NIC and
how a platform progresses from "detected" to "validated".

The core rule is simple:

> Capability detection is not a timing-accuracy calibration.

A NIC can expose hardware timestamping and a PHC, libpcap can report nanosecond
resolution, and linuxptp can converge successfully while the end-to-end setup
still has uncharacterized PHY, topology, oscillator, driver, queueing or
reference-clock error.

## Product states

### Preflight: READY

Studio detected all known structural prerequisites for the selected workflow.
For a real GrandMaster/Slave role this currently means:

- Linux control path;
- a selected Ethernet interface exists;
- hardware TX + RX timestamp capability is reported;
- a PHC is mapped to the interface;
- `ptp4l` is available;
- `phc2sys` is available when GrandMaster uses the system clock as reference;
- a proven privilege path is available (root, passwordless sudo, or the
  role-appropriate linuxptp file capabilities).

`READY` means "reasonable to start the real workflow". It does **not** mean the
host is a calibrated timing instrument.

### Preflight: VERIFY

No structural blocker is known, but one or more non-fatal items still need
verification, for example:

- Ethernet carrier is currently down (the engine may start and wait for link);
- the privilege path is direct-best-effort / ambient capabilities are not
  proven until the real process starts;
- `pmc` or auxiliary detection tools are absent;
- a running capture uses host/default rather than adapter timestamps.

A VERIFY result does not prevent startup. The actual `ptp4l` / `phc2sys` process
result and logs remain authoritative.

### Preflight: PASSIVE ONLY

The selected NIC/host is useful for packet/protocol analysis but does not expose
the hardware timing path required by the real GM/Slave engine.

For real GM/Slave startup, this state is a hard blocker.

### Preflight: BLOCKED

A structural prerequisite is missing (for example a selected interface does not
exist, `ptp4l` is unavailable, or GM system-reference mode requires a missing
`phc2sys`).

For real GM/Slave startup, this state is a hard blocker.

## Automatic startup guard

The same qualification logic is enforced inside the engine supervisor, not only
in the GUI. Every real GM/Slave start re-detects the host/NIC before spawning
linuxptp:

- FAIL checks stop startup before `ptp4l` is spawned;
- WARN checks are logged as `Preflight=VERIFY` and startup is allowed;
- simulator and passive Listener workflows are not forced through the real
  clock-role guard.

This prevents a future CLI/API entry point from accidentally bypassing the
hardware prerequisites enforced by the UI.

## Linux privilege paths

Studio recognizes these proven paths:

1. running as root;
2. passwordless `sudo -n`;
3. file capabilities on linuxptp binaries.

For non-root deployment, the usual capability set is:

```bash
sudo setcap cap_net_raw,cap_net_admin+ep "$(command -v ptp4l)"
# Needed only when Studio manages GM reference as CLOCK_REALTIME -> PHC:
sudo setcap cap_sys_time+ep "$(command -v phc2sys)"
```

A Slave or GM using an externally managed PHC does not require `phc2sys` from
Studio. Ambient/container capabilities can also work, but Studio intentionally
labels an unproven path VERIFY until the real process successfully starts.

## Reference-platform lifecycle

Use these labels in documentation, support replies and release notes.

| Label | Meaning | Allowed claim |
|---|---|---|
| Candidate | Hardware looks suitable on paper / in capability detection | "Candidate for validation" |
| Studio-validated | We ran the repeatable validation procedure below on a pinned hardware/software combination | "Validated with gPTP Studio on the listed versions" |
| Calibrated setup | A Studio-validated platform was additionally characterized against an appropriate external timing reference/instrument | Only the measured/calibrated result, with setup and uncertainty stated |

Do not use "instrument grade", "<100 ns", or similar accuracy language from NIC
model, PHC presence, timestamp resolution, or `ptp4l` convergence alone.

## Validation record

Start every record by saving the machine-readable Doctor fingerprint:

```bash
gptp-studio --doctor-json > doctor.json
```

The fingerprint deliberately omits unique host/network identity while pinning
facts that commonly explain timing differences between apparently identical
machines:

- Linux distribution and kernel release/build;
- architecture, system vendor/product/board, virtualization and clocksource;
- linuxptp and relevant runtime package versions;
- NIC PCI vendor/device/subsystem IDs and bus location;
- NIC driver + driver version + firmware;
- PHC device and `clock_name`;
- link speed and NUMA placement;
- privilege path.

A complete validation record should additionally pin:

- external computer/motherboard asset identifier in the lab's private record
  (do not put it into the public Doctor report);
- PHY/transceiver where relevant;
- gPTP Studio version/commit;
- peer device / switch topology;
- cable/media details where relevant;
- test duration and load conditions;
- external reference/instrument model and calibration status when performing
  characterization.

Store the exported Doctor JSON and any test evidence together. Two runs should
be considered the *same reference platform* only when the material fingerprint
fields are intentionally equivalent; a marketing NIC name alone is not enough.

## Repeatable validation procedure

1. **Inventory** — save `--doctor-json` and the private lab record described
   above.
2. **Capability** — verify Preflight has no hard failures for the target role.
3. **Lifecycle** — start/stop/restart the real engine repeatedly and confirm no
   orphan `ptp4l`/`phc2sys` process or stale management socket remains.
4. **GM role** — verify the expected port state, Announce/Sync/Follow_Up traffic,
   and `pmc CURRENT_DATA_SET` response.
5. **Slave role** — verify synchronization convergence and stable
   `offsetFromMaster` / `meanPathDelay` reporting.
6. **Reference clock** — when system-reference mode is selected, verify
   `phc2sys` is running against the same per-user ptp4l management socket and
   survives/restarts with the session.
7. **Capture path** — record the actual libpcap timestamp source and precision.
   Treat host/default timestamps as diagnostic-only for timing conclusions.
8. **Stress** — repeat under realistic CPU, network and storage load; include at
   least one link flap and engine restart.
9. **Soak** — run a long-duration session and check for process, memory, packet
   store and timestamp anomalies.
10. **External characterization** — before publishing an accuracy number,
    compare the setup against a suitable independent timing reference or
    calibrated instrument and document the uncertainty and topology.

## Initial hardware program

The first useful commercial milestone is not a custom PCB. It is a small
**reference-platform program**:

1. choose one or two common Linux hosts;
2. choose one or two PTP-capable PCIe NIC candidates (Intel I210/I350-class
   adapters are sensible starting candidates, but remain *Candidate* until the
   procedure above is completed);
3. pin an Ubuntu/Linux + linuxptp stack;
4. capture the Doctor fingerprint for every accepted configuration;
5. publish the exact validated matrix using non-unique hardware/software facts;
6. use customer feedback to decide whether a dedicated Studio Box is justified.

A future Studio Box should exist to provide deterministic hardware, automotive
Ethernet interfaces, dual-sided/inline timestamping, controlled injection and
external references—not because a normal Linux host is inherently incapable of
useful hardware-timestamped gPTP debugging.
