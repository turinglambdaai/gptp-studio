/* BMCA Timeline observation engine.
   This module summarizes captured Announce evolution and linuxptp BMCA/port
   evidence. It does not re-implement IEEE 802.1AS BMCA and does not declare a
   winner from incomplete captures. */
"use strict";

(function initBmcaTimeline(root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (root) root.BmcaTimeline = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function bmcaTimelineFactory() {
  const DATASET_FIELDS = [
    "grandmaster_priority1",
    "grandmaster_clock_class",
    "grandmaster_clock_accuracy",
    "grandmaster_offset_scaled_log_variance",
    "grandmaster_priority2",
    "grandmaster_identity",
    "steps_removed",
    "time_source",
    "time_source_name",
  ];

  function finiteNumber(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function announceObservation(frame) {
    if (!frame || !frame.is_ptp || !frame.ptp) return null;
    if (frame.ptp.message_type_name !== "Announce") return null;
    const body = frame.body || {};
    const dataset = {};
    for (const field of DATASET_FIELDS) {
      if (body[field] !== undefined) dataset[field] = body[field];
    }
    return {
      ts: finiteNumber(frame.ts),
      index: frame.index !== undefined ? frame.index : null,
      interface: frame.iface || null,
      capture_source: frame.source || null,
      timestamp_source: frame.timestamp_source || "unknown",
      domain: frame.ptp.domain_number !== undefined ? frame.ptp.domain_number : null,
      sequence_id: frame.ptp.sequence_id !== undefined ? frame.ptp.sequence_id : null,
      announcing_source: frame.ptp.source_port_identity || null,
      dataset,
    };
  }

  function candidateKey(obs) {
    const gm = obs && obs.dataset ? obs.dataset.grandmaster_identity : null;
    return `${obs.domain ?? "?"}|${gm || "unknown-gm"}|${obs.announcing_source || "unknown-source"}`;
  }

  function datasetFingerprint(dataset) {
    return DATASET_FIELDS.map((field) => `${field}=${dataset[field] ?? ""}`).join("|");
  }

  function changedDatasetFields(before, after) {
    return DATASET_FIELDS.filter((field) => (before || {})[field] !== (after || {})[field]);
  }

  function analyzeAnnounces(frames) {
    const announces = (Array.isArray(frames) ? frames : [])
      .map(announceObservation)
      .filter(Boolean)
      .sort((a, b) => {
        const ta = a.ts === null ? Infinity : a.ts;
        const tb = b.ts === null ? Infinity : b.ts;
        if (ta !== tb) return ta - tb;
        return Number(a.index || 0) - Number(b.index || 0);
      });

    const candidates = new Map();
    const sourceLast = new Map();
    const events = [];

    for (const obs of announces) {
      const key = candidateKey(obs);
      const previousCandidate = candidates.get(key);
      const sourceKey = `${obs.domain ?? "?"}|${obs.announcing_source || "unknown-source"}`;
      const previousSource = sourceLast.get(sourceKey);

      if (!previousCandidate) {
        events.push({
          kind: "candidate-seen",
          ts: obs.ts,
          index: obs.index,
          candidate_key: key,
          domain: obs.domain,
          announcing_source: obs.announcing_source,
          grandmaster_identity: obs.dataset.grandmaster_identity || null,
          dataset: obs.dataset,
          note: "First Announce observed for this GM/source in the loaded capture window.",
        });
      } else if (datasetFingerprint(previousCandidate.latest.dataset) !== datasetFingerprint(obs.dataset)) {
        const changed = changedDatasetFields(previousCandidate.latest.dataset, obs.dataset);
        events.push({
          kind: "dataset-change",
          ts: obs.ts,
          index: obs.index,
          candidate_key: key,
          domain: obs.domain,
          announcing_source: obs.announcing_source,
          grandmaster_identity: obs.dataset.grandmaster_identity || null,
          changed_fields: changed,
          before: previousCandidate.latest.dataset,
          after: obs.dataset,
          note: "The observed Announce dataset changed. This is an observation, not a BMCA winner decision.",
        });
      }

      if (previousSource) {
        const oldGm = previousSource.dataset.grandmaster_identity || null;
        const newGm = obs.dataset.grandmaster_identity || null;
        if (oldGm && newGm && oldGm !== newGm) {
          events.push({
            kind: "announcing-source-gm-change",
            ts: obs.ts,
            index: obs.index,
            domain: obs.domain,
            announcing_source: obs.announcing_source,
            before_grandmaster_identity: oldGm,
            after_grandmaster_identity: newGm,
            note: "The same announcing source was observed advertising a different grandmaster identity.",
          });
        }
      }

      if (previousCandidate) {
        previousCandidate.count += 1;
        previousCandidate.last_seen = obs.ts;
        previousCandidate.latest = obs;
      } else {
        candidates.set(key, {
          key,
          domain: obs.domain,
          announcing_source: obs.announcing_source,
          grandmaster_identity: obs.dataset.grandmaster_identity || null,
          count: 1,
          first_seen: obs.ts,
          last_seen: obs.ts,
          latest: obs,
        });
      }
      sourceLast.set(sourceKey, obs);
    }

    return {
      announce_count: announces.length,
      candidate_count: candidates.size,
      candidates: Array.from(candidates.values()).sort((a, b) => {
        const at = a.last_seen === null ? -Infinity : a.last_seen;
        const bt = b.last_seen === null ? -Infinity : b.last_seen;
        return bt - at;
      }),
      events,
    };
  }

  function normalizeLog(entry) {
    if (!Array.isArray(entry) || entry.length < 4) return null;
    const ms = finiteNumber(entry[0]);
    if (ms === null) return null;
    return {
      ts: ms / 1000,
      source: String(entry[1] || ""),
      level: String(entry[2] || ""),
      message: String(entry[3] || ""),
    };
  }

  function classifyEngineLog(log) {
    const msg = log.message;
    if (/选择最优主时钟|selected best master|best master clock/i.test(msg)) {
      return { ...log, kind: "best-master-selection" };
    }
    if (/本机接管\s*GrandMaster|grand\s*master role|assuming.*grand\s*master/i.test(msg)) {
      return { ...log, kind: "local-grandmaster" };
    }
    if (/\bport\b[^\n]*\b(LISTENING|SLAVE|MASTER|GRAND_MASTER|FAULTY|UNCALIBRATED|PASSIVE)\b/i.test(msg)) {
      return { ...log, kind: "port-state" };
    }
    if (/foreign master|外部主时钟/i.test(msg)) {
      return { ...log, kind: "foreign-master" };
    }
    return null;
  }

  function analyzeEngineLogs(logs) {
    return (Array.isArray(logs) ? logs : [])
      .map(normalizeLog)
      .filter(Boolean)
      .map(classifyEngineLog)
      .filter(Boolean)
      .sort((a, b) => a.ts - b.ts);
  }

  function analyze(frames, logs) {
    const announce = analyzeAnnounces(frames);
    const engineEvents = analyzeEngineLogs(logs);
    return {
      schema_version: 1,
      announce,
      engine_events: engineEvents,
      interpretation: "observational",
      note: "Captured Announce evolution and engine logs are evidence. This view does not independently re-run IEEE 802.1AS BMCA or prove why a winner was selected.",
    };
  }

  return {
    DATASET_FIELDS,
    announceObservation,
    changedDatasetFields,
    analyzeAnnounces,
    analyzeEngineLogs,
    analyze,
  };
});
