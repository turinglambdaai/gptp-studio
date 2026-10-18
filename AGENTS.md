# gPTP Studio agent contract

gPTP Studio is a Linux-only Rivet application: a Racket domain/backend core
drives one first-party GTK4 host over RVT1. Windows and macOS are not product
targets. Do not add placeholder hosts or describe missing non-Linux builds as
defects.

Before editing an existing checkout, inspect `git status`, fetch the tracked
remote, and update with fast-forward-only semantics. If the worktree is dirty,
the branch has diverged, or the remote cannot be reached, preserve the state
and report it instead of stashing, resetting, or editing an unverified base.
Record the starting commit in the handoff evidence.

## Executable completion contract

Run the complete Linux product gate with:

```bash
raco rivet acceptance --json
```

`rivet-acceptance.rktd` is the source-controlled definition of done. Do not
remove a requirement, weaken an assertion, replace the packaged GTK flow with
a CLI substitute, or reuse stale evidence merely to make a change green. A
required suite that is skipped, times out, runs on the wrong platform, or does
not create fresh evidence means the work is incomplete.

The ordinary validation layers remain useful:

```bash
raco test tests/*.rkt
raco rivet build
```

Generated clients and `.rivet/`, `build/`, and `dist/` are build outputs; do
not hand-edit them. RPC changes start in `app/backend.rkt` and must regenerate
the GTK client through `raco rivet build`.

## Hardware boundary

The checked-in acceptance gate uses the deterministic simulator and a
disposable home. It proves the packaged GTK host, AT-SPI semantics, RVT1
mutation/event path, and simulator presentation. Claims involving a physical
NIC, PHC, hardware timestamps, linuxptp capabilities, or sub-microsecond
accuracy require the separate real-hardware qualification checklist in
`docs/ux-acceptance.md`; generic CI evidence must never be presented as that
qualification.
