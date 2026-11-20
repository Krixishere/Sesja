// Sesja – serwer na Cloudflare Workers + Durable Objects.
// Ten sam protokół co server/rmp_server.py i serwer wbudowany w aplikację, więc mod
// w REAPERze i aplikacja Sesja łączą się z nim bez zmian – wystarczy adres https.
//
// Worker jest cienkim routerem (sprawdza hasło, wybiera pokój). Każdy pokój to osobny
// Durable Object z bazą SQLite: projekt, log operacji, czat, komentarze i pliki audio
// (w kawałkach po 1 MiB, więc nie potrzeba R2).

import { DurableObject } from "cloudflare:workers";

const VERSION = "1.0.0";
const SAFE = /^[A-Za-z0-9._~-]{1,200}$/;
const MAX_OPS_PER_RESPONSE = 400;
const MAX_LOG = 5000; // ile operacji trzymamy (starsze -> klient robi pełną synchronizację)
const MAX_CHAT = 500;
const ONLINE_TIMEOUT = 15; // s
const CHUNK = 1024 * 1024; // kawałek pliku audio w bazie
const MAX_UPLOAD = 95 * 1024 * 1024; // limit żądania w Workers to 100 MB
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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/api/ping") {
      if (url.pathname === "/" && (request.headers.get("Accept") || "").includes("text/html")) {
        return new Response(
          `<!doctype html><meta charset="utf-8"><title>Sesja</title><body style="font:16px system-ui;background:#0e1424;color:#eae3d2;padding:40px">` +
            `<h1>Sesja – serwer działa</h1><p>Wpisz ten adres w aplikacji Sesja albo w oknie moda w REAPERze.</p>`,
          { headers: { "Content-Type": "text/html; charset=utf-8" } },
        );
      }
      return json({ ok: true, app: "Sesja", cloud: true, version: VERSION, auth: !!env.PASSWORD });
    }
    if (env.PASSWORD && request.headers.get("X-RMP-Key") !== env.PASSWORD) {
      return err(403, "bad_password", "Wrong server password");
    }
    let room = url.searchParams.get("room");
    // starsze wersje moda wysyłają pokój tylko w treści /api/sync
    if (!room && url.pathname === "/api/sync" && request.method === "POST") {
      const text = await request.text();
      try { room = JSON.parse(text).room; } catch { /* zły JSON obsłuży pokój */ }
      request = new Request(request.url, { method: "POST", headers: request.headers, body: text });
    }
    if (!room || !SAFE.test(room)) return err(400, "bad_room", "Invalid room name");
    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    return stub.fetch(request);
  },
};

const pad = (n) => String(n).padStart(12, "0");

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
    this.chat = (await st.get("chat")) || [];
    const logs = await st.list({ prefix: "log:", reverse: true, limit: MAX_LOG });
    this.log = [...logs.values()].reverse();
    this.floor = this.log.length ? this.log[0].seq - 1 : this.seq;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const m = request.method;
    if (url.pathname === "/api/state" && m === "GET") return this.state();
    if (url.pathname === "/api/sync" && m === "POST") return this.sync(request);
    if (url.pathname === "/api/file" && m === "PUT") return this.putFile(request, url.searchParams.get("id"));
    if (url.pathname === "/api/file" && m === "GET") return this.getFile(url.searchParams.get("id"));
    return err(404, "not_found", "Unknown endpoint");
  }

  state() {
    return json({
      ok: true, seq: this.seq,
      tracks: Object.fromEntries(this.tracks), items: Object.fromEntries(this.items),
      order: this.order, tempo: this.tempo,
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
      case "comment": {
        if (!op.id) return false;
        const c = { id: op.id, pos: Number(op.pos) || 0, text: String(op.text || ""), user, ts, item: op.item ?? null, itemName: op.itemName ?? null };
        this.comments.set(op.id, c);
        put["c:" + op.id] = c;
        return true;
      }
      case "comment_del":
        this.comments.delete(op.id);
        del.push("c:" + op.id);
        return true;
      case "chat":
        this.chat.push({ user, text: String(op.text || ""), ts });
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
    this.users.set(cid, { name: user, last: now(), presence: b.presence || {} });

    const ops = Array.isArray(b.ops) ? b.ops : [];
    if (ops.length) {
      const put = {}, del = [];
      for (const raw of ops) {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
        const op = { ...raw, user, cid, ts: now() };
        if (!this.applyOp(op, put, del)) continue;
        op.seq = ++this.seq;
        this.log.push(op);
        put["log:" + pad(op.seq)] = op;
      }
      if (this.log.length > MAX_LOG) {
        const cut = this.log.splice(0, this.log.length - MAX_LOG);
        this.floor = cut[cut.length - 1].seq;
        for (const o of cut) del.push("log:" + pad(o.seq));
      }
      put.meta = { seq: this.seq };
      await this.persist(put, del);
    }

    const resp = { ok: true, seq: this.seq, users: await this.online(), color: await userColor(user) };
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
    if (want) { const h = await has(want); resp.available = want.filter((id) => h.has(id)); }
    return json(resp);
  }

  async online() {
    const t = now(), out = [];
    for (const [cid, u] of this.users) {
      if (t - u.last > ONLINE_TIMEOUT) { this.users.delete(cid); continue; }
      const p = u.presence || {};
      out.push({ cid, name: u.name, color: await userColor(u.name), pos: Number(p.pos) || 0, play: !!p.play, rec: !!p.rec, sel: String(p.sel || ""), app: !!p.app });
    }
    return out;
  }

  // ---------------------------------------------------------------- pliki audio
  async putFile(request, id) {
    if (!id || !SAFE.test(id)) return err(400, "bad_name", "Invalid file name");
    const expected = Number(request.headers.get("Content-Length"));
    if (!request.body || !(expected >= 0) || expected > MAX_UPLOAD) return err(400, "bad_upload", "Missing, invalid or too large Content-Length");
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
