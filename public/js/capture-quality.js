/* Distinguish NIC timing capability from the timestamp path actually delivered
   by libpcap. A HW-capable NIC is not evidence that a given capture handle is
   using adapter timestamps. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  let lastLiveQuality = null;

  function qualityFromPackets({ liveOnly = false } = {}) {
    const f = (S.packets || []).find((p) =>
      p && p.timestamp_source && (!liveOnly || p.source === "live"));
    if (!f) return null;
    return {
      source: f.timestamp_source || "unknown",
      precision: f.timestamp_precision || "unknown",
      sec: f.ts_sec,
      nsec: f.ts_nsec,
    };
  }

  function ensureCaptureCell() {
    const grid = q("#timing-capability-card .timing-grid");
    if (!grid || q("#timing-capture-path")) return;
    grid.insertAdjacentHTML("beforeend", `
      <div class="timing-cell">
        <span>Actual capture timestamp</span>
        <strong class="mono" id="timing-capture-path">—</strong>
      </div>`);
  }

  function renderCaptureQuality() {
    ensureCaptureCell();
    const el = q("#timing-capture-path");
    if (!el) return;

    const live = Boolean(S.capture && S.capture.running);
    if (!live) {
      lastLiveQuality = null;
      const offline = qualityFromPackets();
      if (offline && offline.source === "pcap-file") {
        el.textContent = `pcap-file / ${offline.precision}`;
        el.classList.remove("packet-health-good", "packet-health-attention");
        el.title = "离线文件的时间戳分辨率；这不是当前网卡的实时抓包时间戳路径。";
      } else {
        el.textContent = "idle";
        el.classList.remove("packet-health-good", "packet-health-attention");
        el.title = "NIC capability is shown separately; no live capture is active.";
      }
      return;
    }

    const fresh = qualityFromPackets({ liveOnly: true });
    if (fresh) lastLiveQuality = fresh;
    const quality = fresh || lastLiveQuality;
    if (!quality) {
      el.textContent = "waiting for live packet…";
      el.classList.remove("packet-health-good", "packet-health-attention");
      el.title = "The actual timestamp source is reported after libpcap delivers a live packet.";
      return;
    }

    const adapter = quality.source === "adapter";
    el.textContent = `${quality.source} / ${quality.precision}`;
    el.classList.toggle("packet-health-good", adapter);
    el.classList.toggle("packet-health-attention", !adapter);
    el.title = adapter
      ? "libpcap selected a device/adapter timestamp source. Resolution is not the same as calibrated accuracy."
      : "Capture timestamps are not currently identified as adapter/device timestamps. Use ptp4l/PHC metrics for synchronization accuracy judgments.";
  }

  function clarifyNicLabels() {
    const card = q("#timing-capability-card");
    if (!card) return;
    const subtitle = card.querySelector(".timing-subtitle");
    if (subtitle) subtitle.textContent = "NIC / PHC 能力与真实引擎前置条件；实际抓包时间戳路径单独显示";
    const th = q("#nic-timing-head");
    if (th) th.textContent = "NIC timing capability";

    const ready = q("#timing-readiness");
    if (ready && ready.textContent === "HW + PHC") {
      ready.textContent = "NIC HW + PHC";
      ready.title = "表示网卡/驱动能力，不代表当前 libpcap 已使用硬件时间戳";
    }
    const top = q("#st-timing");
    if (top && top.textContent === "HW + PHC") {
      top.textContent = "NIC HW+PHC";
      top.title = `${top.title || ""} · NIC capability only; capture source is verified separately.`;
    }
  }

  function enrichPacketDetail(f) {
    if (!f || !f.timestamp_source) return;
    const tree = q("#pk-tree");
    if (!tree) return;
    const section = document.createElement("div");
    section.className = "tree-section";
    section.textContent = "CAPTURE TIMESTAMP";
    const source = document.createElement("div");
    source.innerHTML = `<span class="tree-k">source</span>: <span class="tree-v">${f.timestamp_source}</span>`;
    const precision = document.createElement("div");
    precision.innerHTML = `<span class="tree-k">precision</span>: <span class="tree-v">${f.timestamp_precision || "—"}</span>`;
    const exact = document.createElement("div");
    exact.innerHTML = `<span class="tree-k">exact</span>: <span class="tree-v">${f.ts_sec ?? "—"}.${String(f.ts_nsec ?? 0).padStart(9, "0")}</span>`;
    tree.prepend(exact);
    tree.prepend(precision);
    tree.prepend(source);
    tree.prepend(section);
  }

  const baseRenderNics = renderNics;
  renderNics = function captureAwareRenderNics(nics) {
    baseRenderNics(nics);
    setTimeout(() => { clarifyNicLabels(); renderCaptureQuality(); }, 0);
  };

  const baseRenderStatus = renderStatus;
  renderStatus = function captureAwareRenderStatus(eng, cap) {
    baseRenderStatus(eng, cap);
    setTimeout(() => { clarifyNicLabels(); renderCaptureQuality(); }, 0);
  };

  const baseRenderPacketList = renderPacketList;
  renderPacketList = function captureAwareRenderPacketList() {
    baseRenderPacketList();
    renderCaptureQuality();
  };

  const baseShowDetail = showDetail;
  showDetail = function captureAwareShowDetail(f) {
    baseShowDetail(f);
    enrichPacketDetail(f);
  };

  const init = setInterval(() => {
    if (!S.bootstrap) return;
    clearInterval(init);
    clarifyNicLabels();
    renderCaptureQuality();
  }, 50);
})();
