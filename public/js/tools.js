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
    return [
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
      "",
      "ptp4l.conf:",
      q("#conf-preview") ? q("#conf-preview").textContent : "—",
    ].join("\n");
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
    btn.title = "复制平台、网卡、PHC、当前同步状态和 ptp4l.conf，方便贴到 issue/聊天中";
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
    installPacketKeyboardNav();

    const hint = q("#shortcut-hint");
    if (hint) hint.title = "⌘/Ctrl+1…6 切页 · / 搜报文 · Space 冻结 · ↑↓/J K 浏览报文 · Esc 关闭详情";
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
})();
