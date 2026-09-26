/* Reference Platform view for daily Linux timing work.
   Shows the same redacted host/NIC identity facts used by Doctor, without
   turning hardware capability into a calibration or accuracy claim. */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  let nics = [];

  const text = (v, fallback = "—") => {
    if (v === null || v === undefined || v === "") return fallback;
    return String(v);
  };

  const nested = (obj, path, fallback = "—") => {
    let cur = obj;
    for (const key of path) {
      if (!cur || typeof cur !== "object" || !(key in cur)) return fallback;
      cur = cur[key];
    }
    return text(cur, fallback);
  };

  function host() {
    return (S.bootstrap && S.bootstrap.host) || {};
  }

  function selectedName() {
    const own = q("#reference-iface");
    if (own && own.value) return own.value;
    const cfg = q("#cfg-iface");
    return (cfg && cfg.value) || (nics[0] && nics[0].name) || "";
  }

  function selectedNic() {
    const name = selectedName();
    return nics.find((n) => n.name === name) || nics[0] || null;
  }

  function compactTool(value) {
    const v = text(value, "not detected");
    return v.length > 64 ? `${v.slice(0, 61)}…` : v;
  }

  function ensureCard() {
    if (q("#reference-platform-card")) return;
    const table = q("#nics-table");
    const tableCard = table && table.closest(".card");
    if (!tableCard) return;

    tableCard.insertAdjacentHTML("afterend", `
      <div class="card reference-platform-card" id="reference-platform-card">
        <div class="card-head">
          <div>
            <h2>Reference Platform</h2>
            <div class="muted">用于复现、售后和硬件资格记录；不代表已校准时间精度</div>
          </div>
          <div class="reference-platform-actions">
            <select id="reference-iface" title="选择要记录的网卡"></select>
            <button class="btn btn-sm" id="reference-copy" title="复制默认脱敏的平台快照">复制参考平台</button>
          </div>
        </div>
        <div class="reference-platform-grid">
          <div class="reference-section">
            <h3>Linux host</h3>
            <dl>
              <div><dt>Distribution</dt><dd id="ref-distro">—</dd></div>
              <div><dt>Kernel</dt><dd class="mono" id="ref-kernel">—</dd></div>
              <div><dt>System</dt><dd id="ref-system">—</dd></div>
              <div><dt>Clock / virt</dt><dd class="mono" id="ref-clock">—</dd></div>
              <div><dt>linuxptp</dt><dd class="mono" id="ref-linuxptp">—</dd></div>
            </dl>
          </div>
          <div class="reference-section">
            <h3>NIC / PHC</h3>
            <dl>
              <div><dt>Driver</dt><dd class="mono" id="ref-driver">—</dd></div>
              <div><dt>Firmware</dt><dd class="mono" id="ref-firmware">—</dd></div>
              <div><dt>PCI identity</dt><dd class="mono" id="ref-pci">—</dd></div>
              <div><dt>Bus / NUMA</dt><dd class="mono" id="ref-bus">—</dd></div>
              <div><dt>PHC</dt><dd class="mono" id="ref-phc">—</dd></div>
            </dl>
          </div>
        </div>
        <div class="reference-platform-foot">
          <span id="ref-capability">—</span>
          <span>Accuracy: <strong>not calibrated</strong></span>
          <span>Privacy: MAC/IP/hostname/machine-id/serials omitted from copied snapshot</span>
        </div>
      </div>`);

    q("#reference-iface").addEventListener("change", render);
    q("#reference-copy").addEventListener("click", copySnapshot);
  }

  function fillSelect() {
    const sel = q("#reference-iface");
    if (!sel) return;
    const before = sel.value || (q("#cfg-iface") && q("#cfg-iface").value) || "";
    sel.textContent = "";
    for (const nic of nics) {
      const option = document.createElement("option");
      option.value = nic.name;
      option.textContent = nic.hw_timestamping && nic.phc_device
        ? `${nic.name} · HW+PHC`
        : nic.hw_timestamping ? `${nic.name} · HW/no PHC` : `${nic.name} · SW`;
      sel.appendChild(option);
    }
    if (before && nics.some((n) => n.name === before)) sel.value = before;
  }

  function render() {
    ensureCard();
    if (!q("#reference-platform-card")) return;
    const h = host();
    const nic = selectedNic();

    q("#ref-distro").textContent = nested(h, ["distro", "pretty_name"]);
    q("#ref-kernel").textContent = `${nested(h, ["kernel", "release"])} · ${nested(h, ["kernel", "architecture"])}`;
    q("#ref-system").textContent = [
      nested(h, ["system", "vendor"]),
      nested(h, ["system", "product_name"]),
      nested(h, ["system", "board_name"]),
    ].filter((v) => v !== "—" && v !== "unknown").join(" · ") || "—";
    q("#ref-clock").textContent = `${nested(h, ["system", "clocksource"])} · virt=${nested(h, ["system", "virtualization"])}`;
    q("#ref-linuxptp").textContent = compactTool(nested(h, ["tools", "ptp4l"], "not detected"));

    if (!nic) {
      for (const id of ["#ref-driver", "#ref-firmware", "#ref-pci", "#ref-bus", "#ref-phc", "#ref-capability"]) q(id).textContent = "—";
      return;
    }

    q("#ref-driver").textContent = `${text(nic.driver)} ${text(nic.driver_version, "")}`.trim();
    q("#ref-firmware").textContent = text(nic.firmware_version);
    q("#ref-pci").textContent = `${text(nic.pci_vendor_id)}:${text(nic.pci_device_id)} · subsystem ${text(nic.subsystem_vendor_id)}:${text(nic.subsystem_device_id)}`;
    q("#ref-bus").textContent = `${text(nic.bus_info)} · NUMA ${text(nic.numa_node)}`;
    q("#ref-phc").textContent = `${text(nic.phc_device, "none")} · ${text(nic.phc_clock_name, "unknown")}`;
    q("#ref-capability").textContent = `${nic.name}: ${nic.hw_timestamping ? "HW timestamp" : "SW timestamp"} · link ${text(nic.operstate, "unknown")} · privilege ${text(nic.privilege_mode, "unknown")}`;
  }

  function enrichNicTable() {
    const rows = Array.from(document.querySelectorAll("#nics-table tbody tr"));
    rows.forEach((row, index) => {
      const nic = nics[index];
      if (!nic) return;
      const cells = row.children;
      const phc = cells[4];
      const driver = cells[5];
      if (phc && !phc.querySelector(".nic-meta")) {
        const meta = document.createElement("div");
        meta.className = "nic-meta mono";
        meta.textContent = text(nic.phc_clock_name, "clock unknown");
        phc.appendChild(meta);
      }
      if (driver && !driver.querySelector(".nic-meta")) {
        const version = document.createElement("div");
        version.className = "nic-meta mono";
        version.textContent = `v ${text(nic.driver_version, "?")} · fw ${text(nic.firmware_version, "?")}`;
        const pci = document.createElement("div");
        pci.className = "nic-meta mono";
        pci.textContent = `${text(nic.pci_vendor_id)}:${text(nic.pci_device_id)} · ${text(nic.bus_info)}`;
        driver.appendChild(version, pci);
        driver.appendChild(pci);
      }
    });
  }

  function snapshotText() {
    const h = host();
    const nic = selectedNic();
    const lines = [
      "gPTP Studio Reference Platform Snapshot",
      `App: ${text(S.bootstrap && S.bootstrap.version, "unknown")}`,
      `Distribution: ${nested(h, ["distro", "pretty_name"])}`,
      `Kernel: ${nested(h, ["kernel", "release"])} · ${nested(h, ["kernel", "architecture"])}`,
      `Kernel build: ${nested(h, ["kernel", "version"])}`,
      `System: ${nested(h, ["system", "vendor"])} · ${nested(h, ["system", "product_name"])} · ${nested(h, ["system", "board_name"])}`,
      `Virtualization: ${nested(h, ["system", "virtualization"])}`,
      `Clocksource: ${nested(h, ["system", "clocksource"])}`,
      `Racket: ${nested(h, ["runtime", "racket_version"])}`,
      `ptp4l: ${nested(h, ["tools", "ptp4l"], "not detected")}`,
      `phc2sys: ${nested(h, ["tools", "phc2sys"], "not detected")}`,
      `pmc: ${nested(h, ["tools", "pmc"], "not detected")}`,
    ];
    if (nic) {
      lines.push(
        "",
        `Interface: ${text(nic.name)}`,
        `Driver: ${text(nic.driver)} ${text(nic.driver_version, "")}`.trim(),
        `Firmware: ${text(nic.firmware_version)}`,
        `PCI: ${text(nic.pci_vendor_id)}:${text(nic.pci_device_id)} · subsystem ${text(nic.subsystem_vendor_id)}:${text(nic.subsystem_device_id)}`,
        `Bus / NUMA: ${text(nic.bus_info)} / ${text(nic.numa_node)}`,
        `Link: ${text(nic.operstate)} · ${text(nic.speed)} Mb/s`,
        `HW timestamp: ${nic.hw_timestamping ? "yes" : "no"}`,
        `PHC: ${text(nic.phc_device, "none")} · ${text(nic.phc_clock_name, "unknown")}`,
        `Privilege: ${text(nic.privilege_mode, "unknown")}`,
      );
    }
    lines.push(
      "",
      "Accuracy: not calibrated",
      "Privacy: MAC/IP/hostname/machine-id/hardware serials omitted",
      "Validation: this snapshot is inventory evidence, not a Studio-validated or calibrated result",
    );
    return lines.join("\n");
  }

  async function writeClipboard(value) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = value;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      return ok;
    }
  }

  async function copySnapshot() {
    const ok = await writeClipboard(snapshotText());
    toast(ok ? "参考平台快照已复制（已脱敏）" : "复制失败", ok ? "info" : "error", 6000);
  }

  const baseRenderNics = renderNics;
  renderNics = function referenceAwareRenderNics(nextNics) {
    nics = Array.isArray(nextNics) ? nextNics : [];
    if (S.bootstrap) S.bootstrap.nics = nics;
    baseRenderNics(nextNics);
    ensureCard();
    fillSelect();
    enrichNicTable();
    render();
  };

  const init = setInterval(() => {
    if (!S.bootstrap) return;
    clearInterval(init);
    nics = S.bootstrap.nics || [];
    ensureCard();
    fillSelect();
    enrichNicTable();
    render();
    const cfg = q("#cfg-iface");
    if (cfg) cfg.addEventListener("change", () => {
      const sel = q("#reference-iface");
      if (sel && nics.some((n) => n.name === cfg.value)) sel.value = cfg.value;
      render();
    });
  }, 50);
})();
