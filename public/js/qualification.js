/* Commercial-readiness preflight.
   Converts raw NIC/tooling facts into a conservative, actionable readiness
   result. It never turns timestamp capability/resolution into an accuracy
   claim. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  let busy = false;
  let refreshTimer = null;

  function hasState() {
    return typeof S !== "undefined" && !!S.bootstrap;
  }

  function currentPayload() {
    const refBtn = q("#source-seg button.active");
    return {
      iface: (q("#cfg-iface") && q("#cfg-iface").value) || "",
      role: (typeof S !== "undefined" && S.role) || "listener",
      reference: (refBtn && refBtn.dataset.source) ||
                 ((typeof S !== "undefined" && S.engine && S.engine.reference) || "system"),
    };
  }

  function ensureUi() {
    const card = q("#timing-capability-card");
    if (!card || q("#qualification-run")) return false;

    const head = card.querySelector(".card-head");
    if (head) {
      const actions = document.createElement("div");
      actions.className = "qualification-actions";
      actions.innerHTML = `
        <button class="btn btn-sm" id="qualification-run" title="检查真实引擎前置条件，不宣称测量精度">运行 Preflight</button>
        <button class="btn btn-sm" id="diagnostics-export" title="导出默认去除 MAC/IP 的支持诊断 JSON">导出诊断</button>`;
      head.appendChild(actions);
    }

    const message = q("#timing-message");
    if (message) {
      message.insertAdjacentHTML("afterend", `
        <div class="qualification-panel" id="qualification-panel" hidden>
          <div class="qualification-summary">
            <span class="qualification-status" id="qualification-status">—</span>
            <span id="qualification-summary-text">—</span>
          </div>
          <div class="qualification-checks" id="qualification-checks"></div>
          <div class="qualification-disclaimer" id="qualification-disclaimer"></div>
        </div>`);
    }

    q("#qualification-run").addEventListener("click", () => runPreflight(false));
    q("#diagnostics-export").addEventListener("click", exportDiagnostics);
    return true;
  }

  function stateLabel(state) {
    if (state === "pass") return "PASS";
    if (state === "warn") return "WARN";
    if (state === "fail") return "FAIL";
    return "INFO";
  }

  function statusLabel(status) {
    if (status === "ready") return "READY";
    if (status === "candidate") return "VERIFY";
    if (status === "passive-only") return "PASSIVE ONLY";
    return "BLOCKED";
  }

  function renderQualification(result) {
    const panel = q("#qualification-panel");
    if (!panel || !result) return;
    panel.hidden = false;
    panel.dataset.status = result.status || "blocked";

    const status = q("#qualification-status");
    status.textContent = statusLabel(result.status);
    status.className = `qualification-status ${result.status || "blocked"}`;
    q("#qualification-summary-text").textContent = result.summary || "—";

    const checks = q("#qualification-checks");
    checks.textContent = "";
    for (const c of (result.checks || [])) {
      const row = document.createElement("div");
      row.className = `qualification-check ${c.state || "info"}`;
      const action = c.action ? `<div class="qualification-action">${escapeHtml(c.action)}</div>` : "";
      row.innerHTML = `
        <span class="qualification-check-state">${stateLabel(c.state)}</span>
        <div><strong>${escapeHtml(c.title || c.id || "check")}</strong>
          <div class="qualification-detail">${escapeHtml(c.detail || "")}</div>${action}
        </div>`;
      checks.appendChild(row);
    }

    q("#qualification-disclaimer").textContent = result.accuracy_note ||
      "Preflight 只验证前置条件，不代表已校准的端到端时间精度。";
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  async function runPreflight(silent) {
    if (busy) return;
    busy = true;
    const btn = q("#qualification-run");
    if (btn) {
      btn.disabled = true;
      btn.textContent = "检查中…";
    }
    try {
      const r = await api("/api/qualification", currentPayload());
      if (!r.ok) {
        if (!silent) toast(r.error || "Preflight 失败", "error", 8000);
        return;
      }
      renderQualification(r.qualification);
      if (!silent) {
        const s = r.qualification && r.qualification.status;
        toast(`Preflight: ${statusLabel(s)}`, s === "blocked" ? "warn" : "info", 5000);
      }
    } catch (e) {
      if (!silent) toast(`Preflight 失败: ${e.message}`, "error", 8000);
    } finally {
      busy = false;
      if (btn) {
        btn.disabled = false;
        btn.textContent = "运行 Preflight";
      }
    }
  }

  async function exportDiagnostics() {
    if (busy) return;
    busy = true;
    const btn = q("#diagnostics-export");
    if (btn) btn.disabled = true;
    try {
      const r = await api("/api/diagnostics/export", currentPayload());
      if (r.ok) {
        toast(`诊断快照已导出（MAC/IP 已脱敏）→ ${r.path}`, "info", 9000);
        if (r.qualification) renderQualification(r.qualification);
      } else if (!r.cancelled) {
        toast(r.error || "诊断导出失败", "error", 8000);
      }
    } catch (e) {
      toast(`诊断导出失败: ${e.message}`, "error", 8000);
    } finally {
      busy = false;
      if (btn) btn.disabled = false;
    }
  }

  function scheduleRefresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => runPreflight(true), 180);
  }

  const init = setInterval(() => {
    if (!hasState()) return;
    if (!ensureUi()) return;
    clearInterval(init);
    runPreflight(true);

    if (q("#cfg-iface")) q("#cfg-iface").addEventListener("change", scheduleRefresh);
    document.addEventListener("click", (ev) => {
      const target = ev.target.closest && ev.target.closest("#role-seg button, #source-seg button");
      if (target) scheduleRefresh();
    });
  }, 50);
})();
