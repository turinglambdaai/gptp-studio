/* gPTP Studio engineering-workflow enhancements.
   This file intentionally layers on top of app.js so the protocol/runtime core
   stays small and low-risk. No build step, no dependencies. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));

  let currentNics = [];
  let pendingPacketSnapshot = null;
  let uxReady = false;

  function platformLabel() {
    const p = S.bootstrap && S.bootstrap.platform;
    if (p === "linux") return "Linux";
    if (p === "macos") return "macOS";
    if (p === "windows") return "Windows";
    return p || "—";
  }

  function selectedNic() {
    const name = (q("#cfg-iface") && q("#cfg-iface").value) ||
                 (q("#pk-iface") && q("#pk-iface").value);
    return currentNics.find((n) => n.name === name) || bestNic();
  }

  function timingRank(n) {
    if (!n) return 0;
    if (n.hw_timestamping && n.phc_device && n.up) return 4;
    if (n.hw_timestamping && n.phc_device) return 3;
    if (n.hw_timestamping) return 2;
    return 1;
  }

  function bestNic() {
    return currentNics.slice().sort((a, b) => timingRank(b) - timingRank(a))[0] || null;
  }

  function timingProfile(n) {
    const platform = S.bootstrap && S.bootstrap.platform;
    if (!n) {
      return {
        level: "bad",
        badge: "NO NIC",
        title: "未检测到可用网卡",
        detail: "请检查网卡、驱动和系统网络接口。",
        path: "—",
      };
    }
    if (platform === "macos") {
      return {
        level: "warn",
        badge: "SW",
        title: `${n.name} · 软件时间戳`,
        detail: "适合协议观察、离线分析和抓包；不作为 gPTP 时间精度验证依据。",
        path: "software timestamp",
      };
    }
    if (n.hw_timestamping && n.phc_device && n.up) {
      return {
        level: "good",
        badge: "HW + PHC",
        title: `${n.name} · Timing ready`,
        detail: "已检测到硬件收发时间戳与 PHC。适合真实 gPTP 同步调试；最终精度仍取决于 NIC/PHY/驱动/拓扑并应通过实测确认。",
        path: `HW timestamp → ${n.phc_device}`,
      };
    }
    if (n.hw_timestamping && n.phc_device) {
      return {
        level: "warn",
        badge: "LINK DOWN",
        title: `${n.name} · 具备硬件时间能力，但链路未就绪`,
        detail: "硬件时间戳与 PHC 已检测到。连接 DUT/交换机并确认链路 UP 后再启动真实引擎。",
        path: `HW timestamp → ${n.phc_device}`,
      };
    }
    if (n.hw_timestamping) {
      return {
        level: "warn",
        badge: "HW / NO PHC",
        title: `${n.name} · 硬件时间戳可用，未发现 PHC`,
        detail: "可用于抓包观察，但真实 gPTP 时钟控制路径不完整。请检查驱动是否暴露 /dev/ptpN。",
        path: "HW timestamp → no PHC",
      };
    }
    return {
      level: "bad",
      badge: "SW ONLY",
      title: `${n.name} · 仅软件时间戳`,
      detail: "适合协议调试，不建议用来判断 ECU 的 ns/µs 级同步精度。优先选择支持硬件时间戳和 PHC 的网卡。",
      path: "software timestamp",
    };
  }

  function ensureTimingCard() {
    if (q("#timing-capability-card")) return;
    const page = q("#page-nics");
    if (!page) return;
    page.insertAdjacentHTML("afterbegin", `
      <div class="card timing-card" id="timing-capability-card">
        <div class="card-head">
          <div>
            <h2>Timing Capability</h2>
            <div class="muted timing-subtitle">这台电脑当前能否用于真实 gPTP 时间调试</div>
          </div>
          <span class="timing-readiness" id="timing-readiness">—</span>
        </div>
        <div class="timing-grid">
          <div class="timing-cell"><span>Host</span><strong id="timing-host">—</strong></div>
          <div class="timing-cell"><span>Interface</span><strong id="timing-iface">—</strong></div>
          <div class="timing-cell"><span>Timestamp path</span><strong class="mono" id="timing-path">—</strong></div>
          <div class="timing-cell"><span>Link</span><strong id="timing-link">—</strong></div>
        </div>
        <div class="timing-message" id="timing-message">—</div>
      </div>`);
  }

  function ensureTimingColumn() {
    const headRow = q("#nics-table thead tr");
    if (headRow && !q("#nic-timing-head")) {
      headRow.insertAdjacentHTML("beforeend", '<th id="nic-timing-head">Timing readiness</th>');
    }
  }

  function decorateNicRows(nics) {
    ensureTimingColumn();
    const rows = qa("#nics-table tbody tr");
    rows.forEach((tr, i) => {
      const n = nics[i];
      if (!n) return;
      const p = timingProfile(n);
      const td = document.createElement("td");
      td.className = "timing-table-cell";
      td.innerHTML = `<span class="timing-mini ${p.level}" title="${p.detail}">${p.badge}</span>`;
      tr.appendChild(td);
      if (p.level === "bad") tr.classList.add("timing-row-limited");
    });
  }

  function renderTimingCard() {
    ensureTimingCard();
    const n = selectedNic();
    const p = timingProfile(n);
    const ready = q("#timing-readiness");
    if (!ready) return;
    ready.textContent = p.badge;
    ready.className = `timing-readiness ${p.level}`;
    q("#timing-host").textContent = platformLabel();
    q("#timing-iface").textContent = n ? `${n.name}${n.driver ? ` · ${n.driver}` : ""}` : "—";
    q("#timing-path").textContent = p.path;
    q("#timing-link").textContent = n ? `${n.operstate || "unknown"}${n.speed && n.speed !== "unknown" ? ` · ${n.speed} Mb/s` : ""}` : "—";
    q("#timing-message").innerHTML = `<strong>${p.title}</strong><span>${p.detail}</span>`;
    renderTopTimingBadge(n, p);
    updateConfigTimingHint();
  }

  function renderTopTimingBadge(n, p) {
    const right = q(".topbar-right");
    if (!right) return;
    let el = q("#st-timing");
    if (!el) {
      el = document.createElement("span");
      el.id = "st-timing";
      right.insertBefore(el, q("#st-capture"));
    }
    el.textContent = n ? p.badge : "NO NIC";
    el.title = n ? `${n.name}: ${p.detail}` : p.detail;
    el.className = `pill timing-top ${p.level}`;
  }

  function ensureConfigTimingHint() {
    if (q("#cfg-timing-hint")) return;
    const alert = q("#cfg-alert");
    if (!alert) return;
    alert.insertAdjacentHTML("beforebegin", '<div class="timing-config-hint" id="cfg-timing-hint" hidden></div>');
  }

  function updateConfigTimingHint() {
    ensureConfigTimingHint();
    const hint = q("#cfg-timing-hint");
    const mode = q("#cfg-mode");
    if (!hint || !mode) return;
    const platform = S.bootstrap && S.bootstrap.platform;
    const realOption = mode.querySelector('option[value="real"]');
    if (realOption) {
      realOption.disabled = platform !== "linux";
      realOption.title = platform === "linux" ? "" : "真实 linuxptp 引擎仅在 Linux 可用";
    }
    if (platform !== "linux" && mode.value === "real") mode.value = "sim";

    if (mode.value !== "real") {
      hint.hidden = true;
      return;
    }
    const n = currentNics.find((x) => x.name === q("#cfg-iface").value);
    const p = timingProfile(n);
    hint.hidden = false;
    hint.className = `timing-config-hint ${p.level}`;
    hint.innerHTML = `<strong>${p.badge}</strong> ${p.detail}`;
  }

  function ensureOverviewStats() {
    if (q("#ov-window-stats")) return;
    const firstCard = q("#page-overview .grid-2 .card");
    if (!firstCard) return;
    firstCard.insertAdjacentHTML("beforeend", `
      <div class="metric-strip" id="ov-window-stats">
        <div><span>RMS · 64 samples</span><strong id="ov-rms">—</strong></div>
        <div><span>Mean</span><strong id="ov-mean">—</strong></div>
        <div><span>Peak-to-peak</span><strong id="ov-pp">—</strong></div>
        <div><span>Max |offset|</span><strong id="ov-maxabs">—</strong></div>
      </div>`);
    const table = q("#page-overview .grid-2 .card:nth-child(2) .kv-table");
    if (table && !q("#ov-timing-path")) {
      table.insertAdjacentHTML("beforeend", '<tr><td>Timing path</td><td class="mono" id="ov-timing-path">—</td></tr>');
    }
  }

  function mean(values) {
    return values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0;
  }

  function renderOverviewStats() {
    ensureOverviewStats();
    if (!S.chart) return;
    S.chart.setThreshold(S.thresholdNs || 100000, true);
    const points = S.chart.data("offset").slice(-64);
    const values = points.map((p) => Number(p[1])).filter(Number.isFinite);
    const n = selectedNic();
    const p = timingProfile(n);
    const path = q("#ov-timing-path");
    if (path) path.textContent = p.path;
    if (!values.length) {
      for (const id of ["#ov-rms", "#ov-mean", "#ov-pp", "#ov-maxabs"]) if (q(id)) q(id).textContent = "—";
      return;
    }
    const avg = mean(values);
    const rms = Math.sqrt(mean(values.map((v) => v * v)));
    const min = Math.min(...values);
    const max = Math.max(...values);
    const maxAbs = Math.max(...values.map(Math.abs));
    q("#ov-rms").textContent = fmtNs(rms, false);
    q("#ov-mean").textContent = fmtNs(avg);
    q("#ov-pp").textContent = fmtNs(max - min, false);
    q("#ov-maxabs").textContent = fmtNs(maxAbs, false);
    q("#ov-rms").classList.toggle("metric-alarm", rms > (S.thresholdNs || 100000));
    q("#ov-maxabs").classList.toggle("metric-alarm", maxAbs > (S.thresholdNs || 100000));
  }

  function ensurePacketTools() {
    if (q("#pk-filter-tools")) return;
    const summary = q("#pk-summary");
    if (!summary) return;
    summary.insertAdjacentHTML("beforebegin", `
      <div class="packet-tools" id="pk-filter-tools">
        <select id="pk-type-filter" title="按 gPTP 报文类型过滤">
          <option value="">全部类型</option>
          <option value="Sync">Sync</option>
          <option value="Follow_Up">Follow_Up</option>
          <option value="Announce">Announce</option>
          <option value="PDelay_Req">PDelay_Req</option>
          <option value="PDelay_Resp">PDelay_Resp</option>
          <option value="PDelay_Resp_Follow_Up">PDelay_Resp_Follow_Up</option>
          <option value="Signalling">Signalling</option>
        </select>
        <input id="pk-filter-search" type="search" placeholder="Seq / sourcePort / MAC / domain…" spellcheck="false">
        <button class="btn btn-sm" id="pk-pause-view" title="只冻结表格视图；后台抓包继续">⏸ 冻结视图</button>
        <span class="packet-live-state" id="pk-live-state">LIVE</span>
      </div>`);
    q("#pk-type-filter").addEventListener("change", () => renderPacketList());
    q("#pk-filter-search").addEventListener("input", () => renderPacketList());
    q("#pk-pause-view").addEventListener("click", () => setPacketPaused(!S.packetViewPaused));
    q("#pk-clear").addEventListener("click", () => setPacketPaused(false), true);
  }

  function packetSearchText(f) {
    const h = f.ptp || {};
    const b = f.body || {};
    return [
      h.message_type_name, h.sequence_id, h.domain_number, h.source_port_identity,
      f.mac_src, f.mac_dst, f.iface, f.source,
      b.grandmaster_identity, b.requesting_port_identity,
    ].filter((v) => v !== null && v !== undefined).join(" ").toLowerCase();
  }

  function filteredPackets() {
    const type = q("#pk-type-filter") ? q("#pk-type-filter").value : "";
    const text = q("#pk-filter-search") ? q("#pk-filter-search").value.trim().toLowerCase() : "";
    return (S.packets || []).filter((f) => {
      if (type && (!f.is_ptp || !f.ptp || f.ptp.message_type_name !== type)) return false;
      if (text && !packetSearchText(f).includes(text)) return false;
      return true;
    });
  }

  function decoratePacketRow(tr, f) {
    if (!f || !f.is_ptp || !f.ptp) return;
    const configuredDomain = Number(q("#cfg-domain") && q("#cfg-domain").value);
    if (Number.isFinite(configuredDomain) && f.ptp.domain_number !== configuredDomain) {
      tr.classList.add("packet-attention");
      tr.title = `Domain ${f.ptp.domain_number} 与当前配置 Domain ${configuredDomain} 不同（可能是多 Domain 流量）`;
    }
    if (f.error) {
      tr.classList.add("packet-error");
      tr.title = f.error;
    }
  }

  function renderPacketSummary(visibleCount) {
    const summary = q("#pk-summary");
    if (!summary) return;
    const loaded = (S.packets || []).length;
    const state = S.packetViewPaused ? "FROZEN" : "LIVE";
    summary.textContent = `显示 ${visibleCount} / 已载入 ${loaded} / 总计 ${S.packetTotal || 0} · ${state}${S.captureSrc ? ` · ${S.captureSrc}` : ""}`;
    const live = q("#pk-live-state");
    if (live) {
      live.textContent = state;
      live.className = `packet-live-state ${S.packetViewPaused ? "frozen" : "live"}`;
    }
  }

  function setPacketPaused(paused) {
    S.packetViewPaused = !!paused;
    const btn = q("#pk-pause-view");
    if (btn) btn.textContent = S.packetViewPaused ? "▶ 恢复实时" : "⏸ 冻结视图";
    if (!S.packetViewPaused && pendingPacketSnapshot) {
      const snap = pendingPacketSnapshot;
      pendingPacketSnapshot = null;
      baseRenderPacketsListFromApi(snap.list, snap.total);
    } else if (!S.packetViewPaused) {
      refreshPackets();
    } else {
      renderPacketSummary(filteredPackets().length);
    }
  }

  function ensureShortcutHint() {
    if (q("#shortcut-hint")) return;
    const footer = q(".sidebar-footer");
    if (!footer) return;
    footer.insertAdjacentHTML("afterbegin", '<div id="shortcut-hint" class="shortcut-hint" title="⌘/Ctrl+1…6 切页 · / 搜报文 · Space 冻结报文 · Esc 关闭详情">⌨ 快捷键</div>');
  }

  function typingTarget(target) {
    return target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT" || target.isContentEditable);
  }

  function installShortcuts() {
    window.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && /^[1-6]$/.test(e.key)) {
        e.preventDefault();
        const pages = ["overview", "nics", "config", "source", "packets", "runtime"];
        location.hash = `#/${pages[Number(e.key) - 1]}`;
        return;
      }
      if (e.key === "Escape" && !q("#pk-detail").hidden) {
        q("#pk-detail").hidden = true;
        return;
      }
      if (typingTarget(e.target)) return;
      const packetsActive = q("#page-packets") && q("#page-packets").classList.contains("active");
      if (packetsActive && e.key === "/") {
        e.preventDefault();
        q("#pk-filter-search").focus();
        q("#pk-filter-search").select();
      } else if (packetsActive && e.code === "Space") {
        e.preventDefault();
        setPacketPaused(!S.packetViewPaused);
      }
    });
  }

  /* Wrap existing functions rather than rewriting the stable app core. */
  const baseRenderNics = renderNics;
  renderNics = function enhancedRenderNics(nics) {
    currentNics = Array.isArray(nics) ? nics : [];
    baseRenderNics(nics);
    decorateNicRows(currentNics);
    renderTimingCard();
  };

  const baseRenderPacketList = renderPacketList;
  renderPacketList = function enhancedRenderPacketList() {
    ensurePacketTools();
    const tb = q("#pk-tbody");
    if (!tb) return baseRenderPacketList();
    const visible = filteredPackets();
    tb.innerHTML = "";
    const frag = document.createDocumentFragment();
    for (const f of visible) {
      const tr = packetRow(f, f.index);
      decoratePacketRow(tr, f);
      frag.appendChild(tr);
    }
    tb.appendChild(frag);
    q("#pk-empty").style.display = visible.length ? "none" : "block";
    renderPacketSummary(visible.length);
  };

  const baseRenderPacketsListFromApi = renderPacketsListFromApi;
  renderPacketsListFromApi = function enhancedPacketsFromApi(list, total) {
    if (S.packetViewPaused) {
      pendingPacketSnapshot = { list, total };
      S.packetTotal = total;
      renderPacketSummary(filteredPackets().length);
      return;
    }
    pendingPacketSnapshot = null;
    baseRenderPacketsListFromApi(list, total);
  };

  const baseShowDetail = showDetail;
  showDetail = function enhancedShowDetail(f) {
    S.uxSelectedPacket = f && f.index;
    baseShowDetail(f);
    qa("#pk-tbody tr").forEach((tr) => tr.classList.toggle("packet-selected", Number(tr.dataset.index) === Number(S.uxSelectedPacket)));
  };

  function initUx() {
    if (uxReady) return;
    uxReady = true;
    S.packetViewPaused = false;
    ensureTimingCard();
    ensureOverviewStats();
    ensurePacketTools();
    ensureShortcutHint();
    installShortcuts();

    q("#cfg-iface").addEventListener("change", renderTimingCard);
    q("#pk-iface").addEventListener("change", renderTimingCard);
    q("#cfg-mode").addEventListener("change", updateConfigTimingHint);
    qa("#role-seg button").forEach((btn) => btn.addEventListener("click", updateConfigTimingHint));

    const waitForBoot = setInterval(() => {
      if (!S.bootstrap) return;
      clearInterval(waitForBoot);
      currentNics = S.bootstrap.nics || [];
      // Initial render may have happened before this enhancement script wrapped it.
      ensureTimingColumn();
      const rows = qa("#nics-table tbody tr");
      if (rows.length && rows[0].children.length < 8) decorateNicRows(currentNics);
      renderTimingCard();
      renderPacketList();
      renderOverviewStats();
    }, 50);

    setInterval(renderOverviewStats, 500);
  }

  initUx();
})();
