# gPTP Studio agent contract

## Authorization decision before implementation

Decision `2026-10-auth-1`: Offline perpetual entitlement plus a bounded update/feature window; no activation lease or device cap. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

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

- 当前决策（2026-10-v2）：Linux 专业工具；官方 Pro 买断。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turlamai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turlamai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turlamai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `docs/licensing-model.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turlamai/gptp-studio/issues/35)。保持 Linux-only；先完成 Commerce 一次性购买到离线凭据及更新资格的纵切。区分命名席位、设备数和合同约定，不宣传离线实时撤销。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turinglambdaai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.
