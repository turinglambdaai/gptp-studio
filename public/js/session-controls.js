/* One-click debug session orchestration.
   GM/Slave: engine + capture in real mode, simulator only in sim mode.
   Listener: capture only in real mode. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  let busy = false;

  function ensureControls() {
    if (q("#session-start")) return;
    const host = q(".overview-head-actions") || q("#page-overview .card-head");
    if (!host) return;
    const wrap = document.createElement("div");
    wrap.className = "session-controls";
    wrap.innerHTML = `
      <button class="btn btn-sm btn-primary" id="session-start" title="按当前角色/模式/网卡启动完整调试会话">▶ 开始会话</button>
      <button class="btn btn-sm btn-danger" id="session-stop" title="停止抓包与引擎">■ 停止全部</button>`;
    host.appendChild(wrap);
    q("#session-start").addEventListener("click", startSession);
    q("#session-stop").addEventListener("click", stopSession);
    refreshButtons();
  }

  function currentConfig() {
    return {
      role: S.role || "listener",
      mode: q("#cfg-mode") ? q("#cfg-mode").value : "sim",
      iface: q("#cfg-iface") ? q("#cfg-iface").value : "",
      ifaces: S.role === "boundary"
        ? [q("#cfg-iface") ? q("#cfg-iface").value : "",
           q("#cfg-iface2") ? q("#cfg-iface2").value : ""].filter(Boolean)
        : [],
    };
  }

  function running() {
    return !!((S.engine && S.engine.mode) || (S.capture && S.capture.running));
  }

  function refreshButtons() {
    const start = q("#session-start");
    const stop = q("#session-stop");
    if (!start || !stop) return;
    start.disabled = busy || running();
    stop.disabled = busy || !running();
    if (busy) start.textContent = "处理中…";
    else start.textContent = "▶ 开始会话";
  }

  async function startCapture(iface) {
    const r = await api("/api/capture/start", { iface });
    if (!r.ok) return { ok: false, error: r.error || "抓包启动失败" };
    S.capture = { running: true, iface };
    renderStatus(S.engine, S.capture);
    return { ok: true };
  }

  async function startSession() {
    if (busy) return;
    busy = true;
    refreshButtons();
    const cfg = currentConfig();
    try {
      if (cfg.mode === "real" && !cfg.iface) {
        toast("真实调试会话需要先选择网卡", "warn", 7000);
        return;
      }
      if (cfg.mode === "real" && cfg.role === "boundary" && cfg.ifaces.length < 2) {
        toast("Boundary clock 需要选择上游与下游两个不同网卡", "warn", 7000);
        return;
      }

      // A real Listener does not need a local ptp4l clock role; capture is the
      // useful operation and avoids changing the host clock/port state.
      if (cfg.mode === "real" && cfg.role === "listener") {
        const cr = await startCapture(cfg.iface);
        if (!cr.ok) toast(cr.error, "error", 8000);
        else {
          toast(`Listener 会话已启动 · ${cfg.iface}`);
          location.hash = "#/packets";
        }
        return;
      }

      const startPayload = { role: cfg.role, mode: cfg.mode, iface: cfg.iface };
      if (cfg.role === "boundary") startPayload.ifaces = cfg.ifaces;
      const er = await api("/api/engine/start", startPayload);
      if (!er.ok) {
        toast(er.error || "引擎启动失败", er.need_pro ? "warn" : "error", 9000);
        return;
      }

      if (cfg.mode === "real") {
        const cr = await startCapture(cfg.iface);
        if (!cr.ok) {
          toast(`引擎已启动，但抓包失败：${cr.error}`, "warn", 9000);
        } else {
          toast(`${cfg.role} 调试会话已启动 · engine + capture`);
        }
      } else {
        toast(`${cfg.role} 模拟会话已启动`);
      }
      location.hash = "#/overview";
    } catch (e) {
      toast(`启动会话失败: ${e.message}`, "error", 9000);
    } finally {
      busy = false;
      setTimeout(refreshButtons, 0);
    }
  }

  async function stopSession() {
    if (busy) return;
    busy = true;
    refreshButtons();
    const errors = [];
    try {
      if (S.capture && S.capture.running) {
        try { await api("/api/capture/stop"); }
        catch (e) { errors.push(`capture: ${e.message}`); }
        S.capture = { running: false };
      }
      if (S.engine && S.engine.mode) {
        try { await api("/api/engine/stop"); }
        catch (e) { errors.push(`engine: ${e.message}`); }
      }
      if (errors.length) toast(`会话停止时有错误：${errors.join("; ")}`, "warn", 9000);
      else toast("调试会话已停止");
      renderStatus(S.engine, S.capture);
    } finally {
      busy = false;
      setTimeout(refreshButtons, 0);
    }
  }

  ensureControls();
  setInterval(refreshButtons, 600);
})();
