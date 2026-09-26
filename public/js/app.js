/* gPTP Studio frontend. Vanilla JS, no build step, works offline.
   Commands go over fetch() JSON; live data streams over SSE /glaze/events. */
"use strict";

/* ---------- tiny helpers ---------- */
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

async function api(path, body, method = body ? "POST" : "GET") {
  const res = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    let msg = `HTTP ${res.status}`;
    try { const j = await res.json(); if (j.error) msg = j.error; } catch (_) {}
    throw new Error(msg);
  }
  return res.json();
}

function toast(msg, kind = "info", ms = 4200) {
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $("#toast-wrap").appendChild(el);
  setTimeout(() => el.remove(), ms);
}

function fmtNs(v, withSign = true) {
  if (v === null || v === undefined) return "—";
  const a = Math.abs(v);
  const s = withSign && v < 0 ? "-" : "";
  if (a >= 1e6) return `${s}${(a / 1e6).toFixed(3)} ms`;
  if (a >= 1e3) return `${s}${(a / 1e3).toFixed(1)} µs`;
  return `${s}${a.toFixed(0)} ns`;
}

function fmtUs(v) {
  if (v === null || v === undefined) return "—";
  const a = Math.abs(v);
  if (a >= 1e6) return `${(v / 1e6).toFixed(3)} ms`;
  if (a >= 1e3) return `${(v / 1e3).toFixed(1)} ms`;
  return `${v.toFixed(1)} µs`;
}

/* ---------- global state ---------- */
const S = {
  i18n: {},
  lang: "zh",
  bootstrap: null,
  chart: null,
  role: "grandmaster",
  packets: [],
  packetTotal: 0,
  detailIndex: null,
  seriesSeen: false,
};

const t = (k) => S.i18n[k] || k;

/* ---------- i18n ---------- */
function applyI18n() {
  $$("[data-i18n]").forEach((el) => {
    const v = S.i18n[el.dataset.i18n];
    if (v) el.textContent = v;
  });
  $$("[data-i18n-ph]").forEach((el) => {
    const v = S.i18n[el.dataset.i18nPh];
    if (v) el.placeholder = v;
  });
}

/* ---------- status bar ---------- */
function renderStatus(eng, cap) {
  const roleEl = $("#st-role");
  if (eng.mode) {
    roleEl.textContent = t(`role-${eng.role}`);
    roleEl.style.display = "";
  } else {
    roleEl.textContent = "idle";
  }
  const ps = $("#st-portstate");
  const portStates = eng.port_states || {};
  const portKeys = Object.keys(portStates);
  if (portKeys.length > 1) {
    // Boundary clock: one pill per port, numbered like ptp4l.
    ps.textContent = portKeys
      .sort((a, b) => Number(a) - Number(b))
      .map((k) => `P${k} ${portStates[k]}`)
      .join(" · ");
    const active = portKeys.some((k) => ["SLAVE", "GRAND_MASTER", "MASTER"].includes(portStates[k]));
    ps.className = "pill " + (active ? "ok" : eng.mode ? "live" : "");
  } else {
    ps.textContent = eng.port_state || "—";
    ps.className = "pill " + (eng.port_state === "SLAVE" || eng.port_state === "GRAND_MASTER" || eng.port_state === "MASTER" ? "ok" : eng.mode ? "live" : "");
  }
  $("#st-gm").textContent = eng.gm_id ? `GM ${eng.gm_id.slice(0, 17)}` : "—";
  const off = $("#st-offset");
  off.textContent = `offset ${fmtNs(eng.offset_ns)}`;
  off.className = "pill pill-value" + (eng.offset_ns !== null && Math.abs(eng.offset_ns) > (S.thresholdNs || 100000) ? " bad" : "");
  $("#st-delay").textContent = `delay ${fmtNs(eng.delay_ns)}`;
  const capEl = $("#st-capture");
  capEl.textContent = cap && cap.running ? `⏺ ${cap.iface}` : "⏸";
  capEl.className = "pill" + (cap && cap.running ? " live" : "");
}

function renderTier(gate) {
  const el = $("#st-tier");
  el.textContent = gate.tier === "pro" ? "PRO" : gate.tier === "trial" ? `TRIAL ${gate.detail.days_left ?? "?"}d` : "FREE";
  el.className = "pill pill-tier" + (gate.tier !== "free" ? " pro" : "");
}

/* ---------- overview ---------- */
function renderOverview(eng, cap) {
  const off = $("#ov-offset-value");
  off.textContent = fmtNs(eng.offset_ns);
  off.className = "bigvalue" + (eng.offset_ns !== null && Math.abs(eng.offset_ns) > (S.thresholdNs || 100000) ? " alarm" : "");
  $("#ov-delay-value").textContent = fmtNs(eng.delay_ns);
  $("#ov-portstate").textContent = eng.port_state || "—";
  $("#ov-gm").textContent = eng.gm_id || "—";
  $("#ov-freq").textContent = eng.freq_ppb !== null && eng.freq_ppb !== undefined ? `${eng.freq_ppb} ppb` : "—";
  $("#ov-threshold").textContent = `±${(S.thresholdNs || 100000) / 1000} µs`;
  $("#ov-engine").textContent = eng.mode ? `${eng.mode === "sim" ? "模拟器" : "linuxptp"} · ${eng.role}` : "—";
  $("#ov-capture").textContent = cap && cap.running ? `⏺ ${cap.iface}` : "—";
  const empty = $("#chart-empty");
  if (S.seriesSeen) empty.classList.add("hidden");
  else empty.classList.remove("hidden");
  S.chart.draw();
}

/* ---------- nics ---------- */
function renderNics(nics) {
  const tb = $("#nics-table tbody");
  tb.innerHTML = "";
  for (const n of nics) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><b>${n.name}</b></td>
      <td class="mono">${n.mac || "—"}</td>
      <td><span class="badge ${n.up ? "green" : "gray"}">${n.operstate}</span></td>
      <td>${n.hw_timestamping ? '<span class="badge blue">HW</span>' : '<span class="badge orange">SW</span>'}</td>
      <td class="mono">${n.phc_device || "—"}</td>
      <td>${n.driver || "—"}</td>
      <td class="mono">${(n.ips || []).join(", ") || "—"}</td>`;
    tb.appendChild(tr);
  }
  // also feed the interface selects
  for (const sel of [$("#cfg-iface"), $("#cfg-iface2"), $("#pk-iface")]) {
    if (!sel) continue;
    const cur = sel.value;
    sel.innerHTML = "";
    for (const n of nics) {
      const opt = document.createElement("option");
      opt.value = n.name;
      opt.textContent = n.hw_timestamping ? `${n.name} (HW)` : n.name;
      sel.appendChild(opt);
    }
    if (cur) sel.value = cur;
  }
}

/* ---------- config page ---------- */
const PARAM_FIELDS = ["domain", "priority1", "priority2", "log_sync_interval", "log_announce_interval"];

function renderParams(p) {
  $("#cfg-domain").value = p.domain;
  $("#cfg-priority1").value = p.priority1;
  $("#cfg-priority2").value = p.priority2;
  $("#cfg-sync").value = p.log_sync_interval;
  $("#cfg-announce").value = p.log_announce_interval;
  $("#cfg-transport").value = p.network_transport;
  $("#cfg-delay").value = p.delay_mechanism;
  updateIntervalHints();
}

function intervalHint(log) {
  const ms = Math.pow(2, log) * 1000;
  return ms >= 1000 ? `${ms / 1000} s` : `${ms} ms`;
}
function updateIntervalHints() {
  $("#cfg-sync-hint").textContent = intervalHint(+$("#cfg-sync").value);
  $("#cfg-announce-hint").textContent = intervalHint(+$("#cfg-announce").value);
}

async function mergeParams() {
  const body = {
    domain: +$("#cfg-domain").value,
    priority1: +$("#cfg-priority1").value,
    priority2: +$("#cfg-priority2").value,
    log_sync_interval: +$("#cfg-sync").value,
    log_announce_interval: +$("#cfg-announce").value,
    network_transport: $("#cfg-transport").value,
    delay_mechanism: $("#cfg-delay").value,
  };
  if (S.role === "boundary") body.ifaces = boundaryIfaces();
  const r = await api("/api/params/merge", body);
  $("#conf-preview").textContent = r.conf;
  const alert = $("#cfg-alert");
  if (!r.ok) {
    alert.hidden = false;
    alert.textContent = r.errors.join("；");
  } else alert.hidden = true;
}

// Boundary clock port set: upstream first, downstream second. Kept in one
// place so the conf preview, engine start and session start all agree.
function boundaryIfaces() {
  const up = ($("#cfg-iface") && $("#cfg-iface").value) || "";
  const down = ($("#cfg-iface2") && $("#cfg-iface2").value) || "";
  return down ? [up, down] : [up];
}

function updateBoundaryUI() {
  const row = $("#bc-iface2-row");
  if (row) row.classList.toggle("on", S.role === "boundary");
}

function renderRole(role) {
  $$("#role-seg button").forEach((b) => b.classList.toggle("active", b.dataset.role === role));
  S.role = role;
  // role presets: fill typical values on explicit switch
  if (role === "grandmaster") { $("#cfg-priority1").value = 0; }
  if (role === "slave" || role === "boundary") { $("#cfg-priority1").value = 248; }
  updateBoundaryUI();
  mergeParams().catch(() => {});
}

/* ---------- packets page ---------- */
function typeBadge(f) {
  if (!f.is_ptp) return '<span class="badge gray">non-PTP</span>';
  const cls = { Sync: "blue", Follow_Up: "blue", Announce: "green", PDelay_Req: "orange", PDelay_Resp: "orange", PDelay_Resp_Follow_Up: "orange", Signalling: "gray" }[f.ptp.message_type_name] || "gray";
  return `<span class="badge ${cls}">${f.ptp.message_type_name}</span>`;
}

function packetRow(f, idx) {
  const tr = document.createElement("tr");
  tr.className = "clickable";
  tr.dataset.index = idx;
  const ts = f.ts !== null && f.ts !== undefined ? (f.ts % 100).toFixed(6) : "—";
  tr.innerHTML = `
    <td>${f.index}</td>
    <td>${ts}</td>
    <td class="msgtype">${typeBadge(f)}</td>
    <td>${f.is_ptp ? f.ptp.sequence_id : "—"}</td>
    <td>${f.is_ptp ? f.ptp.domain_number : "—"}</td>
    <td>${f.is_ptp ? f.ptp.source_port_identity : "—"}</td>
    <td>${f.length}</td>`;
  tr.addEventListener("click", () => showDetail(f));
  return tr;
}

function renderPacketList() {
  const tb = $("#pk-tbody");
  tb.innerHTML = "";
  const frag = document.createDocumentFragment();
  for (const f of S.packets) frag.appendChild(packetRow(f, f.index));
  tb.appendChild(frag);
  $("#pk-empty").style.display = S.packets.length ? "none" : "block";
  $("#pk-summary").textContent =
    `${S.i18n.pk_no || ""} ${S.packets.length} / ${S.packetTotal} PTP 帧${S.captureSrc ? ` · 来源: ${S.captureSrc}` : ""}`;
}

function renderPacketsListFromApi(list, total) {
  S.packets = list;
  S.packetTotal = total;
  S.captureSrc = null;
  renderPacketList();
}

function showDetail(f) {
  $("#pk-detail").hidden = false;
  const tree = $("#pk-tree");
  tree.innerHTML = "";
  const addLine = (cls, k, v) => {
    const div = document.createElement("div");
    if (cls === "section") { div.className = "tree-section"; div.textContent = k; }
    else { div.innerHTML = `<span class="tree-k">${k}</span>: <span class="tree-v">${v}</span>`; }
    tree.appendChild(div);
  };
  addLine("section", `FRAME · ${f.length} bytes · ${f.iface || "-"}`);
  addLine("", "mac_src", f.mac_src || "—");
  addLine("", "mac_dst", f.mac_dst || "—");
  addLine("", "transport", f.transport || "—");
  if (f.ip) { addLine("", "ip", `${f.ip.src_ip}:${f.ip.src_port} → ${f.ip.dst_ip}:${f.ip.dst_port}`); }
  if (f.is_ptp) {
    const h = f.ptp;
    addLine("section", `PTP HEADER · ${h.message_type_name}`);
    for (const k of ["transport_specific", "ptp_version", "message_length", "domain_number", "sequence_id", "control_field", "log_message_interval"])
      addLine("", k, h[k]);
    addLine("", "flags", (h.flags_list || []).join(" | ") || "0");
    addLine("", "correction_field_ns", h.correction_field_ns);
    addLine("", "source_port_identity", h.source_port_identity);
    const b = f.body || {};
    addLine("section", `BODY · ${h.message_type_name}`);
    for (const [k, v] of Object.entries(b)) {
      if (v && typeof v === "object") addLine("", k, `${v.seconds}.${String(v.nanoseconds).padStart(9, "0")}s`);
      else addLine("", k, v);
    }
    if ((f.tlvs || []).length) {
      addLine("section", `TLVs · ${f.tlvs.length}`);
      for (const tv of f.tlvs) {
        addLine("", `tlv ${tv.tlv_type_name}`, tv.length);
        for (const k of ["organization_id", "subtype", "cumulative_scaled_rate_offset", "gm_time_base_indicator", "clock_ids"])
          if (tv[k] !== undefined) addLine("", k, Array.isArray(tv[k]) ? tv[k].join(" → ") : tv[k]);
      }
    }
  } else {
    addLine("", "error", f.error || "not PTP");
  }
  // hex dump
  const hexEl = $("#pk-hex");
  const hex = f.raw_hex || "";
  let out = "";
  for (let i = 0; i < hex.length; i += 32) {
    const row = hex.slice(i, i + 32);
    const off = (i / 2).toString(16).padStart(4, "0");
    const ascii = (row.match(/../g) || []).map((b) => {
      const c = parseInt(b, 16);
      return c >= 32 && c < 127 ? String.fromCharCode(c) : ".";
    }).join("");
    out += `${off}  ${row.match(/../g).join(" ")}  ${ascii}\n`;
  }
  hexEl.textContent = out || "—";
  $("#pk-detail").scrollIntoView({ behavior: "smooth", block: "nearest" });
}

/* ---------- logs ---------- */
function renderLogs(entries) {
  const view = $("#log-view");
  const level = $("#log-level").value;
  const search = ($("#log-search").value || "").toLowerCase();
  const html = entries
    .filter((e) => (!level || e[2] === level) && (!search || e[3].toLowerCase().includes(search)))
    .map((e) => {
      const time = new Date(e[0]).toLocaleTimeString("zh-CN", { hour12: false });
      return `<div class="log-line ${e[2]}"><span class="log-time">${time}</span> <span class="log-src">[${e[1]}]</span> <span class="log-lv">[${e[2]}]</span> ${escapeHtml(e[3])}</div>`;
    })
    .join("");
  view.innerHTML = html || '<div class="empty">—</div>';
  view.scrollTop = 0;
}

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/* ---------- presets ---------- */
function renderPresets(list) {
  const tb = $("#preset-table tbody");
  tb.innerHTML = "";
  for (const p of list) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><b>${p.name}</b></td>
      <td>${p.role || ""}</td>
      <td class="mono">${p.iface || "—"}</td>
      <td><button class="btn btn-sm act-apply">应用</button></td>
      <td><button class="btn btn-sm btn-danger act-del">删</button></td>`;
    tr.querySelector(".act-apply").addEventListener("click", async () => {
      try {
        const r = await api("/api/preset/apply", { name: p.name });
        if (r.ok) {
          renderParams(r.params);
          $("#conf-preview").textContent = r.conf;
          if (r.role) renderRole(r.role);
          if (r.iface) $("#cfg-iface").value = r.iface;
          toast(`预设 ${p.name} 已应用`);
        } else toast(r.error, "error");
      } catch (e) { toast(e.message, "error"); }
    });
    tr.querySelector(".act-del").addEventListener("click", async () => {
      await api(`/api/preset/${encodeURIComponent(p.name)}`, null, "DELETE");
      loadPresets();
    });
    tb.appendChild(tr);
  }
}

/* ---------- license ---------- */
function renderLicense(gate) {
  const body = $("#about-body");
  const tierName = gate.tier === "pro" ? t("lic-tier-pro") : gate.tier === "trial" ? t("lic-tier-trial") : t("lic-tier-free");
  let detail = "";
  if (gate.tier === "pro") {
    detail = `<div class="lic-line"><span class="k">subject</span><span>${gate.detail.subject || "—"}</span></div>
              <div class="lic-line"><span class="k">expiry</span><span>${gate.detail.expiry || "永久"}</span></div>`;
  } else if (gate.tier === "trial") {
    detail = `<div class="lic-line"><span class="k">剩余天数</span><span>${gate.detail.days_left ?? "?"} 天</span></div>`;
  }
  body.innerHTML = `
    <div class="lic-line"><span class="k">版本</span><span>gPTP Studio v${S.version}</span></div>
    <div class="lic-line"><span class="k">${t("lic-tier-free")}</span><span>${tierName}</span></div>
    ${detail}
    <div class="lic-line"><span class="k">Free</span><span>监听抓包 · 离线分析 · 模拟器 · 配置编辑</span></div>
    <div class="lic-line"><span class="k">Pro</span><span>GM/从钟引擎 · 参考源 · pcap 导出</span></div>`;
  $("#lic-trial").disabled = gate.tier !== "free";
}

/* ---------- routing ---------- */
function navigate() {
  const hash = location.hash || "#/overview";
  const page = hash.replace("#/", "") || "overview";
  $$(".nav-item").forEach((a) => a.classList.toggle("active", a.dataset.page === page));
  $$(".page").forEach((p) => p.classList.toggle("active", p.id === `page-${page}`));
}

/* ---------- SSE ---------- */
function openEvents() {
  const es = new EventSource("/glaze/events");
  es.addEventListener("series", (e) => {
    const d = JSON.parse(e.data);
    S.seriesSeen = true;
    if (d.offset_ns !== null && d.offset_ns !== undefined) S.chart.push("offset", d.t, d.offset_ns);
    if (d.delay_ns !== null && d.delay_ns !== undefined) S.chart.push("delay", d.t, d.delay_ns);
    if ($("#page-overview").classList.contains("active")) S.chart.draw();
  });
  es.addEventListener("state-changed", (e) => {
    const d = JSON.parse(e.data);
    S.engine = d;
    renderStatus(d, S.capture);
    renderOverview(d, S.capture);
  });
  es.addEventListener("packets", (e) => {
    const batch = JSON.parse(e.data);
    if (!batch.length) return;
    S.captureSrc = batch[0].source || batch[0].iface;
    // snapshot indices: prepend batch (batch is chronological, newest last)
    S.packetTotal += batch.length;
    const base = S.packets.length ? S.packets[0].index : -1;
    // indices are absolute from the backend; refetch lazily when list page open
    if ($("#page-packets").classList.contains("active")) refreshPackets();
  });
  es.addEventListener("packets-cleared", () => { refreshPackets(); });
  es.addEventListener("capture-state", (e) => {
    S.capture = { running: true, iface: JSON.parse(e.data).iface };
    renderStatus(S.engine, S.capture);
  });
  es.addEventListener("capture-stopped", () => { refreshCapture(); });
  es.addEventListener("alarm", (e) => {
    const d = JSON.parse(e.data);
    toast(d.message, "error", 8000);
  });
  es.addEventListener("backend-error", (e) => {
    toast(`后端错误: ${JSON.parse(e.data).message}`, "error");
  });
}

async function refreshPackets() {
  try {
    const r = await api("/api/packets");
    renderPacketsListFromApi(r.list, r.total);
  } catch (_) {}
}
async function refreshCapture() {
  try {
    S.capture = { running: false };
    renderStatus(S.engine, S.capture);
  } catch (_) {}
}

/* ---------- boot ---------- */
async function boot() {
  S.chart = new LiveChart($("#chart"));
  setInterval(() => { if ($("#page-overview").classList.contains("active")) S.chart.draw(); }, 500);

    const b = await api("/api/bootstrap");
  S.bootstrap = b;
  S.version = b.version;
  S.i18n = b.i18n;
  S.lang = b.language;
  S.engine = b.engine;
  S.capture = b.capture;
  S.thresholdNs = (b.settings["offset-warn-us"] || 100) * 1000;
  $("#lang-switch").value = S.lang;
  $("#version-badge").textContent = "v" + b.version;
  applyI18n();
  renderTier(b.gate);
  renderStatus(b.engine, b.capture);
  renderNics(b.nics);
  renderParams(b.params);
  $("#conf-preview").textContent = b.conf;
  renderLicense(b.gate);
  renderOverview(b.engine, b.capture);
  $("#log-level").addEventListener("change", loadLogs);
  $("#log-search").addEventListener("input", loadLogs);
  loadLogs();
  loadPresets();
  refreshPackets();

  // series backfill
  try {
    const s = await api("/api/series");
    if (s.offset.length || s.delay.length) {
      S.seriesSeen = true;
      S.chart.backfill("offset", s.offset);
      S.chart.backfill("delay", s.delay);
    }
  } catch (_) {}

  openEvents();

  /* ---- wire static handlers ---- */
  window.addEventListener("hashchange", navigate);
  navigate();

  $("#lang-switch").addEventListener("change", async (e) => {
    await api("/api/settings", { language: e.target.value });
    const d = await api("/api/i18n");
    S.i18n = d; applyI18n(); renderLicense(S.bootstrap.gate);
  });

  $("#nics-refresh").addEventListener("click", async () => {
    const r = await api("/api/nics");
    renderNics(r.list);
    toast("已重新扫描网卡");
  });

  $$("#role-seg button").forEach((btn) =>
    btn.addEventListener("click", () => renderRole(btn.dataset.role)));

  for (const id of ["cfg-domain", "cfg-priority1", "cfg-priority2", "cfg-sync", "cfg-announce", "cfg-transport", "cfg-delay"]) {
    $("#" + id).addEventListener("change", mergeParams);
  }
  if ($("#cfg-iface2")) $("#cfg-iface2").addEventListener("change", mergeParams);

  $("#engine-start").addEventListener("click", async () => {
    try {
      const mode = $("#cfg-mode").value;
      const iface = $("#cfg-iface").value;
      const payload = { role: S.role, mode, iface };
      if (S.role === "boundary") payload.ifaces = boundaryIfaces();
      const r = await api("/api/engine/start", payload);
      if (!r.ok) {
        if (r.need_pro) toast(r.error, "warn", 8000);
        else toast(r.error, "error", 8000);
      } else toast(t("running"));
    } catch (e) { toast(e.message, "error"); }
  });

  $("#engine-stop").addEventListener("click", async () => {
    await api("/api/engine/stop");
    toast(t("stopped"));
  });

  $("#preset-save-btn").addEventListener("click", () => savePreset($("#cfg-iface").value));
  $("#preset-save2").addEventListener("click", () => savePreset($("#cfg-iface").value));

  $$("#source-seg button").forEach((btn) =>
    btn.addEventListener("click", () => {
      $$("#source-seg button").forEach((b) => b.classList.toggle("active", b === btn));
      $("#source-note").textContent = btn.dataset.source === "system"
        ? "已选择：系统时钟经 phc2sys 写入 PHC（Pro 功能，重启 GM 引擎后生效）"
        : "不使用外部参考源";
    }));

  $("#pk-start").addEventListener("click", async () => {
    const iface = $("#pk-iface").value;
    try {
      const r = await api("/api/capture/start", { iface });
      if (!r.ok) toast(r.error, "error", 8000);
      else toast(`抓包中: ${iface}`);
      S.capture = { running: r.ok, iface };
      renderStatus(S.engine, S.capture);
    } catch (e) { toast(e.message, "error"); }
  });
  $("#pk-stop").addEventListener("click", async () => {
    await api("/api/capture/stop");
    S.capture = { running: false };
    renderStatus(S.engine, S.capture);
  });
  $("#pk-clear").addEventListener("click", async () => {
    await api("/api/packets/clear");
    refreshPackets();
  });
  $("#pk-import").addEventListener("click", async () => {
    try {
      const r = await api("/api/pcap/import");
      if (r.ok) { toast(`已导入 ${r.count} 帧`); refreshPackets(); }
      else if (!r.cancelled) toast(r.error, "error");
    } catch (e) { toast(e.message, "error"); }
  });
  $("#pk-export").addEventListener("click", async () => {
    try {
      const r = await api("/api/pcap/export");
      if (r.ok) toast(`已导出 ${r.count} 帧 → ${r.path}`);
      else if (r.need_pro) toast(r.error, "warn", 8000);
      else if (!r.cancelled) toast(r.error, "error");
    } catch (e) { toast(e.message, "error"); }
  });
  $("#pk-detail-close").addEventListener("click", () => { $("#pk-detail").hidden = true; });

  $("#log-export").addEventListener("click", async () => {
    try { const r = await api("/api/logs/export"); if (!r.ok && !r.cancelled) toast(r.error, "error"); }
    catch (e) { toast(e.message, "error"); }
  });

  $("#lic-trial").addEventListener("click", async () => {
    const r = await api("/api/license/trial");
    renderTier(r.gate); renderLicense(r.gate);
    toast(`试用已开始（${r.gate.detail.days_left} 天）`);
  });
  $("#lic-activate").addEventListener("click", async () => {
    const r = await api("/api/license/activate", {});
    if (r.ok) { toast(`已激活: ${r.subject}`); const g = await api("/api/license"); renderTier(g); renderLicense(g); }
    else if (!r.cancelled) toast(r.error, "error");
  });
  $("#lic-buy").addEventListener("click", () => {
    toast("购买：请访问 https://github.com/turinglambdaai/gptp-studio 获取授权。", "info", 10000);
  });
}

async function loadLogs() {
  try {
    const r = await api("/api/logs");
    renderLogs(r.list);
  } catch (_) {}
}
async function loadPresets() {
  try {
    const r = await api("/api/presets");
    renderPresets(r.list || []);
  } catch (_) {}
}
async function savePreset(iface) {
  const name = $("#preset-name").value || $("#preset-name").placeholder || "";
  if (!name) { toast("请输入预设名", "warn"); return; }
  try {
    const r = await api("/api/preset/save", { name, role: S.role, iface: iface || "" });
    if (r.ok) { toast(`预设 ${name} 已保存`); loadPresets(); }
    else toast(r.error, "error");
  } catch (e) { toast(e.message, "error"); }
}

/* ---------- in-page verification (agent-friendly; no screen permission
   needed: DOM facts + canvas pixel stats, posted to the backend) ---------- */
async function postVerify() {
  try {

    const chart = $("#chart");
    let stats = { total: 0, blue: 0, orange: 0 };
    try {
      const ctx = chart.getContext("2d");
      const w = chart.width, h = chart.height;
      if (w && h) {
        const img = ctx.getImageData(0, 0, w, h).data;
        let total = 0, blue = 0, orange = 0;
        for (let i = 0; i < img.length; i += 64) {
          total++;
          const r = img[i], g = img[i + 1], b = img[i + 2];
          if (Math.abs(r - 33) < 40 && Math.abs(g - 150) < 40 && Math.abs(b - 243) < 40) blue++;
          if (Math.abs(r - 255) < 40 && Math.abs(g - 152) < 45 && b < 80) orange++;
        }
        stats = { total, blue, orange };
      }
    } catch (_) {}
    const eng = S.engine || {};
    const payload = {
      title: document.title,
      activePage: (location.hash || "#/overview").replace("#/", ""),
      navCount: $$(".nav-item").length,
      statusbar: $("#statusbar").textContent.trim().replace(/\s+/g, " "),
      nicRows: $$("#nics-table tbody tr").length,
      packetRows: $$("#pk-tbody tr").length,
      logLines: $$("#log-view .log-line").length,
      confPreviewLen: ($("#conf-preview").textContent || "").length,
      engineMode: eng.mode || null,
      engineRole: eng.role || null,
      portState: eng.port_state || null,
      offsetNs: eng.offset_ns ?? null,
      chart: stats,
    };
    await api("/api/dev/verify", payload);
  } catch (_) {}
}
setInterval(postVerify, 4000);
setTimeout(postVerify, 1200);

boot().catch((e) => {
  document.body.insertAdjacentHTML("beforeend", `<div class="toast error" style="position:fixed;top:70px;right:16px">初始化失败: ${e.message}</div>`);
  fetch("/api/dev/verify", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload: { bootError: String(e && e.stack || e) } }) }).catch(() => {});
});
window.addEventListener("error", (ev) => {
  fetch("/api/dev/verify", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload: { jsError: String(ev.message) + " @" + ev.filename + ":" + ev.lineno } }) }).catch(() => {});
});
