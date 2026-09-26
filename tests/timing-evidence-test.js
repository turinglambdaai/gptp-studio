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

const packets = [
  {
    ts: base + 0.10,
    index: 10,
    is_ptp: true,
    ptp: {
      message_type_name: "Sync",
      sequence_id: 100,
      domain_number: 0,
      source_port_identity: "aa.1",
      correction_field_ns: 0,
    },
    body: {},
  },
  {
    ts: base + 0.20,
    index: 11,
    is_ptp: true,
    ptp: {
      message_type_name: "Follow_Up",
      sequence_id: 100,
      domain_number: 0,
      source_port_identity: "aa.1",
      correction_field_ns: 25,
    },
    body: {},
  },
  {
    ts: base + 0.22,
    index: 12,
    is_ptp: true,
    ptp: {
      message_type_name: "Announce",
      sequence_id: 200,
      domain_number: 0,
      source_port_identity: "aa.1",
      correction_field_ns: 0,
    },
    body: { grandmaster_identity: "gm-a" },
  },
  {
    ts: base + 0.30,
    index: 13,
    is_ptp: true,
    ptp: {
      message_type_name: "Announce",
      sequence_id: 202,
      domain_number: 0,
      source_port_identity: "aa.1",
      correction_field_ns: 0,
    },
    body: { grandmaster_identity: "gm-b" },
  },
  {
    ts: base + 5,
    index: 99,
    is_ptp: true,
    ptp: {
      message_type_name: "Sync",
      sequence_id: 999,
      domain_number: 0,
      source_port_identity: "zz.1",
      correction_field_ns: 0,
    },
    body: {},
  },
];

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
assert.strictEqual(ev.packets.length, 4);
assert.deepStrictEqual(ev.summary.packet_types, ["Sync", "Follow_Up", "Announce"]);
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
