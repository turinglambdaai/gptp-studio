/* Make the Reference Source page control real supervisor state.
   Loaded after app.js so it can reuse api(), toast(), S and renderStatus(). */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  function renderReference(eng) {
    if (!eng) return;
    const reference = eng.reference || "system";
    qa("#source-seg button").forEach((btn) =>
      btn.classList.toggle("active", btn.dataset.source === reference));

    const note = q("#source-note");
    if (!note) return;
    const state = eng.reference_status || "idle";
    const text = {
      running: "phc2sys 已运行：CLOCK_REALTIME → PHC；UTC/PTP offset 由 ptp4l 提供。",
      starting: "真实引擎正在启动参考时钟…",
      restarting: "linuxptp 会话正在重启，参考时钟将随会话恢复。",
      "pending-restart": "已选择系统时钟；下次启动真实 GrandMaster 时由 phc2sys 写入 PHC。",
      disabled: "不由 gPTP Studio 管理 PHC 参考源。请确保 PHC 的时间基准由其他方式正确提供。",
      "not-applicable": "当前角色不需要 Studio 管理 GrandMaster 参考源。",
      simulated: "模拟器模式：参考源为模拟状态，不会修改系统或 PHC 时钟。",
      error: "参考源进程异常；请查看“运行与日志”中的 phc2sys/ptp4l 日志。",
      idle: reference === "system"
        ? "系统时钟已选为 GrandMaster 参考源；启动真实 GM 后生效。"
        : "未启用 Studio 管理的参考源。",
    }[state] || `参考源状态: ${state}`;
    note.textContent = text;
  }

  qa("#source-seg button").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const source = btn.dataset.source;
      try {
        const r = await api("/api/engine/reference", { source });
        if (!r.ok) {
          toast(r.error || "参考源设置失败", "error", 8000);
          return;
        }
        S.engine = r.status;
        renderReference(r.status);
        toast(source === "system" ? "参考源：系统时钟" : "参考源：不由 Studio 管理");
      } catch (e) {
        toast(e.message, "error", 8000);
      }
    });
  });

  // Piggyback on the app's normal state rendering so phc2sys startup/crashes
  // immediately update this page without opening a second SSE connection.
  const baseRenderStatus = renderStatus;
  renderStatus = function referenceAwareRenderStatus(eng, cap) {
    baseRenderStatus(eng, cap);
    renderReference(eng);
  };

  if (S.engine) renderReference(S.engine);
})();
