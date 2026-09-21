/* Keep the visible role and the hidden ptp4l role constraints consistent.

   The backend starts with listener params (gmCapable=0, slaveOnly=1). The
   original UI, however, defaulted to GrandMaster and only changed priority1
   when switching roles. That could make the UI say "GrandMaster" while the
   generated real-engine config stayed slaveOnly.

   Listener is the safe idle default. Every params merge carries the role
   constraints, and every engine start first commits the complete visible form
   so a click immediately after editing cannot race with an asynchronous
   `change` merge. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  function roleFields(role = S.role) {
    if (role === "grandmaster") return { gm_capable: 1, slave_only: 0 };
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

  // Safe default must match app/api.rkt's initial listener parameters.
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
      // Engine start is a transaction boundary: synchronise every visible
      // field plus role-defining flags before asking the backend to spawn.
      // This closes both role-switch and last-edited-input races.
      const merged = await baseApi(
        "/api/params/merge",
        visibleParams(body.role || S.role),
        "POST",
      );
      if (!merged.ok) {
        return { ok: false, error: (merged.errors || ["参数校验失败"]).join("；") };
      }
      const pre = q("#conf-preview");
      if (pre && merged.conf) pre.textContent = rewritePreviewRole(merged.conf, body.role || S.role);
      return baseApi(path, body, method);
    }

    const r = await baseApi(path, body, method);
    if (path === "/api/conf" && r && r.conf) r.conf = rewritePreviewRole(r.conf);
    return r;
  };

  // Once bootstrap has rendered the initial conf, make its comment match the
  // safe listener default too. Fields already match because backend defaults
  // are listener params.
  const init = setInterval(() => {
    if (!S.bootstrap) return;
    clearInterval(init);
    const pre = q("#conf-preview");
    if (pre) pre.textContent = rewritePreviewRole(pre.textContent, S.role);
  }, 50);
})();
