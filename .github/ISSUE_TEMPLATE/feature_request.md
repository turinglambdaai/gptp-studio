---
name: Feature request
about: Suggest a capability or improvement for gPTP Studio
title: ''
labels: enhancement
assignees: ''
---

**Is your feature about the engine, the packets/capture path, the reports,
or the desktop host?**

gPTP Studio is one Racket backend (linuxptp supervision, decode, store) +
one GTK4 host — saying which layer helps triage. 中文描述完全没问题。

**Problem you're trying to solve**

What are you trying to do that gPTP Studio doesn't let you (or makes
hard)? For timing work: which gPTP / IEEE 802.1AS / AUTOSAR EthTSyn
scenario?

**Proposed solution**

What you'd expect, and how it fits the Linux-only product contract.

**Alternatives you've considered**

How do you work around it today (wireshark, ptp4l CLI, pmc)?

**Pro / entitlement note**

If this touches Pro-gated surfaces (real GM/Slave engine control, pcap
export, GM runtime tuning), commercial customers can also reach official
support per `PRICING.md` — the support channel answers within one business
day.
