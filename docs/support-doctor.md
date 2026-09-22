# Headless Support Doctor

`gptp-studio --doctor` is the first command to run when a Linux host behaves
differently from another workstation or when a real GM/Slave session cannot
start.

The Doctor does not open the GUI, does not acquire the single-instance lock and
does not modify any clock, capability or sudo configuration.

```bash
gptp-studio --doctor
gptp-studio --doctor-json > doctor.json
```

## What it records

The report has two layers.

### Host fingerprint

The host section is designed for reproducible reference-platform work and
support comparison. It records non-unique engineering facts such as:

- distribution ID / version / pretty name;
- kernel release, kernel build string and architecture;
- system vendor, product name and board name;
- virtualization environment;
- active Linux clocksource;
- Racket runtime version;
- `ptp4l`, `phc2sys`, `pmc`, `ethtool` and OpenSSL versions when detectable;
- installed `linuxptp`, libpcap, WebKitGTK and GTK package versions when
  `dpkg-query` can resolve them.

It deliberately does **not** collect hostname, machine-id, DMI serial numbers,
product UUIDs or other unique machine identifiers.

### NIC / PHC fingerprint

For each non-loopback interface the Doctor reports:

- interface name;
- driver + driver version;
- firmware version;
- PCI/bus location;
- PCI vendor/device and subsystem IDs when sysfs exposes them;
- NUMA node;
- link state and speed;
- hardware TX/RX timestamp capability;
- mapped `/dev/ptpN` and PHC `clock_name`;
- linuxptp tool availability;
- file-capability / root / sudo privilege path;
- Slave, GM(system reference), and GM(external/managed PHC) qualification.

MAC addresses and IP addresses are omitted from the support report even though
the GUI may use them locally for normal network display.

## Privacy contract

The JSON report carries explicit privacy flags:

- `network_identifiers_redacted=true`;
- `host_identifiers_redacted=true`;
- host fingerprint flags declaring hostname, machine-id, hardware serials and
  network identifiers omitted.

CI tests the schema so a future refactor cannot casually add obvious unique
identity keys to the fingerprint.

A support report is still technical environment data. Review it under your
organization's normal disclosure policy before attaching it to an external
support ticket.

## Role status meanings

- **READY** — known structural prerequisites are present. This is permission to
  proceed with the real workflow, not a calibration result.
- **VERIFY** — no hard blocker is known, but one or more non-fatal items still
  require real-process or lab verification.
- **PASSIVE-ONLY** — the interface remains useful for packet/protocol work but
  does not expose the hardware timing path required by a real clock role.
- **BLOCKED** — a known structural prerequisite is missing.

Doctor and GUI Preflight use the same qualification engine, and the Supervisor
runs that qualification again immediately before spawning a real engine.

## Comparing two hosts

When two machines with “the same NIC” behave differently, compare these fields
before investigating application code:

1. distro and kernel;
2. system/board model and virtualization;
3. clocksource;
4. NIC PCI vendor/device/subsystem IDs;
5. driver + driver version;
6. firmware version;
7. bus location / NUMA node;
8. PHC clock name;
9. linuxptp version;
10. privilege mode.

This often exposes meaningful differences hidden by a marketing model name, for
example a different subsystem device, firmware revision, kernel/driver revision
or virtualized attachment path.

## Reference-platform use

A Doctor fingerprint can be stored next to a validation record as the machine-
readable inventory for a **Candidate** or **Studio-validated** platform. It does
not promote a platform to `Studio-validated` automatically; the repeatable
procedure in [`hardware-qualification.md`](hardware-qualification.md) still has
to be executed on real hardware.

## Accuracy boundary

The report always retains:

```text
accuracy_claim = not-calibrated
```

PHC presence, nanosecond timestamp resolution, a specific NIC model or a READY
qualification are capability/observability facts. Publish an accuracy number
only after external characterization of the pinned host/NIC/PHY/software/
topology against an appropriate independent timing reference.

## Exit behavior

A successfully generated report exits with code `0` even when one or all NICs
are unsuitable for real GM/Slave operation. Suitability is data inside the
report; this keeps Doctor useful in CI and support automation instead of turning
a customer's hardware state into a command-execution failure.

An internal Doctor failure exits with code `2` and writes the error to stderr.
