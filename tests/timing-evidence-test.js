"use strict";

const assert = require("assert");
const TimingEvidence = require("../public/js/timing-evidence.js");

const base = 1_800_000_000;
const points = [
  [base + 0.00, 100],
  [base + 0.12, 250],
  [base + 0.25, 120_500],
  [base + 0.37, 120_700],
  [base + 0.50, -30_000],
];

const jumps = TimingEvidence.detectOffsetJumps(points, 100_000);
assert.strictEqual(jumps.length, 2);
assert.strictEqual(jumps[0].ts, base + 0.50);
assert.strictEqual(jumps[1].ts, base + 0.25);
assert.strictEqual(jumps[1].before_ns, 250);
assert.strictEqual(jumps[1].after_ns, 120_500);
assert.strictEqual(jumps[1].delta_ns, 120_250);

function packet(ts, index, type, seq, body = {}, timestampSource = "adapter") {
  return {
    ts,
    index,
    is_ptp: true,
    timestamp_source: timestampSource,
    ptp: {
      message_type_name: type,
      sequence_id: seq,
      domain_number: 0,
      source_port_identity: "aa.1",
      correction_field_ns: type === "Follow_Up" ? 25 : 0,
    },
    body,
  };
}

const packets = [
  packet(base + 0.10, 10, "Sync", 100),
  packet(base + 0.20, 11, "Follow_Up", 100, {}, "host-high-precision"),
  packet(base + 0.22, 12, "Announce", 200, { grandmaster_identity: "gm-a" }),
  packet(base + 0.30, 13, "Announce", 202, { grandmaster_identity: "gm-b" }),
  // This packet is close in wall-clock value but libpcap only reports the
  // generic HOST source, which is not guaranteed to be synchronized with the
  // OS clock. It must never become Timing Evidence packet correlation.
  packet(base + 0.28, 14, "Sync", 101, {}, "host"),
  packet(base + 5, 99, "Sync", 999),
];

assert.strictEqual(TimingEvidence.packetTimeSourceVerified(packets[0]), true);
assert.strictEqual(TimingEvidence.packetTimeSourceVerified(packets[1]), true);
assert.strictEqual(TimingEvidence.packetTimeSourceVerified(packets[4]), false);

const logs = [
  [(base + 0.24) * 1000, "ptp4l", "info", "port 1: LISTENING to SLAVE"],
  [(base + 0.26) * 1000, "ptp4l", "info", "selected best master clock gm-b"],
  [(base + 5) * 1000, "app", "info", "outside evidence window"],
];

const evidence = TimingEvidence.buildEvidenceWindows([jumps[1]], packets, logs, {
  beforeSec: 0.2,
  afterSec: 0.2,
});
assert.strictEqual(evidence.length, 1);
const ev = evidence[0];
assert.strictEqual(ev.correlation_supported, true);
assert.strictEqual(ev.causality, "not-established");
assert.strictEqual(ev.packet_timebase_policy, "verified-host-synchronized-only");
assert.strictEqual(ev.packets.length, 4);
assert.strictEqual(ev.unverified_packet_count, 1);
assert.deepStrictEqual(ev.unverified_timestamp_sources, ["host"]);
assert.deepStrictEqual(ev.summary.packet_types, ["Sync", "Follow_Up", "Announce"]);
assert.deepStrictEqual(ev.summary.packet_timestamp_sources, ["adapter", "host-high-precision"]);
assert.deepStrictEqual(ev.summary.announce_grandmasters, ["gm-a", "gm-b"]);
assert.strictEqual(ev.summary.sequence_observation_count, 1);
assert.strictEqual(ev.sequence_observations[0].kind, "sequence-gap");
assert.strictEqual(ev.summary.port_state_log_count, 1);
assert.strictEqual(ev.summary.gm_log_count, 1);
assert.strictEqual(ev.logs.length, 2);

const relativeJump = TimingEvidence.detectOffsetJumps([[0, 0], [0.1, 200_000]], 100_000)[0];
const relativeEvidence = TimingEvidence.buildEvidenceWindows([relativeJump], packets, logs)[0];
assert.strictEqual(relativeEvidence.correlation_supported, false);
assert.strictEqual(relativeEvidence.packets.length, 0);
assert.strictEqual(relativeEvidence.causality, "not-established");

console.log("timing-evidence-test: ok");
