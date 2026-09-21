/* Keep the visible role and the hidden ptp4l role constraints consistent.

   The backend starts with listener params (gmCapable=0, slaveOnly=1). The
   original UI, however, defaulted to GrandMaster and only changed priority1
   when switching roles. That could make the UI say "GrandMaster" while the
   generated real-engine config stayed slaveOnly.

   Listener is the safe idle default. Every params merge and every engine
   start now carries the role-defining fields explicitly. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  function roleFields(role = S.role) {
    if (role === "grandmaster") return { gm_capable: 1, slave_only: 0 };
    return { gm_capable: 0, slave_only: 1 };
  }

  function rewritePreviewRole(conf, role = S.role) {
    if (typeof conf !== "string") return conf;
    return conf.replace(/^# role:.*$/m, `# role: ${role}   iface: UI selection`);
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
      // Close the click-race between renderRole()->mergeParams() and Start.
      // This also protects callers other than the role buttons (e.g. the
      // one-click session control) from stale hidden role fields.
      await baseApi("/api/params/merge", roleFields(body.role || S.role), "POST");
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
