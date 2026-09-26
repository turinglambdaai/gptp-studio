/* Wireshark one-click launch buttons on the Packets page.
   The backend owns detection, temp pcap writing, Pro gating (retained mode)
   and the detached spawn; this module only routes the click. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);

  function zh() {
    return !S.lang || S.lang === "zh";
  }

  function labels() {
    const live = q("#ws-live");
    const kept = q("#ws-retained");
    if (live) {
      live.textContent = zh() ? "Wireshark 实时" : "Wireshark live";
      live.title = zh()
        ? "在同一网卡上启动 Wireshark 并应用 gPTP 捕获过滤器（Studio 抓包不受影响）"
        : "Launch Wireshark on the same interface with a gPTP capture filter (Studio capture is unaffected)";
    }
    if (kept) {
      kept.textContent = zh() ? "Wireshark 打开报文" : "Wireshark packets";
      kept.title = zh()
        ? "把当前保留的报文写入临时 pcap 并用 Wireshark 打开（Pro）"
        : "Write retained packets to a temp pcap and open it in Wireshark (Pro)";
    }
  }

  async function launch(action) {
    const iface = q("#pk-iface") ? q("#pk-iface").value : "";
    try {
      const r = await api("/api/tools/wireshark", { action, iface });
      if (r.need_pro) {
        toast(r.error, "warn", 8000);
        return;
      }
      if (!r.ok) {
        toast(r.error || "Wireshark 联动失败", "error", 8000);
        return;
      }
      if (action === "live") {
        toast(zh() ? `Wireshark 已启动（${r.iface}，filter: ${r.filter}）` : `Wireshark started (${r.iface}, filter: ${r.filter})`);
      } else {
        toast(zh() ? `已在 Wireshark 中打开 ${r.count} 帧` : `Opened ${r.count} frames in Wireshark`);
      }
    } catch (e) {
      toast(`${zh() ? "Wireshark 联动失败" : "Wireshark launch failed"}: ${e.message}`, "error", 8000);
    }
  }

  function install() {
    const exportBtn = q("#pk-export");
    const row = exportBtn && exportBtn.parentNode;
    if (!row || q("#ws-live")) return;

    const live = document.createElement("button");
    live.id = "ws-live";
    live.className = "btn";
    live.addEventListener("click", () => launch("live"));

    const kept = document.createElement("button");
    kept.id = "ws-retained";
    kept.className = "btn";
    kept.addEventListener("click", () => launch("retained"));

    exportBtn.insertAdjacentElement("afterend", kept);
    kept.insertAdjacentElement("beforebegin", live);
    labels();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
  setInterval(labels, 1000);
})();
