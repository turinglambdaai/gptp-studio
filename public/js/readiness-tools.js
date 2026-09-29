/* Complete the Linux timing-readiness picture with local tool availability.
   NIC quality and tool installation are separate concerns; this layer keeps
   them visible without blocking users who intentionally use custom privilege
   setups (setcap/polkit/etc.). */
"use strict";

(() => {
  const q = (sel) => document.querySelector(sel);
  const zhEn = (z, e) => (!S.lang || S.lang === "zh") ? z : e;
  let latestNics = [];

  function selectedNic() {
    const iface = q("#cfg-iface") && q("#cfg-iface").value;
    return latestNics.find((n) => n.name === iface) || latestNics[0] || null;
  }

  function ensureCells() {
    const grid = q("#timing-capability-card .timing-grid");
    if (!grid || q("#timing-tools")) return;
    grid.style.gridTemplateColumns = "repeat(3, minmax(0, 1fr))";
    grid.insertAdjacentHTML("beforeend", `
      <div class="timing-cell"><span>LinuxPTP tools</span><strong class="mono" id="timing-tools">—</strong></div>
      <div class="timing-cell"><span>Privilege path</span><strong class="mono" id="timing-privilege">—</strong></div>`);
  }

  function toolState(n) {
    if (!n || (S.bootstrap && S.bootstrap.platform) !== "linux") {
      return { missing: [], missingSupport: [], text: "n/a", privilege: "n/a" };
    }
    const core = [
      ["ptp4l", n.ptp4l_available],
      ["phc2sys", n.phc2sys_available],
      ["pmc", n.pmc_available],
    ];
    const support = [
      ["ethtool", n.ethtool_available],
      ["ip", n.ip_available],
    ];
    const missing = core.filter(([, ok]) => !ok).map(([name]) => name);
    const missingSupport = support.filter(([, ok]) => !ok).map(([name]) => name);
    const installed = core.filter(([, ok]) => ok).map(([name]) => name);
    return {
      missing,
      missingSupport,
      text: missing.length ? `missing: ${missing.join(", ")}` : installed.join(" · "),
      privilege: n.privilege_mode || "unknown",
    };
  }

  function renderReadiness() {
    ensureCells();
    const n = selectedNic();
    const tools = toolState(n);
    const toolsEl = q("#timing-tools");
    const privEl = q("#timing-privilege");
    if (!toolsEl || !privEl) return;

    toolsEl.textContent = tools.text;
    toolsEl.classList.toggle("metric-alarm", tools.missing.length > 0);
    toolsEl.title = tools.missingSupport.length
      ? zhEn(`辅助检测工具缺失: ${tools.missingSupport.join(", ")}；网卡能力检测可能不完整`,
          `Support tools missing: ${tools.missingSupport.join(", ")}; NIC capability detection may be incomplete`)
      : zhEn("真实引擎使用的 linuxptp 命令", "linuxptp commands used by the real engine");

    const privilegeText = tools.privilege === "root"
      ? "root"
      : tools.privilege === "sudo-noninteractive"
        ? "sudo -n ready"
        : tools.privilege === "n/a" ? "n/a" : "custom / verify on start";
    privEl.textContent = privilegeText;
    privEl.title = tools.privilege === "unknown"
      ? zhEn("没有检测到 root 或免交互 sudo；setcap / polkit 等自定义授权仍可能可用，实际以启动结果为准",
          "No root or passwordless sudo detected; custom authorization (setcap / polkit) may still work — the actual start result is authoritative")
      : zhEn("当前检测到的权限路径", "Currently detected privilege path");

    const platform = S.bootstrap && S.bootstrap.platform;
    if (platform !== "linux" || !n) return;

    const message = q("#timing-message");
    const configHint = q("#cfg-timing-hint");
    const readiness = q("#timing-readiness");
    const top = q("#st-timing");

    if (tools.missing.length) {
      const note = zhEn(`缺少 ${tools.missing.join(", ")}；安装 linuxptp 后才能完整运行真实 GM/Slave 工作流。`,
        `Missing ${tools.missing.join(", ")}; install linuxptp to run the full real GM/Slave workflow.`);
      if (message && !message.textContent.includes(note)) {
        const extra = document.createElement("span");
        extra.className = "tooling-warning";
        extra.textContent = note;
        message.appendChild(extra);
      }
      if (configHint && !configHint.hidden && !configHint.textContent.includes(note)) {
        configHint.appendChild(document.createTextNode(` ${note}`));
      }
      if (readiness && readiness.classList.contains("good")) {
        readiness.textContent = "TOOLS MISSING";
        readiness.className = "timing-readiness warn";
      }
      if (top && top.classList.contains("good")) {
        top.textContent = "TOOLS MISSING";
        top.className = "pill timing-top warn";
        top.title = note;
      }
    } else if (tools.missingSupport.length && message) {
      const note = zhEn(`辅助工具 ${tools.missingSupport.join(", ")} 缺失，硬件时间戳/接口信息检测可能不完整。`,
        `Support tools ${tools.missingSupport.join(", ")} missing; hardware timestamp / interface detection may be incomplete.`);
      if (!message.textContent.includes(note)) {
        const extra = document.createElement("span");
        extra.className = "tooling-warning";
        extra.textContent = note;
        message.appendChild(extra);
      }
    }
  }

  const baseRenderNics = renderNics;
  renderNics = function toolingAwareRenderNics(nics) {
    latestNics = Array.isArray(nics) ? nics : [];
    if (S.bootstrap) S.bootstrap.nics = latestNics;
    baseRenderNics(nics);
    renderReadiness();
  };

  const init = setInterval(() => {
    if (!S.bootstrap) return;
    clearInterval(init);
    latestNics = S.bootstrap.nics || [];
    renderReadiness();
    if (q("#cfg-iface")) q("#cfg-iface").addEventListener("change", () => setTimeout(renderReadiness, 0));
  }, 50);
})();
