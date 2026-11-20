// Rysuje zapisaną klatkę okna moda (ui_frame.json z mock_reaper.lua, RMP_RECORD=1) do PNG.
// Użycie: node tests/render_mod_ui.js ui_frame.json wynik.png
const fs = require("fs");
const { chromium } = require("playwright");
(async () => {
  const frame = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: frame.w, height: frame.h }, deviceScaleFactor: 2 });
  await p.setContent(`<canvas id=c width=${frame.w} height=${frame.h} style="display:block"></canvas>`);
  await p.evaluate((frame) => {
    const ctx = document.getElementById("c").getContext("2d");
    ctx.fillStyle = "rgb(14,20,36)";
    ctx.fillRect(0, 0, frame.w, frame.h);
    let color = "rgba(255,255,255,1)";
    for (const op of frame.ops) {
      const [k, ...a] = op;
      if (k === "set") { color = `rgba(${a[0] * 255},${a[1] * 255},${a[2] * 255},${a[3]})`; continue; }
      ctx.fillStyle = color; ctx.strokeStyle = color; ctx.lineWidth = 1;
      if (k === "rect") { a[4] ? ctx.fillRect(a[0], a[1], a[2], a[3]) : ctx.strokeRect(a[0] + 0.5, a[1] + 0.5, a[2], a[3]); }
      else if (k === "circle") { ctx.beginPath(); ctx.arc(a[0], a[1], a[2], 0, Math.PI * 2); a[3] ? ctx.fill() : ctx.stroke(); }
      else if (k === "roundrect") { ctx.beginPath(); ctx.roundRect(a[0] + 0.5, a[1] + 0.5, a[2], a[3], a[4]); ctx.stroke(); }
      else if (k === "line") { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(a[2], a[3]); ctx.stroke(); }
      else if (k === "triangle") { ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(a[2], a[3]); ctx.lineTo(a[4], a[5]); ctx.fill(); }
      else if (k === "text") { ctx.font = `${a[4] ? "bold " : ""}${a[3]}px "Segoe UI", Arial, sans-serif`; ctx.textBaseline = "top"; ctx.fillText(a[2], a[0], a[1]); }
    }
  }, frame);
  await p.screenshot({ path: process.argv[3] });
  await b.close();
})();
