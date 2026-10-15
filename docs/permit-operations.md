# Permit commercial operations

This is the intentionally small v0.x operating playbook for official gPTP Studio
entitlements. It is designed for manual sales first; payment automation can call
the same Permit issuer boundary later.

## 1. Provision the production entitlement key once

Install the pinned Permit revision used by the product, then generate a dedicated
entitlement-signing key:

```bash
raco permit keygen \
  --private /secure/gptp-entitlement-2026.der \
  --public /tmp/gptp-entitlement-2026-public.der \
  --trust-store app/keys/permit-trust-store.json \
  --key-id gptp-entitlement-2026 \
  --issuer site.jrtx.gptpstudio
```

Immediately move the private DER into the trusted private key workflow
(Keyward / encrypted private sync / HSM-equivalent operator storage). Never
commit it, put it in application resources, or reuse the updater key.

The generated `app/keys/permit-trust-store.json` is public material and **is**
committed. The release workflow intentionally rejects the repository's empty
placeholder trust store, so a production release cannot accidentally ship
without a real public anchor.

Update signing and entitlement signing remain different keys.

## 2. Permanent Pro + one-year maintenance

The customer owns the entitled features permanently, while official releases
and newly published paid features are included through the maintenance cutoff:

```bash
racket scripts/issue-license.rkt \
  --key /secure/gptp-entitlement-2026.der \
  --key-id gptp-entitlement-2026 \
  --subject customer@example.com \
  --subject-id cus_acme_001 \
  --updates-through 2027-10-16T23:59:59Z \
  --out acme-gptp-studio.license
```

When `--features-through` is omitted, the script mirrors
`--updates-through`. This is intentional: copying a later binary does not
grant paid features published after maintenance ended.

For a renewal, keep the same `--entitlement-id`, increment `--revision`, and
issue a new credential.

## 3. Subscription

```bash
racket scripts/issue-license.rkt \
  --key /secure/gptp-entitlement-2026.der \
  --key-id gptp-entitlement-2026 \
  --subject customer@example.com \
  --subject-id cus_acme_001 \
  --use-expires-at 2026-11-16T23:59:59Z \
  --out acme-monthly.license
```

For subscriptions, the script defaults the update and future-feature cutoffs to
the same use-expiry instant.

## 4. Optional single-installation binding

The License page exposes the application's random Permit
`installation_id` in its gate detail. It is not a hardware fingerprint.

To bind a credential:

```bash
racket scripts/issue-license.rkt \
  ... \
  --installation-id ins_0123456789abcdef0123456789abcdef \
  --out bound-seat.license
```

For the current five-device team offer, issue up to five installation-bound
credentials and track the allocation operationally. Pure offline credentials
cannot honestly provide centralized seat reclamation; add activation leases
only if that operational need becomes real.

## 5. Customer activation

The customer imports the `.license` file from **Runtime & Logs → Activate
License**, or places it at:

```text
~/.gptp-studio/license.lic
```

Verification is local Ed25519 verification through Permit. No account or
license-server request is required.

## 6. Trial

The 14-day Pro trial is local application state. It is deliberately not
presented as unresettable DRM. The state records a random trial id, absolute
expiry, and a last-seen clock high-water mark.

## 7. Refunds, revocation, and compromise

A fully offline entitlement cannot learn that a refund or remote revocation
occurred. Do not pretend otherwise.

- routine reissue/renewal: same entitlement id, higher revision;
- timely subscription/seat control: use short-lived Permit activation leases;
- signing-key compromise: mark the key revoked in the shipped trust store and
  deliver that trust-store change through the authenticated application update
  channel.

Keep the commercial system simple until real sales volume makes automation
worthwhile.
