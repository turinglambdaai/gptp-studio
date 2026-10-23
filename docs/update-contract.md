# gPTP Studio Update Contract

> The family online-update pattern (rivet/distribution, taskly benchmark):
> the feed is an Ed25519-signed manifest, the backend verifies and
> downloads, hosts own installation and the silent-check throttle. This
> document is the product contract for gPTP Studio's Linux-only updater.

## Behavior contract

- **Triggers**: one silent check shortly after launch (throttled: at most
  once per 4 hours, persisted as a host-owned stamp file,
  `~/.local/share/gptp-studio/last-update-check`, unix epoch seconds), plus
  a manual `menu ▸ 检查更新… / Check for Updates…` entry that bypasses the
  throttle. Every settled check (any status) records the stamp.
- **Silent mode**: network failure / verification failure → silently
  ignored (never nag). Manual mode reports every outcome.
- **Newer version found** → consent dialog with the new version:
  `下载更新 / Download` or `稍后 / Later`, plus the releases page link.
  Up-to-date → `当前已是最新版本 / You're up to date`.
- **Download**: performed by the backend over the `check-updates` /
  `start-download` / `update-state` / `apply-update` RPCs (rivet
  protocol; hosts never implement crypto). The host polls `update-state`
  (state: idle | downloading | staged | applying | applied | failed) and
  shows progress with the signed percent.
- **The updates window gates staging, not use**: Free and trial installs
  update always; a perpetual Pro install stages exactly the releases its
  entitlement covers. Eligibility is a pure function of the candidate
  release's authenticated `published_at` (the signed feed) against the
  entitlement's `updates_through` — the current date is not an input, so
  a release published inside the window stays stageable forever no
  matter when the customer checks (PRICING.md's authorization decision).
  A release published after the cutoff is refused at `start-download`
  before any network leg and the flow lands on `failed` with the renewal
  message — the customer's installed version keeps working forever
  (perpetual rights, `docs/licensing-model.md`). A newer version is
  still reported honestly: the pill stays, the refusal names the renewal.
- **Bounded transfer**: a stalled download surfaces a retryable error after
  a finite timeout (no byte progress for 120 s, wall clock capped at
  30 min); a slow or stalled manifest fetch is bounded the same way (60 s).
  The progress UI can be detached (family parity: there is no cancel RPC —
  the backend finishes and the next poll shows the outcome).
- **Failure text must leave the screen with the user**: every update and
  error dialog body label is selectable in the host, and the About dialog
  carries `复制诊断信息 / Copy Diagnostics` — one click puts the redacted
  doctor report (version, distro, kernel, Racket runtime, license tier,
  per-NIC PHC/linuxptp verdicts, recent log tail) on the clipboard,
  aligned with the issue template fields.
- **Air-gapped hosts**: `--no-update-check` skips the silent check
  entirely (the manual entry answers with the disabled notice).

## Install shapes (Linux-only, so the form split is short)

| Install | Feed pick | Download | Apply |
|---|---|---|---|
| deb (system install under `/opt` or `/usr`) | `linux/<arch>` `deb` entry | kept at `~/.local/share/gptp-studio/updates/<asset>` | the dialog shows `sudo apt-get install -y <staged deb>`; the optional `安装更新 / Install` button runs the same through `pkexec`, which raises the standard system authentication dialog — nothing installs without the operator's explicit consent |
| relocatable tarball (everything else) | `linux/<arch>` `targz` entry | same stage dir | in-place swap: extract to a temp dir beside the stage, rename the running payload root to `<root>.old`, move the extracted payload in, chmod the launch executables with the integer mode `#o755`; a failed swap restores `<root>.old` so the previous install always stays runnable; the host then offers `重启应用 / Quit to Restart` |

The arm64 feed entries are the same shapes (`gptp-studio-<v>-linux-arm64.*`
assets); `pick-artifact` keys on the running architecture. The AppImage
is a distribution format, not an update shape: its users update by
re-downloading from Releases (the in-app updater serves deb and tarball
shapes only). There is no Windows/macOS channel.

## The feed: `update-stable.json`

- Location: the repository's `main` branch
  (`https://raw.githubusercontent.com/turinglambdaai/gptp-studio/main/update-stable.json`),
  regenerated and committed by the Release workflow's publish job after the
  assets are attached (`feed: x.y.z`) — that commit is what makes the
  check fire for older installs.
- Format: rivet/distribution's signed wrapper — the inner manifest travels
  base64-encoded inside a JSON envelope, so the Ed25519 signature covers
  the exact bytes every client verifies:

```json
{
  "schema": 1,
  "payload": "<base64 of the inner manifest JSON>",
  "signature": { "algorithm": "ed25519", "key_id": "gptp-studio-2026-10",
                 "value": "<base64, 64 bytes>" }
}
```

- Inner manifest (decoded `payload`): rivet's manifest schema —
  `application_id` `site.jrtx.gptp-studio`, `version`, `build` (from
  `rivet.rktd`), `channel` `stable`, RFC 3339 `published_at`, and one
  artifact entry per shape:

```json
{
  "platform": "linux", "architecture": "x64",
  "url": "https://github.com/turinglambdaai/gptp-studio/releases/download/v0.2.0/gptp-studio-0.2.0-linux-amd64.deb",
  "sha256": "<lowercase hex>", "size": 12345678, "installer": "deb", "arguments": []
}
```

- Artifact URLs are pinned to the concrete release tag (the assets carry
  the version in their names). Versionless copies of the installers are
  additionally uploaded as stable aliases
  (`releases/latest/download/gptp-studio-linux-<arch>.<ext>`) for download
  buttons; the feed never points at them.
- Generation: `scripts/make-update-manifest.rkt` (the publish job signs
  with the `UPDATER_PRIVATE_KEY` secret and re-verifies the written feed
  against the shipped anchor `app/keys/updater/public.pem` before
  committing — a mismatched key fails the release).

## Trust chain

1. TLS gets the bytes; it authenticates nothing by itself.
2. `fetch-update-manifest` enforces HTTPS, caps the body at 1 MiB,
   follows the release-asset redirects (budgeted), and verifies wrapper →
   schema → key id → Ed25519 over the exact payload bytes **before
   anything else looks at the data**.
3. rivet's `select-update` applies identity / channel / SemVer precedence /
   rollout (releases ship at 100, bucket 0).
4. The product picks its install shape's artifact (deb for system
   installs, tarball otherwise).
5. The download lands through rivet's `download-update`: redirect-following
   fetch under the signed size cap, `.partial` cleanup on every failure,
   SHA-256 + size verification against the signed manifest, atomic rename
   into the stage dir. Any mismatch aborts the update — silently in silent
   mode, with an error in manual mode.

- Key type Ed25519. The private key lives ONLY in the GitHub secret
  `UPDATER_PRIVATE_KEY` (PEM) and the release manager's local backup —
  never in the repository.
- Public key: pinned twice, same keypair — raw 32 bytes base64 in
  `support/updates.rkt` (`update-public-key-b64`) and the SPKI DER anchor
  `app/keys/updater/public.pem`; the test suite ties the two together.
  `key_id` is `gptp-studio-2026-10`; clients pin it. Rotate = ship a build
  that trusts the next key before releases stop being signed with the old
  one.
- The updater never touches `~/.gptp-studio/` (settings, licenses, run
  state) — it replaces application payloads only.
