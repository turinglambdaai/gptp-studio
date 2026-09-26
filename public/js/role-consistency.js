/* Keep the visible role and linuxptp role constraints consistent.

   Listener is a passive-capture workflow. GM/Slave engine starts first commit
   the complete visible form so a click immediately after editing cannot race
   with an asynchronous `change` merge. Role flags are also enforced again by
   the backend config generator, so this layer is UX protection rather than the
   only correctness boundary. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  function roleFields(role = S.role) {
    if (role === "grandmaster" || role === "boundary") return { gm_capable: 1, slave_only: 0 };
    return { gm_capable: 0, slave_only: 1 };
  }

  function visibleParams(role = S.role) {
    const num = (id) => {
      const el = q(id);
      return el ? Number(el.value) : undefined;
    };
    const value = (id) => {
      const el = q(id);
      return el ? el.value : undefined;
    };
    return {
      domain: num("#cfg-domain"),
      priority1: num("#cfg-priority1"),
      priority2: num("#cfg-priority2"),
      log_sync_interval: num("#cfg-sync"),
      log_announce_interval: num("#cfg-announce"),
      network_transport: value("#cfg-transport"),
      delay_mechanism: value("#cfg-delay"),
      ...roleFields(role),
    };
  }

  function rewritePreviewRole(conf, role = S.role) {
    if (typeof conf !== "string") return conf;
    return conf.replace(/^# role:\s+\S+/m, `# role: ${role}`);
  }

  function updateRealListenerHint() {
    const mode = q("#cfg-mode");
    const start = q("#engine-start");
    if (!mode || !start) return;
    const passive = S.role === "listener" && mode.value === "real";
    start.disabled = passive;
    start.title = passive
      ? "真实 Listener 是纯抓包角色，请使用“开始会话”或报文页“开始抓包”，不会启动 ptp4l。"
      : "";
  }

  // Safe default matches the backend's initial listener parameters.
  S.role = "listener";
  qa("#role-seg button").forEach((btn) =>
    btn.classList.toggle("active", btn.dataset.role === "listener"));

  const baseApi = api;
  api = async function roleAwareApi(path, body, method = body ? "POST" : "GET") {
    if (path === "/api/params/merge" && body) {
      const r = await baseApi(path, { ...body, ...roleFields() }, method);
      if (r && r.conf) r.conf = rewritePreviewRole(r.conf);
      return r;
    }

    if (path === "/api/engine/start" && body) {
      const role = body.role || S.role;
      if (body.mode === "real" && role === "listener") {
        return {
          ok: false,
          passive_listener: true,
          error: "真实 Listener 是被动抓包角色，不启动 ptp4l。请使用“开始会话”或报文分析页开始抓包。",
        };
      }

      // Engine start is a transaction boundary: synchronise every visible
      // field plus role-defining flags before asking the backend to spawn.
      const merged = await baseApi(
        "/api/params/merge",
        visibleParams(role),
        "POST",
      );
      if (!merged.ok) {
        return { ok: false, error: (merged.errors || ["参数校验失败"]).join("；") };
      }
      const pre = q("#conf-preview");
      if (pre && merged.conf) pre.textContent = rewritePreviewRole(merged.conf, role);
      return baseApi(path, body, method);
    }

    const r = await baseApi(path, body, method);
    if (path === "/api/conf" && r && r.conf) r.conf = rewritePreviewRole(r.conf);
    return r;
  };

  // Keep the direct engine button truthful as role/mode changes.
  const mode = q("#cfg-mode");
  if (mode) mode.addEventListener("change", updateRealListenerHint);
  qa("#role-seg button").forEach((btn) =>
    btn.addEventListener("click", () => setTimeout(updateRealListenerHint, 0)));

  const init = setInterval(() => {
    if (!S.bootstrap) return;
    clearInterval(init);
    const pre = q("#conf-preview");
    if (pre) pre.textContent = rewritePreviewRole(pre.textContent, S.role);
    updateRealListenerHint();
  }, 50);
})();
