# Licensing model

This document explains the boundary between gPTP Studio's open-source license
and the commercial Free/Pro experience in official distributions. It is product
and engineering documentation, not a substitute for legal review of a specific
customer contract or jurisdiction.

## Source license

gPTP Studio source is published under the Apache License, Version 2.0. The
license grants broad rights to use, copy, modify, build and redistribute the
covered work, subject to the Apache-2.0 conditions.

Third-party components keep their own licenses. See `THIRD_PARTY_NOTICES.md`.

## What the official Pro entitlement actually sells

The Pro license file in the official binary is a **commercial entitlement for
the official product distribution and services**, not a mechanism that revokes
Apache-2.0 rights in the source code.

A Pro purchase can therefore legitimately bundle value such as:

- the official tested/signed build and its Pro product configuration;
- updates during the purchased update period;
- license migration / seat administration;
- response-time support commitments;
- validated host/NIC reference-platform guidance;
- future official reports, certification-oriented workflows, or hardware
  integration;
- access to future proprietary add-ons if any are introduced under clearly
  separate terms.

A recipient may still exercise Apache-2.0 rights on the open-source code. A
fork or self-built binary is not automatically an official gPTP Studio build and
does not carry the official support/update/validation commitments.

## What not to rely on as a moat

Do not base the business model on the assumption that an Apache-2.0 recipient is
contractually forbidden from reading, modifying or rebuilding the open-source
code to change the Free/Pro gate. That is not a reliable boundary for an
Apache-licensed project.

The defensible product moat should instead be the combination of:

- trustworthy release engineering;
- hardware qualification and repeatable timing validation;
- support and enterprise procurement;
- automotive-specific workflows and domain expertise;
- curated reference platforms;
- future Studio Box hardware / automotive Ethernet interfaces;
- optional future components that are intentionally kept under a separate
  commercial license from their first release.

## Official binaries and EULA

`EULA.md` governs official-distribution Pro entitlements, license credentials,
updates/support, and official-brand/trademark relationships. It explicitly does
not revoke rights already granted by Apache-2.0 or another applicable open-source
license.

Accordingly, the official EULA must not contain blanket statements such as
"users may not reverse engineer the distributed binary" when that statement
would conflict with rights the same recipient already has in Apache-covered
code.

## Trademark / provenance distinction

Apache-2.0 does not grant general trademark rights. A downstream fork may comply
with Apache-2.0 and still need to avoid representing itself as an official
`turinglambdaai` / gPTP Studio release.

The commercial terms therefore focus restrictions on:

- redistribution or forgery of official license credentials;
- impersonating an official reseller, certified lab, or support provider;
- presenting an unofficial build as an official release.

## Distribution compliance

Official release artifacts must contain:

- `LICENSE`
- `NOTICE`
- `EULA.md`
- `THIRD_PARTY_NOTICES.md`

The packaging smoke tests check those files in both the Linux distributed
artifact and the macOS application bundle.

## Dependency policy

Before adding a new bundled dependency:

1. identify its exact license and copyright notices;
2. determine whether the dependency is linked/bundled or merely a system
   dependency;
3. update `THIRD_PARTY_NOTICES.md` and package payloads as required;
4. review reciprocal/copyleft obligations before merge;
5. rerun the distribution smoke tests.

System-provided tools/libraries that are merely invoked or dynamically loaded
are still engineering dependencies, but they are not automatically copied into
the gPTP Studio artifact. If packaging changes later begin bundling one of them,
its notices must be added at that time.

## Future license changes

If the project owner later decides that newly developed Pro-only source should
not be Apache-2.0, that should be done deliberately for future code with a clear
repository/layout boundary and contributor-ownership review. Changing a future
license does not retroactively revoke rights already granted for versions that
were released under Apache-2.0.
