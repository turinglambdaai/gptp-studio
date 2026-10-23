# gPTP Studio product and pricing plan

**English** · [简体中文](PRICING.zh-CN.md)

## Launch status and implementation boundaries

- Policy version: `2026-10-v2`, 2026-10-23. The owner confirmed that every product is still in development and has no actual users. This document replaces conflicting previous pricing, early-bird and Pro proposals; there is no existing customer cohort to migrate. **Prices are launch targets, not live offers or claims that the listed features are implemented.**
- Entitlements cover delivered platforms only. New commercial plans do not change the LICENSE of released source. Source use, modification and redistribution rights are separate from official products, updates and services.
- Security fixes and reading, backing up or exporting your own data must not require another purchase. BYOK keys, payment-provider secrets and issuer private keys have different owners. Native hosts do not collect payment or issue credentials directly.

## Decision

**Linux professional tool; purchase of the official Pro product**

Launch target: **Individual: ¥699 / US$99; 5 named seats: ¥2,799 / US$399. Optional 12-month update renewal: ¥279 / US$39 per individual, or ¥1,119 / US$159 for 5 seats**. CNY and USD are independently set regional targets, not a live exchange-rate conversion.

Engineering value and support effort are higher than for an everyday utility. A professional price should support that maintenance. Use a purchase with optional updates, rather than charging per capture or ECU.

## Free and paid scope

Free / evaluation: Passive capture, protocol decoding, offline import, simulator, parameter previews, existing diagnostics and raw-data export are intended to be free. Moving raw capture export out of its legacy Pro gate still requires implementation; current installers must not be described as already unrestricted. Apache-2.0 source rights remain unchanged.

Paid: Official Pro GM/slave runtime control, reference-source management, repeatable test orchestration, evidence-backed comparison reports and validated reference combinations. Seats mean named users, not network adapters, devices or concurrent sessions. Only delivered and verified capabilities may appear in an active offer.

## Purchase, trial and updates

A purchase includes 12 months of new-version eligibility. Versions obtained within that update window remain usable afterwards. Optional renewal adds 12 months from `max(payment time, current updates_through)`, with no back-billing for a gap and no automatic charge. Team renewals apply to the purchased number of named seats. There is no lifetime-all-future-updates plan. One named user can use their own computers; no hardware fingerprint is collected. Offline seat limits are contractual, not real-time concurrency enforcement. A team purchase combines seats; it does not imply a collaboration cloud.

A new paid tier has a full 14-day trial, then returns to the free tier. For a complete paid product, trial expiry preserves reading/search/backup/export. Offline trial state is a convenience and an agreement, not advertised as rollback-proof or impossible to reset. Do not presell codes before technical and platform gates pass. After a successful payment, Commerce issues Permit credentials idempotently. Use release time and `updates_through` for update eligibility; the current date must not suddenly invalidate an acquired version. Do not promise prompt offline refund/revocation enforcement that cannot be implemented.

The target price includes no custom development, hardware procurement, certification or response-time SLA. Support is asynchronous issue handling for the purchased version, supported platforms and validated combinations; a solo maintainer must not promise round-the-clock responses. Before sales, publish refund/cancellation rules, currency/tax totals, privacy terms and support scope, and confirm them at checkout. This plan is not a substitute for final checkout terms.

## Authorization decision for implementation

Decision revision: `2026-10-auth-1` (2026-10-23). This selects the integration design; it does not claim that the running app already implements it. Follow Permit's [normative entitlement semantics](https://github.com/turinglambdaai/permit/blob/main/docs/entitlement-v1.md) and [framework boundary](https://github.com/turinglambdaai/permit/blob/main/docs/framework-integration.md); this document owns product policy, not a second wire protocol.

- **Credential and connectivity:** use a signed Protocol v1 `entitlement` for the purchased product, verified locally through the public `permit` facade. Set `activation_required=false` and `installation_id=null`. Do not issue activation leases, require periodic online checks, bind hardware or introduce a device cap. Purchase, reissue and recovery may use Commerce online; an imported credential must work without that service.
- **Perpetual use and update window:** `use_expires_at=null`; `updates_through` is the paid update cutoff. For the paid scope use `feature_policy="published-through"`, `features=[]` and `features_through=updates_through`. Evaluate authenticated release and feature-introduction timestamps; a manually copied future binary must not widen rights. Keep free capabilities outside this gate. An expired update window preserves eligible acquired functionality and user data; security-fix delivery needs a separately identified eligible patch path.
- **People and teams:** use an opaque stable person subject, never an email address as the authorization key. One named user may use their own computers. Where a five-seat offer exists, Commerce records five named assignments and issues a separate one-seat entitlement per assignee; reassignment creates a new right. There is no floating/concurrent-seat promise. Offline use cannot prove that a former assignee discarded an old credential; accept that commercial risk rather than adding an undisclosed online lease.
- **Trial, renewal and recovery:** keep the full 14-day evaluation local, outside the signed protocol; do not require signup. Preserve the free/data-access behavior described above on expiry. Renewal/reissue retains `entitlement_id`, increases `revision` and replaces the complete snapshot; the update cutoff uses `max(payment time, current updates_through)`. Idempotent payment delivery must not create extra rights or extend a window twice. Re-download/import restores the same purchase rather than consuming a device slot.
- **Refund and trust:** record refunds and stop future issuance/download eligibility according to the published refund terms. A connected client can receive a withdrawn snapshot; an old offline perpetual credential cannot be revoked immediately. Keep issuer keys on the issuing service, public trust keys in the product, and release-signing keys separate. Store credentials through product-owned storage, redact diagnostics, and retain legitimate historical trust paths through normal key retirement.
- **Implementation gate:** pin the Permit version and reviewed immutable Offer, map the exact product/edition/features in the existing product contract, and prove import, wrong-product rejection, signature failure, renewal replay, cutoff boundaries, service outage and post-expiry data access. Record the source/policy SHAs read and remaining platform evidence. No new payment wall is activated by this document.

## Next gate before sales

Remain Linux-only. Complete real reference-hardware, privilege, runtime-control and signed-update gates in #35, then verify Commerce purchase, duplicate delivery, credential recovery and update eligibility. A passing simulator is not hardware qualification. Previous provisional ¥399/¥1599 prices and manual-purchase instructions are no longer active quotations.

Execution entry: [issue #35](https://github.com/turinglambdaai/gptp-studio/issues/35). Complete this bounded slice before expanding commercial features.

Portfolio role and shared boundaries: [PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).
