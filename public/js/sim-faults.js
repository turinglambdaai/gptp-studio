/* Simulator fault injection card on the Role & Config page.
   Negative testing for the analyst's own tooling: alarms, BMCA timeline,
   timing-evidence correlation and reports can be exercised without hardware.
   The backend owns validation and the encode pipeline; this module only
   renders the profile. Visible in simulator mode only. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);

  function zh() {
    return !S.lang || S.lang === "zh";
  }

  const FIELDS = [
    { key: "sync_drop_pct", label: "sync_drop_pct", hint: "%；Sync 丢弃概率，Follow_Up 成为孤儿帧",
      hintEn: "% Sync drop probability; Follow_Up becomes orphaned" },
    { key: "announce_drop_pct", label: "announce_drop_pct", hint: "%；Announce 丢弃，制造 BMCA 候选断档",
      hintEn: "% Announce drops; creates BMCA candidate gaps" },
    { key: "followup_delay_ms", label: "followup_delay_ms", hint: "ms；Follow_Up 时间戳后移（迟到的主钟）",
      hintEn: "ms; shift Follow_Up timestamp (late master)" },
    { key: "sequence_gap_every", label: "sequence_gap_every", hint: "每 N 个 Sync 注入一次 sequenceId 跳变（0=关）",
      hintEn: "inject a sequenceId gap every N Sync pairs (0=off)" },
    { key: "offset_spike_ns", label: "offset_spike_ns", hint: "ns；从钟 offset 周期性尖峰幅度（0=关）",
      hintEn: "ns; periodic slave offset spike amplitude (0=off)" },
    { key: "offset_spike_every_s", label: "offset_spike_every_s", hint: "s；尖峰周期",
      hintEn: "s; spike period" },
  ];

  function labels() {
    const card = q("#sim-faults-card");
    if (!card) return;
    card.querySelector("h2").textContent = zh() ? "故障注入（模拟器）" : "Fault injection (simulator)";
    card.querySelector(".card-sub").textContent = zh()
      ? "在模拟器会话中注入异常报文行为，用于验证告警、BMCA 时间轴、根因关联与工程报告。注入帧仍是语法合法的 gPTP，走同一条解码管道；仅模拟器模式生效。"
      : "Inject abnormal frame behaviour into a simulator session to exercise alarms, the BMCA timeline, root-cause correlation and engineering reports. Injected frames remain valid gPTP on the same decode pipeline; simulator mode only.";
    q("#faults-read").textContent = zh() ? "读取当前" : "Read current";
    q("#faults-apply").textContent = zh() ? "应用" : "Apply";
    q("#faults-clear").textContent = zh() ? "清除" : "Clear";
    for (const f of FIELDS) {
      const hint = q(`#faults-${f.key}-hint`);
      if (hint) hint.textContent = zh() ? f.hint : (f.hintEn || f.hint);
    }
  }

  function ensureCard() {
    if (q("#sim-faults-card")) return;
    const page = q("#page-config");
    if (!page) return;

    const rows = FIELDS.map((f) => `
      <label class="mono">${f.label}</label>
      <div class="input-row">
        <input id="faults-${f.key}" type="number" step="1" min="0" autocomplete="off">
        <span class="hint" id="faults-${f.key}-hint"></span>
      </div>`).join("");

    page.insertAdjacentHTML("beforeend", `
      <div class="card" id="sim-faults-card" hidden>
        <div class="card-head">
          <div>
            <h2>故障注入（模拟器）</h2>
            <div class="card-sub muted"></div>
          </div>
          <div class="btn-row">
            <button class="btn" id="faults-read">读取当前</button>
            <button class="btn" id="faults-clear">清除</button>
            <button class="btn btn-primary" id="faults-apply">应用</button>
          </div>
        </div>
        <div class="form-grid">${rows}</div>
        <div class="alert alert-info" id="faults-note" hidden></div>
      </div>`);

    q("#faults-read").addEventListener("click", readCurrent);
    q("#faults-clear").addEventListener("click", clearAll);
    q("#faults-apply").addEventListener("click", apply);
  }

  function fill(faults) {
    if (!faults) return;
    for (const f of FIELDS) {
      const el = q(`#faults-${f.key}`);
      if (el) el.value = faults[f.key] || 0;
    }
  }

  function note(message, isError) {
    const el = q("#faults-note");
    if (!el) return;
    el.textContent = message;
    el.hidden = !message;
    el.classList.toggle("alert-info", !isError);
  }

  async function readCurrent() {
    note("", false);
    try {
      const r = await api("/api/simulator/faults");
      if (r.ok) {
        fill(r.faults);
        note(zh() ? "已读取当前注入配置。" : "Current fault profile loaded.", false);
      }
    } catch (e) {
      note(e.message, true);
    }
  }

  function collect() {
    const body = {};
    for (const f of FIELDS) {
      const el = q(`#faults-${f.key}`);
      if (el && el.value !== "") body[f.key] = Number(el.value);
    }
    return body;
  }

  async function apply() {
    try {
      const r = await api("/api/simulator/faults", collect());
      if (!r.ok) {
        note(r.error || "应用失败", true);
        return;
      }
      fill(r.faults);
      note(zh() ? "已应用；下一个模拟 tick 起生效。" : "Applied; effective from the next simulated tick.", false);
      toast(zh() ? "故障注入已应用" : "Fault injection applied");
    } catch (e) {
      note(e.message, true);
    }
  }

  async function clearAll() {
    const body = {};
    for (const f of FIELDS) body[f.key] = 0;
    try {
      const r = await api("/api/simulator/faults", body);
      if (!r.ok) {
        note(r.error || "清除失败", true);
        return;
      }
      fill(r.faults);
      note(zh() ? "已清除全部注入。" : "All faults cleared.", false);
    } catch (e) {
      note(e.message, true);
    }
  }

  function render(eng) {
    ensureCard();
    const card = q("#sim-faults-card");
    if (!card) return;
    card.hidden = !(eng && eng.mode === "sim");
    labels();
  }

  const baseRenderStatus = renderStatus;
  renderStatus = function simFaultsAwareRenderStatus(eng, cap) {
    baseRenderStatus(eng, cap);
    render(eng);
  };

  if (S.engine) render(S.engine);
  setInterval(labels, 1000);
})();
