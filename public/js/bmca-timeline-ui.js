/* BMCA Timeline UI.
   Shows captured Announce evolution separately from linuxptp selection/state
   logs. The two evidence streams are intentionally not fused into causality. */
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

  function zh() {
    return !S.lang || S.lang === "zh";
  }

  function fmtTime(ts) {
    const n = Number(ts);
    if (!Number.isFinite(n)) return "—";
    if (n < 100000000) return `t=${n.toFixed(3)}s`;
    return new Date(n * 1000).toLocaleTimeString(zh() ? "zh-CN" : "en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      fractionalSecondDigits: 3,
    });
  }

  function ensureCard() {
    if (q("#bmca-timeline-card")) return q("#bmca-timeline-card");
    const packetPage = q("#page-packets");
    const firstCard = packetPage && packetPage.querySelector(":scope > .card");
    if (!firstCard) return null;
    const card = document.createElement("div");
    card.className = "card";
    card.id = "bmca-timeline-card";
    card.innerHTML = `
      <div class="card-head">
        <div>
          <h3 id="bmca-title">BMCA Timeline</h3>
          <div class="muted" id="bmca-subtitle"></div>
        </div>
        <div class="btn-row" style="margin-top:0">
          <button class="btn btn-sm" id="bmca-refresh">刷新</button>
          <button class="btn btn-sm" id="bmca-copy" disabled>复制摘要</button>
        </div>
      </div>
      <div id="bmca-summary" class="muted">—</div>
      <div class="grid-2" style="margin-top:12px">
        <div>
          <h4 id="bmca-candidates-title">Observed Announce candidates</h4>
          <div id="bmca-candidates"></div>
          <h4 id="bmca-announce-events-title" style="margin-top:14px">Announce evolution</h4>
          <div id="bmca-announce-events"></div>
        </div>
        <div>
          <h4 id="bmca-engine-events-title">linuxptp BMCA / port evidence</h4>
          <div id="bmca-engine-events"></div>
        </div>
      </div>`;
    firstCard.insertAdjacentElement("afterend", card);
    q("#bmca-refresh").addEventListener("click", () => refresh(true));
    q("#bmca-copy").addEventListener("click", copySummary);
    updateLabels();
    return card;
  }

  function updateLabels() {
    if (!q("#bmca-timeline-card")) return;
    q("#bmca-title").textContent = zh() ? "BMCA 演化时间线" : "BMCA Timeline";
    q("#bmca-subtitle").textContent = zh()
      ? "Announce 抓包证据与 linuxptp 选择/端口日志分开显示；此视图不独立重跑 BMCA，也不从不完整抓包推断必然胜者。"
      : "Captured Announce evidence is shown separately from linuxptp selection/port logs. This view does not re-run BMCA or infer a guaranteed winner from an incomplete capture.";
    q("#bmca-refresh").textContent = zh() ? "刷新" : "Refresh";
    q("#bmca-copy").textContent = zh() ? "复制摘要" : "Copy summary";
    q("#bmca-candidates-title").textContent = zh() ? "观察到的 Announce 候选" : "Observed Announce candidates";
    q("#bmca-announce-events-title").textContent = zh() ? "Announce 演化" : "Announce evolution";
    q("#bmca-engine-events-title").textContent = zh() ? "linuxptp BMCA / 端口证据" : "linuxptp BMCA / port evidence";
  }

  function datasetText(d) {
    if (!d) return "—";
    const parts = [
      `p1=${d.grandmaster_priority1 ?? "—"}`,
      `class=${d.grandmaster_clock_class ?? "—"}`,
      `acc=${d.grandmaster_clock_accuracy ?? "—"}`,
      `var=${d.grandmaster_offset_scaled_log_variance ?? "—"}`,
      `p2=${d.grandmaster_priority2 ?? "—"}`,
      `steps=${d.steps_removed ?? "—"}`,
      `source=${d.time_source_name || d.time_source || "—"}`,
    ];
    return parts.join(" · ");
  }

  function candidateHtml(c) {
    const d = c.latest && c.latest.dataset ? c.latest.dataset : {};
    return `
      <div style="padding:8px 0;border-bottom:1px solid var(--border,#e5e7eb)">
        <div><strong class="mono">${esc(c.grandmaster_identity || "unknown GM")}</strong></div>
        <div class="muted mono">domain=${esc(c.domain ?? "—")} · via ${esc(c.announcing_source || "—")}</div>
        <div class="mono" style="font-size:12px;margin-top:3px">${esc(datasetText(d))}</div>
        <div class="muted" style="font-size:12px">${esc(c.count)} Announce · ${esc(fmtTime(c.first_seen))} → ${esc(fmtTime(c.last_seen))}</div>
      </div>`;
  }

  function announceEventLabel(e) {
    if (e.kind === "candidate-seen") {
      return `${zh() ? "首次观察候选" : "candidate first seen"}: GM=${e.grandmaster_identity || "—"} via ${e.announcing_source || "—"}`;
    }
    if (e.kind === "dataset-change") {
      return `${zh() ? "候选数据集变化" : "candidate dataset changed"}: GM=${e.grandmaster_identity || "—"} · ${(e.changed_fields || []).join(", ")}`;
    }
    if (e.kind === "announcing-source-gm-change") {
      return `${zh() ? "同一源广告的 GM 改变" : "announcing source changed GM"}: ${e.before_grandmaster_identity || "—"} → ${e.after_grandmaster_identity || "—"} · via ${e.announcing_source || "—"}`;
    }
    return e.kind || "event";
  }

  function eventRow(time, kind, text) {
    return `<div style="padding:6px 0;border-bottom:1px solid var(--border,#e5e7eb)">
      <span class="mono muted">${esc(fmtTime(time))}</span>
      <span class="badge gray" style="margin:0 6px">${esc(kind)}</span>
      <span>${esc(text)}</span>
    </div>`;
  }

  function resultText(result) {
    const a = result.announce || {};
    const lines = [
      "gPTP Studio BMCA Timeline",
      "Observational evidence only. This report does not independently re-run IEEE 802.1AS BMCA or prove why a winner was selected.",
      `Announce frames: ${a.announce_count || 0}`,
      `Observed candidates: ${a.candidate_count || 0}`,
      "",
      "Candidates:",
    ];
    for (const c of a.candidates || []) {
      lines.push(`- GM=${c.grandmaster_identity || "—"} domain=${c.domain ?? "—"} via=${c.announcing_source || "—"} count=${c.count}`);
      lines.push(`  ${datasetText(c.latest && c.latest.dataset)}`);
    }
    lines.push("", "Announce evolution:");
    for (const e of a.events || []) lines.push(`- ${fmtTime(e.ts)} [${e.kind}] ${announceEventLabel(e)}`);
    lines.push("", "linuxptp evidence:");
    for (const e of result.engine_events || []) lines.push(`- ${fmtTime(e.ts)} [${e.kind}] ${e.message}`);
    return lines.join("\n");
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast(zh() ? "BMCA 摘要已复制" : "BMCA summary copied");
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      toast(ok ? (zh() ? "BMCA 摘要已复制" : "BMCA summary copied") : (zh() ? "复制失败" : "Copy failed"), ok ? "info" : "error");
    }
  }

  function copySummary() {
    if (S.bmcaTimeline) copyText(resultText(S.bmcaTimeline));
  }

  function render(result) {
    ensureCard();
    updateLabels();
    S.bmcaTimeline = result;
    const a = result.announce || {};
    q("#bmca-copy").disabled = false;
    q("#bmca-summary").textContent = zh()
      ? `当前窗口：${a.announce_count || 0} 个 Announce · ${a.candidate_count || 0} 个 GM/源候选 · ${(result.engine_events || []).length} 条 linuxptp 相关事件`
      : `Current window: ${a.announce_count || 0} Announce · ${a.candidate_count || 0} GM/source candidates · ${(result.engine_events || []).length} linuxptp evidence events`;

    q("#bmca-candidates").innerHTML = (a.candidates || []).length
      ? (a.candidates || []).map(candidateHtml).join("")
      : `<div class="empty">${zh() ? "当前窗口未观察到 Announce" : "No Announce observed in the current window"}</div>`;

    q("#bmca-announce-events").innerHTML = (a.events || []).length
      ? (a.events || []).slice(-40).reverse().map((e) => eventRow(e.ts, e.kind, announceEventLabel(e))).join("")
      : `<div class="empty">—</div>`;

    q("#bmca-engine-events").innerHTML = (result.engine_events || []).length
      ? (result.engine_events || []).slice(-40).reverse().map((e) => eventRow(e.ts, e.kind, e.message)).join("")
      : `<div class="empty">${zh() ? "当前日志窗口没有 BMCA/端口相关事件" : "No BMCA/port events in the current log window"}</div>`;
  }

  async function refresh(force = false) {
    ensureCard();
    updateLabels();
    if (loading || !window.BmcaTimeline) return;
    if (!force) {
      const page = q("#page-packets");
      if (!page || !page.classList.contains("active")) return;
    }
    loading = true;
    try {
      const [packets, logs] = await Promise.all([
        api("/api/packets/1000"),
        api("/api/logs"),
      ]);
      if (packets && packets.ok === false) throw new Error(packets.error || "packet snapshot failed");
      render(BmcaTimeline.analyze((packets && packets.list) || [], (logs && logs.list) || []));
    } catch (e) {
      const el = q("#bmca-summary");
      if (el) el.textContent = `${zh() ? "BMCA 时间线加载失败" : "BMCA timeline failed"}: ${e.message}`;
    } finally {
      loading = false;
    }
  }

  function install() {
    ensureCard();
    refresh(true);
    setInterval(() => refresh(false), 5000);
    setInterval(updateLabels, 1000);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
