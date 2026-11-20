/* Sesja – interfejs aplikacji. Czysty JS, bez frameworka i bez kroku budowania. */
"use strict";

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args);
const listen = (ev, cb) => T.event.listen(ev, (e) => cb(e.payload));
const fileSrc = (p) => T.core.convertFileSrc(p);

/* Linki wsparcia – podmień na własne konta przed wydaniem. */
const LINKS = {
  repo: "https://github.com/krixishere/repomulitplayer",
  issues: "https://github.com/krixishere/repomulitplayer/issues",
  reaperDownload: "https://www.reaper.fm/download.php",
  donate: [
    { name: "Buy Me a Coffee", note: "Jednorazowa kawa dla twórcy", url: "https://buymeacoffee.com/krixishere" },
    { name: "Ko-fi", note: "Wsparcie jednorazowe lub co miesiąc", url: "https://ko-fi.com/krixishere" },
    { name: "GitHub Sponsors", note: "Stałe wsparcie przez GitHuba", url: "https://github.com/sponsors/krixishere" },
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
  chatSeen: 0,
  seenKeys: new Set(),
  audio: { el: new Audio(), id: null, raf: 0 },
  peaks: new Map(),
  musicFilter: null,
  releases: null,
};

/* ------------------------------------------------------------------ narzędzia */
const $ = (sel, root = document) => root.querySelector(sel);
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;

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
  const hm = d.toLocaleTimeString("pl-PL", { hour: "2-digit", minute: "2-digit" });
  const today = new Date().toDateString() === d.toDateString();
  return today ? hm : `${d.getDate()}.${String(d.getMonth() + 1).padStart(2, "0")} ${hm}`;
}
function colorOf(user) {
  const s = S.session;
  return (s && s.colors && s.colors[user]) || "#8e95ab";
}
function initial(name) {
  return esc((name || "?").trim().charAt(0).toUpperCase());
}
function debounce(fn, ms) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
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
  let timer = timeout && !actions.length && !progress ? setTimeout(close, timeout) : null;
  // nie zamykaj, gdy kursor jest nad powiadomieniem
  el.addEventListener("mouseenter", () => timer && clearTimeout(timer));
  el.addEventListener("mouseleave", () => { if (timeout && !actions.length && !progress) timer = setTimeout(close, 2500); });
  return {
    close,
    setProgress(f) { const i = el.querySelector(".progress i"); if (i) i.style.width = `${Math.round(f * 100)}%`; },
    setText(t) { let p = el.querySelector("p"); if (!p) { p = document.createElement("p"); el.querySelector("b").after(p); } p.textContent = t; },
  };
}
const fail = (e) => toast({ title: "Coś poszło nie tak", text: String(e), timeout: 7000 });

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
  restart() { this.t0 = performance.now(); }

  /* poziom „muzyki” – suma kilku sinusów, żeby wskazówka żyła, ale nie szalała */
  level(t) {
    if (reduceMotion) return 0.62;
    const base = this.mode === "scan" ? 0.5 : this.mode === "calm" ? 0.42 : 0.56;
    let v = base + 0.16 * Math.sin(t * 1.7) + 0.09 * Math.sin(t * 4.3 + 1.2) + 0.05 * Math.sin(t * 9.1);
    if (this.mode === "scan") v += 0.12 * Math.sin(t * 6.0);
    if (performance.now() < this.kickUntil) v = 0.97;
    return Math.min(1, Math.max(0, v));
  }

  frame(now) {
    const { ctx, w, h } = this;
    if (!w || !h) return;
    const t = (now - this.t0) / 1000;
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2, cy = h * 0.66;
    const R = Math.min(w * 0.36, h * 0.46);
    const reveal = reduceMotion ? 1 : Math.min(1, t / 1.6);
    const ease = 1 - Math.pow(1 - reveal, 3);

    // łuk skali
    const a0 = Math.PI * 1.12, a1 = Math.PI * 1.88;
    ctx.lineCap = "round";
    ctx.lineWidth = Math.max(6, R * 0.035);
    ctx.strokeStyle = "rgba(234,227,210,0.10)";
    ctx.beginPath(); ctx.arc(cx, cy, R, a0, a1); ctx.stroke();
    ctx.strokeStyle = "rgba(240,82,79,0.85)";
    ctx.beginPath(); ctx.arc(cx, cy, R, a0 + (a1 - a0) * 0.8, a1); ctx.stroke();
    // podziałka
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

    // dwa sygnały płynące do środka
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
        const d = Math.abs(x - cx) / cx; // 0 przy wskazówce
        const env = Math.min(1, d * 3) * (0.55 + 0.45 * d);
        const phase = (fromLeft ? 1 : -1) * x * 0.022 - t * 3.2 + (fromLeft ? 0 : 1.7);
        const y = cy + Math.sin(phase) * amp * env * (0.7 + 0.3 * Math.sin(t * 0.9 + f * 3));
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
    };
    drawWave(true, "#5fc9b5");
    drawWave(false, "#eae3d2");

    // podświetlenie łuku do poziomu i wskazówka na sprężynie (tłumienie ~0.8)
    const lvl = reveal < 1 ? 0 : this.level(t);
    const target = a0 + (a1 - a0) * lvl - Math.PI * 1.5; // względem pionu
    if (reduceMotion) {
      this.angle = target;
    } else {
      const k = 120, c = 2 * 0.8 * Math.sqrt(k); // sztywność i tłumienie
      const dt = 1 / 60;
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

/* ------------------------------------------------------------------ instalator powitalny */
const OB = { step: 0, anim: null, detect: null, mode: "join", report: null };
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
        <h1>Jeden projekt.<br>Dwa miasta.</h1>
        <p>Sesja łączy Twojego REAPERa z REAPERem znajomych. Każde nagranie, przesunięty klip
        i zmiana na ścieżce trafia do wszystkich – bez wysyłania plików.</p>
        <p class="muted">Najpierw znajdę REAPERa i zainstaluję mod. To zajmie minutę.</p>`;
      foot.innerHTML = `<span class="ver">Wersja ${esc(S.info.version)}</span>
        <button class="btn primary big" data-ob="next">Zaczynamy</button>`;
    },
    search: () => obSearch(body, foot),
    profile: () => obProfile(body, foot),
    install: () => obInstall(body, foot),
    done: () => {
      OB.anim.kick();
      body.innerHTML = `
        <svg class="tick" viewBox="0 0 72 72" fill="none" stroke="#5fc9b5" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><circle cx="36" cy="36" r="33"/><path d="M23 37l9 9 18-19"/></svg>
        <h2>Wszystko gotowe</h2>
        <p>${OB.report ? "Mod jest zainstalowany. Otwórz REAPERa – okno Sesji pojawi się samo i połączy z pokojem „" + esc(S.cfg.room) + "”." : "Możesz zainstalować mod później w zakładce REAPER."}</p>
        ${OB.report?.warning ? `<div class="notice">${icon("alert")}<span>${esc(OB.report.warning)}</span></div>` : ""}`;
      foot.innerHTML = `${OB.report && S.reaper?.exe ? `<button class="btn ghost" data-ob="launch">Otwórz REAPERa</button>` : "<span></span>"}
        <button class="btn primary big" data-ob="finish">Przejdź do studia</button>`;
    },
  };
  steps[name]();
}

async function obSearch(body, foot) {
  body.innerHTML = `<h2>Szukam REAPERa</h2>
    <p>Sprawdzam typowe miejsca instalacji na tym komputerze.</p>
    <div class="scan" id="scan"></div>`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">Wstecz</button><div class="spinner"></div>`;
  const started = performance.now();
  let info;
  try { info = await invoke("detect_reaper"); } catch (e) { info = { found: false, checked: [], error: String(e) }; }
  const scan = $("#scan");
  const list = (info.checked || []).slice(0, 7);
  for (let i = 0; i < list.length; i++) {
    const d = document.createElement("div");
    d.innerHTML = `${icon("search")}<span>${esc(list[i])}</span>`;
    d.style.animationDelay = `${i * 70}ms`;
    scan?.appendChild(d);
  }
  // krótka pauza, żeby wynik nie „mignął” – wyszukiwanie zwykle trwa milisekundy
  await new Promise((r) => setTimeout(r, Math.max(0, 900 - (performance.now() - started))));
  OB.detect = info;
  S.reaper = info;
  obSearchResult(body, foot, info);
}

function obSearchResult(body, foot, info) {
  if (info.found) {
    OB.anim.kick();
    body.innerHTML = `<h2>Mamy go</h2>
      <div class="found"><div class="ic">${icon("check")}</div><div>
        <b>REAPER znaleziony${info.portable ? " (wersja przenośna)" : ""}</b>
        <small>${esc(info.exe || "Folder ustawień: " + info.resource)}</small>
      </div></div>
      ${info.script_installed ? `<p class="muted">Mod jest już zainstalowany (wersja ${esc(info.script_version || "?")}). Zaktualizuję go do ${esc(info.bundled_version)}.</p>` : ""}
      <button class="btn ghost" data-ob="pick">${icon("folder")}To nie ten – wskaż inny folder</button>`;
    foot.innerHTML = `<button class="btn ghost" data-ob="back">Wstecz</button><button class="btn primary big" data-ob="next">Dalej</button>`;
  } else {
    body.innerHTML = `<h2>Nie znaleziono REAPERa</h2>
      <div class="found miss"><div class="ic">${icon("x")}</div><div>
        <b>REAPERa nie ma w typowych miejscach</b>
        <small>Jeśli masz go zainstalowanego gdzie indziej (np. na innym dysku albo jako wersję przenośną), wskaż jego folder.</small>
      </div></div>
      <div class="row">
        <button class="btn primary" data-ob="pick">${icon("folder")}Wskaż folder REAPERa</button>
        <button class="btn ghost" data-url="${LINKS.reaperDownload}">${icon("download")}Pobierz REAPERa</button>
      </div>`;
    foot.innerHTML = `<button class="btn ghost" data-ob="back">Wstecz</button>
      <div class="row"><button class="btn ghost" data-ob="retry">${icon("refresh")}Szukaj ponownie</button>
      <button class="btn ghost" data-ob="skip">Pomiń na razie</button></div>`;
  }
}

function obProfile(body, foot) {
  // zachowaj to, co użytkownik już wpisał, przy przełączaniu trybu
  const keep = (id, key) => { const el = document.getElementById(id); if (el) OB.draft[key] = el.value; };
  OB.draft = OB.draft || {};
  keep("ob-nick", "nick"); keep("ob-room", "room"); keep("ob-server", "server"); keep("ob-pass", "pass");
  const c = { ...S.cfg, ...Object.fromEntries(Object.entries(OB.draft).filter(([k]) => k !== "pass")) };
  if (OB.draft.pass !== undefined) { c.password = OB.draft.pass; c.host_password = OB.draft.pass; }
  OB.mode = OB.mode || "join";
  body.innerHTML = `<h2>Kim jesteś w sesji?</h2>
    <label class="field"><span>Twój nick</span><input class="input" id="ob-nick" maxlength="40" placeholder="np. Ania" value="${esc(c.nick)}"></label>
    <div class="modes">
      <button class="mode ${OB.mode === "host" ? "on" : ""}" data-ob="mode-host"><b>Zakładam sesję</b><small>Serwer działa w tej aplikacji, znajomi łączą się do Ciebie</small></button>
      <button class="mode ${OB.mode === "join" ? "on" : ""}" data-ob="mode-join"><b>Dołączam</b><small>Mam adres od osoby, która założyła sesję</small></button>
    </div>
    ${OB.mode === "join" ? `<label class="field"><span>Adres serwera</span><input class="input" id="ob-server" placeholder="http://100.101.102.103:8765" value="${esc(c.server)}"><small>Dostaniesz go od osoby, która założyła sesję.</small></label>` : ""}
    <div class="form-grid">
      <label class="field"><span>Pokój</span><input class="input" id="ob-room" placeholder="nasz_kawalek" value="${esc(c.room)}"><small>Litery, cyfry, - _ .</small></label>
      <label class="field"><span>Hasło (opcjonalne)</span><input class="input" id="ob-pass" type="password" value="${esc(OB.mode === "host" ? c.host_password : c.password)}"></label>
    </div>`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">Wstecz</button><button class="btn primary big" data-ob="profile-save">Dalej</button>`;
  setTimeout(() => $("#ob-nick")?.focus(), 50);
}

async function obProfileSave() {
  const nick = $("#ob-nick").value.trim();
  const room = $("#ob-room").value.trim();
  const pass = $("#ob-pass").value.trim();
  if (!nick) return toast({ title: "Podaj swój nick", text: "Po nim inni zobaczą, co dodajesz do projektu." });
  if (!room) return toast({ title: "Podaj nazwę pokoju", text: "Wszyscy w tym samym pokoju pracują nad jednym projektem." });
  const cfg = { ...S.cfg, nick, room };
  if (OB.mode === "host") {
    cfg.host_password = pass;
    cfg.password = pass;
    cfg.server = `http://127.0.0.1:${cfg.host_port || 8765}`;
    cfg.host_on_start = true;
  } else {
    const server = $("#ob-server").value.trim();
    if (!server) return toast({ title: "Podaj adres serwera", text: "Dostaniesz go od osoby, która założyła sesję." });
    cfg.server = server;
    cfg.password = pass;
  }
  try {
    S.cfg = await invoke("save_config", { cfg });
    if (OB.mode === "host") S.host = await invoke("host_start", { port: S.cfg.host_port || 8765, password: S.cfg.host_password });
  } catch (e) { return fail(e); }
  OB.step = OB.detect?.found ? 3 : 4;
  obRender();
}

function obInstall(body, foot) {
  const info = OB.detect;
  body.innerHTML = `<h2>Instaluję mod do REAPERa</h2>
    <p>Do folderu REAPERa trafią:</p>
    <div class="checklist" id="ob-check">
      <div data-k="script">${icon("check")}<span>Skrypt REAPER Multiplayer ${esc(info.bundled_version)}</span></div>
      <div data-k="action">${icon("check")}<span>Akcja „Sesja – REAPER Multiplayer” w menu Actions</span></div>
      <div data-k="settings">${icon("check")}<span>Twój nick i adres sesji, żeby mod łączył się sam</span></div>
    </div>
    <label class="switch"><input type="checkbox" id="ob-auto" ${S.cfg.autostart_script ? "checked" : ""}><i></i><span>Otwieraj okno Sesji razem z REAPERem</span></label>
    ${info.running ? `<div class="notice">${icon("alert")}<span>REAPER jest teraz otwarty. Zamknij go przed instalacją, żeby zapisał nowe ustawienia.</span></div>` : ""}`;
  foot.innerHTML = `<button class="btn ghost" data-ob="back">Wstecz</button><button class="btn primary big" data-ob="install">Zainstaluj</button>`;
}

async function obDoInstall(btn) {
  btn.disabled = true;
  btn.innerHTML = `<div class="spinner"></div>Instaluję`;
  try {
    const autostart = $("#ob-auto").checked;
    const rep = await invoke("install_mod", { resource: OB.detect.resource, autostart });
    OB.report = rep;
    S.reaper = rep.info;
    const rows = [...document.querySelectorAll("#ob-check div")];
    for (let i = 0; i < rows.length; i++) {
      await new Promise((r) => setTimeout(r, 160));
      rows[i].classList.add("done");
    }
    await new Promise((r) => setTimeout(r, 350));
    OB.step = 4;
    obRender();
  } catch (e) {
    btn.disabled = false;
    btn.textContent = "Spróbuj ponownie";
    fail(e);
  }
}

async function obAction(act, el) {
  switch (act) {
    case "next": OB.step = Math.min(OB.step + 1, OB_STEPS.length - 1); return obRender();
    case "back": OB.step = Math.max(OB.step - 1, 0); return obRender();
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
  { id: "studio", label: "Studio", icon: "studio" },
  { id: "chat", label: "Wiadomości", icon: "chat" },
  { id: "music", label: "Nagrania", icon: "music" },
  { id: "comments", label: "Komentarze", icon: "comment" },
  "sep",
  { id: "reaper", label: "REAPER", icon: "reaper" },
  { id: "changes", label: "Zmiany", icon: "changes" },
  { id: "support", label: "Wspieraj", icon: "heart" },
  { id: "settings", label: "Ustawienia", icon: "settings" },
];

function renderNav() {
  $("#nav").innerHTML = VIEWS.map((v) =>
    v === "sep"
      ? `<div class="nav-sep"></div>`
      : `<button class="nav ${S.view === v.id ? "on" : ""}" data-view="${v.id}">${icon(v.icon)}<span>${v.label}</span>${
          v.id === "chat" && S.unread ? `<span class="badge">${S.unread > 99 ? "99+" : S.unread}</span>` : ""
        }</button>`
  ).join("");
}

function renderConn() {
  const s = S.session;
  const st = s ? s.status : "off";
  const label = { on: "Połączono", connecting: "Łączenie", error: "Brak połączenia", off: "Rozłączono" }[st];
  $("#conn").innerHTML = `<span class="dot ${st}"></span><div><b>${label}</b><small>${esc(s ? `Pokój ${s.room}` : S.host.running ? "Serwer działa" : "Nie jesteś w sesji")}</small></div>`;
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
  if (r) r();
  else if (!document.activeElement || !$("#view").contains(document.activeElement) || document.activeElement === document.body) {
    $("#view").innerHTML = (RENDER[S.view] || RENDER.studio)();
    AFTER[S.view]?.();
  }
}

/* ------------------------------------------------------------------ widoki */
const RENDER = {};
const AFTER = {};
const REFRESH = {};

function noSession(title, text) {
  return `<div class="panel empty">${icon("users")}<b>${esc(title)}</b><span>${esc(text)}</span>
    <button class="btn primary" data-view="studio">Przejdź do studia</button></div>`;
}

RENDER.studio = () => {
  const s = S.session;
  if (!s) return studioEmpty();
  return `
    <div class="head">
      <div>
        <h1 class="room-title">${esc(s.room)}</h1>
        <div class="room-sub">
          <span class="pill"><span class="dot ${s.status}"></span>${{ on: "Połączono", connecting: "Łączenie", error: "Brak połączenia" }[s.status] || ""}</span>
          <span>${esc(s.server)}</span>
        </div>
      </div>
      <div class="actions">
        ${S.reaper?.exe ? `<button class="btn ghost" data-act="launch">${icon("reaper")}Otwórz REAPERa</button>` : ""}
        <button class="btn ghost" data-act="disconnect">Rozłącz</button>
      </div>
    </div>
    ${s.error ? `<div class="notice" style="margin-bottom:18px">${icon("alert")}<span>${esc(s.error)}</span></div>` : ""}
    <div class="studio-grid">
      <div class="stack">
        <section class="panel"><h2>W sesji <span class="muted" id="people-n"></span></h2><div class="people" id="people"></div></section>
        <section class="panel"><h2>Ścieżki <span class="muted" id="tracks-n"></span></h2><div class="tracks" id="tracks"></div></section>
      </div>
      <section class="panel"><h2>Co się dzieje</h2><div class="feed" id="feed"></div></section>
    </div>
    ${S.host.running ? `<div style="margin-top:18px">${hostPanel()}</div>` : ""}`;
};

function studioEmpty() {
  return `
    <div class="head"><div><h1>Studio</h1><p>Załóż sesję u siebie albo dołącz do kogoś, kto już ją prowadzi.</p></div></div>
    ${S.host.running ? `<div style="margin-bottom:18px">${hostPanel()}</div>` : ""}
    <div class="choice-grid">
      <section class="panel choice">
        ${icon("server").replace("<svg", '<svg style="width:28px;height:28px;color:var(--amber)"')}
        <h3>Zakładam sesję</h3>
        <p>Serwer uruchomi się w tej aplikacji. Wyślesz znajomym adres, a oni połączą się do Ciebie.
        Przez internet najprościej działa to z Tailscale.</p>
        <button class="btn primary" data-act="host-and-join">${S.host.running ? "Dołącz do własnej sesji" : "Uruchom serwer i dołącz"}</button>
      </section>
      <section class="panel choice">
        ${icon("link").replace("<svg", '<svg style="width:28px;height:28px;color:var(--signal)"')}
        <h3>Dołączam do sesji</h3>
        <p>Wpisz adres od osoby, która założyła sesję, i nazwę pokoju.</p>
        <div class="field"><input class="input" id="join-server" placeholder="http://100.101.102.103:8765" value="${esc(S.cfg.server)}"></div>
        <div class="form-grid">
          <input class="input" id="join-room" placeholder="pokój" value="${esc(S.cfg.room)}">
          <input class="input" id="join-pass" type="password" placeholder="hasło (opcjonalne)" value="${esc(S.cfg.password)}">
        </div>
        <button class="btn primary" data-act="join">Dołącz</button>
      </section>
    </div>`;
}

function hostPanel() {
  const a = S.host.addresses || [];
  return `<section class="panel">
    <h2>${icon("server").replace("<svg", '<svg style="width:18px;height:18px;color:var(--amber)"')}Twój serwer działa <span class="muted">port ${S.host.port}</span></h2>
    <p class="muted">Wyślij znajomym jeden z tych adresów. Spoza Twojej sieci zadziała adres Tailscale.</p>
    ${a.map((x) => `<div class="addr"><code>${esc(x.url)}</code><small>${esc(x.kind)}</small>
      <button class="btn icon ghost" title="Kopiuj" data-copy="${esc(x.url)}">${icon("copy")}</button></div>`).join("")}
    <div class="row" style="margin-top:14px"><button class="btn danger" data-act="host-stop">Zatrzymaj serwer</button></div>
  </section>`;
}

function peopleHtml(s) {
  const users = s.users || [];
  if (!users.length) return `<div class="empty">Nikogo jeszcze nie ma. Otwórz REAPERa – pojawisz się tutaj.</div>`;
  return users.map((u) => {
    const state = u.app ? `<span class="state">w aplikacji</span>`
      : u.rec ? `<span class="state rec">nagrywa · ${fmtPos(u.pos)}</span>`
      : u.play ? `<span class="state">${icon("play").replace("<svg", '<svg style="width:12px;height:12px"')}${fmtPos(u.pos)}</span>`
      : `<span class="state num">${fmtPos(u.pos)}</span>`;
    return `<div class="person"><div class="avatar" style="background:${esc(u.color)}">${initial(u.name)}</div>
      <div><b>${esc(u.name)}${u.name === s.me ? " (Ty)" : ""}</b><small>${esc(u.sel ? "ścieżka „" + u.sel + "”" : u.app ? "Sesja" : "REAPER")}</small></div>${state}</div>`;
  }).join("");
}

function tracksHtml(s) {
  if (!s.tracks.length) return `<div class="empty">Projekt jest pusty. Dodaj ścieżkę w REAPERze, a zobaczysz ją tutaj.</div>`;
  const count = {};
  for (const it of s.items) count[it.track] = (count[it.track] || 0) + 1;
  return s.tracks.map((t) => `<div class="track"><div class="bar" style="background:${esc(colorOf(t.author))}"></div>
    <div><b>${esc(t.name)}</b><small>autor: ${esc(t.author)}${t.editor && t.editor !== t.author ? ` · ostatnie zmiany: ${esc(t.editor)}` : ""}</small></div>
    <span class="n num">${count[t.guid] || 0} ${plural(count[t.guid] || 0, "klip", "klipy", "klipów")}</span></div>`).join("");
}

function plural(n, one, few, many) {
  if (n === 1) return one;
  const d = n % 10, dd = n % 100;
  return d >= 2 && d <= 4 && (dd < 12 || dd > 14) ? few : many;
}

function feedKey(e) { return `${e.ts}|${e.user}|${e.kind}|${e.text}`; }

function feedHtml(s) {
  const list = s.feed.filter((e) => e.kind !== "chat").slice(-120).reverse();
  if (!list.length) return `<div class="empty">Tu zobaczysz, kto co dodaje i zmienia w projekcie.</div>`;
  return list.map((e) => {
    const k = feedKey(e);
    const fresh = S.seenKeys.size && !S.seenKeys.has(k);
    const text = e.kind === "comment"
      ? `komentuje${e.item_name ? ` „${esc(e.item_name)}”` : ""} @ ${fmtPos(e.pos)}: ${esc(e.text)}`
      : esc(e.text);
    return `<div class="ev ${e.kind} ${fresh ? "fresh" : ""}"><time class="num">${fmtClock(e.ts)}</time>
      <div><b style="color:${esc(colorOf(e.user))}">${esc(e.user)}</b> <span class="t">${text}</span></div></div>`;
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
  if (pill) pill.innerHTML = `<span class="dot ${s.status}"></span>${{ on: "Połączono", connecting: "Łączenie", error: "Brak połączenia" }[s.status] || ""}`;
};
AFTER.studio = () => S.session && REFRESH.studio();

/* --- czat --- */
RENDER.chat = () => {
  if (!S.session) return `<div class="head"><div><h1>Wiadomości</h1></div></div>` + noSession("Nie jesteś w sesji", "Połącz się z sesją, żeby pisać z pozostałymi.");
  return `<div class="head"><div><h1>Wiadomości</h1><p>Czat widzą wszyscy w pokoju – także w oknie Sesji w REAPERze.</p></div></div>
    <div class="chat"><div class="msgs" id="msgs"></div>
      <form class="composer" id="chat-form"><input class="input" id="chat-input" maxlength="1000" placeholder="Napisz wiadomość" autocomplete="off">
      <button class="btn primary">${icon("send")}Wyślij</button></form></div>`;
};
function msgsHtml(s) {
  const list = s.feed.filter((e) => e.kind === "chat" || e.kind === "comment");
  if (!list.length) return `<div class="empty">${icon("chat")}Napisz pierwszą wiadomość.</div>`;
  return list.map((e) => {
    const fresh = S.seenKeys.size && !S.seenKeys.has(feedKey(e));
    if (e.kind === "comment") {
      return `<div class="msg note ${fresh ? "fresh" : ""}"><div class="bubble">${esc(e.user)} komentuje${e.item_name ? ` „${esc(e.item_name)}”` : ""} @ ${fmtPos(e.pos)}: ${esc(e.text)}</div></div>`;
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
  if (!S.session) return `<div class="head"><div><h1>Nagrania</h1></div></div>` + noSession("Nie jesteś w sesji", "Tutaj pojawią się wszystkie nagrania z projektu.");
  return `<div class="head"><div><h1>Nagrania</h1><p>Wszystkie klipy audio z projektu. Posłuchaj, kto co nagrał, bez otwierania REAPERa.</p></div></div>
    <div class="filters" id="filters"></div><div class="clips" id="clips"></div>`;
};
function musicItems() {
  const s = S.session;
  return s.items.filter((i) => i.file && !i.midi && (!S.musicFilter || i.author === S.musicFilter));
}
REFRESH.music = () => {
  const s = S.session;
  if (!s || !$("#clips")) return renderView(false);
  const authors = [...new Set(s.items.filter((i) => i.file && !i.midi).map((i) => i.author))];
  $("#filters").innerHTML = authors.length > 1
    ? `<button class="chip ${!S.musicFilter ? "on" : ""}" data-filter="">Wszyscy</button>` +
      authors.map((a) => `<button class="chip ${S.musicFilter === a ? "on" : ""}" data-filter="${esc(a)}"><i style="background:${esc(colorOf(a))}"></i>${esc(a)}</button>`).join("")
    : "";
  const tname = Object.fromEntries(s.tracks.map((t) => [t.guid, t.name]));
  const items = musicItems();
  const box = $("#clips");
  const ids = items.map((i) => i.guid).join(",");
  if (box.dataset.ids === ids) return; // nic się nie zmieniło – nie przerywaj odtwarzania
  box.dataset.ids = ids;
  box.innerHTML = items.length ? items.map((it) => `
    <div class="clip" data-guid="${esc(it.guid)}">
      <button class="play ${S.audio.id === it.file ? "on" : ""}" data-play="${esc(it.file)}" aria-label="Odtwórz">${icon(S.audio.id === it.file && !S.audio.el.paused ? "pause" : "play")}</button>
      <div><b>${esc(it.name)}</b><small>${esc(tname[it.track] || "?")} · ${fmtPos(it.pos)}</small></div>
      <canvas class="wave" data-wave="${esc(it.file)}" data-len="${it.len}"></canvas>
      <div class="meta"><span class="by"><i style="background:${esc(colorOf(it.author))}"></i>${esc(it.author)}</span><span class="num">${fmtPos(it.len)} · ${fmtClock(it.created)}</span></div>
    </div>`).join("")
    : `<div class="panel empty">${icon("music")}Nie ma jeszcze nagrań audio. Nagraj coś w REAPERze – pojawi się tutaj.</div>`;
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
    toast({ title: "Nie mogę odtworzyć tego nagrania", text: "Sprawdź, czy komputer ma działające wyjście audio. Nagranie możesz też odsłuchać w REAPERze.", timeout: 6000 });
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
  if (!S.session) return `<div class="head"><div><h1>Komentarze</h1></div></div>` + noSession("Nie jesteś w sesji", "Komentarze przypinasz do miejsca w utworze albo do konkretnego klipu.");
  const s = S.session;
  const tname = Object.fromEntries(s.tracks.map((t) => [t.guid, t.name]));
  const items = [...s.items].sort((a, b) => a.pos - b.pos);
  return `<div class="head"><div><h1>Komentarze</h1><p>Przypnij uwagę do miejsca w utworze albo do konkretnego klipu, np. wokalu. W REAPERze pojawi się jako znacznik.</p></div></div>
    <form class="panel cmt-form" id="cmt-form">
      <label class="field"><span>Komentarz</span><input class="input" id="cmt-text" maxlength="500" placeholder="np. w refrenie wejdź pół taktu później"></label>
      <label class="field"><span>Klip</span><select class="input" id="cmt-item"><option value="">Cały utwór</option>
        ${items.map((i) => `<option value="${esc(i.guid)}" data-pos="${i.pos}" data-name="${esc(i.name)}">${esc(i.name)} (${esc(tname[i.track] || "?")})</option>`).join("")}</select></label>
      <label class="field"><span>Miejsce</span><input class="input num" id="cmt-pos" value="0:00" placeholder="1:23"></label>
      <button class="btn primary">Dodaj</button>
    </form>
    <div class="cmts" id="cmts"></div>`;
};
REFRESH.comments = () => {
  const box = $("#cmts");
  if (!box) return renderView(false);
  const list = [...S.session.comments].reverse();
  box.innerHTML = list.length ? list.map((c) => `
    <div class="cmt"><div class="avatar" style="background:${esc(colorOf(c.user))}">${initial(c.user)}</div>
      <div><div class="where">${c.item_name ? `Klip „${esc(c.item_name)}” · ` : ""}${fmtPos(c.pos)}</div>
      <div class="body">${esc(c.text)}</div><small>${esc(c.user)} · ${fmtClock(c.ts)}</small></div>
      ${c.mine ? `<button class="btn icon ghost" title="Usuń komentarz" data-del-comment="${esc(c.id)}">${icon("x")}</button>` : "<span></span>"}
    </div>`).join("")
    : `<div class="panel empty">${icon("comment")}Brak komentarzy. Dodaj pierwszy – np. do wokalu, który trzeba poprawić.</div>`;
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
      toast({ title: "Komentarz dodany", text: "Zobaczą go wszyscy w pokoju." });
    } catch (err) { fail(err); }
  });
};

/* --- REAPER --- */
RENDER.reaper = () => {
  const r = S.reaper || {};
  const upToDate = r.script_installed && r.script_version === r.bundled_version;
  return `<div class="head"><div><h1>REAPER</h1><p>Mod REAPER Multiplayer synchronizuje projekt i pokazuje okno Sesji w REAPERze.</p></div>
      <div class="actions"><button class="btn ghost" data-act="redetect">${icon("refresh")}Sprawdź ponownie</button></div></div>
    <div class="stack">
      <section class="panel">
        <h2>Instalacja</h2>
        ${r.found ? `<dl class="kv">
          <dt>Program</dt><dd>${esc(r.exe || "nie wiem, gdzie jest plik programu")}</dd>
          <dt>Folder ustawień</dt><dd>${esc(r.resource || "?")}</dd>
          <dt>Mod</dt><dd>${r.script_installed ? `<span class="${upToDate ? "ok" : "warn"}">wersja ${esc(r.script_version)}${upToDate ? ", aktualna" : `, dostępna ${esc(r.bundled_version)}`}</span>` : `<span class="bad">nie zainstalowany</span>`}</dd>
          <dt>Uruchamianie</dt><dd>${r.autostart ? "razem z REAPERem" : "ręcznie z menu Actions"}</dd>
          <dt>REAPER teraz</dt><dd>${r.running ? "otwarty" : "zamknięty"}</dd>
        </dl>` : `<div class="found miss"><div class="ic">${icon("x")}</div><div><b>Nie znaleziono REAPERa</b><small>Wskaż folder, w którym jest zainstalowany.</small></div></div>`}
        ${r.running ? `<div class="notice" style="margin-top:16px">${icon("alert")}<span>Po instalacji lub aktualizacji zamknij i otwórz REAPERa ponownie.</span></div>` : ""}
        <div class="row" style="margin-top:18px">
          ${r.found ? `<button class="btn primary" data-act="install">${icon("download")}${r.script_installed ? (upToDate ? "Zainstaluj ponownie" : "Zaktualizuj mod") : "Zainstaluj mod"}</button>` : ""}
          <button class="btn ghost" data-act="pick">${icon("folder")}Wskaż folder REAPERa</button>
          ${r.resource ? `<button class="btn ghost" data-act="open-res">Otwórz folder ustawień</button>` : ""}
          ${r.exe ? `<button class="btn ghost" data-act="launch">${icon("reaper")}Otwórz REAPERa</button>` : ""}
        </div>
      </section>
      ${r.found ? `<section class="panel"><h2>Opcje</h2>
        <label class="switch"><input type="checkbox" id="auto-toggle" ${r.autostart ? "checked" : ""}><i></i><span>Otwieraj okno Sesji razem z REAPERem</span></label>
        ${r.script_installed ? `<div class="row" style="margin-top:18px"><button class="btn danger" data-act="uninstall">Odinstaluj mod</button></div>` : ""}
      </section>` : ""}
      <section class="panel"><h2>Jak używać w REAPERze</h2>
        <div class="md"><ul>
          <li>Okno Sesji otwiera się samo albo z <code>Actions → Sesja – REAPER Multiplayer</code>.</li>
          <li>Nagrywaj normalnie – po zatrzymaniu nagranie trafi do wszystkich.</li>
          <li>Zaznacz klip i kliknij <code>Komentarz do „…”</code>, żeby przypiąć uwagę do tego klipu.</li>
          <li>Zaznacz klip albo ścieżkę, a u góry okna zobaczysz, kto ją dodał.</li>
        </ul></div>
      </section>
    </div>`;
};
AFTER.reaper = () => {
  $("#auto-toggle")?.addEventListener("change", async (e) => {
    try {
      const rep = await invoke("install_mod", { resource: S.reaper.resource, autostart: e.target.checked });
      S.reaper = rep.info;
      toast({ title: e.target.checked ? "Okno Sesji otworzy się z REAPERem" : "Okno Sesji tylko z menu Actions" });
      renderView(false);
    } catch (err) { fail(err); }
  });
};

/* --- zmiany --- */
RENDER.changes = () => `<div class="head"><div><h1>Zmiany</h1><p>Co nowego w kolejnych wersjach.</p></div>
    <div class="actions"><button class="btn ghost" data-act="check-update">${icon("refresh")}Sprawdź aktualizacje</button></div></div>
  <div class="panel md" id="changes">${S.releases ? releasesHtml(S.releases) : md(S.changelog || "")}</div>`;
function releasesHtml(list) {
  if (!list.length) return md(S.changelog || "");
  return list.map((r) => `<div class="release"><div class="tag"><h2>${esc(r.name || r.tag)}</h2><span class="muted">${esc((r.date || "").slice(0, 10))}</span></div>${md(r.body || "")}</div>`).join("");
}
AFTER.changes = () => {
  if (S.releases) return;
  invoke("check_update").then((u) => {
    if (u.releases?.length) {
      S.releases = u.releases;
      if (S.view === "changes") $("#changes").innerHTML = releasesHtml(S.releases);
    }
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
      <h2>Sesja jest darmowa i ma otwarty kod</h2>
      <p>Każdy może zajrzeć do kodu, zgłosić błąd albo dopisać funkcję. Jeśli Sesja oszczędza Ci godziny
      przesyłania plików między studiami, możesz postawić twórcy kawę – to pomaga rozwijać kolejne wersje.</p>
      <div class="row" style="margin-top:20px">
        <button class="btn ghost" data-url="${LINKS.repo}">${icon("github")}Kod na GitHubie</button>
        <button class="btn ghost" data-url="${LINKS.issues}">Zgłoś błąd lub pomysł</button>
      </div>
    </div>
    <img src="img/logo.svg" alt="">
  </div>
  <div class="donate">${LINKS.donate.map((d) => `<button data-url="${esc(d.url)}"><b>${esc(d.name)}</b><small>${esc(d.note)}</small></button>`).join("")}</div>`;

/* --- ustawienia --- */
RENDER.settings = () => {
  const c = S.cfg;
  return `<div class="head"><div><h1>Ustawienia</h1></div></div>
  <div class="stack">
    <form class="panel" id="set-profile">
      <h2>Ty i sesja</h2>
      <div class="form-grid">
        <label class="field"><span>Nick</span><input class="input" name="nick" maxlength="40" value="${esc(c.nick)}"></label>
        <label class="field"><span>Pokój</span><input class="input" name="room" value="${esc(c.room)}"></label>
        <label class="field"><span>Adres serwera</span><input class="input" name="server" value="${esc(c.server)}"></label>
        <label class="field"><span>Hasło serwera</span><input class="input" name="password" type="password" value="${esc(c.password)}"><small>Tylko litery, cyfry i . _ -</small></label>
      </div>
      <div class="row" style="margin-top:18px"><button class="btn primary">Zapisz i połącz ponownie</button>
        ${S.reaper?.script_installed ? `<span class="muted">Zapiszę też te dane w REAPERze.</span>` : ""}</div>
    </form>
    <form class="panel" id="set-host">
      <h2>Mój serwer</h2>
      <div class="form-grid">
        <label class="field"><span>Port</span><input class="input num" name="host_port" type="number" min="1024" max="65535" value="${c.host_port}"></label>
        <label class="field"><span>Hasło</span><input class="input" name="host_password" type="password" value="${esc(c.host_password)}"></label>
      </div>
      <label class="switch" style="margin-top:16px"><input type="checkbox" name="host_on_start" ${c.host_on_start ? "checked" : ""}><i></i><span>Uruchamiaj serwer razem z aplikacją</span></label>
      <div class="row" style="margin-top:18px">
        <button class="btn primary">${S.host.running ? "Zapisz i uruchom ponownie" : "Uruchom serwer"}</button>
        ${S.host.running ? `<button type="button" class="btn danger" data-act="host-stop">Zatrzymaj</button>` : ""}
      </div>
    </form>
    <section class="panel">
      <h2>Aktualizacje</h2>
      <label class="switch"><input type="checkbox" id="auto-update" ${c.auto_update ? "checked" : ""}><i></i><span>Sprawdzaj aktualizacje przy uruchomieniu</span></label>
      <div class="row" style="margin-top:18px"><button class="btn ghost" data-act="check-update">${icon("refresh")}Sprawdź teraz</button>
        <span class="muted">Masz wersję ${esc(S.info.version)}</span></div>
    </section>
    <section class="panel">
      <h2>Instalator powitalny</h2>
      <p class="muted">Przejdź jeszcze raz przez wyszukiwanie REAPERa i instalację moda.</p>
      <div class="row" style="margin-top:14px"><button class="btn ghost" data-act="rerun-onboarding">Uruchom ponownie</button></div>
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
        if (rep.warning) toast({ title: "Zapisano w REAPERze", text: rep.warning, timeout: 8000 });
      }
      await connect();
      toast({ title: "Zapisano", text: `Łączę z pokojem „${S.cfg.room}”.` });
      renderView(false);
    } catch (err) { fail(err); }
  });
  $("#set-host").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      S.cfg = await invoke("save_config", { cfg: { ...S.cfg, host_port: +f.get("host_port") || 8765, host_password: f.get("host_password"), host_on_start: f.get("host_on_start") === "on" } });
      S.host = await invoke("host_start", { port: S.cfg.host_port, password: S.cfg.host_password });
      toast({ title: "Serwer działa", text: `Port ${S.host.port}. Adresy do wysłania znajdziesz w Studiu.` });
      renderConn();
      renderView(false);
    } catch (err) { fail(err); }
  });
  $("#auto-update").addEventListener("change", async (e) => {
    S.cfg = await invoke("save_config", { cfg: { ...S.cfg, auto_update: e.target.checked } });
  });
};

/* ------------------------------------------------------------------ akcje */
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
  async launch() { try { await invoke("launch_reaper"); toast({ title: "Otwieram REAPERa" }); } catch (e) { fail(e); } },
  async "host-stop"() { await invoke("host_stop"); S.host = { running: false }; S.cfg = await invoke("save_config", { cfg: { ...S.cfg, host_on_start: false } }); renderConn(); renderView(false); },
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
    if (!server || !room) return toast({ title: "Podaj adres serwera i pokój" });
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
      toast({ title: "Mod zainstalowany", text: rep.warning || `Wersja ${rep.info.script_version}.`, timeout: 7000 });
      renderView(false);
    } catch (e) { fail(e); }
  },
  async uninstall() {
    toast({
      title: "Odinstalować mod?",
      text: "Usunę skrypt, akcję i autostart. Twoje projekty zostaną nietknięte.",
      actions: [
        { label: "Anuluj", fn: (close) => close() },
        { label: "Odinstaluj", primary: true, fn: async (close) => {
          close();
          try { await invoke("uninstall_mod", { resource: S.reaper.resource }); S.reaper = await invoke("detect_reaper"); renderView(false); toast({ title: "Mod odinstalowany" }); } catch (e) { fail(e); }
        } },
      ],
    });
  },
  "open-res"() { invoke("open_path", { path: S.reaper.resource }).catch(fail); },
  async "check-update"() { await checkUpdates(true); },
  "rerun-onboarding"() { OB.step = 0; OB.report = null; obShow(); },
};

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-view],[data-act],[data-ob],[data-url],[data-copy],[data-play],[data-filter],[data-del-comment],canvas.wave");
  if (!t) return;
  if (t.dataset.view) return go(t.dataset.view);
  if (t.dataset.act) return ACTIONS[t.dataset.act]?.(t);
  if (t.dataset.ob) return obAction(t.dataset.ob, t);
  if (t.dataset.url) { e.preventDefault(); return invoke("open_url", { url: t.dataset.url }).catch(fail); }
  if (t.dataset.copy) {
    navigator.clipboard?.writeText(t.dataset.copy).then(() => toast({ title: "Skopiowano adres", text: t.dataset.copy }), fail);
    return;
  }
  if (t.dataset.play) return togglePlay(t.dataset.play, t);
  if (t.dataset.filter !== undefined) { S.musicFilter = t.dataset.filter || null; $("#clips").dataset.ids = ""; return REFRESH.music(); }
  if (t.dataset.delComment) return invoke("delete_comment", { id: t.dataset.delComment }).catch(fail);
  if (t.matches("canvas.wave") && S.audio.id === t.dataset.wave && S.audio.el.duration) {
    const r = t.getBoundingClientRect();
    S.audio.el.currentTime = ((e.clientX - r.left) / r.width) * S.audio.el.duration;
    drawWave(t);
  }
});

window.addEventListener("resize", debounce(drawAllWaves, 120));

/* ------------------------------------------------------------------ aktualizacje */
async function checkUpdates(manual) {
  let u;
  try { u = await invoke("check_update"); } catch (e) { if (manual) fail(e); return; }
  if (u.releases?.length) S.releases = u.releases;
  if (!u.newer) { if (manual) toast({ title: "Masz najnowszą wersję", text: `Sesja ${u.current}` }); return; }
  if (!u.asset_url) {
    toast({ title: `Dostępna wersja ${u.latest}`, text: "Pobierz ją ze strony projektu.", actions: [{ label: "Otwórz", primary: true, fn: (c) => { c(); invoke("open_url", { url: `${LINKS.repo}/releases/latest` }); } }] });
    return;
  }
  toast({
    title: `Nowa wersja ${u.latest}`,
    text: (u.notes || "").split("\n").find((l) => l.trim() && !l.startsWith("#"))?.replace(/^[-*]\s*/, "") || "Poprawki i nowe funkcje.",
    actions: [
      { label: "Później", fn: (c) => c() },
      { label: "Zainstaluj", primary: true, fn: async (close) => {
        close();
        const t = toast({ title: `Pobieram wersję ${u.latest}`, progress: true });
        try { await invoke("install_update", { url: u.asset_url, name: u.asset_name }); }
        catch (e) { t.close(); fail(e); }
      } },
    ],
  });
}

/* ------------------------------------------------------------------ zdarzenia sesji */
let lastChatCount = 0;
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
  // komentarze od innych – krótkie powiadomienie
  if (prev) {
    const known = new Set(prev.comments.map((c) => c.id));
    for (const c of sum.comments) if (!known.has(c.id) && !c.mine) toast({ title: `${c.user} dodaje komentarz`, text: c.text });
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
  await listen("session", onSession);
  await listen("update-progress", ([done, total]) => {
    const el = document.querySelector(".toast .progress i");
    if (el && total) el.style.width = `${Math.round((done / total) * 100)}%`;
  });
  if (!cfg.onboarded) {
    obShow();
  } else {
    startApp();
    if (cfg.nick && cfg.server && cfg.room) connect().catch(() => {});
  }
  if (cfg.auto_update) setTimeout(() => checkUpdates(false), 2500);
}

boot().catch((e) => {
  document.body.innerHTML = `<div style="padding:40px;font:16px system-ui;color:#eae3d2">Nie udało się uruchomić aplikacji: ${esc(e)}</div>`;
});
