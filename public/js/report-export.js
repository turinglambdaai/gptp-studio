/* Engineering report export controls.
   The backend owns report generation, privacy redaction and file writing; this
   module only supplies the currently selected role/interface/reference. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);

  function zh() {
    return !S.lang || S.lang === "zh";
  }

  function context() {
    const source = q("#source-seg button.active");
    return {
      iface: q("#cfg-iface") ? q("#cfg-iface").value : "",
      role: S.role || "",
      reference: source && source.dataset.source ? source.dataset.source : "",
    };
  }

  async function exportReport(format) {
    const button = q(format === "json" ? "#report-export-json" : "#report-export-md");
    const old = button && button.textContent;
    if (button) button.disabled = true;
    try {
      const r = await api("/api/report/export", { format, ...context() });
      if (r.ok) {
        toast(zh() ? `工程报告已导出 → ${r.path}` : `Engineering report exported → ${r.path}`, "info", 8000);
      } else if (!r.cancelled) {
        toast(r.error || (zh() ? "工程报告导出失败" : "Engineering report export failed"), "error", 8000);
      }
    } catch (e) {
      toast(`${zh() ? "工程报告导出失败" : "Engineering report export failed"}: ${e.message}`, "error", 8000);
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = old;
      }
    }
  }

  function labels() {
    const md = q("#report-export-md");
    const json = q("#report-export-json");
    if (md) {
      md.textContent = zh() ? "工程报告 .md" : "Report .md";
      md.title = zh() ? "导出脱敏的人类可读工程报告" : "Export a redacted human-readable engineering report";
    }
    if (json) {
      json.textContent = zh() ? "工程报告 .json" : "Report .json";
      json.title = zh() ? "导出脱敏的机器可读工程报告" : "Export a redacted machine-readable engineering report";
    }
  }

  function install() {
    if (q("#report-export-md")) return;
    const logExport = q("#log-export");
    const row = logExport && logExport.parentNode;
    if (!row) return;

    const md = document.createElement("button");
    md.id = "report-export-md";
    md.className = "btn";
    md.addEventListener("click", () => exportReport("markdown"));

    const json = document.createElement("button");
    json.id = "report-export-json";
    json.className = "btn";
    json.addEventListener("click", () => exportReport("json"));

    row.appendChild(md);
    row.appendChild(json);
    labels();
    setInterval(labels, 1000);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
