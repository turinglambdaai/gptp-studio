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

## 组合定位（Portfolio placement）

- 轨道与授权：轨道 1 商业支柱（B2B 专业工具）；授权形态：Apache-2.0 开源核心 + 官方 Pro；商业归属：第一棒，模式已落地（见本仓 PRICING.md 与 docs/licensing-model.md）。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `docs/licensing-model.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/gptp-studio/issues/35)。保持 Linux-only；先完成 Commerce 一次性购买到离线凭据及更新资格的纵切。区分命名席位、设备数和合同约定，不宣传离线实时撤销。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。
