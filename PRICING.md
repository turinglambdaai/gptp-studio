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

## Next gate before sales

Remain Linux-only. Complete real reference-hardware, privilege, runtime-control and signed-update gates in #35, then verify Commerce purchase, duplicate delivery, credential recovery and update eligibility. A passing simulator is not hardware qualification. Previous provisional ¥399/¥1599 prices and manual-purchase instructions are no longer active quotations.

Execution entry: [issue #35](https://github.com/turinglambdaai/gptp-studio/issues/35). Complete this bounded slice before expanding commercial features.

Portfolio role and shared boundaries: [PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).
