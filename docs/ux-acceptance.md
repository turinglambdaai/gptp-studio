# GTK interaction qualification

**English** · [简体中文](ux-acceptance.zh-CN.md)

Revision: 2026-10-23. This is the interaction supplement to the existing
[product acceptance guide](../ACCEPTANCE.md) and executable
[`rivet-acceptance.rktd`](../rivet-acceptance.rktd), not a second release gate.
All items below require fresh evidence; publishing this checklist does not
mark them passed. Follow [issue #40](https://github.com/turinglambdaai/gptp-studio/issues/40).

## Actual interface and ownership

The product is Linux-only, with a Rivet/GTK4 native host. The current six pages
are Engine, Qualification, Packets, Logs, GM Tuning and License & Reports.
The native-package baseline is Ubuntu 24.04 / GTK >= 4.10, as specified in
ACCEPTANCE. An AppImage needs its own host compatibility evidence; bundled
libraries do not establish support for every older distribution. Do not use
the retired WebKitGTK page list, build commands or unverified Ctrl+1…6 bindings.

The primary user loop is select a simulator/real target and interface, inspect
readiness, explicitly start a session, inspect timing/packets, stop the owned
work and export evidence. Passive listener is the initial role. Protocol and
preflight policy remain in the shared backend; the host owns native input,
focus, accessible controls and honest state presentation.

## One scenario contract

| Initial state / action | Required visible result and recovery |
| --- | --- |
| Fresh package, start simulator | Mode and passive role are identifiable; startup progresses to useful status or an actionable failure. No real clock-role process starts implicitly. |
| Select real mode / interface / role | The selected target, actual running session and preflight result are distinguishable. Pending edits are not presented as applied configuration. |
| Start is rejected | Name the failed prerequisite and next diagnostic action; preserve an existing healthy session. READY is capability detection, never accuracy calibration. |
| Session is running | Curves, packet details and logs identify their source. A simulator trace is never labelled physical-NIC evidence. |
| Stop engine / stop capture | Show their independent outcomes and any still-running owned process. Do not label one control Stop All until that behavior exists and is verified. |
| Packet selection / filter / detail | Selection and detail identify the same packet; native keyboard operation and return focus are defined. Preserve selection or explain its invalidation during live refresh. |
| Export / permission failure | Raw capture export and retained Wireshark replay remain free; paid reports follow current PRICING. Cancellation/failure does not announce a completed export or leave a misleading final file. |
| Change language / window / text scale | Primary page names, mode/role controls, status/error and recovery actions remain usable. Shared semantics do not require identical typography or fixed dimensions. |

Use existing widget names and documented native activation. Any additional
keyboard shortcut, focus rule or state representation remains a target until
implemented and exercised through native input. Do not invent automation IDs
or substitute CLI output for the GUI interaction.

## Evidence to record

- [ ] Source/dependency SHAs, package digest/format, distro, architecture, GTK version, display backend, language and scale.
- [ ] Clean simulator start → input → visible result → stop → export, with disposable data and native accessibility/keyboard evidence.
- [ ] Missing dependency, failed startup, denied start, failed export and recovery; preserve user context and any existing healthy session.
- [ ] Keyboard reachability, names/roles, focus return and readable layouts at declared supported window sizes and enlarged text; new screenshots of the actual artifact.
- [ ] Free export and report refusal/import/recovery follow current policy; distinguish authenticated release-time update eligibility from the current date.

Physical NIC/PHC, hardware timestamps, actual privileges, reference clocks and
timing accuracy require the separate [hardware qualification](hardware-qualification.md)
and [real-engine setup](linux-real-engine-setup.md) evidence. Run real clock-role
changes only on the explicitly selected test setup. Do not count simulator,
build, queued, skipped or unrun checks as those results.
