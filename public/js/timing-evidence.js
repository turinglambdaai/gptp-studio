/* Timing Evidence: correlate offset jumps with nearby packets and logs.
   This module reports temporal observations only. A nearby event is evidence
   context, not proof of causality. The pure functions are shared by the UI
   and Node-based CI tests. */
"use strict";

(function initTimingEvidence(root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (root) root.TimingEvidence = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function timingEvidenceFactory() {
  const EPOCH_FLOOR_SECONDS = 100000000;
  const VERIFIED_PACKET_TIME_SOURCES = new Set([
    "adapter",
    "host-high-precision",
    "host-low-precision",
  ]);

  function finiteNumber(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function normalizeSeries(points) {
    return (Array.isArray(points) ? points : [])
      .map((p) => Array.isArray(p) && p.length >= 2
        ? [finiteNumber(p[0]), finiteNumber(p[1])]
        : [null, null])
      .filter((p) => p[0] !== null && p[1] !== null)
      .sort((a, b) => a[0] - b[0]);
  }

  function detectOffsetJumps(points, thresholdNs, opts = {}) {
    const series = normalizeSeries(points);
    const threshold = Math.max(1, Math.abs(finiteNumber(thresholdNs) || 100000));
    const minSpacingSec = Math.max(0, finiteNumber(opts.minSpacingSec) || 0.05);
    const maxEvents = Math.max(1, Math.floor(finiteNumber(opts.maxEvents) || 20));
    const jumps = [];
    let lastEventTs = -Infinity;

    for (let i = 1; i < series.length; i++) {
      const [t0, before] = series[i - 1];
      const [t1, after] = series[i];
      const delta = after - before;
      if (Math.abs(delta) < threshold) continue;
      if (t1 - lastEventTs < minSpacingSec) continue;
      jumps.push({
        id: `offset-jump-${i}-${Math.round(t1 * 1000)}`,
        index: i,
        ts: t1,
        previous_ts: t0,
        before_ns: before,
        after_ns: after,
        delta_ns: delta,
        threshold_ns: threshold,
      });
      lastEventTs = t1;
    }
    return jumps.slice(-maxEvents).reverse();
  }

  function isEpochSeconds(v) {
    return Number.isFinite(v) && v >= EPOCH_FLOOR_SECONDS;
  }

  function packetTimestamp(packet) {
    return finiteNumber(packet && packet.ts);
  }

  function packetTimestampSource(packet) {
    return packet && packet.timestamp_source ? String(packet.timestamp_source) : "unknown";
  }

  function packetTimeSourceVerified(packet) {
    return VERIFIED_PACKET_TIME_SOURCES.has(packetTimestampSource(packet));
  }

  function packetObservation(packet) {
    const h = packet && packet.ptp ? packet.ptp : {};
    const b = packet && packet.body ? packet.body : {};
    return {
      ts: packetTimestamp(packet),
      index: packet && packet.index !== undefined ? packet.index : null,
      message_type: h.message_type_name || "unknown",
      sequence_id: h.sequence_id !== undefined ? h.sequence_id : null,
      domain: h.domain_number !== undefined ? h.domain_number : null,
      source_port_identity: h.source_port_identity || null,
      correction_field_ns: finiteNumber(h.correction_field_ns),
      grandmaster_identity: b.grandmaster_identity || null,
      interface: packet && packet.iface ? packet.iface : null,
      timestamp_source: packetTimestampSource(packet),
    };
  }

  function seqDistance(a, b) {
    return (b - a + 65536) & 0xffff;
  }

  function sequenceObservations(packets) {
    const groups = new Map();
    for (const p of packets) {
      if (!p || !p.message_type || p.sequence_id === null || !p.source_port_identity) continue;
      const key = `${p.message_type}|${p.domain}|${p.source_port_identity}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(p);
    }
    const observations = [];
    for (const [key, frames] of groups.entries()) {
      frames.sort((a, b) => a.ts - b.ts);
      for (let i = 1; i < frames.length; i++) {
        const prev = Number(frames[i - 1].sequence_id);
        const cur = Number(frames[i].sequence_id);
        if (!Number.isInteger(prev) || !Number.isInteger(cur)) continue;
        const distance = seqDistance(prev, cur);
        if (distance === 0 || distance > 1) {
          observations.push({
            kind: distance === 0 ? "duplicate-sequence" : "sequence-gap",
            key,
            previous_sequence_id: prev,
            sequence_id: cur,
            distance,
            ts: frames[i].ts,
            note: "Capture loss or the evidence-window boundary can also produce this observation.",
          });
        }
      }
    }
    return observations;
  }

  function relevantLogs(logs, startSec, endSec) {
    return (Array.isArray(logs) ? logs : [])
      .map((entry) => {
        if (!Array.isArray(entry) || entry.length < 4) return null;
        const ms = finiteNumber(entry[0]);
        if (ms === null) return null;
        return {
          ts: ms / 1000,
          source: String(entry[1] || ""),
          level: String(entry[2] || ""),
          message: String(entry[3] || ""),
        };
      })
      .filter((entry) => entry && entry.ts >= startSec && entry.ts <= endSec)
      .sort((a, b) => a.ts - b.ts);
  }

  function unique(values) {
    return [...new Set(values.filter((v) => v !== null && v !== undefined && v !== ""))];
  }

  function summarizeEvidence(packets, logs, seq, meta = {}) {
    const packetTypes = unique(packets.map((p) => p.message_type));
    const announceGms = unique(packets.map((p) => p.grandmaster_identity));
    // A port-state observation must actually be in a port context. A generic
    // "best master clock" message contains the word MASTER but is a BMCA/GM
    // observation, not a port-state transition.
    const portStateLogs = logs.filter((l) =>
      /\bport\b[^\n]*\b(LISTENING|SLAVE|MASTER|GRAND_MASTER|FAULTY|UNCALIBRATED|PASSIVE)\b/i.test(l.message));
    const gmLogs = logs.filter((l) => /grand\s*master|best master|主时钟|GM\b/i.test(l.message));
    const excluded = Math.max(0, Number(meta.unverifiedPacketCount) || 0);
    const excludedSources = unique(meta.unverifiedTimestampSources || []);
    return {
      packet_count: packets.length,
      packet_types: packetTypes,
      packet_timestamp_sources: unique(packets.map((p) => p.timestamp_source)),
      unverified_packet_count: excluded,
      unverified_timestamp_sources: excludedSources,
      announce_grandmasters: announceGms,
      sequence_observation_count: seq.length,
      port_state_log_count: portStateLogs.length,
      gm_log_count: gmLogs.length,
      labels: [
        packets.length ? `${packets.length} verified-time packet(s)` : null,
        excluded ? `${excluded} packet(s) excluded: unverified timebase` : null,
        seq.length ? `${seq.length} sequence observation(s)` : null,
        portStateLogs.length ? `${portStateLogs.length} port-state log(s)` : null,
        gmLogs.length ? `${gmLogs.length} GM-related log(s)` : null,
      ].filter(Boolean),
    };
  }

  function buildEvidenceWindows(jumps, packets, logs, opts = {}) {
    const beforeSec = Math.max(0, finiteNumber(opts.beforeSec) || 1.0);
    const afterSec = Math.max(0, finiteNumber(opts.afterSec) || 1.0);
    const allPackets = (Array.isArray(packets) ? packets : [])
      .filter((p) => p && p.is_ptp && p.ptp && packetTimestamp(p) !== null);

    return (Array.isArray(jumps) ? jumps : []).map((jump) => {
      const ts = finiteNumber(jump.ts);
      if (ts === null || !isEpochSeconds(ts)) {
        return {
          ...jump,
          correlation_supported: false,
          correlation_note: "Offset series is not on an epoch timebase, so packet/log timestamp correlation is disabled for this sample.",
          packet_timebase_policy: "verified-host-synchronized-only",
          window_before_sec: beforeSec,
          window_after_sec: afterSec,
          packets: [],
          logs: [],
          sequence_observations: [],
          summary: summarizeEvidence([], [], []),
          causality: "not-established",
        };
      }

      const start = ts - beforeSec;
      const end = ts + afterSec;
      const nearbyRawPackets = allPackets.filter((p) => {
        const pTs = packetTimestamp(p);
        return isEpochSeconds(pTs) && pTs >= start && pTs <= end;
      });
      const verifiedRawPackets = nearbyRawPackets.filter(packetTimeSourceVerified);
      const unverifiedRawPackets = nearbyRawPackets.filter((p) => !packetTimeSourceVerified(p));
      const windowPackets = verifiedRawPackets
        .map(packetObservation)
        .sort((a, b) => a.ts - b.ts);
      const unverifiedSources = unique(unverifiedRawPackets.map(packetTimestampSource));
      const windowLogs = relevantLogs(logs, start, end);
      const seq = sequenceObservations(windowPackets);

      return {
        ...jump,
        correlation_supported: true,
        correlation_note: "Logs share the host epoch timebase. Packet evidence is included only when libpcap reports a host-synchronized timestamp source; temporal proximity alone does not establish causality.",
        packet_timebase_policy: "verified-host-synchronized-only",
        verified_packet_timestamp_sources: unique(windowPackets.map((p) => p.timestamp_source)),
        unverified_packet_count: unverifiedRawPackets.length,
        unverified_timestamp_sources: unverifiedSources,
        window_before_sec: beforeSec,
        window_after_sec: afterSec,
        packets: windowPackets,
        logs: windowLogs,
        sequence_observations: seq,
        summary: summarizeEvidence(windowPackets, windowLogs, seq, {
          unverifiedPacketCount: unverifiedRawPackets.length,
          unverifiedTimestampSources: unverifiedSources,
        }),
        causality: "not-established",
      };
    });
  }

  return {
    normalizeSeries,
    detectOffsetJumps,
    buildEvidenceWindows,
    sequenceObservations,
    packetTimeSourceVerified,
  };
});
