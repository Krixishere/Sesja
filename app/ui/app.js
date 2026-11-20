/* Sesja – interfejs aplikacji. Czysty JS, bez frameworka i bez kroku budowania.
   Wszystkie napisy pochodzą z i18n.js (funkcja t). */
"use strict";

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args);
const listen = (ev, cb) => T.event.listen(ev, (e) => cb(e.payload));
const fileSrc = (p) => T.core.convertFileSrc(p);

/* Linki wsparcia – podmień na własne konta przed wydaniem. */
const LINKS = {
  repo: "https://github.com/Krixishere/Sesja",
  issues: "https://github.com/Krixishere/Sesja/issues",
  reaperDownload: "https://www.reaper.fm/download.php",
  donate: [
    { name: "Buy Me a Coffee", note: "donate_bmc", url: "https://buymeacoffee.com/krixishere" },
    { name: "Ko-fi", note: "donate_kofi", url: "https://ko-fi.com/krixishere" },
    { name: "GitHub Sponsors", note: "donate_gh", url: "https://github.com/sponsors/krixishere" },
  ],
};

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const S = {
  cfg: null,
  info: null,
  reaper: null,
  session: null,
  host: { running: false },
  view: "studio",
  unread: 0,
  seenKeys: new Set(),
  firstSync: false,
  audio: { el: new Audio(), id: null, raf: 0 },
  peaks: new Map(),
  musicFilter: null,
  releases: null,
  changelog: "",
};

/* ------------------------------------------------------------------ narzędzia */
const $ = (sel, root = document) => root.querySelector(sel);
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const icon = (name, style) => `<svg aria-hidden="true"${style ? ` style="${style}"` : ""}><use href="#i-${name}"/></svg>`;
/* tłumaczenie z bezpiecznie wstawionymi parametrami (do HTML) */
const th = (key, params = {}) => t(key, Object.fromEntries(Object.entries(params).map(([k, v]) => [k, esc(v)])));

function fmtPos(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}
function parsePos(str) {
  const parts = String(str || "").trim().split(":").map(Number);
  if (parts.some(isNaN) || !parts.length) return 0;
  return parts.reduce((acc, v) => acc * 60 + v, 0);
}
function fmtClock(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  const hm = d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
  const today = new Date().toDateString() === d.toDateString();
  return today ? hm : `${d.toLocaleDateString(locale(), { day: "numeric", month: "numeric" })} ${hm}`;
}
function colorOf(user) {
  const s = S.session;
  return (s && s.colors && s.colors[user]) || "#8e95ab";
}
function initial(name) {
  return esc((name || "?").trim().charAt(0).toUpperCase());
}
function debounce(fn, ms) {
  let tm;
  return (...a) => { clearTimeout(tm); tm = setTimeout(() => fn(...a), ms); };
}
function statusLabel(st) {
  return t({ on: "st_on", connecting: "st_connecting", error: "st_error" }[st] || "st_off");
}

/* ------------------------------------------------------------------ powiadomienia */
function toast({ title, text = "", actions = [], progress = false, timeout = 5000 }) {
  const el = document.createElement("div");
  el.className = "toast";
  el.innerHTML = `<b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ""}${
    progress ? `<div class="progress"><i></i></div>` : ""
  }${actions.length ? `<div class="row">${actions.map((a, i) => `<button class="btn ${a.primary ? "primary" : "ghost"}" data-i="${i}">${esc(a.label)}</button>`).join("")}</div>` : ""}`;
  $("#toasts").appendChild(el);
  const close = () => {
    el.classList.add("out");
    setTimeout(() => el.remove(), 200);
  };
  el.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-i]");
    if (b) actions[+b.dataset.i].fn?.(close);
  });
  const auto = timeout && !actions.length && !progress;
  let timer = auto ? setTimeout(close, timeout) : null;
  el.addEventListener("mouseenter", () => timer && clearTimeout(timer));
  el.addEventListener("mouseleave", () => { if (auto) timer = setTimeout(close, 2500); });
  return { close };
}
const fail = (e) => toast({ title: t("err_title"), text: String(e), timeout: 7000 });

/* ------------------------------------------------------------------ animacja sygnału */
class SignalAnim {
  constructor(canvas) {
    this.c = canvas;
    this.ctx = canvas.getContext("2d");
    this.t0 = performance.now();
    this.mode = "welcome";
    this.angle = -1.1;
    this.vel = 0;
    this.kickUntil = 0;
    this.running = false;
    this.resize = this.resize.bind(this);
    window.addEventListener("resize", this.resize);
    this.resize();
  }
  resize() {
    const r = this.c.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this.w = r.width; this.h = r.height;
    this.c.width = Math.max(1, r.width * dpr); this.c.height = Math.max(1, r.height * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!this.running) this.frame(performance.now());
  }
  start() {
    if (this.running) return;
    this.running = true;
    const loop = (now) => {
      if (!this.running) return;
      this.frame(now);
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  }
  stop() { this.running = false; }
  kick() { this.kickUntil = performance.now() + 900; }

  /* poziom „muzyki” – suma kilku sinusów, żeby wskazówka żyła, ale nie szalała */
  level(tt) {
    if (reduceMotion) return 0.62;
    const base = this.mode === "scan" ? 0.5 : this.mode === "calm" ? 0.42 : 0.56;
    let v = base + 0.16 * Math.sin(tt * 1.7) + 0.09 * Math.sin(tt * 4.3 + 1.2) + 0.05 * Math.sin(tt * 9.1);
    if (this.mode === "scan") v += 0.12 * Math.sin(tt * 6.0);
    if (performance.now() < this.kickUntil) v = 0.97;
    return Math.min(1, Math.max(0, v));
  }

  frame(now) {
    const { ctx, w, h } = this;
    if (!w || !h) return;
    const tt = (now - this.t0) / 1000;
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2, cy = h * 0.66;
    const R = Math.min(w * 0.36, h * 0.46);
    const reveal = reduceMotion ? 1 : Math.min(1, tt / 1.6);
    const ease = 1 - Math.pow(1 - reveal, 3);

    const a0 = Math.PI * 1.12, a1 = Math.PI * 1.88;
    ctx.lineCap = "round";
    ctx.lineWidth = Math.max(6, R * 0.035);
    ctx.strokeStyle = "rgba(234,227,210,0.10)";
    ctx.beginPath(); ctx.arc(cx, cy, R, a0, a1); ctx.stroke();
    ctx.strokeStyle = "rgba(240,82,79,0.85)";
    ctx.beginPath(); ctx.arc(cx, cy, R, a0 + (a1 - a0) * 0.8, a1); ctx.stroke();
    ctx.lineWidth = 2;
    for (let i = 0; i <= 10; i++) {
      const a = a0 + ((a1 - a0) * i) / 10;
      const r1 = R + R * 0.07, r2 = R + R * (i % 5 === 0 ? 0.15 : 0.11);
      ctx.strokeStyle = i >= 8 ? "rgba(240,82,79,0.6)" : "rgba(234,227,210,0.28)";
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1);
      ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2);
      ctx.stroke();
    }

    const amp = Math.min(h * 0.07, 46);
    const drawWave = (fromLeft, color) => {
      ctx.strokeStyle = color;
      ctx.lineWidth = Math.max(3, R * 0.022);
      ctx.beginPath();
      const steps = 160;
      const span = cx * ease;
      for (let i = 0; i <= steps; i++) {
        const f = i / steps;
        const x = fromLeft ? f * span : w - f * span;
        const d = Math.abs(x - cx) / cx;
        const env = Math.min(1, d * 3) * (0.55 + 0.45 * d);
        const phase = (fromLeft ? 1 : -1) * x * 0.022 - tt * 3.2 + (fromLeft ? 0 : 1.7);
        const y = cy + Math.sin(phase) * amp * env * (0.7 + 0.3 * Math.sin(tt * 0.9 + f * 3));
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
    };
    drawWave(true, "#5fc9b5");
    drawWave(false, "#eae3d2");

    // wskazówka na sprężynie (tłumienie ~0.8)
    const lvl = reveal < 1 ? 0 : this.level(tt);
    const target = a0 + (a1 - a0) * lvl - Math.PI * 1.5;
    if (reduceMotion) {
      this.angle = target;
    } else {
      const k = 120, c = 2 * 0.8 * Math.sqrt(k), dt = 1 / 60;
      const acc = -k * (this.angle - target) - c * this.vel;
      this.vel += acc * dt;
      this.angle += this.vel * dt;
    }
    const needleA = this.angle + Math.PI * 1.5;
    const lit = Math.max(a0, Math.min(a1, needleA));
    const glow = ctx.createLinearGradient(cx - R, 0, cx + R, 0);
    glow.addColorStop(0, "rgba(243,167,59,0.25)");
    glow.addColorStop(1, "rgba(243,167,59,0.95)");
    ctx.strokeStyle = glow;
    ctx.lineWidth = Math.max(6, R * 0.035);
    ctx.globalAlpha = ease;
    ctx.beginPath(); ctx.arc(cx, cy, R, a0, lit); ctx.stroke();
    ctx.strokeStyle = "#f3a73b";
    ctx.lineWidth = Math.max(4, R * 0.03);
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(needleA) * R * 0.96, cy + Math.sin(needleA) * R * 0.96);
    ctx.stroke();
    ctx.globalAlpha = 1;

    const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, R * 0.5);
    g.addColorStop(0, `rgba(243,167,59,${0.22 * ease})`);
    g.addColorStop(1, "rgba(243,167,59,0)");
    ctx.fillStyle = g;
    ctx.beginPath(); ctx.arc(cx, cy, R * 0.5, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#f3a73b";
    ctx.beginPath(); ctx.arc(cx, cy, Math.max(10, R * 0.06), 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#0b1020";
    ctx.beginPath(); ctx.arc(cx, cy, Math.max(4, R * 0.024), 0, Math.PI * 2); ctx.fill();
  }
}

/* ------------------------------------------------------------------ język */
function langSelect(id) {
  return `<select class="input lang-select" id="${id}" aria-label="${esc(t("language"))}">${LANGS.map(
    (l) => `<option value="${l.code}" ${l.code === lang() ? "selected" : ""}>${esc(l.name)}</option>`
  ).join("")}</select>`;
}
async function changeLang(code) {
  setLang(code);
  S.cfg = await invoke("save_config", { cfg: { ...S.cfg, lang: code } });
  applyStaticTexts();
  // mod w REAPERze też dostanie nowy język przy następnym zapisie ustawień
  if (S.reaper?.script_installed && S.cfg.nick) invoke("install_mod", { resource: S.reaper.resource, autostart: S.reaper.autostart }).catch(() => {});
  if (!$("#onboard").hidden) obRender();
  if (!$("#shell").hidden) { renderNav(); renderConn(); renderView(false); }
}
function applyStaticTexts() {
  document.documentElement.lang = lang();
  $("#city-a").textContent = t("city_a");
  $("#city-b").textContent = t("city_b");
}
document.addEventListener("change", (e) => {
  if (e.target.matches(".lang-select")) changeLang(e.target.value).catch(fail);
});

/* ------------------------------------------------------------------ instalator powitalny */
const OB = { step: 0, anim: null, detect: null, mode: "join", report: null, draft: {} };
const OB_STEPS = ["welcome", "search", "profile", "install", "done"];

function obShow() {
  $("#onboard").hidden = false;
  $("#shell").hidden = true;
  if (!OB.anim) OB.anim = new SignalAnim($("#signal"));
  OB.anim.start();
  obRender();
}

function obRender() {
  const name = OB_STEPS[OB.step];
  $("#ob-steps").innerHTML = OB_STEPS.map((_, i) => `<i class="${i <= OB.step ? "done" : ""}"></i>`).join("");
  OB.anim.mode = name === "search" ? "scan" : name === "welcome" ? "welcome" : "calm";
  const body = $("#ob-body"), foot = $("#ob-foot");
  const steps = {
    welcome: () => {
      body.innerHTML = `
        <h1>${t("ob_title")}</h1>
        <p>${t("ob_lead")}</p>
        <p class="muted">${t("ob_lead2")}</p>`;
      foot.innerHTML = `${langSelect("ob-lang")}
        <button class="btn primary big" data-ob="next">${t("ob_start")}</button>`;
    },
    search: () => obSearch(body, foot),
    profile: () => obProfile(body, foot),
    install: () => obInstall(body, foot),
    done: () => {
      OB.anim.kick();
      body.innerHTML = `
        <svg class="tick" viewBox="0 0 72 72" fill="none" stroke="#5fc9b5" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><circle cx="36" cy="36" r="33"/><path d="M23 37l9 9 18-19"/></svg>
        <h2>${t("ob_done_title")}</h2>
        <p>${OB.report ? th("ob_done_text", { room: S.cfg.room }) : t("ob_done_later")}</p>
        ${OB.report?.warning ? `<div class="notice">${icon("alert")}<span>${esc(OB.report.warning)}</span></div>` : ""}`;
      foot.innerHTML = `${OB.report && S.reaper?.exe ? `<button class="btn ghost" data-ob="launch">${t("open_reaper")}</button>` : "<span></span>"}
        <button class="btn primary big" data-ob="finish">${t("ob_to_studio")}</button>`;
    },
  };
  steps[name]();
}

async function obSearch(body, foot) {
  body.innerHTML = `<h2>${t("ob_search_title")}</h2>
    <p>${t("ob_search_text")}</p>
    <div class="scan" id="scan"></div>`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button><div class="spinner"></div>`;
  const started = performance.now();
  let info;
  try { info = await invoke("detect_reaper"); } catch (e) { info = { found: false, checked: [], error: String(e) }; }
  const scan = $("#scan");
  (info.checked || []).slice(0, 7).forEach((p, i) => {
    const d = document.createElement("div");
    d.innerHTML = `${icon("search")}<span>${esc(p)}</span>`;
    d.style.animationDelay = `${i * 70}ms`;
    scan?.appendChild(d);
  });
  // krótka pauza, żeby wynik nie „mignął” – wyszukiwanie zwykle trwa milisekundy
  await new Promise((r) => setTimeout(r, Math.max(0, 900 - (performance.now() - started))));
  OB.detect = info;
  S.reaper = info;
  if (OB_STEPS[OB.step] === "search") obSearchResult(body, foot, info);
}

let firstRunTimer = 0;
function obSearchResult(body, foot, info) {
  clearInterval(firstRunTimer);
  if (info.found && !info.resource) {
    // program jest, ale REAPER nie był jeszcze uruchomiony – nie ma folderu ustawień
    body.innerHTML = `<h2>${t("ob_firstrun_title")}</h2>
      <div class="found"><div class="ic">${icon("alert")}</div><div>
        <b>${t("ob_firstrun_head")}</b>
        <small>${esc(info.exe || "")}</small>
      </div></div>
      <p>${t("ob_firstrun_text")}</p>
      <div class="row">
        ${info.exe ? `<button class="btn primary" data-ob="launch-wait">${icon("reaper")}${t("open_reaper")}</button>` : ""}
        <button class="btn ghost" data-ob="pick">${icon("folder")}${t("pick_reaper")}</button>
      </div>`;
    foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button>
      <div class="row"><button class="btn ghost" data-ob="retry">${icon("refresh")}${t("search_again")}</button>
      <button class="btn ghost" data-ob="skip">${t("skip_for_now")}</button></div>`;
    return;
  }
  if (info.found) {
    OB.anim.kick();
    body.innerHTML = `<h2>${t("ob_found_title")}</h2>
      <div class="found"><div class="ic">${icon("check")}</div><div>
        <b>${t(info.portable ? "ob_found_portable" : "ob_found")}</b>
        <small>${esc(info.exe || t("settings_folder") + ": " + info.resource)}</small>
      </div></div>
      ${info.script_installed ? `<p class="muted">${th("ob_mod_present", { v: info.script_version || "?", nv: info.bundled_version })}</p>` : ""}
      <button class="btn ghost" data-ob="pick">${icon("folder")}${t("ob_not_this")}</button>`;
    foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button><button class="btn primary big" data-ob="next">${t("next")}</button>`;
  } else {
    body.innerHTML = `<h2>${t("ob_missing_title")}</h2>
      <div class="found miss"><div class="ic">${icon("x")}</div><div>
        <b>${t("ob_missing_head")}</b>
        <small>${t("ob_missing_text")}</small>
      </div></div>
      <div class="row">
        <button class="btn primary" data-ob="pick">${icon("folder")}${t("pick_reaper")}</button>
        <button class="btn ghost" data-url="${LINKS.reaperDownload}">${icon("download")}${t("download_reaper")}</button>
      </div>`;
    foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button>
      <div class="row"><button class="btn ghost" data-ob="retry">${icon("refresh")}${t("search_again")}</button>
      <button class="btn ghost" data-ob="skip">${t("skip_for_now")}</button></div>`;
  }
}

function obProfile(body, foot) {
  // zachowaj to, co użytkownik już wpisał, przy przełączaniu trybu
  const keep = (id, key) => { const el = document.getElementById(id); if (el) OB.draft[key] = el.value; };
  keep("ob-nick", "nick"); keep("ob-room", "room"); keep("ob-server", "server"); keep("ob-pass", "pass");
  const c = { ...S.cfg };
  for (const k of ["nick", "room", "server"]) if (OB.draft[k] !== undefined) c[k] = OB.draft[k];
  const pass = OB.draft.pass !== undefined ? OB.draft.pass : OB.mode === "host" ? c.host_password : c.password;
  body.innerHTML = `<h2>${t("ob_profile_title")}</h2>
    <label class="field"><span>${t("nick")}</span><input class="input" id="ob-nick" maxlength="40" placeholder="${esc(t("nick_ph"))}" value="${esc(c.nick)}"></label>
    <div class="modes">
      <button class="mode ${OB.mode === "host" ? "on" : ""}" data-ob="mode-host"><b>${t("mode_host")}</b><small>${t("mode_host_text")}</small></button>
      <button class="mode ${OB.mode === "join" ? "on" : ""}" data-ob="mode-join"><b>${t("mode_join")}</b><small>${t("mode_join_text")}</small></button>
    </div>
    ${OB.mode === "join" ? `<label class="field"><span>${t("server_addr")}</span><input class="input" id="ob-server" placeholder="http://100.101.102.103:8765" value="${esc(c.server)}"><small>${t("server_addr_hint")}</small></label>` : ""}
    <div class="form-grid">
      <label class="field"><span>${t("room")}</span><input class="input" id="ob-room" placeholder="${esc(t("room_ph"))}" value="${esc(c.room)}"><small>${t("room_hint")}</small></label>
      <label class="field"><span>${t("password_opt")}</span><input class="input" id="ob-pass" type="password" value="${esc(pass)}"></label>
    </div>`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button><button class="btn primary big" data-ob="profile-save">${t("next")}</button>`;
  setTimeout(() => $("#ob-nick")?.focus(), 50);
}

async function obProfileSave() {
  const nick = $("#ob-nick").value.trim();
  const room = $("#ob-room").value.trim();
  const pass = $("#ob-pass").value.trim();
  if (!nick) return toast({ title: t("need_nick"), text: t("need_nick_text") });
  if (!room) return toast({ title: t("need_room"), text: t("need_room_text") });
  const cfg = { ...S.cfg, nick, room };
  if (OB.mode === "host") {
    cfg.host_password = pass;
    cfg.password = pass;
    cfg.server = `http://127.0.0.1:${cfg.host_port || 8765}`;
    cfg.host_on_start = true;
  } else {
    const server = $("#ob-server").value.trim();
    if (!server) return toast({ title: t("need_server"), text: t("server_addr_hint") });
    cfg.server = server;
    cfg.password = pass;
  }
  try {
    S.cfg = await invoke("save_config", { cfg });
    if (OB.mode === "host") S.host = await invoke("host_start", { port: S.cfg.host_port || 8765, password: S.cfg.host_password });
  } catch (e) { return fail(e); }
  OB.step = OB.detect?.found && OB.detect?.resource ? 3 : 4;
  obRender();
}

function obInstall(body, foot) {
  const info = OB.detect;
  body.innerHTML = `<h2>${t("ob_install_title")}</h2>
    <p>${t("ob_install_text")}</p>
    <div class="checklist" id="ob-check">
      <div>${icon("check")}<span>${th("ob_inst_script", { v: info.bundled_version })}</span></div>
      <div>${icon("check")}<span>${t("ob_inst_action")}</span></div>
      <div>${icon("check")}<span>${t("ob_inst_settings")}</span></div>
    </div>
    <label class="switch"><input type="checkbox" id="ob-auto" ${S.cfg.autostart_script ? "checked" : ""}><i></i><span>${t("autostart")}</span></label>
`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">${t("back")}</button><button class="btn primary big" data-ob="install" id="ob-install">${t("install")}</button>`;
  watchReaperClosed();
}

/* REAPER zapisuje swoje ustawienia przy zamykaniu – instalacja przy otwartym REAPERze
   zostałaby nadpisana. Przycisk czeka, aż REAPER zostanie zamknięty. */
let reaperWatch = 0;
async function watchReaperClosed() {
  clearInterval(reaperWatch);
  const update = async () => {
    const btn = $("#ob-install");
    if (!btn || OB_STEPS[OB.step] !== "install") return clearInterval(reaperWatch);
    if (btn.dataset.busy) return;
    const running = await invoke("reaper_running").catch(() => false);
    const notice = $("#ob-running");
    if (running) {
      btn.disabled = true;
      btn.textContent = t("close_reaper_first");
      if (!notice) $("#ob-check").insertAdjacentHTML("afterend", `<div class="notice" id="ob-running">${icon("alert")}<span>${t("ob_close_reaper")}</span></div>`);
    } else {
      btn.disabled = false;
      btn.textContent = t("install");
      notice?.remove();
    }
  };
  await update();
  reaperWatch = setInterval(update, 2000);
}

async function obDoInstall(btn) {
  clearInterval(reaperWatch);
  btn.dataset.busy = "1";
  btn.disabled = true;
  btn.innerHTML = `<div class="spinner"></div>${t("installing")}`;
  try {
    const rep = await invoke("install_mod", { resource: OB.detect.resource, autostart: $("#ob-auto").checked });
    OB.report = rep;
    S.reaper = rep.info;
    const rows = [...document.querySelectorAll("#ob-check div")];
    for (const row of rows) {
      await new Promise((r) => setTimeout(r, 160));
      row.classList.add("done");
    }
    await new Promise((r) => setTimeout(r, 350));
    OB.step = 4;
    obRender();
  } catch (e) {
    btn.disabled = false;
    delete btn.dataset.busy;
    btn.textContent = t("try_again");
    fail(e);
  }
}

async function obAction(act, el) {
  switch (act) {
    case "next": OB.step = Math.min(OB.step + 1, OB_STEPS.length - 1); return obRender();
    case "back": clearInterval(firstRunTimer); OB.step = Math.max(OB.step - 1, 0); return obRender();
    case "retry": OB.step = 1; return obRender();
    case "skip": OB.detect = { found: false }; OB.step = 2; return obRender();
    case "pick": {
      try {
        const info = await invoke("pick_reaper_folder");
        if (!info) return;
        OB.detect = info;
        S.reaper = info;
        obSearchResult($("#ob-body"), $("#ob-foot"), info);
      } catch (e) { fail(e); }
      return;
    }
    case "mode-host": OB.mode = "host"; return obProfile($("#ob-body"), $("#ob-foot"));
    case "mode-join": OB.mode = "join"; return obProfile($("#ob-body"), $("#ob-foot"));
    case "profile-save": return obProfileSave();
    case "install": return obDoInstall(el);
    case "launch": invoke("launch_reaper").catch(fail); return;
    case "launch-wait": {
      // otwórz REAPERa i czekaj, aż utworzy folder ustawień – wtedy przejdź dalej sam
      try { await invoke("launch_reaper"); } catch (e) { return fail(e); }
      el.disabled = true;
      el.innerHTML = `<div class="spinner"></div>${t("waiting_for_reaper")}`;
      clearInterval(firstRunTimer);
      firstRunTimer = setInterval(async () => {
        if (OB_STEPS[OB.step] !== "search") return clearInterval(firstRunTimer);
        const info = await invoke("detect_reaper").catch(() => null);
        if (info?.resource) {
          clearInterval(firstRunTimer);
          OB.detect = info;
          S.reaper = info;
          obSearchResult($("#ob-body"), $("#ob-foot"), info);
        }
      }, 3000);
      return;
    }
    case "finish": {
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, onboarded: true } });
      OB.anim.stop();
      $("#onboard").hidden = true;
      startApp();
      if (S.cfg.nick && S.cfg.server && S.cfg.room) connect().then(() => renderView(false)).catch(() => {});
      return;
    }
  }
}

/* ------------------------------------------------------------------ nawigacja */
const VIEWS = [
  { id: "studio", label: "nav_studio", icon: "studio" },
  { id: "chat", label: "nav_chat", icon: "chat" },
  { id: "music", label: "nav_music", icon: "music" },
  { id: "comments", label: "nav_comments", icon: "comment" },
  "sep",
  { id: "reaper", label: "nav_reaper", icon: "reaper" },
  { id: "changes", label: "nav_changes", icon: "changes" },
  { id: "support", label: "nav_support", icon: "heart" },
  { id: "settings", label: "nav_settings", icon: "settings" },
];

function renderNav() {
  $("#nav").innerHTML = VIEWS.map((v) =>
    v === "sep"
      ? `<div class="nav-sep"></div>`
      : `<button class="nav ${S.view === v.id ? "on" : ""}" data-view="${v.id}">${icon(v.icon)}<span>${t(v.label)}</span>${
          v.id === "chat" && S.unread ? `<span class="badge">${S.unread > 99 ? "99+" : S.unread}</span>` : ""
        }</button>`
  ).join("");
}

function renderConn() {
  const s = S.session;
  const st = s ? s.status : "off";
  const sub = s ? th("room_n", { room: s.room }) : S.host.running ? t("server_running") : t("not_in_session");
  $("#conn").innerHTML = `<span class="dot ${st}"></span><div><b>${statusLabel(st)}</b><small>${sub}</small></div>`;
  $("#ver").textContent = `Sesja ${S.info.version} · mod ${S.info.mod_version}`;
}

function go(view) {
  if (S.view === view) return;
  S.view = view;
  if (view === "chat") S.unread = 0;
  renderNav();
  renderView(true);
}

function renderView(animate) {
  const v = $("#view");
  v.innerHTML = (RENDER[S.view] || RENDER.studio)();
  if (animate && !reduceMotion) {
    v.classList.remove("enter");
    void v.offsetWidth;
    v.classList.add("enter");
  }
  $("#main").scrollTop = 0;
  AFTER[S.view]?.();
}

/* aktualizacja widoku po zmianie stanu sesji – bez przebudowy pól formularzy */
function refreshView() {
  const r = REFRESH[S.view];
  if (r) return r();
  const a = document.activeElement;
  if (!a || a === document.body || !$("#view").contains(a)) {
    $("#view").innerHTML = (RENDER[S.view] || RENDER.studio)();
    AFTER[S.view]?.();
  }
}

/* ------------------------------------------------------------------ widoki */
const RENDER = {};
const AFTER = {};
const REFRESH = {};

const head = (title, text = "", actions = "") =>
  `<div class="head"><div><h1>${title}</h1>${text ? `<p>${text}</p>` : ""}</div>${actions ? `<div class="actions">${actions}</div>` : ""}</div>`;

function noSession(text) {
  return `<div class="panel empty">${icon("users")}<b>${t("no_session")}</b><span>${text}</span>
    <button class="btn primary" data-view="studio">${t("go_studio")}</button></div>`;
}

RENDER.studio = () => {
  const s = S.session;
  if (!s) return studioEmpty();
  return `
    <div class="head">
      <div>
        <h1 class="room-title">${esc(s.room)}</h1>
        <div class="room-sub">
          <span class="pill"><span class="dot ${s.status}"></span>${statusLabel(s.status)}</span>
          <span>${esc(s.server)}</span>
        </div>
      </div>
      <div class="actions">
        ${S.reaper?.exe ? `<button class="btn ghost" data-act="launch">${icon("reaper")}${t("open_reaper")}</button>` : ""}
        <button class="btn ghost" data-act="disconnect">${t("disconnect")}</button>
      </div>
    </div>
    ${s.error ? `<div class="notice" style="margin-bottom:18px">${icon("alert")}<span>${esc(s.error)}</span></div>` : ""}
    <div class="studio-grid">
      <div class="stack">
        <section class="panel"><h2>${t("in_session")} <span class="muted" id="people-n"></span></h2><div class="people" id="people"></div></section>
        <section class="panel"><h2>${t("tracks")} <span class="muted" id="tracks-n"></span></h2><div class="tracks" id="tracks"></div></section>
      </div>
      <section class="panel"><h2>${t("activity")}</h2><div class="feed" id="feed"></div></section>
    </div>
    ${S.host.running ? `<div style="margin-top:18px">${hostPanel()}</div>` : ""}`;
};

function studioEmpty() {
  return `
    ${head(t("nav_studio"), t("studio_empty_lead"))}
    ${S.host.running ? `<div style="margin-bottom:18px">${hostPanel()}</div>` : ""}
    <div class="choice-grid">
      <section class="panel choice">
        ${icon("server", "width:28px;height:28px;color:var(--amber)")}
        <h3>${t("mode_host")}</h3>
        <p>${t("host_text")}</p>
        <button class="btn primary" data-act="host-and-join">${t(S.host.running ? "join_own" : "start_and_join")}</button>
      </section>
      <section class="panel choice">
        ${icon("link", "width:28px;height:28px;color:var(--signal)")}
        <h3>${t("join_title")}</h3>
        <p>${t("join_text")}</p>
        <div class="field"><input class="input" id="join-server" placeholder="http://100.101.102.103:8765" value="${esc(S.cfg.server)}"></div>
        <div class="form-grid">
          <input class="input" id="join-room" placeholder="${esc(t("room"))}" value="${esc(S.cfg.room)}">
          <input class="input" id="join-pass" type="password" placeholder="${esc(t("password_opt"))}" value="${esc(S.cfg.password)}">
        </div>
        <button class="btn primary" data-act="join">${t("join")}</button>
      </section>
    </div>`;
}

function hostPanel() {
  const a = S.host.addresses || [];
  return `<section class="panel">
    <h2>${icon("server", "width:18px;height:18px;color:var(--amber)")}${t("host_running")} <span class="muted">${th("port_n", { port: S.host.port })}</span></h2>
    <p class="muted">${t("host_share")}</p>
    ${a.map((x) => `<div class="addr"><code>${esc(x.url)}</code><small>${esc(t("net_" + x.kind))}</small>
      <button class="btn icon ghost" title="${esc(t("copy"))}" data-copy="${esc(x.url)}">${icon("copy")}</button></div>`).join("")}
    <div class="row" style="margin-top:14px"><button class="btn danger" data-act="host-stop">${t("stop_server")}</button></div>
  </section>`;
}

function peopleHtml(s) {
  const users = s.users || [];
  if (!users.length) return `<div class="empty">${t("nobody_yet")}</div>`;
  return users.map((u) => {
    const state = u.app ? `<span class="state">${t("in_app")}</span>`
      : u.rec ? `<span class="state rec">${th("recording_at", { pos: fmtPos(u.pos) })}</span>`
      : u.play ? `<span class="state">${icon("play", "width:12px;height:12px")}${fmtPos(u.pos)}</span>`
      : `<span class="state num">${fmtPos(u.pos)}</span>`;
    const where = u.sel ? th("on_track", { name: u.sel }) : u.app ? "Sesja" : "REAPER";
    return `<div class="person"><div class="avatar" style="background:${esc(u.color)}">${initial(u.name)}</div>
      <div><b>${esc(u.name)}${u.name === s.me ? ` (${t("you")})` : ""}</b><small>${where}</small></div>${state}</div>`;
  }).join("");
}

function tracksHtml(s) {
  if (!s.tracks.length) return `<div class="empty">${t("tracks_empty")}</div>`;
  const count = {};
  for (const it of s.items) count[it.track] = (count[it.track] || 0) + 1;
  return s.tracks.map((tr) => `<div class="track"><div class="bar" style="background:${esc(colorOf(tr.author))}"></div>
    <div><b>${esc(tr.name)}</b><small>${th("author_n", { name: tr.author })}${tr.editor && tr.editor !== tr.author ? ` · ${th("edited_by", { name: tr.editor })}` : ""}</small></div>
    <span class="n num">${tn("clips", count[tr.guid] || 0)}</span></div>`).join("");
}

function feedKey(e) { return `${e.ts}|${e.user}|${e.kind}|${e.action || ""}|${e.name || ""}|${e.text}`; }

/* zdanie opisujące wpis aktywności, np. „dodaje klip „wokal” na ścieżce „Wokal” @ 0:12” */
function actText(e) {
  if (e.kind === "comment") {
    return th(e.item_name ? "act_comment_item" : "act_comment", { item: e.item_name, pos: fmtPos(e.pos), text: e.text });
  }
  if (e.kind === "chat") return esc(e.text);
  const p = { name: e.name || "?", track: e.track || "?", pos: fmtPos(e.pos), bpm: (e.bpm || 0).toFixed(2) };
  return th("act_" + (e.action || "unknown"), p);
}

function feedHtml(s) {
  const list = s.feed.filter((e) => e.kind !== "chat").slice(-120).reverse();
  if (!list.length) return `<div class="empty">${t("activity_empty")}</div>`;
  return list.map((e) => {
    const fresh = S.seenKeys.size && !S.seenKeys.has(feedKey(e));
    return `<div class="ev ${e.kind} ${fresh ? "fresh" : ""}"><time class="num">${fmtClock(e.ts)}</time>
      <div><b style="color:${esc(colorOf(e.user))}">${esc(e.user)}</b> <span class="t">${actText(e)}</span></div></div>`;
  }).join("");
}

REFRESH.studio = () => {
  const s = S.session;
  if (!s || !$("#people")) return renderView(false);
  $("#people").innerHTML = peopleHtml(s);
  $("#people-n").textContent = s.users.length ? String(s.users.length) : "";
  $("#tracks").innerHTML = tracksHtml(s);
  $("#tracks-n").textContent = s.tracks.length ? String(s.tracks.length) : "";
  $("#feed").innerHTML = feedHtml(s);
  const pill = document.querySelector(".room-sub .pill");
  if (pill) pill.innerHTML = `<span class="dot ${s.status}"></span>${statusLabel(s.status)}`;
};
AFTER.studio = () => S.session && REFRESH.studio();

/* --- czat --- */
RENDER.chat = () => {
  if (!S.session) return head(t("nav_chat")) + noSession(t("chat_no_session"));
  return `${head(t("nav_chat"), t("chat_lead"))}
    <div class="chat"><div class="msgs" id="msgs"></div>
      <form class="composer" id="chat-form"><input class="input" id="chat-input" maxlength="1000" placeholder="${esc(t("chat_ph"))}" autocomplete="off">
      <button class="btn primary">${icon("send")}${t("send")}</button></form></div>`;
};
function msgsHtml(s) {
  const list = s.feed.filter((e) => e.kind === "chat" || e.kind === "comment");
  if (!list.length) return `<div class="empty">${icon("chat")}${t("chat_empty")}</div>`;
  return list.map((e) => {
    const fresh = S.seenKeys.size && !S.seenKeys.has(feedKey(e));
    if (e.kind === "comment") {
      return `<div class="msg note ${fresh ? "fresh" : ""}"><div class="bubble">${esc(e.user)} ${actText(e)}</div></div>`;
    }
    return `<div class="msg ${e.mine ? "mine" : ""} ${fresh ? "fresh" : ""}"><div class="who"><b style="color:${esc(colorOf(e.user))}">${esc(e.user)}</b><span class="num">${fmtClock(e.ts)}</span></div>
      <div class="bubble">${esc(e.text)}</div></div>`;
  }).join("");
}
REFRESH.chat = () => {
  const box = $("#msgs");
  if (!box) return renderView(false);
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  box.innerHTML = msgsHtml(S.session);
  if (atBottom) box.scrollTop = box.scrollHeight;
};
AFTER.chat = () => {
  if (!S.session) return;
  const box = $("#msgs");
  box.innerHTML = msgsHtml(S.session);
  box.scrollTop = box.scrollHeight;
  $("#chat-input").focus();
  $("#chat-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const inp = $("#chat-input");
    const text = inp.value.trim();
    if (!text) return;
    inp.value = "";
    try { await invoke("send_chat", { text }); } catch (err) { inp.value = text; fail(err); }
  });
};

/* --- nagrania --- */
RENDER.music = () => {
  if (!S.session) return head(t("nav_music")) + noSession(t("music_no_session"));
  return `${head(t("nav_music"), t("music_lead"))}<div class="filters" id="filters"></div><div class="clips" id="clips"></div>`;
};
function musicItems() {
  return S.session.items.filter((i) => i.file && !i.midi && (!S.musicFilter || i.author === S.musicFilter));
}
REFRESH.music = () => {
  const s = S.session;
  if (!s || !$("#clips")) return renderView(false);
  const authors = [...new Set(s.items.filter((i) => i.file && !i.midi).map((i) => i.author))];
  $("#filters").innerHTML = authors.length > 1
    ? `<button class="chip ${!S.musicFilter ? "on" : ""}" data-filter="">${t("everyone")}</button>` +
      authors.map((a) => `<button class="chip ${S.musicFilter === a ? "on" : ""}" data-filter="${esc(a)}"><i style="background:${esc(colorOf(a))}"></i>${esc(a)}</button>`).join("")
    : "";
  const tname = Object.fromEntries(s.tracks.map((tr) => [tr.guid, tr.name]));
  const items = musicItems();
  const box = $("#clips");
  const ids = items.map((i) => i.guid).join(",");
  if (box.dataset.ids === ids) return; // nic się nie zmieniło – nie przerywaj odtwarzania
  box.dataset.ids = ids;
  box.innerHTML = items.length ? items.map((it) => `
    <div class="clip" data-guid="${esc(it.guid)}">
      <button class="play ${S.audio.id === it.file ? "on" : ""}" data-play="${esc(it.file)}" aria-label="${esc(t("play"))}">${icon(S.audio.id === it.file && !S.audio.el.paused ? "pause" : "play")}</button>
      <div><b>${esc(it.name)}</b><small>${esc(tname[it.track] || "?")} · ${fmtPos(it.pos)}</small></div>
      <canvas class="wave" data-wave="${esc(it.file)}"></canvas>
      <div class="meta"><span class="by"><i style="background:${esc(colorOf(it.author))}"></i>${esc(it.author)}</span><span class="num">${fmtPos(it.len)} · ${fmtClock(it.created)}</span></div>
    </div>`).join("")
    : `<div class="panel empty">${icon("music")}${t("music_empty")}</div>`;
  drawAllWaves();
};
AFTER.music = () => S.session && REFRESH.music();

function drawWave(cv) {
  const id = cv.dataset.wave;
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (!w) return;
  cv.width = w * dpr; cv.height = h * dpr;
  const ctx = cv.getContext("2d");
  ctx.scale(dpr, dpr);
  const peaks = S.peaks.get(id);
  const playing = S.audio.id === id;
  const prog = playing && S.audio.el.duration ? S.audio.el.currentTime / S.audio.el.duration : 0;
  const bars = Math.floor(w / 4);
  for (let i = 0; i < bars; i++) {
    const x = i * 4;
    let v = 0.06;
    if (peaks) v = Math.max(0.06, peaks[Math.floor((i / bars) * peaks.length)] || 0);
    const bh = Math.max(2, v * (h - 4));
    ctx.fillStyle = !peaks ? "rgba(234,227,210,0.14)" : x / w < prog ? "#f3a73b" : "rgba(234,227,210,0.42)";
    ctx.fillRect(x, (h - bh) / 2, 2, bh);
  }
}
function drawAllWaves() { document.querySelectorAll("canvas.wave").forEach(drawWave); }

async function loadPeaks(id, url) {
  if (S.peaks.has(id)) return;
  try {
    const buf = await (await fetch(url)).arrayBuffer();
    const ac = new (window.AudioContext || window.webkitAudioContext)();
    const audio = await ac.decodeAudioData(buf);
    const data = audio.getChannelData(0);
    const n = 240, step = Math.floor(data.length / n) || 1, peaks = new Float32Array(n);
    let max = 0;
    for (let i = 0; i < n; i++) {
      let m = 0;
      for (let j = i * step; j < Math.min(data.length, (i + 1) * step); j += 8) m = Math.max(m, Math.abs(data[j]));
      peaks[i] = m; max = Math.max(max, m);
    }
    for (let i = 0; i < n; i++) peaks[i] = max ? peaks[i] / max : 0;
    S.peaks.set(id, peaks);
    ac.close();
  } catch { S.peaks.set(id, null); }
}

async function togglePlay(id, btn) {
  const a = S.audio;
  if (a.id === id && !a.el.paused) { a.el.pause(); return; }
  if (a.id !== id) {
    btn.innerHTML = `<div class="spinner"></div>`;
    try {
      const path = await invoke("fetch_audio", { id });
      const url = fileSrc(path);
      a.el.src = url;
      a.id = id;
      loadPeaks(id, url).then(drawAllWaves);
    } catch (e) {
      btn.innerHTML = icon("play");
      return fail(e);
    }
  }
  a.el.play().catch(() => {
    a.el.pause();
    a.id = null;
    syncPlayButtons();
    toast({ title: t("cant_play"), text: t("cant_play_text"), timeout: 6000 });
  });
}
S.audio.el.addEventListener("play", () => { syncPlayButtons(); tickAudio(); });
S.audio.el.addEventListener("pause", syncPlayButtons);
S.audio.el.addEventListener("ended", syncPlayButtons);
function syncPlayButtons() {
  document.querySelectorAll("[data-play]").forEach((b) => {
    const on = b.dataset.play === S.audio.id && !S.audio.el.paused;
    b.classList.toggle("on", b.dataset.play === S.audio.id);
    b.innerHTML = icon(on ? "pause" : "play");
  });
  drawAllWaves();
}
function tickAudio() {
  cancelAnimationFrame(S.audio.raf);
  const loop = () => {
    const cv = document.querySelector(`canvas.wave[data-wave="${CSS.escape(S.audio.id || "")}"]`);
    if (cv) drawWave(cv);
    if (!S.audio.el.paused) S.audio.raf = requestAnimationFrame(loop);
  };
  loop();
}

/* --- komentarze --- */
RENDER.comments = () => {
  if (!S.session) return head(t("nav_comments")) + noSession(t("comments_no_session"));
  const s = S.session;
  const tname = Object.fromEntries(s.tracks.map((tr) => [tr.guid, tr.name]));
  const items = [...s.items].sort((a, b) => a.pos - b.pos);
  return `${head(t("nav_comments"), t("comments_lead"))}
    <form class="panel cmt-form" id="cmt-form">
      <label class="field"><span>${t("comment")}</span><input class="input" id="cmt-text" maxlength="500" placeholder="${esc(t("comment_ph"))}"></label>
      <label class="field"><span>${t("clip")}</span><select class="input" id="cmt-item"><option value="">${t("whole_song")}</option>
        ${items.map((i) => `<option value="${esc(i.guid)}" data-pos="${i.pos}" data-name="${esc(i.name)}">${esc(i.name)} (${esc(tname[i.track] || "?")})</option>`).join("")}</select></label>
      <label class="field"><span>${t("position")}</span><input class="input num" id="cmt-pos" value="0:00" placeholder="1:23"></label>
      <button class="btn primary">${t("add")}</button>
    </form>
    <div class="cmts" id="cmts"></div>`;
};
REFRESH.comments = () => {
  const box = $("#cmts");
  if (!box) return renderView(false);
  const list = [...S.session.comments].reverse();
  box.innerHTML = list.length ? list.map((c) => `
    <div class="cmt"><div class="avatar" style="background:${esc(colorOf(c.user))}">${initial(c.user)}</div>
      <div><div class="where">${c.item_name ? `${th("clip_n", { name: c.item_name })} · ` : ""}${fmtPos(c.pos)}</div>
      <div class="body">${esc(c.text)}</div><small>${esc(c.user)} · ${fmtClock(c.ts)}</small></div>
      ${c.mine ? `<button class="btn icon ghost" title="${esc(t("delete_comment"))}" data-del-comment="${esc(c.id)}">${icon("x")}</button>` : "<span></span>"}
    </div>`).join("")
    : `<div class="panel empty">${icon("comment")}${t("comments_empty")}</div>`;
};
AFTER.comments = () => {
  if (!S.session) return;
  REFRESH.comments();
  $("#cmt-item").addEventListener("change", (e) => {
    const o = e.target.selectedOptions[0];
    if (o && o.dataset.pos) $("#cmt-pos").value = fmtPos(+o.dataset.pos);
  });
  $("#cmt-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = $("#cmt-text").value.trim();
    if (!text) return $("#cmt-text").focus();
    const o = $("#cmt-item").selectedOptions[0];
    try {
      await invoke("send_comment", { text, pos: parsePos($("#cmt-pos").value), item: o.value || null, itemName: o.value ? o.dataset.name : null });
      $("#cmt-text").value = "";
      toast({ title: t("comment_added"), text: t("comment_added_text") });
    } catch (err) { fail(err); }
  });
};

/* --- REAPER --- */
RENDER.reaper = () => {
  const r = S.reaper || {};
  const upToDate = r.script_installed && r.script_version === r.bundled_version;
  const modState = r.script_installed
    ? `<span class="${upToDate ? "ok" : "warn"}">${th(upToDate ? "mod_current" : "mod_outdated", { v: r.script_version, nv: r.bundled_version })}</span>`
    : `<span class="bad">${t("mod_missing")}</span>`;
  return `${head(t("nav_reaper"), t("reaper_lead"), `<button class="btn ghost" data-act="redetect">${icon("refresh")}${t("check_again")}</button>`)}
    <div class="stack">
      <section class="panel">
        <h2>${t("installation")}</h2>
        ${r.found ? `<dl class="kv">
          <dt>${t("program")}</dt><dd>${esc(r.exe || t("exe_unknown"))}</dd>
          <dt>${t("settings_folder")}</dt><dd>${esc(r.resource || "?")}</dd>
          <dt>Mod</dt><dd>${modState}</dd>
          <dt>${t("startup")}</dt><dd>${t(r.autostart ? "startup_auto" : "startup_manual")}</dd>
          <dt>${t("reaper_now")}</dt><dd>${t(r.running ? "reaper_open" : "reaper_closed")}</dd>
        </dl>` : `<div class="found miss"><div class="ic">${icon("x")}</div><div><b>${t("ob_missing_title")}</b><small>${t("pick_reaper_text")}</small></div></div>`}
        ${r.running ? `<div class="notice" style="margin-top:16px">${icon("alert")}<span>${t("restart_reaper")}</span></div>` : ""}
        ${r.found && !r.resource ? `<div class="notice" style="margin-top:16px">${icon("alert")}<span>${t("ob_firstrun_text")}</span></div>` : ""}
        <div class="row" style="margin-top:18px">
          ${r.found && r.resource ? `<button class="btn primary" data-act="install">${icon("download")}${t(r.script_installed ? (upToDate ? "reinstall" : "update_mod") : "install_mod")}</button>` : ""}
          <button class="btn ghost" data-act="pick">${icon("folder")}${t("pick_reaper")}</button>
          ${r.resource ? `<button class="btn ghost" data-act="open-res">${t("open_settings_folder")}</button>` : ""}
          ${r.exe ? `<button class="btn ghost" data-act="launch">${icon("reaper")}${t("open_reaper")}</button>` : ""}
        </div>
      </section>
      ${r.found && r.resource ? `<section class="panel"><h2>${t("options")}</h2>
        <label class="switch"><input type="checkbox" id="auto-toggle" ${r.autostart ? "checked" : ""}><i></i><span>${t("autostart")}</span></label>
        ${r.script_installed ? `<div class="row" style="margin-top:18px"><button class="btn danger" data-act="uninstall">${t("uninstall_mod")}</button></div>` : ""}
      </section>` : ""}
      <section class="panel"><h2>${t("howto_title")}</h2>
        <div class="md"><ul><li>${t("howto_1")}</li><li>${t("howto_2")}</li><li>${t("howto_3")}</li><li>${t("howto_4")}</li></ul></div>
      </section>
    </div>`;
};
AFTER.reaper = () => {
  $("#auto-toggle")?.addEventListener("change", async (e) => {
    try {
      const rep = await invoke("install_mod", { resource: S.reaper.resource, autostart: e.target.checked });
      S.reaper = rep.info;
      toast({ title: t(e.target.checked ? "autostart_on" : "autostart_off") });
      renderView(false);
    } catch (err) { fail(err); }
  });
};

/* --- zmiany --- */
RENDER.changes = () => `${head(t("nav_changes"), t("changes_lead"), `<button class="btn ghost" data-act="check-update">${icon("refresh")}${t("check_updates")}</button>`)}
  <div class="panel md" id="changes">${S.releases?.length ? releasesHtml(S.releases) : md(S.changelog || "")}</div>`;
function releasesHtml(list) {
  return list.map((r) => `<div class="release"><div class="tag"><h2>${esc(r.name || r.tag)}</h2><span class="muted">${esc((r.date || "").slice(0, 10))}</span></div>${md(r.body || "")}</div>`).join("");
}
AFTER.changes = () => {
  if (S.releases) return;
  invoke("check_update").then((u) => {
    S.releases = u.releases || [];
    if (S.view === "changes" && S.releases.length) $("#changes").innerHTML = releasesHtml(S.releases);
  }).catch(() => {});
};

function md(src) {
  const inline = (s) => esc(s)
    .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
    .replace(/`(.+?)`/g, "<code>$1</code>")
    .replace(/\[(.+?)\]\((https?:[^)\s]+)\)/g, '<a href="#" data-url="$2">$1</a>');
  let html = "", list = false;
  for (const raw of src.split(/\r?\n/)) {
    if (/^\s*[-*] /.test(raw)) {
      if (!list) { html += "<ul>"; list = true; }
      html += `<li>${inline(raw.replace(/^\s*[-*] /, ""))}</li>`;
      continue;
    }
    if (list && /^\s{2,}\S/.test(raw)) { html = html.replace(/<\/li>$/, ` ${inline(raw.trim())}</li>`); continue; }
    if (list) { html += "</ul>"; list = false; }
    if (/^### /.test(raw)) html += `<h3>${inline(raw.slice(4))}</h3>`;
    else if (/^## /.test(raw)) html += `<h2>${inline(raw.slice(3))}</h2>`;
    else if (/^# /.test(raw)) continue;
    else if (raw.trim()) html += `<p>${inline(raw)}</p>`;
  }
  return html + (list ? "</ul>" : "");
}

/* --- wsparcie --- */
RENDER.support = () => `
  <div class="panel support-hero">
    <div>
      <h2>${t("support_title")}</h2>
      <p>${t("support_text")}</p>
      <div class="row" style="margin-top:20px">
        <button class="btn ghost" data-url="${LINKS.repo}">${icon("github")}${t("code_on_github")}</button>
        <button class="btn ghost" data-url="${LINKS.issues}">${t("report_issue")}</button>
      </div>
    </div>
    <img src="img/logo.svg" alt="">
  </div>
  <div class="donate">${LINKS.donate.map((d) => `<button data-url="${esc(d.url)}"><b>${esc(d.name)}</b><small>${t(d.note)}</small></button>`).join("")}</div>`;

/* --- ustawienia --- */
RENDER.settings = () => {
  const c = S.cfg;
  return `${head(t("nav_settings"))}
  <div class="stack">
    <section class="panel">
      <h2>${t("language")}</h2>
      <div style="max-width:280px">${langSelect("set-lang")}</div>
    </section>
    <form class="panel" id="set-profile">
      <h2>${t("you_and_session")}</h2>
      <div class="form-grid">
        <label class="field"><span>${t("nick")}</span><input class="input" name="nick" maxlength="40" value="${esc(c.nick)}"></label>
        <label class="field"><span>${t("room")}</span><input class="input" name="room" value="${esc(c.room)}"></label>
        <label class="field"><span>${t("server_addr")}</span><input class="input" name="server" value="${esc(c.server)}"></label>
        <label class="field"><span>${t("server_password")}</span><input class="input" name="password" type="password" value="${esc(c.password)}"><small>${t("password_hint")}</small></label>
      </div>
      <div class="row" style="margin-top:18px"><button class="btn primary">${t("save_reconnect")}</button>
        ${S.reaper?.script_installed ? `<span class="muted">${t("save_to_reaper_too")}</span>` : ""}</div>
    </form>
    <form class="panel" id="set-host">
      <h2>${t("my_server")}</h2>
      <div class="form-grid">
        <label class="field"><span>${t("port")}</span><input class="input num" name="host_port" type="number" min="1024" max="65535" value="${c.host_port}"></label>
        <label class="field"><span>${t("password")}</span><input class="input" name="host_password" type="password" value="${esc(c.host_password)}"></label>
      </div>
      <label class="switch" style="margin-top:16px"><input type="checkbox" name="host_on_start" ${c.host_on_start ? "checked" : ""}><i></i><span>${t("host_on_start")}</span></label>
      <div class="row" style="margin-top:18px">
        <button class="btn primary">${t(S.host.running ? "save_restart" : "start_server")}</button>
        ${S.host.running ? `<button type="button" class="btn danger" data-act="host-stop">${t("stop")}</button>` : ""}
      </div>
    </form>
    <section class="panel">
      <h2>${t("updates")}</h2>
      <label class="switch"><input type="checkbox" id="auto-update" ${c.auto_update ? "checked" : ""}><i></i><span>${t("auto_update")}</span></label>
      <div class="row" style="margin-top:18px"><button class="btn ghost" data-act="check-update">${icon("refresh")}${t("check_now")}</button>
        <span class="muted">${th("you_have_version", { v: S.info.version })}</span></div>
    </section>
    <section class="panel">
      <h2>${t("welcome_wizard")}</h2>
      <p class="muted">${t("welcome_wizard_text")}</p>
      <div class="row" style="margin-top:14px"><button class="btn ghost" data-act="rerun-onboarding">${t("run_again")}</button></div>
    </section>
  </div>`;
};
AFTER.settings = () => {
  $("#set-profile").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, nick: f.get("nick"), room: f.get("room"), server: f.get("server"), password: f.get("password") } });
      if (S.reaper?.script_installed) {
        const rep = await invoke("install_mod", { resource: S.reaper.resource, autostart: S.reaper.autostart });
        S.reaper = rep.info;
        if (rep.warning) toast({ title: t("saved_in_reaper"), text: rep.warning, timeout: 8000 });
      }
      await connect();
      toast({ title: t("saved"), text: th("connecting_to", { room: S.cfg.room }) });
      renderView(false);
    } catch (err) { fail(err); }
  });
  $("#set-host").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, host_port: +f.get("host_port") || 8765, host_password: f.get("host_password"), host_on_start: f.get("host_on_start") === "on" } });
      S.host = await invoke("host_start", { port: S.cfg.host_port, password: S.cfg.host_password });
      toast({ title: t("server_started"), text: th("server_started_text", { port: S.host.port }) });
      renderConn();
      renderView(false);
    } catch (err) { fail(err); }
  });
  $("#auto-update").addEventListener("change", async (e) => {
    S.cfg = await invoke("save_config", { cfg: { ...S.cfg, auto_update: e.target.checked } });
  });
};

/* ------------------------------------------------------------------ akcje */
let lastChatCount = 0;
function markSeen(sum) {
  if (!sum) return;
  lastChatCount = sum.feed.filter((e) => e.kind === "chat").length;
  for (const e of sum.feed) S.seenKeys.add(feedKey(e));
}

async function connect() {
  await invoke("session_connect");
  S.session = (await invoke("session_state")) || null;
  S.firstSync = true;
  markSeen(S.session);
  renderConn();
}

const ACTIONS = {
  async disconnect() { await invoke("session_disconnect"); S.session = null; renderConn(); renderView(false); },
  async launch() { try { await invoke("launch_reaper"); toast({ title: t("opening_reaper") }); } catch (e) { fail(e); } },
  async "host-stop"() {
    await invoke("host_stop");
    S.host = { running: false };
    S.cfg = await invoke("save_config", { cfg: { ...S.cfg, host_on_start: false } });
    renderConn();
    renderView(false);
  },
  async "host-and-join"() {
    try {
      if (!S.host.running) S.host = await invoke("host_start", { port: S.cfg.host_port || 8765, password: S.cfg.host_password });
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, server: `http://127.0.0.1:${S.host.port}`, password: S.cfg.host_password } });
      await connect();
      renderView(true);
    } catch (e) { fail(e); }
  },
  async join() {
    const server = $("#join-server").value.trim(), room = $("#join-room").value.trim();
    if (!server || !room) return toast({ title: t("need_server_room") });
    try {
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, server, room, password: $("#join-pass").value.trim() } });
      await connect();
      renderView(true);
    } catch (e) { fail(e); }
  },
  async redetect() { S.reaper = await invoke("detect_reaper"); renderView(false); },
  async pick() {
    try { const info = await invoke("pick_reaper_folder"); if (info) { S.reaper = info; renderView(false); } } catch (e) { fail(e); }
  },
  async install() {
    try {
      const rep = await invoke("install_mod", { resource: S.reaper.resource, autostart: S.reaper.autostart || S.cfg.autostart_script });
      S.reaper = rep.info;
      toast({ title: t("mod_installed"), text: rep.warning || th("version_n", { v: rep.info.script_version }), timeout: 7000 });
      renderView(false);
    } catch (e) { fail(e); }
  },
  uninstall() {
    toast({
      title: t("uninstall_q"),
      text: t("uninstall_text"),
      actions: [
        { label: t("cancel"), fn: (close) => close() },
        { label: t("uninstall"), primary: true, fn: async (close) => {
          close();
          try {
            await invoke("uninstall_mod", { resource: S.reaper.resource });
            S.reaper = await invoke("detect_reaper");
            renderView(false);
            toast({ title: t("mod_uninstalled") });
          } catch (e) { fail(e); }
        } },
      ],
    });
  },
  "open-res"() { invoke("open_path", { path: S.reaper.resource }).catch(fail); },
  async "check-update"() { await checkUpdates(true); },
  "rerun-onboarding"() { OB.step = 0; OB.report = null; obShow(); },
};

document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-view],[data-act],[data-ob],[data-url],[data-copy],[data-play],[data-filter],[data-del-comment],canvas.wave");
  if (!el) return;
  if (el.dataset.view) return go(el.dataset.view);
  if (el.dataset.act) return ACTIONS[el.dataset.act]?.(el);
  if (el.dataset.ob) return obAction(el.dataset.ob, el);
  if (el.dataset.url) { e.preventDefault(); return invoke("open_url", { url: el.dataset.url }).catch(fail); }
  if (el.dataset.copy) {
    navigator.clipboard?.writeText(el.dataset.copy).then(() => toast({ title: t("copied"), text: el.dataset.copy }), fail);
    return;
  }
  if (el.dataset.play) return togglePlay(el.dataset.play, el);
  if (el.dataset.filter !== undefined) { S.musicFilter = el.dataset.filter || null; $("#clips").dataset.ids = ""; return REFRESH.music(); }
  if (el.dataset.delComment) return invoke("delete_comment", { id: el.dataset.delComment }).catch(fail);
  if (el.matches("canvas.wave") && S.audio.id === el.dataset.wave && S.audio.el.duration) {
    const r = el.getBoundingClientRect();
    S.audio.el.currentTime = ((e.clientX - r.left) / r.width) * S.audio.el.duration;
    drawWave(el);
  }
});

window.addEventListener("resize", debounce(drawAllWaves, 120));

/* ------------------------------------------------------------------ aktualizacje */
async function checkUpdates(manual) {
  let u;
  try { u = await invoke("check_update"); } catch (e) { if (manual) fail(e); return; }
  if (u.releases?.length) S.releases = u.releases;
  if (!u.newer) { if (manual) toast({ title: t("up_to_date"), text: `Sesja ${u.current}` }); return; }
  if (!u.asset_url) {
    toast({ title: t("new_version", { v: u.latest }), text: t("get_from_site"), actions: [{ label: t("open"), primary: true, fn: (c) => { c(); invoke("open_url", { url: `${LINKS.repo}/releases/latest` }); } }] });
    return;
  }
  toast({
    title: t("new_version", { v: u.latest }),
    text: (u.notes || "").split("\n").find((l) => l.trim() && !l.startsWith("#"))?.replace(/^[-*]\s*/, "") || t("update_default_note"),
    actions: [
      { label: t("later"), fn: (c) => c() },
      { label: t("install"), primary: true, fn: async (close) => {
        close();
        const tt = toast({ title: t("downloading_version", { v: u.latest }), progress: true });
        try { await invoke("install_update", { url: u.asset_url, name: u.asset_name }); }
        catch (e) { tt.close(); fail(e); }
      } },
    ],
  });
}

/* ------------------------------------------------------------------ zdarzenia sesji */
function onSession(sum) {
  // pierwsza porcja danych po połączeniu to historia – nie liczymy jej jako nowości
  const prev = S.firstSync ? null : S.session;
  if (S.firstSync && sum.status === "on") { S.firstSync = false; markSeen(sum); }
  S.session = sum;
  const chats = sum.feed.filter((e) => e.kind === "chat");
  if (prev && chats.length > lastChatCount && S.view !== "chat") {
    const fresh = chats.slice(lastChatCount).filter((e) => !e.mine);
    S.unread += fresh.length;
    if (fresh.length) renderNav();
  }
  if (prev) {
    const known = new Set(prev.comments.map((c) => c.id));
    for (const c of sum.comments) if (!known.has(c.id) && !c.mine) toast({ title: t("new_comment_from", { name: c.user }), text: c.text });
  }
  lastChatCount = chats.length;
  renderConn();
  refreshView();
  for (const e of sum.feed) S.seenKeys.add(feedKey(e));
}

/* ------------------------------------------------------------------ start */
function startApp() {
  $("#shell").hidden = false;
  renderNav();
  renderConn();
  renderView(true);
}

async function boot() {
  const [cfg, info, changelog, host, reaperInfo] = await Promise.all([
    invoke("get_config"), invoke("app_info"), invoke("changelog"), invoke("host_status"), invoke("detect_reaper"),
  ]);
  Object.assign(S, { cfg, info, changelog, host, reaper: reaperInfo });
  setLang(cfg.lang || detectLang());
  if (!cfg.lang) S.cfg = await invoke("save_config", { cfg: { ...cfg, lang: lang() } });
  applyStaticTexts();
  await listen("session", onSession);
  await listen("update-progress", ([done, total]) => {
    const el = document.querySelector(".toast .progress i");
    if (el && total) el.style.width = `${Math.round((done / total) * 100)}%`;
  });
  if (!S.cfg.onboarded) {
    obShow();
  } else {
    startApp();
    if (S.cfg.nick && S.cfg.server && S.cfg.room) connect().catch(() => {});
  }
  if (S.cfg.auto_update) setTimeout(() => checkUpdates(false), 2500);
}

boot().catch((e) => {
  document.body.innerHTML = `<div style="padding:40px;font:16px system-ui;color:#eae3d2">${esc(String(e))}</div>`;
});
