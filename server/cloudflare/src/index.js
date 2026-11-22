// Sesja – serwer na Cloudflare Workers + Durable Objects.
// Ten sam protokół co server/rmp_server.py i serwer wbudowany w aplikację, więc mod
// w REAPERze i aplikacja Sesja łączą się z nim bez zmian – wystarczy adres https.
//
// Worker jest cienkim routerem (sprawdza hasło, wybiera pokój). Każdy pokój to osobny
// Durable Object z bazą SQLite: projekt, log operacji, czat, komentarze i pliki audio
// (w kawałkach po 1 MiB, więc nie potrzeba R2).

import { DurableObject } from "cloudflare:workers";

const VERSION = "1.3.0";
const SAFE = /^[A-Za-z0-9._~-]{1,200}$/;
const MAX_OPS_PER_RESPONSE = 400;
const MAX_LOG = 5000; // ile operacji trzymamy (starsze -> klient robi pełną synchronizację)
const MAX_CHAT = 500;
const ONLINE_TIMEOUT = 15; // s
const CHUNK = 1024 * 1024; // kawałek pliku audio w bazie
const MAX_UPLOAD = 95 * 1024 * 1024; // limit żądania w Workers to 100 MB
// Duże pliki (np. bit w WAV) przychodzą w częściach po 8 MiB: brak limitu rozmiaru,
// postęp i ponawianie pojedynczych części zamiast całego pliku.
const PART = 8 * 1024 * 1024;
const MAX_FILE = 2 * 1024 * 1024 * 1024; // 2 GiB na plik
// ochrona przed spamem
const MAX_USERS = 20; // osób naraz w jednej sesji
const MAX_OPS_IN = 2000; // operacji w jednym żądaniu
const MAX_TEXT = 2000; // znaków w wiadomości / komentarzu
const CHAT_BURST = 10, CHAT_WINDOW = 20; // max 10 wiadomości na 20 s na osobę
const REQ_BURST = 120, REQ_WINDOW = 10; // max 120 żądań na 10 s na połączenie
const ROOMS_PER_HOUR = 20; // nowych sesji z jednego adresu IP
const DECISIONS = new Set(["req_ok", "req_no", "draft_ok", "draft_no"]);
const PALETTE = [
  "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6",
  "#bcf60c", "#fabebe", "#008080", "#e6beff", "#9a6324", "#fffac8", "#aaffc3", "#ffd8b1",
];

// odpowiedź JSON; klient Lua sprawdza, że kończy się na "_end":true
function json(obj, status = 200) {
  const o = { ...obj };
  delete o._end;
  o._end = true;
  return new Response(JSON.stringify(o), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}
const err = (status, code, msg) => json({ ok: false, code, error: msg }, status);
const now = () => Date.now() / 1000;

// kolor użytkownika – ten sam co w Pythonie/Ruście: PALETTE[md5(nick) % 16]
async function userColor(name) {
  const h = new Uint8Array(await crypto.subtle.digest("MD5", new TextEncoder().encode(name)));
  return PALETTE[h[15] & 0x0f];
}

// kod sesji: 10 znaków bez mylących (0/o, 1/l/i)
const CODE_ABC = "abcdefghjkmnpqrstuvwxyz23456789";
function newCode() {
  const b = crypto.getRandomValues(new Uint8Array(10));
  return [...b].map((x) => CODE_ABC[x % CODE_ABC.length]).join("");
}
async function sha256(s) {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return [...h].map((x) => x.toString(16).padStart(2, "0")).join("");
}
const htmlEsc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const ROOM_PATHS = new Set(["/api/state", "/api/sync", "/api/file", "/api/room"]);
const DOWNLOAD = "https://github.com/Krixishere/Sesja/releases/latest";

function page(title, body) {
  return new Response(
    `<!doctype html><html lang="pl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${htmlEsc(title)}</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(1200px 600px at 20% -10%,#2a2440 0,transparent 60%),radial-gradient(900px 500px at 110% 110%,#173a3a 0,transparent 55%),#0e1424;color:#eae3d2;font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
.card{width:min(520px,100%);background:rgba(255,255,255,.04);border:1px solid rgba(234,227,210,.12);border-radius:22px;padding:32px;box-shadow:0 30px 80px rgba(0,0,0,.45);animation:in .7s cubic-bezier(.2,.8,.2,1)}
@keyframes in{from{opacity:0;transform:translateY(14px) scale(.98);filter:blur(6px)}}
.k{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#f3a73b}h1{margin:6px 0 4px;font-size:34px;line-height:1.1;letter-spacing:-.02em}
p{color:rgba(234,227,210,.72)}code{display:block;margin:14px 0;padding:12px 14px;border-radius:12px;background:#0a0f1c;border:1px solid rgba(234,227,210,.1);font:14px ui-monospace,monospace;word-break:break-all}
ol{padding-left:20px;color:rgba(234,227,210,.85)}li{margin:6px 0}a.b{display:inline-block;margin-top:14px;padding:12px 18px;border-radius:12px;background:#f3a73b;color:#1a1408;font-weight:600;text-decoration:none}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}.row a.b{margin-top:0}a.b.g{background:transparent;color:#eae3d2;box-shadow:inset 0 0 0 1px rgba(234,227,210,.22)}
.hint{display:none;margin-top:14px;font-size:14px;color:#f3a73b}.hint.on{display:block;animation:in .5s}
.bars{display:flex;gap:4px;height:26px;align-items:flex-end;margin-bottom:14px}.bars i{width:5px;border-radius:3px;background:#f3a73b;animation:b 1.1s ease-in-out infinite}
.bars i:nth-child(2){animation-delay:-.2s;background:#5fc9b5}.bars i:nth-child(3){animation-delay:-.4s}.bars i:nth-child(4){animation-delay:-.6s;background:#f0524f}.bars i:nth-child(5){animation-delay:-.8s}
@keyframes b{0%,100%{height:30%}50%{height:100%}}@media (prefers-reduced-motion:reduce){*{animation:none!important}}
</style><div class="card"><div class="bars"><i></i><i></i><i></i><i></i><i></i></div>${body}</div></html>`,
    { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } },
  );
}

async function createRoom(request, env, url) {
  let b;
  try { b = await request.json(); } catch { return err(400, "bad_json", "Invalid JSON"); }
  const name = String(b.name || "").trim().slice(0, 60);
  if (!name) return err(400, "bad_name", "Session name is required");
  const password = String(b.password || "");
  if (password.length > 200) return err(400, "bad_password", "Password too long");
  // limit zakładania sesji z jednego adresu
  const ip = request.headers.get("CF-Connecting-IP") || "local";
  const lim = await env.ROOMS.get(env.ROOMS.idFromName("__limit:" + ip)).fetch("https://room/__limit", { method: "POST" });
  if (lim.status === 429) return err(429, "slow_down", "Too many new sessions, try again later");
  // klucz gospodarza: tylko twórca sesji go dostaje – daje prawa administratora
  const adminKey = [...crypto.getRandomValues(new Uint8Array(18))].map((x) => CODE_ABC[x % CODE_ABC.length]).join("");
  for (let i = 0; i < 4; i++) {
    const code = newCode();
    const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
    const r = await stub.fetch("https://room/__init", { method: "POST", body: JSON.stringify({ name, password, adminKey }) });
    if (r.status === 409) continue;
    const link = `${url.origin}/s/${code}`;
    return json({ ok: true, room: code, name, link, server: url.origin, has_password: !!password, admin_key: adminKey });
  }
  return err(500, "busy", "Could not create a session, try again");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const central = !!env.CENTRAL;
    if (url.pathname === "/" || url.pathname === "/api/ping") {
      if (url.pathname === "/" && (request.headers.get("Accept") || "").includes("text/html")) {
        return page("Sesja", `<div class="k">Sesja</div><h1>Serwer działa</h1><p>Wspólne nagrywanie w REAPERze – z każdego miasta naraz. Załóż sesję w aplikacji Sesja i wyślij znajomym link.</p><a class="b" href="${DOWNLOAD}">Pobierz Sesję</a>`);
      }
      return json({ ok: true, app: "Sesja", cloud: true, version: VERSION, auth: !!env.PASSWORD, rooms: true, central });
    }
    // strona zaproszenia: https://serwer/s/<kod>
    const inv = url.pathname.match(/^\/s\/([a-z0-9]{4,40})\/?$/);
    if (inv && request.method === "GET") {
      const info = await (await env.ROOMS.get(env.ROOMS.idFromName(inv[1])).fetch("https://room/api/room")).json();
      if (!info.exists) return page("Sesja", `<div class="k">Sesja</div><h1>Nie ma takiej sesji</h1><p>Link jest niepełny albo sesja została usunięta. Poproś o nowy link.</p>`);
      const deep = `sesja://join/${url.host}/${inv[1]}`;
      return page(`Sesja – ${info.name}`, `<div class="k">Zaproszenie do sesji</div><h1>${htmlEsc(info.name)}</h1>
        <p>Ktoś zaprasza Cię do wspólnego nagrywania w REAPERze.</p>
        <div class="row"><a class="b" id="open" href="${htmlEsc(deep)}">Otwórz w Sesji</a><a class="b g" href="${DOWNLOAD}">Pobierz Sesję</a></div>
        <p class="hint" id="hint">Nic się nie otworzyło? Zainstaluj Sesję (Windows, macOS, Linux) i kliknij jeszcze raz.</p>
        <p>Albo ręcznie: w Studiu wybierz <b>Dołącz przez link</b> i wklej:</p><code>${htmlEsc(url.origin + url.pathname)}</code>
        ${info.has_password ? "<p>Hasło dostaniesz od osoby, która Cię zaprosiła.</p>" : ""}
        <script>document.getElementById("open").addEventListener("click",function(){var h=document.getElementById("hint");var t=setTimeout(function(){if(!document.hidden)h.classList.add("on")},1800);window.addEventListener("blur",function(){clearTimeout(t)},{once:true})});</script>`);
    }
    if (env.PASSWORD && request.headers.get("X-RMP-Key") !== env.PASSWORD && url.pathname !== "/api/room") {
      return err(403, "bad_password", "Wrong server password");
    }
    if (url.pathname === "/api/rooms" && request.method === "POST") return createRoom(request, env, url);
    if (!ROOM_PATHS.has(url.pathname)) return err(404, "not_found", "Unknown endpoint");
    let room = url.searchParams.get("room");
    // starsze wersje moda wysyłają pokój tylko w treści /api/sync
    if (!room && url.pathname === "/api/sync" && request.method === "POST") {
      const text = await request.text();
      try { room = JSON.parse(text).room; } catch { /* zły JSON obsłuży pokój */ }
      request = new Request(request.url, { method: "POST", headers: request.headers, body: text });
    }
    if (!room || !SAFE.test(room)) return err(400, "bad_room", "Invalid room name");
    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    if (central) request = new Request(request, { headers: new Headers([...request.headers, ["X-Sesja-Central", "1"]]) });
    return stub.fetch(request);
  },
};

const pad = (n) => String(n).padStart(12, "0");
// nazwa ścieżki / klipu z fragmentu stanu REAPERa (pierwsza linia NAME)
function chunkName(chunk) {
  const m = String(chunk || "").match(/^\s*NAME\s+(?:"([^"]*)"|(\S+))/m);
  return m ? (m[1] ?? m[2] ?? "") : "";
}

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.users = new Map(); // cid -> {name, color, last, presence}
    ctx.blockConcurrencyWhile(() => this.load());
  }

  async load() {
    const st = this.ctx.storage;
    const meta = (await st.get("meta")) || { seq: 0 };
    this.seq = meta.seq;
    const strip = (m, p) => new Map([...m].map(([k, v]) => [k.slice(p.length), v]));
    this.tracks = strip(await st.list({ prefix: "t:" }), "t:");
    this.items = strip(await st.list({ prefix: "i:" }), "i:");
    this.comments = strip(await st.list({ prefix: "c:" }), "c:");
    this.order = (await st.get("order")) || [];
    this.tempo = (await st.get("tempo")) || null;
    this.proj = strip(await st.list({ prefix: "p:" }), "p:"); // master, markery, mapa tempa
    this.chat = (await st.get("chat")) || [];
    const logs = await st.list({ prefix: "log:", reverse: true, limit: MAX_LOG });
    this.log = [...logs.values()].reverse();
    this.floor = this.log.length ? this.log[0].seq - 1 : this.seq;
    this.room = (await st.get("room")) || null; // {name, salt, hash, adminHash, created} – sesja założona z linkiem
    this.requests = strip(await st.list({ prefix: "req:" }), "req:"); // prośby edytorów o usunięcie
    this.rate = new Map(); // cid -> {hits: [], chats: []}
  }

  // role: sesja z linkiem ma gospodarza (klucz z „Utwórz sesję”); starsze pokoje – wszyscy równi
  get roles() { return !!this.room?.adminHash; }
  async isAdmin(request) {
    if (!this.roles) return true;
    const k = request.headers.get("X-Sesja-Admin") || "";
    return !!k && (await sha256(this.room.salt + ":a:" + k)) === this.room.adminHash;
  }

  async init(request) {
    if (this.room) return err(409, "exists", "Session exists");
    const b = await request.json();
    const salt = [...crypto.getRandomValues(new Uint8Array(12))].map((x) => x.toString(16).padStart(2, "0")).join("");
    this.room = {
      name: b.name, salt, hash: b.password ? await sha256(salt + ":" + b.password) : "",
      adminHash: b.adminKey ? await sha256(salt + ":a:" + b.adminKey) : "", created: now(),
    };
    await this.ctx.storage.put("room", this.room);
    return json({ ok: true });
  }

  // null = wolno; inaczej odpowiedź z błędem
  async guard(request) {
    if (!this.room) {
      // na serwerze centralnym wchodzi się tylko do sesji założonych przez „Utwórz sesję”
      return request.headers.get("X-Sesja-Central") ? err(404, "no_room", "Session not found") : null;
    }
    if (!this.room.hash) return null;
    const key = request.headers.get("X-RMP-Key") || "";
    if (key && (await sha256(this.room.salt + ":" + key)) === this.room.hash) return null;
    return err(403, "bad_password", "Wrong session password");
  }

  async fetch(request) {
    const url = new URL(request.url);
    const m = request.method;
    if (url.pathname === "/__init" && m === "POST") return this.init(request);
    if (url.pathname === "/__limit") {
      const t = now();
      this.hits = (this.hits || []).filter((x) => t - x < 3600);
      if (this.hits.length >= ROOMS_PER_HOUR) return err(429, "slow_down", "Too many");
      this.hits.push(t);
      return json({ ok: true });
    }
    if (url.pathname === "/api/room") {
      return json({ ok: true, exists: !!this.room, name: this.room?.name || null, has_password: !!this.room?.hash });
    }
    const denied = await this.guard(request);
    if (denied) return denied;
    if (url.pathname === "/api/state" && m === "GET") return this.state(request);
    if (url.pathname === "/api/sync" && m === "POST") return this.sync(request);
    if (url.pathname === "/api/file" && m === "PUT") {
      const part = url.searchParams.get("part");
      if (part !== null) return this.putPart(request, url.searchParams.get("id"), +part, +url.searchParams.get("parts"));
      return this.putFile(request, url.searchParams.get("id"));
    }
    if (url.pathname === "/api/file" && m === "GET") return this.getFile(url.searchParams.get("id"));
    return err(404, "not_found", "Unknown endpoint");
  }

  // rola, prośby o usunięcie i szkice – wysyłane przy każdej synchronizacji
  review(admin) {
    if (!this.roles) return { role: "admin", roles: false, requests: [], drafts: [] };
    const drafts = [];
    for (const [guid, tr] of this.tracks) if (tr.draft && drafts.length < 300) drafts.push({ kind: "track", guid, user: tr.author, name: chunkName(tr.chunk) });
    for (const [guid, it] of this.items) if (it.draft && drafts.length < 300) drafts.push({ kind: "item", guid, user: it.author, name: chunkName(it.chunk), track: it.track });
    return { role: admin ? "admin" : "editor", roles: true, requests: [...this.requests.values()], drafts };
  }

  addRequest(op, target, put) {
    for (const r of this.requests.values()) if (r.t === op.t && r.guid === op.guid) return; // już czeka
    const id = "r" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    const r = { id, t: op.t, guid: op.guid, user: op.user, ts: op.ts, name: chunkName(target.chunk), track: target.track || null };
    this.requests.set(id, r);
    put["req:" + id] = r;
  }

  // decyzje gospodarza; zwraca operacje do zapisania w logu (wszyscy je dostaną)
  decide(op, put, del) {
    const out = [], ts = now(), by = op.user;
    const emitState = (kind, guid) => {
      const e = kind === "track" ? this.tracks.get(guid) : this.items.get(guid);
      if (!e) return;
      const o = { t: kind, guid, chunk: e.chunk, user: e.editor, cid: "server", ts, restored: true };
      if (kind === "item") o.track = e.track;
      if (e.draft) o.draft = true;
      out.push(o);
    };
    if (op.t === "req_ok" || op.t === "req_no") {
      const r = this.requests.get(op.id);
      if (!r) return out;
      this.requests.delete(op.id);
      del.push("req:" + op.id);
      if (op.t === "req_ok") {
        const d = { t: r.t, guid: r.guid, user: r.user, cid: "server", ts, by };
        if (this.applyOp(d, put, del)) out.push(d);
      } else if (r.t === "item_del") {
        emitState("item", r.guid); // przywróć klip u osoby, która go usunęła
      } else {
        emitState("track", r.guid);
        for (const [ig, it] of this.items) if (it.track === r.guid) emitState("item", ig);
        out.push({ t: "order", list: this.order, user: by, cid: "server", ts });
      }
      out.push({ t: op.t, id: op.id, guid: r.guid, kind: r.t, name: r.name, who: r.user, user: by, cid: op.cid, ts });
    } else {
      const g = op.guid;
      const kind = this.tracks.has(g) ? "track" : this.items.has(g) ? "item" : null;
      if (!kind) return out;
      const e = kind === "track" ? this.tracks.get(g) : this.items.get(g);
      if (!e.draft) return out;
      if (op.t === "draft_ok") {
        delete e.draft;
        put[(kind === "track" ? "t:" : "i:") + g] = e;
        out.push({ t: "draft_ok", guid: g, kind, name: chunkName(e.chunk), who: e.author, user: by, cid: op.cid, ts });
      } else {
        const d = { t: kind + "_del", guid: g, user: e.author, cid: "server", ts, by };
        if (this.applyOp(d, put, del)) out.push(d);
        out.push({ t: "draft_no", guid: g, kind, name: chunkName(e.chunk), who: e.author, user: by, cid: op.cid, ts });
      }
    }
    return out;
  }

  async state(request) {
    const review = this.review(await this.isAdmin(request));
    return json({
      ...review,
      ok: true, seq: this.seq,
      tracks: Object.fromEntries(this.tracks), items: Object.fromEntries(this.items),
      order: this.order, tempo: this.tempo, proj: Object.fromEntries(this.proj),
      comments: [...this.comments.values()], chat: this.chat.slice(-200),
    });
  }

  // zastosowanie operacji do stanu; zwraca klucze do zapisania / usunięcia
  applyOp(op, put, del) {
    const user = op.user, ts = op.ts, g = typeof op.guid === "string" ? op.guid : "";
    switch (op.t) {
      case "track": {
        if (!g) return false;
        const prev = this.tracks.get(g);
        const v = { chunk: String(op.chunk || ""), author: prev ? prev.author : user, created: prev ? prev.created : ts, editor: user, ts };
        if (prev ? prev.draft : op.draft) v.draft = true;
        this.tracks.set(g, v);
        put["t:" + g] = v;
        if (!this.order.includes(g)) { this.order.push(g); put.order = this.order; }
        return true;
      }
      case "track_del": {
        this.tracks.delete(g);
        del.push("t:" + g);
        this.order = this.order.filter((x) => x !== g);
        put.order = this.order;
        for (const [ig, it] of this.items) if (it.track === g) { this.items.delete(ig); del.push("i:" + ig); }
        return true;
      }
      case "item": {
        if (!g) return false;
        const prev = this.items.get(g);
        const v = { chunk: String(op.chunk || ""), track: op.track, author: prev ? prev.author : user, created: prev ? prev.created : ts, editor: user, ts };
        if (prev ? prev.draft : op.draft) v.draft = true;
        this.items.set(g, v);
        put["i:" + g] = v;
        return true;
      }
      case "item_del":
        this.items.delete(g);
        del.push("i:" + g);
        return true;
      case "order":
        if (Array.isArray(op.list)) { this.order = op.list.filter((x) => typeof x === "string"); put.order = this.order; }
        return true;
      case "tempo":
        this.tempo = { bpm: op.bpm, user, ts };
        put.tempo = this.tempo;
        return true;
      case "proj": {
        if (!["master", "markers", "tempomap"].includes(op.key)) return false;
        const v = { data: String(op.data ?? "").slice(0, 2000000), user, ts };
        this.proj.set(op.key, v);
        put["p:" + op.key] = v;
        return true;
      }
      case "comment": {
        if (!op.id) return false;
        const c = { id: op.id, pos: Number(op.pos) || 0, text: String(op.text || "").slice(0, MAX_TEXT), user, ts, item: op.item ?? null, itemName: op.itemName ?? null };
        this.comments.set(op.id, c);
        put["c:" + op.id] = c;
        return true;
      }
      case "comment_del":
        this.comments.delete(op.id);
        del.push("c:" + op.id);
        return true;
      case "chat":
        this.chat.push({ user, text: String(op.text || "").slice(0, MAX_TEXT), ts });
        if (this.chat.length > MAX_CHAT) this.chat = this.chat.slice(-MAX_CHAT);
        put.chat = this.chat;
        return true;
      default:
        return false;
    }
  }

  async persist(put, del) {
    const st = this.ctx.storage;
    const entries = Object.entries(put);
    for (let i = 0; i < entries.length; i += 128) await st.put(Object.fromEntries(entries.slice(i, i + 128)));
    for (let i = 0; i < del.length; i += 128) await st.delete(del.slice(i, i + 128));
  }

  async sync(request) {
    let b;
    try { b = await request.json(); } catch { return err(400, "bad_json", "Invalid JSON"); }
    const user = String(b.user || "anon").slice(0, 40);
    const cid = String(b.cid || "").slice(0, 64);
    const since = Number.isFinite(+b.since) ? +b.since : 0;
    const admin = await this.isAdmin(request);
    // ochrona przed zalewaniem: limit żądań na połączenie i miejsc w sesji
    const t0 = now();
    const rl = this.rate.get(cid) || { hits: [], chats: [] };
    rl.hits = rl.hits.filter((x) => t0 - x < REQ_WINDOW);
    if (rl.hits.length >= REQ_BURST) return err(429, "slow_down", "Too many requests");
    rl.hits.push(t0);
    this.rate.set(cid, rl);
    if (!this.users.has(cid) && (await this.online()).length >= MAX_USERS) return err(403, "room_full", "Session is full");
    this.users.set(cid, { name: user, last: t0, presence: b.presence || {}, admin });

    const ops = (Array.isArray(b.ops) ? b.ops : []).slice(0, MAX_OPS_IN);
    if (ops.length) {
      const put = {}, del = [];
      const log = (op) => { op.seq = ++this.seq; this.log.push(op); put["log:" + pad(op.seq)] = op; };
      for (const raw of ops) {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
        const op = { ...raw, user, cid, ts: now() };
        if (op.t === "chat") {
          rl.chats = rl.chats.filter((x) => op.ts - x < CHAT_WINDOW);
          if (rl.chats.length >= CHAT_BURST) continue; // zalew wiadomości – pomijamy
          rl.chats.push(op.ts);
        }
        if (typeof op.text === "string") op.text = op.text.slice(0, MAX_TEXT);
        if (DECISIONS.has(op.t)) {
          if (admin) for (const out of this.decide(op, put, del)) log(out);
          continue;
        }
        if (!admin) {
          if (op.t === "track_del" || op.t === "item_del") {
            const target = op.t === "track_del" ? this.tracks.get(op.guid) : this.items.get(op.guid);
            if (!target) continue;
            // własny szkic edytor usuwa sam; resztę zatwierdza gospodarz
            if (!(target.draft && target.author === user)) { this.addRequest(op, target, put); continue; }
          }
          if (op.t === "track" && !this.tracks.has(op.guid)) op.draft = true;
          if (op.t === "item" && !this.items.has(op.guid)) op.draft = true;
        } else {
          delete op.draft;
        }
        if (!this.applyOp(op, put, del)) continue;
        log(op);
      }
      if (this.log.length > MAX_LOG) {
        const cut = this.log.splice(0, this.log.length - MAX_LOG);
        this.floor = cut[cut.length - 1].seq;
        for (const o of cut) del.push("log:" + pad(o.seq));
      }
      put.meta = { seq: this.seq };
      await this.persist(put, del);
    }

    const resp = { ok: true, seq: this.seq, users: await this.online(), color: await userColor(user), parts: PART, ...this.review(admin) };
    if (since < this.floor) {
      resp.resync = true;
      resp.ops = [];
    } else {
      let lo = 0, hi = this.log.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (this.log[mid].seq <= since) lo = mid + 1; else hi = mid; }
      resp.ops = this.log.slice(lo, lo + MAX_OPS_PER_RESPONSE);
      resp.more = lo + MAX_OPS_PER_RESPONSE < this.log.length;
    }
    const ids = (a) => (Array.isArray(a) ? a.filter((x) => typeof x === "string" && SAFE.test(x)) : null);
    const has = async (list) => {
      const out = new Set();
      for (let i = 0; i < list.length; i += 128) {
        const got = await this.ctx.storage.get(list.slice(i, i + 128).map((id) => "fm:" + id));
        for (const k of got.keys()) out.add(k.slice(3));
      }
      return out;
    };
    const check = ids(b.check), want = ids(b.want);
    if (check) { const h = await has(check); resp.missing = check.filter((id) => !h.has(id)); }
    if (want) {
      const h = await has(want);
      resp.available = want.filter((id) => h.has(id));
      // postęp plików, które ktoś właśnie wysyła w częściach (odbiorca widzi procenty)
      const waiting = want.filter((id) => !h.has(id)).slice(0, 20);
      if (waiting.length) {
        const got = await this.ctx.storage.get(waiting.map((id) => "fp:" + id));
        const progress = {};
        for (const [k, v] of got) {
          const id = k.slice(3), size = Number((id.match(/~(\d+)~/) || [])[1]) || 0;
          progress[id] = [v.length, Math.ceil(size / PART)];
        }
        if (Object.keys(progress).length) resp.progress = progress;
      }
    }
    return json(resp);
  }

  async online() {
    const t = now(), out = [];
    for (const [cid, u] of this.users) {
      if (t - u.last > ONLINE_TIMEOUT) { this.users.delete(cid); continue; }
      const p = u.presence || {};
      out.push({ cid, name: u.name, color: await userColor(u.name), pos: Number(p.pos) || 0, play: !!p.play, rec: !!p.rec, sel: String(p.sel || ""), app: !!p.app, admin: this.roles && !!u.admin });
    }
    return out;
  }

  // ---------------------------------------------------------------- pliki audio
  async putFile(request, id) {
    if (!id || !SAFE.test(id)) return err(400, "bad_name", "Invalid file name");
    const expected = Number(request.headers.get("Content-Length"));
    if (!request.body || !(expected >= 0) || expected > MAX_UPLOAD) return err(400, "bad_upload", "Missing, invalid or too large Content-Length");
    // rozmiar z identyfikatora (nazwa~rozmiar~hash) musi się zgadzać – inaczej odbiorca czekałby wiecznie
    const named = Number((id.match(/~(\d+)~[0-9a-f]+/) || [])[1]);
    if (named && named !== expected) return err(400, "size_mismatch", "File changed since it was added");
    const st = this.ctx.storage;
    const reader = request.body.getReader();
    let buf = new Uint8Array(CHUNK), fill = 0, n = 0, total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      let off = 0;
      while (off < value.length) {
        const take = Math.min(CHUNK - fill, value.length - off);
        buf.set(value.subarray(off, off + take), fill);
        fill += take; off += take; total += take;
        if (fill === CHUNK) { await st.put(`f:${id}:${n++}`, buf); buf = new Uint8Array(CHUNK); fill = 0; }
      }
    }
    if (fill) await st.put(`f:${id}:${n++}`, buf.slice(0, fill));
    if (total !== expected) return err(400, "bad_upload", "Upload interrupted");
    // metadane zapisujemy na końcu – niedokończony plik nigdy nie jest „dostępny”
    await st.put("fm:" + id, { size: total, chunks: n });
    return json({ ok: true, id, size: total });
  }

  async putPart(request, id, part, parts) {
    if (!id || !SAFE.test(id)) return err(400, "bad_name", "Invalid file name");
    const size = Number((id.match(/~(\d+)~[0-9a-f]+/) || [])[1]);
    if (!(size > 0) || size > MAX_FILE) return err(400, "bad_upload", "Invalid file size");
    const want = Math.ceil(size / PART);
    if (parts !== want || !Number.isInteger(part) || part < 0 || part >= parts) return err(400, "bad_upload", "Invalid part");
    const len = part === parts - 1 ? size - part * PART : PART;
    if (Number(request.headers.get("Content-Length")) !== len || !request.body) return err(400, "bad_upload", "Invalid part length");
    const st = this.ctx.storage;
    if (await st.get("fm:" + id)) return json({ ok: true, id, part, done: true }); // już jest
    const per = PART / CHUNK, base = part * per;
    const reader = request.body.getReader();
    let buf = new Uint8Array(CHUNK), fill = 0, n = 0, total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      let off = 0;
      while (off < value.length) {
        const take = Math.min(CHUNK - fill, value.length - off);
        buf.set(value.subarray(off, off + take), fill);
        fill += take; off += take; total += take;
        if (fill === CHUNK) { await st.put(`f:${id}:${base + n++}`, buf); buf = new Uint8Array(CHUNK); fill = 0; }
      }
    }
    if (fill) await st.put(`f:${id}:${base + n++}`, buf.slice(0, fill));
    if (total !== len) return err(400, "bad_upload", "Upload interrupted");
    const got = new Set((await st.get("fp:" + id)) || []);
    got.add(part);
    if (got.size < parts) {
      await st.put("fp:" + id, [...got]);
      return json({ ok: true, id, part, done: false, have: got.size, parts });
    }
    await st.delete("fp:" + id);
    await st.put("fm:" + id, { size, chunks: Math.ceil(size / CHUNK) });
    return json({ ok: true, id, part, done: true, size });
  }

  async getFile(id) {
    if (!id || !SAFE.test(id)) return err(400, "bad_name", "Invalid file name");
    const st = this.ctx.storage;
    const meta = await st.get("fm:" + id);
    if (!meta) return err(404, "no_file", "File not found");
    const { readable, writable } = new FixedLengthStream(meta.size);
    (async () => {
      const w = writable.getWriter();
      for (let i = 0; i < meta.chunks; i++) await w.write(new Uint8Array(await st.get(`f:${id}:${i}`)));
      await w.close();
    })();
    return new Response(readable, { headers: { "Content-Type": "application/octet-stream" } });
  }
}
