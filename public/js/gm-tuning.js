/* GM runtime tuning card on the Role & Config page.
   Speaks to /api/engine/gm-settings; the backend owns pmc command encoding,
   current-value reads (GET-then-overlay) and validation. This module only
   renders fields and sends what the operator typed. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);

  function zh() {
    return !S.lang || S.lang === "zh";
  }

  // Hex-native fields are edited as 0x… strings and sent as decimal integers,
  // matching how these codes are written in IEEE 1588 and linuxptp configs.
  const HEX_FIELDS = new Set(["clock_accuracy", "offset_scaled_log_variance", "time_source"]);

  const FIELDS = [
    { key: "clock_class", type: "num", hint: "6 GNSS · 7 holdover · 248 gPTP 默认 · 255 uncalibrated",
      hintEn: "6 GNSS · 7 holdover · 248 gPTP default · 255 uncalibrated" },
    { key: "clock_accuracy", type: "hex", hint: "0x20 1ns · 0x24 25ns · 0x29 1µs · 0xFE unknown",
      hintEn: "0x20 1ns · 0x24 25ns · 0x29 1µs · 0xFE unknown" },
    { key: "offset_scaled_log_variance", type: "hex", hint: "0x4E5D 常用 · 0xFFFF unknown",
      hintEn: "0x4E5D common · 0xFFFF unknown" },
    { key: "current_utc_offset", type: "num", hint: "TAI−UTC 秒", hintEn: "TAI−UTC seconds" },
    { key: "time_source", type: "hex", hint: "0xA0 内部振荡器（gPTP 默认）· 0x10 GPS",
      hintEn: "0xA0 internal oscillator (gPTP default) · 0x10 GPS" },
    { key: "priority1", type: "num", hint: "802.1AS 固定 248；改动用于 BMCA 接管测试",
      hintEn: "802.1AS fixes 248; changing is for BMCA takeover tests" },
    { key: "priority2", type: "num", hint: "同 GM 内部排序", hintEn: "tie-break inside one GM" },
  ];

  const FLAGS = [
    { key: "leap61", label: "leap61" },
    { key: "leap59", label: "leap59" },
    { key: "current_utc_offset_valid", label: "utcOffsetValid" },
    { key: "ptp_timescale", label: "ptpTimescale" },
    { key: "time_traceable", label: "timeTraceable" },
    { key: "frequency_traceable", label: "freqTraceable" },
  ];

  function labels() {
    const card = q("#gm-tuning-card");
    if (!card) return;
    card.querySelector("h2").textContent = zh() ? "GM 运行时调优" : "GM runtime tuning";
    card.querySelector(".card-sub").textContent = zh()
      ? "通过 pmc 在线修改本机 GrandMaster 时钟质量与 BMCA 优先级（无需重启引擎）。读取当前值后仅改动需要的字段。调试用途：改变的是对外宣告的质量，不构成校准声明。"
      : "Change this station's announced clock quality and BMCA priorities via pmc without an engine restart. Read current values, edit only what you need. Debugging only: this changes what is announced, not a calibration claim.";
    q("#gm-read").textContent = zh() ? "读取当前" : "Read current";
    q("#gm-apply").textContent = zh() ? "应用" : "Apply";
    const note = q("#gm-note");
    if (note && !note.dataset.error) {
      note.textContent = zh()
        ? "需要真实引擎（linuxptp）运行中。"
        : "Requires a running real engine (linuxptp).";
    }
  }

  function ensureCard() {
    if (q("#gm-tuning-card")) return;
    const page = q("#page-config");
    if (!page) return;

    const rows = FIELDS.map((f) => `
      <label class="mono">${f.key}</label>
      <div class="input-row">
        <input id="gm-${f.key}" type="text" inputmode="numeric" autocomplete="off">
        <span class="hint" id="gm-${f.key}-hint"></span>
      </div>`).join("");

    const checks = FLAGS.map((f) => `
      <label class="gm-flag"><input type="checkbox" id="gm-${f.key}"> ${f.label}</label>`).join("");

    page.insertAdjacentHTML("beforeend", `
      <div class="card" id="gm-tuning-card" hidden>
        <div class="card-head">
          <div>
            <h2>GM 运行时调优</h2>
            <div class="card-sub muted"></div>
          </div>
          <div class="btn-row">
            <button class="btn" id="gm-read">读取当前</button>
            <button class="btn btn-primary" id="gm-apply">应用</button>
          </div>
        </div>
        <div class="form-grid">${rows}</div>
        <div class="gm-flags">${checks}</div>
        <div class="alert alert-info" id="gm-note" hidden></div>
      </div>`);

    q("#gm-read").addEventListener("click", readCurrent);
    q("#gm-apply").addEventListener("click", apply);
    for (const f of FIELDS) {
      const hint = q(`#gm-${f.key}-hint`);
      if (hint) hint.textContent = zh() ? f.hint : (f.hintEn || f.hint);
    }
  }

  function toDisplay(key, value) {
    if (value === null || value === undefined) return "";
    return HEX_FIELDS.has(key) ? `0x${Number(value).toString(16)}` : String(value);
  }

  function parseInput(key, raw) {
    const text = String(raw || "").trim();
    if (text === "") return null;
    const n = /^0[xX][0-9a-fA-F]+$/.test(text) ? parseInt(text, 16) : Number(text);
    return Number.isInteger(n) ? n : NaN;
  }

  function fillFields(settings) {
    if (!settings) return;
    for (const f of FIELDS) {
      const el = q(`#gm-${f.key}`);
      if (el) el.value = toDisplay(f.key, settings[f.key]);
    }
    for (const f of FLAGS) {
      const el = q(`#gm-${f.key}`);
      if (el) el.checked = Number(settings[f.key]) === 1;
    }
  }

  function note(message, isError) {
    const el = q("#gm-note");
    if (!el) return;
    el.textContent = message;
    el.hidden = !message;
    el.classList.toggle("alert-info", !isError);
    el.dataset.error = isError ? "1" : "";
  }

  async function readCurrent() {
    note("", false);
    try {
      const r = await api("/api/engine/gm-settings");
      if (!r.ok) {
        note(r.error || "读取失败", true);
        return;
      }
      fillFields(r.settings);
      note(zh() ? "已读取当前值。" : "Current values loaded.", false);
    } catch (e) {
      note(e.message, true);
    }
  }

  async function apply() {
    const body = {};
    let bad = null;
    for (const f of FIELDS) {
      const el = q(`#gm-${f.key}`);
      if (!el || el.value.trim() === "") continue;
      const n = parseInput(f.key, el.value);
      if (Number.isNaN(n)) { bad = f.key; break; }
      body[f.key] = n;
    }
    for (const f of FLAGS) {
      const el = q(`#gm-${f.key}`);
      if (el) body[f.key] = el.checked ? 1 : 0;
    }
    if (bad) {
      note(`${bad}: ${zh() ? "无法解析的数值" : "unparseable value"}`, true);
      return;
    }
    try {
      const r = await api("/api/engine/gm-settings", body);
      if (r.need_pro) {
        note(r.error || (zh() ? "GM 运行时调优需要 Pro。" : "GM runtime tuning requires Pro."), true);
        return;
      }
      if (!r.ok) {
        note(r.error || "应用失败", true);
        return;
      }
      fillFields(r.settings);
      note(zh() ? "已应用；下一次 Announce 起对外生效。" : "Applied; takes effect on the next Announce.", false);
      toast(zh() ? "GM 调优已应用" : "GM tuning applied");
    } catch (e) {
      note(e.message, true);
    }
  }

  function render(eng) {
    ensureCard();
    const card = q("#gm-tuning-card");
    if (!card) return;
    card.hidden = !(eng && eng.mode === "real");
    labels();
  }

  // Piggyback on the app's status rendering, mirroring reference-controls.
  const baseRenderStatus = renderStatus;
  renderStatus = function gmTuningAwareRenderStatus(eng, cap) {
    baseRenderStatus(eng, cap);
    render(eng);
  };

  if (S.engine) render(S.engine);
  setInterval(labels, 1000);
})();
