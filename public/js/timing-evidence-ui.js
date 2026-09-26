/* Timing Evidence UI.
   Pulls existing series / packet / log snapshots and renders temporal context
   around offset jumps. It never promotes temporal proximity to root cause. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  let loading = false;

  function esc(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function langZh() {
    return !S.lang || S.lang === "zh";
  }

  function ensureCard() {
    if (q("#timing-evidence-card")) return q("#timing-evidence-card");
    const chart = q("#page-overview .chart-card");
    if (!chart) return null;
    const card = document.createElement("div");
    card.className = "card";
    card.id = "timing-evidence-card";
    card.innerHTML = `
      <div class="card-head">
        <div>
          <h3 id="timing-evidence-title">Timing Evidence</h3>
          <div class="muted" id="timing-evidence-subtitle"></div>
        </div>
        <div class="btn-row" style="margin-top:0">
          <button class="btn btn-sm" id="timing-evidence-refresh">刷新</button>
          <button class="btn btn-sm" id="timing-evidence-copy" disabled>复制证据</button>
        </div>
      </div>
      <div id="timing-evidence-body" class="muted">—</div>`;
    chart.insertAdjacentElement("afterend", card);
    q("#timing-evidence-refresh").addEventListener("click", () => refreshEvidence(true));
    q("#timing-evidence-copy").addEventListener("click", copyCurrentEvidence);
    updateLabels();
    return card;
  }

  function updateLabels() {
    const zh = langZh();
    const title = q("#timing-evidence-title");
    const subtitle = q("#timing-evidence-subtitle");
    const refresh = q("#timing-evidence-refresh");
    const copy = q("#timing-evidence-copy");
    if (title) title.textContent = zh ? "时间证据 / Timing Evidence" : "Timing Evidence";
    if (subtitle) subtitle.textContent = zh
      ? "offset 突变附近的报文与引擎事件；时间相邻不代表因果关系"
      : "Packets and engine events near offset jumps; temporal proximity does not establish causality.";
    if (refresh) refresh.textContent = zh ? "刷新" : "Refresh";
    if (copy) copy.textContent = zh ? "复制证据" : "Copy evidence";
  }

  function fmtNsLocal(v) {
    if (typeof fmtNs === "function") return fmtNs(Number(v));
    const n = Number(v);
    if (!Number.isFinite(n)) return "—";
    const a = Math.abs(n);
    if (a >= 1e6) return `${(n / 1e6).toFixed(3)} ms`;
    if (a >= 1e3) return `${(n / 1e3).toFixed(1)} µs`;
    return `${n.toFixed(0)} ns`;
  }

  function fmtTime(ts) {
    const n = Number(ts);
    if (!Number.isFinite(n) || n < 100000000) return `t=${Number.isFinite(n) ? n.toFixed(3) : "?"}s`;
    return new Date(n * 1000).toLocaleTimeString(langZh() ? "zh-CN" : "en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      fractionalSecondDigits: 3,
    });
  }

  function packetLine(p, eventTs) {
    const relMs = ((Number(p.ts) - Number(eventTs)) * 1000).toFixed(1);
    const rel = Number(relMs) >= 0 ? `+${relMs}` : relMs;
    const gm = p.grandmaster_identity ? ` GM=${p.grandmaster_identity}` : "";
    const corr = p.correction_field_ns !== null && p.correction_field_ns !== undefined
      ? ` corr=${fmtNsLocal(p.correction_field_ns)}` : "";
    return `${rel} ms · ${p.message_type} seq=${p.sequence_id ?? "—"} domain=${p.domain ?? "—"}${gm}${corr}`;
  }

  function logLine(l, eventTs) {
    const relMs = ((Number(l.ts) - Number(eventTs)) * 1000).toFixed(1);
    const rel = Number(relMs) >= 0 ? `+${relMs}` : relMs;
    return `${rel} ms · [${l.source}] [${String(l.level).toUpperCase()}] ${l.message}`;
  }

  function summaryTags(ev) {
    const s = ev.summary || {};
    const tags = [];
    if ((s.packet_types || []).length) tags.push(`PTP: ${(s.packet_types || []).join(" / ")}`);
    if (s.sequence_observation_count) tags.push(`Seq: ${s.sequence_observation_count}`);
    if ((s.announce_grandmasters || []).length > 1) tags.push(`Announce GM: ${(s.announce_grandmasters || []).length}`);
    if (s.port_state_log_count) tags.push(`Port-state: ${s.port_state_log_count}`);
    if (s.gm_log_count) tags.push(`GM log: ${s.gm_log_count}`);
    return tags;
  }

  function eventText(ev) {
    const lines = [
      `Offset jump @ ${fmtTime(ev.ts)}`,
      `before=${ev.before_ns} ns`,
      `after=${ev.after_ns} ns`,
      `delta=${ev.delta_ns} ns`,
      `threshold=${ev.threshold_ns} ns`,
      `causality=${ev.causality || "not-established"}`,
      `correlation_supported=${!!ev.correlation_supported}`,
      `note=${ev.correlation_note || ""}`,
    ];
    if (ev.correlation_supported) {
      lines.push("", "Packets:");
      for (const p of ev.packets || []) lines.push(`- ${packetLine(p, ev.ts)}`);
      lines.push("", "Sequence observations:");
      for (const s of ev.sequence_observations || []) {
        lines.push(`- ${s.kind}: ${s.previous_sequence_id} -> ${s.sequence_id} (${s.key})`);
      }
      lines.push("", "Logs:");
      for (const l of ev.logs || []) lines.push(`- ${logLine(l, ev.ts)}`);
    }
    return lines.join("\n");
  }

  function evidenceText(events) {
    const header = [
      "gPTP Studio Timing Evidence",
      "Temporal correlation only. Causality is not established by proximity alone.",
      `Jump threshold: ${S.thresholdNs || 100000} ns`,
      "",
    ];
    return header.concat((events || []).map(eventText)).join("\n\n");
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast(langZh() ? "Timing Evidence 已复制" : "Timing Evidence copied");
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      toast(ok ? (langZh() ? "Timing Evidence 已复制" : "Timing Evidence copied") : (langZh() ? "复制失败" : "Copy failed"), ok ? "info" : "error");
    }
  }

  function copyCurrentEvidence() {
    const events = S.timingEvidence || [];
    if (!events.length) return;
    copyText(evidenceText(events));
  }

  function render(events) {
    ensureCard();
    updateLabels();
    const body = q("#timing-evidence-body");
    const copy = q("#timing-evidence-copy");
    if (!body || !copy) return;
    S.timingEvidence = events || [];
    copy.disabled = !S.timingEvidence.length;

    if (!S.timingEvidence.length) {
      body.innerHTML = `<div class="empty">${langZh()
        ? `当前 offset 样本未检测到瞬时跳变（|Δ| ≥ ${esc(fmtNsLocal(S.thresholdNs || 100000))}）。`
        : `No instantaneous offset jump detected in the current sample (|Δ| ≥ ${esc(fmtNsLocal(S.thresholdNs || 100000))}).`}</div>`;
      return;
    }

    body.innerHTML = S.timingEvidence.slice(0, 6).map((ev, idx) => {
      const tags = summaryTags(ev).map((tag) => `<span class="badge gray" style="margin-right:6px">${esc(tag)}</span>`).join("");
      const packets = (ev.packets || []).slice(0, 16).map((p) => `<div class="mono">${esc(packetLine(p, ev.ts))}</div>`).join("");
      const seq = (ev.sequence_observations || []).slice(0, 8).map((s) =>
        `<div class="mono">${esc(`${s.kind}: ${s.previous_sequence_id} → ${s.sequence_id} · ${s.key}`)}</div>`).join("");
      const logs = (ev.logs || []).slice(0, 16).map((l) => `<div class="mono">${esc(logLine(l, ev.ts))}</div>`).join("");
      const support = ev.correlation_supported;
      return `
        <details ${idx === 0 ? "open" : ""} style="margin:10px 0">
          <summary style="cursor:pointer">
            <strong>${esc(fmtTime(ev.ts))}</strong>
            · Δ ${esc(fmtNsLocal(ev.delta_ns))}
            · ${esc(fmtNsLocal(ev.before_ns))} → ${esc(fmtNsLocal(ev.after_ns))}
          </summary>
          <div style="margin:10px 0 0 16px">
            <div>${tags || '<span class="muted">no nearby evidence labels</span>'}</div>
            <p class="muted" style="margin:8px 0">${esc(ev.correlation_note || "")}</p>
            ${support ? `
              <div style="margin-top:8px"><b>${langZh() ? "附近报文" : "Nearby packets"}</b></div>
              ${packets || '<div class="muted">—</div>'}
              <div style="margin-top:8px"><b>${langZh() ? "序列观察" : "Sequence observations"}</b></div>
              ${seq || '<div class="muted">—</div>'}
              <div style="margin-top:8px"><b>${langZh() ? "附近日志" : "Nearby logs"}</b></div>
              ${logs || '<div class="muted">—</div>'}` : ""}
            <div class="muted" style="margin-top:8px">causality = ${esc(ev.causality || "not-established")}</div>
          </div>
        </details>`;
    }).join("");
  }

  async function refreshEvidence(force = false) {
    ensureCard();
    updateLabels();
    if (loading || !window.TimingEvidence) return;
    if (!force) {
      const page = q("#page-overview");
      if (!page || !page.classList.contains("active")) return;
    }
    loading = true;
    try {
      const [series, packetResult, logResult] = await Promise.all([
        api("/api/series"),
        api("/api/packets/1000"),
        api("/api/logs"),
      ]);
      const jumps = TimingEvidence.detectOffsetJumps(
        (series && series.offset) || [],
        S.thresholdNs || 100000,
        { minSpacingSec: 0.05, maxEvents: 12 },
      );
      const evidence = TimingEvidence.buildEvidenceWindows(
        jumps,
        (packetResult && packetResult.list) || [],
        (logResult && logResult.list) || [],
        { beforeSec: 1.0, afterSec: 1.0 },
      );
      render(evidence);
    } catch (e) {
      const body = q("#timing-evidence-body");
      if (body) body.textContent = `${langZh() ? "证据关联失败" : "Evidence correlation failed"}: ${e.message}`;
    } finally {
      loading = false;
    }
  }

  function install() {
    ensureCard();
    refreshEvidence(true);
    setInterval(() => refreshEvidence(false), 3000);
    setInterval(updateLabels, 1000);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
