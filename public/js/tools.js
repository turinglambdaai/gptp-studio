/* Small daily-use utilities for gPTP Studio.
   Kept separate from the runtime and protocol code so these conveniences are
   easy to iterate without destabilising capture or linuxptp control. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  async function copyText(text, success) {
    try {
      await navigator.clipboard.writeText(text);
      toast(success || "已复制");
      return true;
    } catch (_) {
      try {
        const ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        const ok = document.execCommand("copy");
        ta.remove();
        if (ok) toast(success || "已复制");
        else toast("复制失败", "error");
        return ok;
      } catch (e) {
        toast(`复制失败: ${e.message}`, "error");
        return false;
      }
    }
  }

  function addHeaderButton(card, id, label, handler) {
    if (!card || q(`#${id}`)) return;
    let head = card.querySelector(":scope > .card-head");
    if (!head) {
      const title = card.querySelector(":scope > h2, :scope > h3");
      if (!title) return;
      head = document.createElement("div");
      head.className = "card-head";
      title.parentNode.insertBefore(head, title);
      head.appendChild(title);
    }
    const btn = document.createElement("button");
    btn.id = id;
    btn.className = "btn btn-sm";
    btn.textContent = label;
    btn.addEventListener("click", handler);
    head.appendChild(btn);
  }

  function installConfigCopy() {
    const pre = q("#conf-preview");
    const card = pre && pre.closest(".card");
    addHeaderButton(card, "copy-conf", "复制配置", () => copyText(pre.textContent || "", "ptp4l.conf 已复制"));
  }

  function selectedPacket() {
    const selected = q("#pk-tbody tr.packet-selected");
    if (selected) {
      const idx = Number(selected.dataset.index);
      return (S.packets || []).find((f) => Number(f.index) === idx) || null;
    }
    return null;
  }

  function packetSummaryText(f) {
    if (!f) return "";
    const h = f.ptp || {};
    const lines = [
      `Frame: ${f.index ?? "—"}`,
      `Timestamp: ${f.ts ?? "—"}`,
      `Interface: ${f.iface || "—"}`,
      `Source: ${f.source || "—"}`,
      `MAC: ${f.mac_src || "—"} -> ${f.mac_dst || "—"}`,
      `Length: ${f.length ?? "—"}`,
    ];
    if (f.is_ptp) {
      lines.push(
        `Message: ${h.message_type_name || "—"}`,
        `Domain: ${h.domain_number ?? "—"}`,
        `Sequence ID: ${h.sequence_id ?? "—"}`,
        `Source Port Identity: ${h.source_port_identity || "—"}`,
        `Correction: ${h.correction_field_ns ?? "—"} ns`,
        `Flags: ${(h.flags_list || []).join(" | ") || "0"}`,
      );
      for (const [k, v] of Object.entries(f.body || {})) {
        lines.push(`${k}: ${typeof v === "object" ? JSON.stringify(v) : v}`);
      }
      for (const tlv of f.tlvs || []) lines.push(`TLV ${tlv.tlv_type_name || tlv.tlv_type || "?"}: ${JSON.stringify(tlv)}`);
    } else if (f.error) {
      lines.push(`Decode error: ${f.error}`);
    }
    return lines.join("\n");
  }

  function installPacketCopy() {
    const card = q("#pk-detail");
    const head = card && card.querySelector(":scope > .card-head");
    if (!head || q("#copy-packet-summary")) return;
    const close = q("#pk-detail-close");
    const actions = document.createElement("div");
    actions.className = "btn-row packet-detail-actions";
    actions.style.marginTop = "0";
    actions.innerHTML = '<button class="btn btn-sm" id="copy-packet-summary">复制摘要</button><button class="btn btn-sm" id="copy-packet-hex">复制 Hex</button>';
    head.insertBefore(actions, close);
    q("#copy-packet-summary").addEventListener("click", () => {
      const f = selectedPacket();
      if (!f) return toast("请先选择报文", "warn");
      copyText(packetSummaryText(f), "报文摘要已复制");
    });
    q("#copy-packet-hex").addEventListener("click", () => {
      const f = selectedPacket();
      if (!f) return toast("请先选择报文", "warn");
      copyText(f.raw_hex || "", "报文 Hex 已复制");
    });
  }

  function failureText(f) {
    if (!f) return "";
    const actions = Array.isArray(f.actions) ? f.actions : [];
    return [
      `Failure: ${f.title || f.kind || "linuxptp startup failure"}`,
      `Kind: ${f.kind || "unknown"}`,
      `Summary: ${f.summary || "—"}`,
      `Exit code: ${f.exit_code ?? "—"}`,
      `Launch mode: ${f.launch_mode || "—"}`,
      `Evidence: ${f.evidence || "—"}`,
      ...(actions.length ? ["Actions:", ...actions.map((a, i) => `  ${i + 1}. ${a}`)] : []),
    ].join("\n");
  }

  function supportSnapshot() {
    const eng = S.engine || {};
    const cap = S.capture || {};
    const iface = q("#cfg-iface") ? q("#cfg-iface").value : "";
    const nics = (S.bootstrap && S.bootstrap.nics) || [];
    const nic = nics.find((n) => n.name === iface) || null;
    const params = {
      role: S.role,
      mode: q("#cfg-mode") ? q("#cfg-mode").value : null,
      interface: iface || null,
      domain: q("#cfg-domain") ? Number(q("#cfg-domain").value) : null,
      priority1: q("#cfg-priority1") ? Number(q("#cfg-priority1").value) : null,
      priority2: q("#cfg-priority2") ? Number(q("#cfg-priority2").value) : null,
      logSyncInterval: q("#cfg-sync") ? Number(q("#cfg-sync").value) : null,
      logAnnounceInterval: q("#cfg-announce") ? Number(q("#cfg-announce").value) : null,
    };
    const lines = [
      `gPTP Studio v${S.version || "?"}`,
      `Platform: ${(S.bootstrap && S.bootstrap.platform) || "?"}`,
      `Role / mode: ${params.role} / ${params.mode}`,
      `Interface: ${params.interface || "—"}`,
      `NIC driver: ${nic && nic.driver || "—"}`,
      `Link: ${nic && nic.operstate || "—"} ${nic && nic.speed && nic.speed !== "unknown" ? `${nic.speed} Mb/s` : ""}`.trim(),
      `HW timestamp: ${nic ? !!nic.hw_timestamping : "—"}`,
      `PHC: ${nic && nic.phc_device || "—"}`,
      `Engine: ${eng.mode || "idle"} / ${eng.port_state || "—"}`,
      `GM: ${eng.gm_id || "—"}`,
      `Offset: ${eng.offset_ns ?? "—"} ns`,
      `Path delay: ${eng.delay_ns ?? "—"} ns`,
      `Frequency: ${eng.freq_ppb ?? "—"} ppb`,
      `Capture: ${cap.running ? `running on ${cap.iface}` : "stopped"}`,
      `Params: ${JSON.stringify(params)}`,
    ];
    if (eng.last_failure) lines.push("", "Last engine failure:", failureText(eng.last_failure));
    lines.push("", "ptp4l.conf:", q("#conf-preview") ? q("#conf-preview").textContent : "—");
    return lines.join("\n");
  }

  function installOverviewSnapshot() {
    const chartCard = q("#page-overview .chart-card");
    const head = chartCard && chartCard.querySelector(":scope > .card-head");
    if (!head || q("#copy-support-snapshot")) return;
    const legend = head.querySelector(".legend");
    const wrap = document.createElement("div");
    wrap.className = "overview-head-actions";
    const btn = document.createElement("button");
    btn.id = "copy-support-snapshot";
    btn.className = "btn btn-sm";
    btn.textContent = "复制调试快照";
    btn.title = "复制平台、网卡、PHC、当前同步状态、最近引擎失败和 ptp4l.conf，方便贴到 issue/聊天中";
    btn.addEventListener("click", () => copyText(supportSnapshot(), "调试快照已复制"));
    if (legend) wrap.appendChild(legend);
    wrap.appendChild(btn);
    head.appendChild(wrap);
  }

  function installLogCopy() {
    const exportBtn = q("#log-export");
    if (!exportBtn || q("#log-copy-visible")) return;
    const btn = document.createElement("button");
    btn.id = "log-copy-visible";
    btn.className = "btn";
    btn.textContent = "复制当前日志";
    btn.title = "复制当前过滤后可见的日志";
    btn.addEventListener("click", () => {
      const lines = qa("#log-view .log-line").map((el) => el.textContent).join("\n");
      if (!lines) return toast("当前没有可复制的日志", "warn");
      copyText(lines, "当前日志已复制");
    });
    exportBtn.parentNode.insertBefore(btn, exportBtn);
  }

  function injectFailureStyles() {
    if (q("#failure-card-styles")) return;
    const style = document.createElement("style");
    style.id = "failure-card-styles";
    style.textContent = `
      #last-failure-card { border-left: 3px solid var(--red, #c43b3b); }
      #last-failure-card[hidden] { display: none; }
      .failure-kind { font-size: 12px; text-transform: uppercase; letter-spacing: .06em; opacity: .7; }
      .failure-title { font-weight: 700; margin: 8px 0 4px; }
      .failure-summary { margin-bottom: 8px; }
      .failure-evidence { white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; padding: 8px; border-radius: 5px; background: rgba(127,127,127,.10); }
      .failure-actions { margin: 8px 0 0 20px; padding: 0; }
      .failure-meta { font-size: 12px; opacity: .72; margin-top: 8px; }
    `;
    document.head.appendChild(style);
  }

  function installFailureCard() {
    if (q("#last-failure-card")) return;
    const col = q("#page-runtime .col");
    const about = q("#about-card");
    if (!col || !about) return;
    injectFailureStyles();
    const card = document.createElement("div");
    card.className = "card";
    card.id = "last-failure-card";
    card.hidden = true;
    card.innerHTML = `
      <div class="card-head">
        <h3 id="failure-card-heading">最近一次启动失败</h3>
        <button class="btn btn-sm" id="copy-last-failure">复制详情</button>
      </div>
      <div class="failure-kind" id="failure-kind"></div>
      <div class="failure-title" id="failure-title"></div>
      <div class="failure-summary" id="failure-summary"></div>
      <div class="failure-evidence" id="failure-evidence"></div>
      <ol class="failure-actions" id="failure-actions"></ol>
      <div class="failure-meta" id="failure-meta"></div>`;
    col.insertBefore(card, about);
    q("#copy-last-failure").addEventListener("click", () => {
      const failure = S.engine && S.engine.last_failure;
      if (!failure) return toast("当前没有启动失败详情", "warn");
      copyText(failureText(failure), "启动失败详情已复制");
    });
  }

  let lastFailureFingerprint = null;
  function renderFailureCard() {
    const card = q("#last-failure-card");
    if (!card) return;
    const failure = S.engine && S.engine.last_failure;
    const fingerprint = failure ? JSON.stringify(failure) : "";
    if (fingerprint === lastFailureFingerprint) return;
    lastFailureFingerprint = fingerprint;
    if (!failure) {
      card.hidden = true;
      return;
    }
    card.hidden = false;
    const english = q("#lang-switch") && q("#lang-switch").value === "en";
    q("#failure-card-heading").textContent = english ? "Last startup failure" : "最近一次启动失败";
    q("#copy-last-failure").textContent = english ? "Copy details" : "复制详情";
    q("#failure-kind").textContent = failure.kind || "unknown";
    q("#failure-title").textContent = failure.title || (english ? "linuxptp startup failure" : "linuxptp 启动失败");
    q("#failure-summary").textContent = failure.summary || "";
    q("#failure-evidence").textContent = failure.evidence || (english ? "No stderr evidence captured" : "未捕获 stderr 证据");
    const actions = q("#failure-actions");
    actions.innerHTML = "";
    for (const action of failure.actions || []) {
      const li = document.createElement("li");
      li.textContent = action;
      actions.appendChild(li);
    }
    q("#failure-meta").textContent = `rc=${failure.exit_code ?? "—"} · launch=${failure.launch_mode || "—"}`;
  }

  function visibleRows() {
    return qa("#pk-tbody tr.clickable");
  }

  function selectPacketRow(row) {
    if (!row) return;
    row.click();
    row.scrollIntoView({ block: "nearest" });
  }

  function installPacketKeyboardNav() {
    window.addEventListener("keydown", (e) => {
      const page = q("#page-packets");
      if (!page || !page.classList.contains("active")) return;
      const target = e.target;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT" || target.isContentEditable)) return;
      if (!["ArrowDown", "ArrowUp", "j", "k"].includes(e.key)) return;
      const rows = visibleRows();
      if (!rows.length) return;
      e.preventDefault();
      const selected = q("#pk-tbody tr.packet-selected");
      let index = selected ? rows.indexOf(selected) : -1;
      const forward = e.key === "ArrowDown" || e.key === "j";
      if (index < 0) index = forward ? 0 : rows.length - 1;
      else index = Math.max(0, Math.min(rows.length - 1, index + (forward ? 1 : -1)));
      selectPacketRow(rows[index]);
    });
  }

  function install() {
    installConfigCopy();
    installPacketCopy();
    installOverviewSnapshot();
    installLogCopy();
    installFailureCard();
    installPacketKeyboardNav();
    renderFailureCard();
    setInterval(renderFailureCard, 300);

    const hint = q("#shortcut-hint");
    if (hint) hint.title = "⌘/Ctrl+1…6 切页 · / 搜报文 · Space 冻结 · ↑↓/J K 浏览报文 · Esc 关闭详情";
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
