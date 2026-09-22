# Headless Support Doctor

`gptp-studio --doctor` is the first command to run when a customer reports that
real gPTP operation cannot start or behaves differently across machines. It does
not open the GUI, does not acquire the single-instance lock, and does not modify
or discipline any clock.

## Human-readable report

```bash
gptp-studio --doctor
```

The report lists each detected non-loopback interface and summarizes:

- driver, link state and reported speed;
- hardware timestamp capability and mapped PHC;
- availability of `ptp4l`, `phc2sys` and `pmc`;
- detected privilege path;
- independent qualification for Slave, GM with system reference, and GM with an
  externally managed PHC;
- blocking actions and VERIFY/warning items.

A typical support workflow is: run Doctor, fix structural FAIL items, then run
the GUI Preflight on the exact interface/topology and finally attempt the real
session.

## Machine-readable report

```bash
gptp-studio --doctor-json > gptp-doctor.json
```

The JSON schema currently reports `schema_version: 1`. It is intended for
support tickets, lab automation and future fleet/reference-platform validation.

Both Doctor formats deliberately omit MAC and IP addresses. The report states
`network_identifiers_redacted: true`, so a customer can normally attach it to a
support ticket without disclosing local network identifiers.

## Interpreting status

- `READY`: the known structural prerequisites for that role are present.
- `CANDIDATE` / `VERIFY`: no known hard blocker, but something still needs
  verification (for example link DOWN or an unproven privilege path).
- `PASSIVE-ONLY`: the host/NIC is useful for protocol analysis but a confirmed
  hardware timing prerequisite is absent for that real clock role.
- `BLOCKED`: another structural prerequisite is absent.

Doctor uses the same qualification engine as GUI Preflight and supervisor start
protection, so support output cannot drift into a separate definition of
"supported".

## Privacy and timing claims

Doctor is a readiness/support tool, not a calibration tool. `READY`, a PHC,
hardware timestamp capability, or nanosecond timestamp resolution must never be
translated into an accuracy claim. The JSON explicitly carries
`accuracy_claim: "not-calibrated"`.

For a publishable timing specification, use the pinned reference-platform and
external-characterization process in
[`hardware-qualification.md`](hardware-qualification.md).

## Exit behavior

A successfully generated report exits with code `0` even when one or all NICs
are unsuitable for real GM/Slave operation. Suitability is data inside the
report; this keeps Doctor useful in CI and support automation instead of turning
a customer's hardware state into a command-execution failure.

An internal Doctor failure exits with code `2` and writes the error to stderr.
