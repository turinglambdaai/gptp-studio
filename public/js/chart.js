/* Real-time canvas chart for offset / delay series. No dependencies. */
"use strict";

class LiveChart {
  constructor(canvas, opts) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.series = { offset: [], delay: [] };
    this.maxPoints = 600;
    this.thresholdNs = 100000;   // ±100 µs default
    this.showThreshold = false;
    this.hover = null;
    canvas.addEventListener("mousemove", (e) => {
      const r = canvas.getBoundingClientRect();
      this.hover = { x: e.clientX - r.left, y: e.clientY - r.top };
    });
    canvas.addEventListener("mouseleave", () => { this.hover = null; });
  }

  setThreshold(ns, show) { this.thresholdNs = ns; this.showThreshold = show; }

  push(name, t, v) {
    const s = this.series[name];
    s.push([t, v]);
    if (s.length > this.maxPoints * 2) s.splice(0, s.length - this.maxPoints * 2);
  }

  backfill(name, points) {
    this.series[name] = points.slice(-this.maxPoints * 2);
  }

  clear() { this.series = { offset: [], delay: [] }; this.draw(); }

  data(name) {
    const s = this.series[name];
    return s.length > this.maxPoints ? s.slice(-this.maxPoints) : s;
  }

  draw() {
    const c = this.canvas, ctx = this.ctx;
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth, h = c.clientHeight;
    if (c.width !== w * dpr || c.height !== h * dpr) {
      c.width = w * dpr; c.height = h * dpr;
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const padL = 74, padR = 14, padT = 12, padB = 26;
    const iw = w - padL - padR, ih = h - padT - padB;
    if (iw < 10 || ih < 10) return;

    const off = this.data("offset"), del = this.data("delay");
    if (off.length === 0 && del.length === 0) return;

    // y range over both series + threshold
    let lo = Infinity, hi = -Infinity;
    for (const [, v] of off) { if (v < lo) lo = v; if (v > hi) hi = v; }
    for (const [, v] of del) { if (v < lo) lo = v; if (v > hi) hi = v; }
    if (this.showThreshold) {
      lo = Math.min(lo, -this.thresholdNs); hi = Math.max(hi, this.thresholdNs);
    }
    if (lo === hi) { lo -= 1; hi += 1; }
    const pad = (hi - lo) * 0.1;
    lo -= pad; hi += pad;

    const x = (i, n) => padL + (n <= 1 ? iw / 2 : (i / (n - 1)) * iw);
    const y = (v) => padT + (1 - (v - lo) / (hi - lo)) * ih;

    // grid: horizontal lines with ns labels
    ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.fillStyle = "#64748b";
    ctx.strokeStyle = "#e8eef7";
    ctx.lineWidth = 1;
    const rows = 5;
    for (let r = 0; r <= rows; r++) {
      const v = lo + ((hi - lo) * r) / rows;
      const yy = y(v);
      ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(w - padR, yy); ctx.stroke();
      ctx.textAlign = "right";
      ctx.fillText(fmtNs(v), padL - 6, yy + 3);
    }

    // threshold lines
    if (this.showThreshold) {
      ctx.strokeStyle = "rgba(244,67,54,.5)";
      ctx.setLineDash([5, 4]);
      for (const tv of [this.thresholdNs, -this.thresholdNs]) {
        ctx.beginPath(); ctx.moveTo(padL, y(tv)); ctx.lineTo(w - padR, y(tv)); ctx.stroke();
      }
      ctx.setLineDash([]);
    }

    // series
    drawLine(ctx, off, x, y, "#2196F3", 1.6);
    drawLine(ctx, del, x, y, "#FF9800", 1.4);

    // hover crosshair
    if (this.hover && this.hover.x >= padL && this.hover.x <= w - padR) {
      const { off: ov, del: dv, t } = this.pickAt(this.hover.x);
      ctx.strokeStyle = "rgba(100,116,139,.4)";
      ctx.beginPath(); ctx.moveTo(this.hover.x, padT); ctx.lineTo(this.hover.x, h - padB); ctx.stroke();
      const lines = [];
      if (ov) lines.push(["offset", ov[1], "#2196F3"]);
      if (dv) lines.push(["delay", dv[1], "#FF9800"]);
      if (lines.length) {
        const bw = 150, bh = lines.length * 16 + 8;
        let bx = this.hover.x + 10; if (bx + bw > w) bx = this.hover.x - bw - 10;
        ctx.fillStyle = "rgba(255,255,255,.95)";
        ctx.strokeStyle = "#dce7f5";
        roundRect(ctx, bx, padT + 6, bw, bh, 6); ctx.fill(); ctx.stroke();
        ctx.textAlign = "left";
        let ly = padT + 20;
        for (const [name, v, color] of lines) {
          ctx.fillStyle = color;
          ctx.fillText(`${name} ${fmtNs(v)}`, bx + 8, ly); ly += 16;
        }
      }
    }

    // time axis: first/last timestamp in seconds
    ctx.fillStyle = "#64748b"; ctx.textAlign = "left";
    const all = off.length ? off : del;
    ctx.fillText(`t0 ${fmtSec(all[0][0])}`, padL, h - 8);
    ctx.textAlign = "right";
    const last = all[all.length - 1];
    ctx.fillText(`now ${fmtSec(last[0])}`, w - padR, h - 8);
  }

  pickAt(px) {
    const padL = 74, padR = 14;
    const pick = (s) => {
      if (!s.length) return null;
      const n = s.length;
      const i = Math.round(((px - padL) / (padR === 0 ? 1 : (this.canvas.clientWidth - padL - padR))) * (n - 1));
      return s[Math.max(0, Math.min(n - 1, i))];
    };
    return { off: pick(this.data("offset")), del: pick(this.data("delay")) };
  }
}

function drawLine(ctx, s, xf, yf, color, width) {
  if (s.length < 2) return;
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineJoin = "round";
  ctx.beginPath();
  ctx.moveTo(xf(0, s.length), yf(s[0][1]));
  for (let i = 1; i < s.length; i++) ctx.lineTo(xf(i, s.length), yf(s[i][1]));
  ctx.stroke();
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function fmtNs(v) {
  const a = Math.abs(v);
  if (a >= 1e6) return (v / 1e6).toFixed(2) + " ms";
  if (a >= 1e3) return (v / 1e3).toFixed(1) + " µs";
  return v.toFixed(0) + " ns";
}

function fmtSec(t) {
  const ms = Math.floor((t % 60) * 1000);
  return `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}.${String(ms % 1000).padStart(3, "0")}`;
}
