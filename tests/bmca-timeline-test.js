"use strict";

const assert = require("assert");
const BmcaTimeline = require("../public/js/bmca-timeline.js");

const base = 1_800_000_000;

function announce(ts, index, source, gm, priority1, clockClass, priority2, seq) {
  return {
    ts,
    index,
    is_ptp: true,
    source: "live",
    timestamp_source: "adapter",
    iface: "enp3s0",
    ptp: {
      message_type_name: "Announce",
      domain_number: 0,
      sequence_id: seq,
      source_port_identity: source,
    },
    body: {
      grandmaster_priority1: priority1,
      grandmaster_clock_class: clockClass,
      grandmaster_clock_accuracy: 0x22,
      grandmaster_offset_scaled_log_variance: 0x4e5d,
      grandmaster_priority2: priority2,
      grandmaster_identity: gm,
      steps_removed: 1,
      time_source: 0x20,
      time_source_name: "GPS",
    },
  };
}

const frames = [
  announce(base + 0.1, 1, "src-a.1", "gm-a", 128, 248, 128, 10),
  announce(base + 1.1, 2, "src-a.1", "gm-a", 128, 248, 128, 11),
  // Same candidate, dataset change.
  announce(base + 2.1, 3, "src-a.1", "gm-a", 100, 248, 128, 12),
  // Same announcing source begins advertising a different GM.
  announce(base + 3.1, 4, "src-a.1", "gm-b", 100, 248, 128, 13),
  // Second source / candidate.
  announce(base + 1.5, 5, "src-c.1", "gm-c", 120, 248, 120, 20),
  { ts: base + 1.7, index: 6, is_ptp: true, ptp: { message_type_name: "Sync" }, body: {} },
];

const announceResult = BmcaTimeline.analyzeAnnounces(frames);
assert.strictEqual(announceResult.announce_count, 5);
assert.strictEqual(announceResult.candidate_count, 3);
assert.strictEqual(announceResult.events.filter((e) => e.kind === "candidate-seen").length, 3);
assert.strictEqual(announceResult.events.filter((e) => e.kind === "dataset-change").length, 1);
assert.strictEqual(announceResult.events.filter((e) => e.kind === "announcing-source-gm-change").length, 1);

const datasetChange = announceResult.events.find((e) => e.kind === "dataset-change");
assert.deepStrictEqual(datasetChange.changed_fields, ["grandmaster_priority1"]);
assert.strictEqual(datasetChange.before.grandmaster_priority1, 128);
assert.strictEqual(datasetChange.after.grandmaster_priority1, 100);

const sourceGmChange = announceResult.events.find((e) => e.kind === "announcing-source-gm-change");
assert.strictEqual(sourceGmChange.before_grandmaster_identity, "gm-a");
assert.strictEqual(sourceGmChange.after_grandmaster_identity, "gm-b");

const gmACandidate = announceResult.candidates.find((c) => c.grandmaster_identity === "gm-a");
assert.strictEqual(gmACandidate.count, 3);
assert.strictEqual(gmACandidate.latest.dataset.grandmaster_priority1, 100);

const logs = [
  [(base + 0.2) * 1000, "ptp4l", "info", "port 1: LISTENING to SLAVE"],
  [(base + 0.3) * 1000, "ptp4l", "info", "selected best master clock gm-a"],
  [(base + 0.4) * 1000, "ptp4l", "info", "foreign master gm-c"],
  [(base + 0.5) * 1000, "ptp4l", "info", "ordinary unrelated message"],
  [(base + 0.6) * 1000, "ptp4l", "info", "本机接管 GrandMaster 角色"],
];

const engineEvents = BmcaTimeline.analyzeEngineLogs(logs);
assert.strictEqual(engineEvents.length, 4);
assert.deepStrictEqual(engineEvents.map((e) => e.kind), [
  "port-state",
  "best-master-selection",
  "foreign-master",
  "local-grandmaster",
]);

const result = BmcaTimeline.analyze(frames, logs);
assert.strictEqual(result.schema_version, 1);
assert.strictEqual(result.interpretation, "observational");
assert.strictEqual(result.announce.candidate_count, 3);
assert.strictEqual(result.engine_events.length, 4);
assert.match(result.note, /does not independently re-run/i);

console.log("bmca-timeline-test: ok");
