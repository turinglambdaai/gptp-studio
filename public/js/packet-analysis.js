/* Passive analysis of the currently loaded packet window.
   The analyzer intentionally reports observations, not verdicts: multiple
   domains and unpaired packets can be legitimate depending on topology and
   capture boundaries. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));
  const TRACKED_SEQ_TYPES = new Set(["Sync", "Follow_Up", "Announce"]);

  function ensureHealthStrip() {
    if (q("#pk-health")) return;
    const summary = q("#pk-summary");
    if (!summary) return;
    summary.insertAdjacentHTML("afterend", `
      <div class="packet-health" id="pk-health">
        <div class="packet-health-item"><span>Sample rate</span><strong id="pk-health-rate">—</strong></div>
        <div class="packet-health-item"><span>Domains</span><strong id="pk-health-domains">—</strong></div>
        <div class="packet-health-item"><span>Clock sources</span><strong id="pk-health-sources">—</strong></div>
        <div class="packet-health-item"><span>Seq anomalies</span><strong id="pk-health-seq">—</strong></div>
        <div class="packet-health-item"><span>Two-step pairs</span><strong id="pk-health-pairs">—</strong></div>
      </div>`);
  }

  function seqDistance(a, b) {
    return (b - a + 65536) & 0xffff;
  }

  function analyzePackets(packets) {
    const ptp = (packets || []).filter((f) => f && f.is_ptp && f.ptp);
    const timestamps = ptp.map((f) => Number(f.ts)).filter(Number.isFinite);
    const minTs = timestamps.length ? Math.min(...timestamps) : null;
    const maxTs = timestamps.length ? Math.max(...timestamps) : null;
    const duration = minTs !== null && maxTs !== null ? Math.max(0, maxTs - minTs) : 0;
    const rate = duration > 0 ? ptp.length / duration : null;

    const domains = [...new Set(ptp.map((f) => f.ptp.domain_number))].sort((a, b) => a - b);
    const sources = [...new Set(ptp.map((f) => f.ptp.source_clock_identity || f.ptp.source_port_identity).filter(Boolean))];

    const groups = new Map();
    for (const f of ptp) {
      const h = f.ptp;
      if (!TRACKED_SEQ_TYPES.has(h.message_type_name)) continue;
      const key = `${h.message_type_name}|${h.domain_number}|${h.source_port_identity}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(f);
    }

    const anomalyIndices = new Map();
    let gaps = 0;
    let duplicates = 0;
    for (const [key, frames] of groups.entries()) {
      frames.sort((a, b) => Number(a.ts || 0) - Number(b.ts || 0));
      for (let i = 1; i < frames.length; i++) {
        const prev = Number(frames[i - 1].ptp.sequence_id);
        const cur = Number(frames[i].ptp.sequence_id);
        if (!Number.isInteger(prev) || !Number.isInteger(cur)) continue;
        const d = seqDistance(prev, cur);
        if (d === 0) {
          duplicates++;
          anomalyIndices.set(Number(frames[i].index), `重复 sequenceId ${cur} · ${key.split("|")[0]}`);
        } else if (d !== 1) {
          gaps++;
          anomalyIndices.set(Number(frames[i].index), `sequenceId ${prev} → ${cur}（步进 ${d}）· ${key.split("|")[0]}`);
        }
      }
    }

    const followUps = new Set();
    for (const f of ptp) {
      const h = f.ptp;
      if (h.message_type_name === "Follow_Up") {
        followUps.add(`${h.domain_number}|${h.source_port_identity}|${h.sequence_id}`);
      }
    }
    let twoStep = 0;
    let missingFollowUp = 0;
    for (const f of ptp) {
      const h = f.ptp;
      if (h.message_type_name !== "Sync" || !(h.flags_list || []).includes("twoStep")) continue;
      twoStep++;
      const key = `${h.domain_number}|${h.source_port_identity}|${h.sequence_id}`;
      if (!followUps.has(key)) missingFollowUp++;
    }

    return { ptpCount: ptp.length, rate, domains, sources, gaps, duplicates, anomalyIndices, twoStep, missingFollowUp };
  }

  function setMetric(id, text, state, title) {
    const el = q(id);
    if (!el) return;
    el.textContent = text;
    el.className = state ? `packet-health-${state}` : "";
    if (title) el.title = title;
    else el.removeAttribute("title");
  }

  function renderHealth() {
    ensureHealthStrip();
    const a = analyzePackets(S.packets || []);
    setMetric("#pk-health-rate", a.rate === null ? "—" : `${a.rate.toFixed(a.rate >= 10 ? 1 : 2)} pkt/s`, "neutral",
              `当前载入窗口内 ${a.ptpCount} 个 PTP 报文；不是线速或丢包率测量`);
    setMetric("#pk-health-domains", a.domains.length ? a.domains.join(", ") : "—",
              a.domains.length > 1 ? "attention" : "neutral",
              a.domains.length > 1 ? "观察到多个 PTP Domain；这可能是正常拓扑，也可能提示选错网络/Domain" : "当前载入窗口内观察到的 Domain");
    setMetric("#pk-health-sources", String(a.sources.length), a.sources.length > 1 ? "attention" : "neutral",
              "按 source clock identity 统计当前载入窗口内的时钟源数量");
    const anomalyCount = a.gaps + a.duplicates;
    setMetric("#pk-health-seq", anomalyCount ? `${anomalyCount} (${a.gaps} gap / ${a.duplicates} dup)` : "0",
              anomalyCount ? "attention" : "good",
              "仅检查 Sync / Follow_Up / Announce 的同源 sequenceId 连续性；抓包起止、丢包或过滤都可能造成 gap");
    setMetric("#pk-health-pairs", a.twoStep ? `${a.twoStep - a.missingFollowUp}/${a.twoStep}` : "—",
              a.missingFollowUp ? "attention" : (a.twoStep ? "good" : "neutral"),
              a.twoStep ? `当前窗口中 twoStep Sync 与同 Domain/Source/Seq Follow_Up 的配对；未配对 ${a.missingFollowUp} 个。窗口边界可能产生假阳性。` : "当前窗口未观察到设置 twoStep flag 的 Sync");

    for (const tr of qa("#pk-tbody tr")) {
      const idx = Number(tr.dataset.index);
      const reason = a.anomalyIndices.get(idx);
      tr.classList.toggle("packet-seq-anomaly", !!reason);
      if (reason) {
        const old = tr.title ? `${tr.title}\n` : "";
        if (!tr.title.includes(reason)) tr.title = old + reason;
      }
    }
  }

  const baseRenderPacketList = renderPacketList;
  renderPacketList = function analyzedRenderPacketList() {
    baseRenderPacketList();
    renderHealth();
  };

  // Ensure the health strip exists even before the first packet arrives.
  ensureHealthStrip();
  setInterval(() => {
    if (q("#page-packets") && q("#page-packets").classList.contains("active")) renderHealth();
  }, 1500);
})();
