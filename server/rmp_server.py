#!/usr/bin/env python3
"""
REAPER Multiplayer (RMP) - serwer synchronizacji.

Zero zależności: wystarczy Python 3.8+.

    python3 rmp_server.py --port 8765 --password tajne

Serwer trzyma dla każdego "pokoju":
  * log operacji (ścieżki, klipy, kolejność ścieżek, tempo, czat, komentarze),
  * zmaterializowany stan projektu (dla osób, które dołączają później),
  * pliki audio wysłane automatycznie przez klientów,
  * listę osób online (obecność + pozycja kursora).

Wszystko zapisywane jest na dysku w katalogu --data (domyślnie ./rmp_data).
"""

import argparse
import hashlib
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "1.0.0"

SAFE_RE = re.compile(r"^[A-Za-z0-9._~\-]{1,200}$")
MAX_OPS_PER_RESPONSE = 400
MAX_LOG = 20000          # ile operacji trzymamy w pamięci, zanim przytniemy log
MAX_CHAT = 500
ONLINE_TIMEOUT = 15.0    # po ilu sekundach bez sync-a użytkownik znika z listy
MAX_UPLOAD = 4 * 1024 * 1024 * 1024  # 4 GB

PALETTE = [
    "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4",
    "#46f0f0", "#f032e6", "#bcf60c", "#fabebe", "#008080", "#e6beff",
    "#9a6324", "#fffac8", "#aaffc3", "#ffd8b1",
]


def user_color(name):
    h = int(hashlib.md5(name.encode("utf-8")).hexdigest(), 16)
    return PALETTE[h % len(PALETTE)]


def now():
    return time.time()


class Room:
    def __init__(self, name, data_dir):
        self.name = name
        self.dir = os.path.join(data_dir, name)
        self.files_dir = os.path.join(self.dir, "files")
        os.makedirs(self.files_dir, exist_ok=True)
        self.lock = threading.RLock()
        self.seq = 0
        self.log = []          # lista operacji (dict) z polem "seq"
        self.log_floor = 0     # najmniejszy seq, którego już nie mamy w logu
        self.tracks = {}       # guid -> {chunk, author, editor, ts}
        self.items = {}        # guid -> {chunk, track, author, editor, ts}
        self.order = []
        self.tempo = None
        self.comments = {}     # id -> {id, pos, text, user, ts}
        self.chat = []
        self.users = {}        # cid -> {name, color, pos, play, rec, last}
        self.dirty = False
        self._load()

    # ------------------------------------------------------------ persystencja
    def _state_path(self):
        return os.path.join(self.dir, "state.json")

    def _load(self):
        p = self._state_path()
        if not os.path.exists(p):
            return
        try:
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
            self.seq = d.get("seq", 0)
            self.log_floor = self.seq  # po restarcie log jest pusty -> klienci robią resync
            self.tracks = d.get("tracks", {})
            self.items = d.get("items", {})
            self.order = d.get("order", [])
            self.tempo = d.get("tempo")
            self.comments = d.get("comments", {})
            self.chat = d.get("chat", [])
        except Exception as e:  # pragma: no cover
            print(f"[{self.name}] nie udało się wczytać stanu: {e}")

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            d = {
                "seq": self.seq, "tracks": self.tracks, "items": self.items,
                "order": self.order, "tempo": self.tempo,
                "comments": self.comments, "chat": self.chat,
            }
            self.dirty = False
        tmp = self._state_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False)
        os.replace(tmp, self._state_path())

    # ------------------------------------------------------------ operacje
    def apply_op(self, op):
        """Aktualizuje zmaterializowany stan. Wywoływane pod self.lock."""
        t = op.get("t")
        user = op.get("user", "?")
        ts = op.get("ts", now())
        if t == "track":
            g = op["guid"]
            prev = self.tracks.get(g)
            self.tracks[g] = {
                "chunk": op.get("chunk", ""),
                "author": prev["author"] if prev else user,
                "created": prev["created"] if prev else ts,
                "editor": user, "ts": ts,
            }
            if g not in self.order:
                self.order.append(g)
        elif t == "track_del":
            g = op["guid"]
            self.tracks.pop(g, None)
            if g in self.order:
                self.order.remove(g)
            for ig in [k for k, v in self.items.items() if v.get("track") == g]:
                del self.items[ig]
        elif t == "item":
            g = op["guid"]
            prev = self.items.get(g)
            self.items[g] = {
                "chunk": op.get("chunk", ""), "track": op.get("track"),
                "author": prev["author"] if prev else user,
                "created": prev["created"] if prev else ts,
                "editor": user, "ts": ts,
            }
        elif t == "item_del":
            self.items.pop(op["guid"], None)
        elif t == "order":
            lst = op.get("list") or []
            if isinstance(lst, list):
                self.order = [g for g in lst if isinstance(g, str)]
        elif t == "tempo":
            self.tempo = {"bpm": op.get("bpm"), "user": user, "ts": ts}
        elif t == "comment":
            cid = op.get("id")
            if cid:
                self.comments[cid] = {
                    "id": cid, "pos": op.get("pos", 0), "text": op.get("text", ""),
                    "user": user, "ts": ts,
                }
        elif t == "comment_del":
            self.comments.pop(op.get("id"), None)
        elif t == "chat":
            self.chat.append({"user": user, "text": op.get("text", ""), "ts": ts})
            del self.chat[:-MAX_CHAT]
        else:
            return False
        return True

    def add_ops(self, ops, user, cid):
        added = []
        with self.lock:
            for op in ops:
                if not isinstance(op, dict):
                    continue
                op = dict(op)
                op["user"] = user
                op["cid"] = cid
                op["ts"] = now()
                if not self.apply_op(op):
                    continue
                self.seq += 1
                op["seq"] = self.seq
                self.log.append(op)
                added.append(op)
            if len(self.log) > MAX_LOG:
                cut = len(self.log) - MAX_LOG
                self.log_floor = self.log[cut - 1]["seq"]
                del self.log[:cut]
            if added:
                self.dirty = True
        return added

    def ops_since(self, since):
        with self.lock:
            if since < self.log_floor:
                return None, False
            # log jest posortowany po seq -> szukamy pierwszego > since
            lo, hi = 0, len(self.log)
            while lo < hi:
                mid = (lo + hi) // 2
                if self.log[mid]["seq"] <= since:
                    lo = mid + 1
                else:
                    hi = mid
            out = self.log[lo:lo + MAX_OPS_PER_RESPONSE]
            more = lo + MAX_OPS_PER_RESPONSE < len(self.log)
            return out, more

    def touch_user(self, cid, name, presence):
        with self.lock:
            u = self.users.get(cid) or {"name": name, "color": user_color(name)}
            u["name"] = name
            u["color"] = user_color(name)
            u["last"] = now()
            if isinstance(presence, dict):
                u["pos"] = presence.get("pos", 0)
                u["play"] = bool(presence.get("play"))
                u["rec"] = bool(presence.get("rec"))
                u["sel"] = presence.get("sel", "")
            self.users[cid] = u

    def online_users(self):
        t = now()
        with self.lock:
            for k in [k for k, u in self.users.items() if t - u["last"] > ONLINE_TIMEOUT]:
                del self.users[k]
            return [
                {"cid": k, "name": u["name"], "color": u["color"], "pos": u.get("pos", 0),
                 "play": u.get("play", False), "rec": u.get("rec", False),
                 "sel": u.get("sel", "")}
                for k, u in self.users.items()
            ]

    def snapshot(self):
        with self.lock:
            return {
                "seq": self.seq, "tracks": self.tracks, "items": self.items,
                "order": self.order, "tempo": self.tempo,
                "comments": list(self.comments.values()), "chat": self.chat[-200:],
            }

    def file_path(self, fid):
        return os.path.join(self.files_dir, fid)

    def has_file(self, fid):
        return os.path.isfile(self.file_path(fid))


class Server:
    def __init__(self, data_dir, password):
        self.data_dir = data_dir
        self.password = password or ""
        self.rooms = {}
        self.lock = threading.Lock()
        os.makedirs(data_dir, exist_ok=True)

    def room(self, name):
        with self.lock:
            r = self.rooms.get(name)
            if r is None:
                r = Room(name, self.data_dir)
                self.rooms[name] = r
            return r

    def existing_rooms(self):
        names = set(self.rooms)
        try:
            for n in os.listdir(self.data_dir):
                if os.path.isdir(os.path.join(self.data_dir, n)) and SAFE_RE.match(n):
                    names.add(n)
        except OSError:
            pass
        return sorted(names)

    def save_all(self):
        with self.lock:
            rooms = list(self.rooms.values())
        for r in rooms:
            try:
                r.save()
            except Exception as e:  # pragma: no cover
                print(f"[{r.name}] błąd zapisu: {e}")


def make_handler(srv):
    class Handler(BaseHTTPRequestHandler):
        server_version = "RMP/" + VERSION

        def log_message(self, fmt, *args):  # cisza - logujemy tylko błędy
            pass

        # -------------------------------------------------- helpers
        def _json(self, code, obj):
            obj = dict(obj)
            obj["_end"] = True  # klient sprawdza ten znacznik, czy odpowiedź jest kompletna
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _err(self, code, msg):
            self._json(code, {"ok": False, "error": msg})

        def _auth(self):
            if not srv.password:
                return True
            key = self.headers.get("X-RMP-Key", "")
            if key == srv.password:
                return True
            self._err(403, "Złe hasło serwera")
            return False

        def _query(self):
            u = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            return u.path, q

        def _room_from(self, name):
            if not name or not SAFE_RE.match(name):
                self._err(400, "Niepoprawna nazwa pokoju")
                return None
            return srv.room(name)

        def _read_json(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 256 * 1024 * 1024:
                return None
            raw = self.rfile.read(n)
            try:
                return json.loads(raw.decode("utf-8"))
            except Exception:
                return None

        # -------------------------------------------------- GET
        def do_GET(self):
            path, q = self._query()
            if path in ("/", "/index.html"):
                return self._index()
            if path == "/api/ping":
                return self._json(200, {"ok": True, "version": VERSION,
                                        "auth": bool(srv.password)})
            if not self._auth():
                return
            if path == "/api/state":
                room = self._room_from(q.get("room"))
                if room is None:
                    return
                return self._json(200, {"ok": True, **room.snapshot()})
            if path == "/api/file":
                room = self._room_from(q.get("room"))
                if room is None:
                    return
                fid = q.get("id", "")
                if not SAFE_RE.match(fid) or not room.has_file(fid):
                    return self._err(404, "Brak pliku")
                p = room.file_path(fid)
                size = os.path.getsize(p)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                with open(p, "rb") as f:
                    while True:
                        b = f.read(1024 * 256)
                        if not b:
                            break
                        self.wfile.write(b)
                return
            self._err(404, "Nieznany adres")

        # -------------------------------------------------- POST
        def do_POST(self):
            path, q = self._query()
            if not self._auth():
                return
            if path != "/api/sync":
                return self._err(404, "Nieznany adres")
            body = self._read_json()
            if not isinstance(body, dict):
                return self._err(400, "Zły JSON")
            room = self._room_from(body.get("room"))
            if room is None:
                return
            user = str(body.get("user") or "anon")[:40]
            cid = str(body.get("cid") or "")[:64]
            try:
                since = int(body.get("since") or 0)
            except (TypeError, ValueError):
                since = 0
            ops = body.get("ops") or []
            if not isinstance(ops, list):
                ops = []
            room.touch_user(cid, user, body.get("presence"))
            if ops:
                room.add_ops(ops, user, cid)
            out, more = room.ops_since(since)
            resp = {"ok": True, "seq": room.seq, "users": room.online_users(),
                    "color": user_color(user)}
            if out is None:
                resp["resync"] = True
                resp["ops"] = []
            else:
                resp["ops"] = out
                resp["more"] = more
            # pliki: klient pyta, których brakuje na serwerze (check) i które już są (want)
            check = body.get("check") or []
            want = body.get("want") or []
            if isinstance(check, list):
                resp["missing"] = [f for f in check if isinstance(f, str)
                                   and SAFE_RE.match(f) and not room.has_file(f)]
            if isinstance(want, list):
                resp["available"] = [f for f in want if isinstance(f, str)
                                     and SAFE_RE.match(f) and room.has_file(f)]
            self._json(200, resp)

        # -------------------------------------------------- PUT (upload pliku audio)
        def do_PUT(self):
            path, q = self._query()
            if not self._auth():
                return
            if path != "/api/file":
                return self._err(404, "Nieznany adres")
            room = self._room_from(q.get("room"))
            if room is None:
                return
            fid = q.get("id", "")
            if not SAFE_RE.match(fid):
                return self._err(400, "Zła nazwa pliku")
            n = int(self.headers.get("Content-Length") or -1)
            if n < 0 or n > MAX_UPLOAD:
                return self._err(400, "Brak lub zły Content-Length")
            dest = room.file_path(fid)
            tmp = dest + ".part%d" % threading.get_ident()
            left = n
            with open(tmp, "wb") as f:
                while left > 0:
                    b = self.rfile.read(min(left, 1024 * 256))
                    if not b:
                        break
                    f.write(b)
                    left -= len(b)
            if left != 0:
                os.remove(tmp)
                return self._err(400, "Przerwany upload")
            os.replace(tmp, dest)
            self._json(200, {"ok": True, "id": fid, "size": n})

        # -------------------------------------------------- mini panel WWW
        def _index(self):
            rows = []
            for name in srv.existing_rooms():
                r = srv.room(name)
                users = ", ".join(u["name"] for u in r.online_users()) or "-"
                rows.append(
                    f"<tr><td>{_esc(name)}</td><td>{len(r.tracks)}</td>"
                    f"<td>{len(r.items)}</td><td>{r.seq}</td><td>{_esc(users)}</td></tr>")
            html = f"""<!doctype html><meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>REAPER Multiplayer</title>
<style>body{{font-family:sans-serif;margin:2em;background:#1e1e1e;color:#ddd}}
td,th{{padding:4px 12px;border-bottom:1px solid #444;text-align:left}}</style>
<h1>REAPER Multiplayer – serwer v{VERSION}</h1>
<p>Hasło: {"włączone" if srv.password else "wyłączone"}</p>
<table><tr><th>Pokój</th><th>Ścieżki</th><th>Klipy</th><th>Operacje</th><th>Online</th></tr>
{''.join(rows) or '<tr><td colspan=5>Brak pokoi</td></tr>'}</table>"""
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def _esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def main():
    ap = argparse.ArgumentParser(description="REAPER Multiplayer – serwer")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=int(os.environ.get("RMP_PORT", 8765)))
    ap.add_argument("--data", default=os.environ.get("RMP_DATA", "rmp_data"))
    ap.add_argument("--password", default=os.environ.get("RMP_PASSWORD", ""))
    args = ap.parse_args()

    srv = Server(args.data, args.password)
    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(srv))
    httpd.daemon_threads = True

    def saver():
        while True:
            time.sleep(2)
            srv.save_all()

    threading.Thread(target=saver, daemon=True).start()
    print(f"REAPER Multiplayer server v{VERSION} na http://{args.host}:{args.port}  "
          f"(dane: {os.path.abspath(args.data)}, hasło: {'tak' if args.password else 'nie'})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.save_all()


if __name__ == "__main__":
    main()
