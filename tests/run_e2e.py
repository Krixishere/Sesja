#!/usr/bin/env python3
"""Test end-to-end: prawdziwy serwer + dwa klienty (skrypt Lua w atrapie REAPERa).

Uruchom z katalogu repozytorium:  python3 tests/run_e2e.py
Wymaga: lua5.4, curl.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    tmp = tempfile.mkdtemp(prefix="rmp_e2e_")
    port = free_port()
    server = f"http://127.0.0.1:{port}"
    # RMP_SERVER_URL=http://... -> test działającego już serwera (np. wrangler dev dla Cloudflare)
    external = os.environ.get("RMP_SERVER_URL")
    room = os.environ.get("RMP_ROOM") or (f"e2e{int(time.time())}" if external else "test")
    if external:
        server = external.rstrip("/")
    env = dict(os.environ, NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost", RMP_ROOM=room)
    # RMP_SERVER=rust -> wbudowany serwer aplikacji Sesja (app/src-tauri/target/debug/sesja --serve)
    if os.environ.get("RMP_SERVER") == "rust":
        exe = os.path.join(ROOT, "app", "src-tauri", "target", "debug", "sesja")
        cmd = [exe, "--serve", str(port), "--data", os.path.join(tmp, "data")]
    else:
        cmd = [sys.executable, os.path.join(ROOT, "server", "rmp_server.py"), "--port", str(port),
               "--host", "127.0.0.1", "--data", os.path.join(tmp, "data")]
    srv = subprocess.Popen(cmd, env=env) if not external else None
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(server + "/api/ping", timeout=1)
                break
            except Exception:
                time.sleep(0.1)
        procs = []
        for role in ("A", "B"):
            d = os.path.join(tmp, role)
            os.makedirs(d)
            procs.append(subprocess.Popen(
                ["lua5.4", os.path.join("tests", "mock_reaper.lua"), role, d, server],
                cwd=ROOT, env=env))
        for p in procs:
            p.wait(timeout=60 + int(os.environ.get("RMP_END", "0") or 0))
            assert p.returncode == 0, f"klient zakończył się błędem ({p.returncode})"

        res = {}
        for role in ("A", "B"):
            with open(os.path.join(tmp, role, "result.json"), encoding="utf-8") as f:
                res[role] = json.load(f)

        fails = []

        def check(cond, msg):
            print(("ok   " if cond else "FAIL ") + msg)
            if not cond:
                fails.append(msg)

        a, b = res["A"], res["B"]
        an = [t["name"] for t in a["tracks"]]
        bn = [t["name"] for t in b["tracks"]]
        print("A:", an)
        print("B:", bn)
        check(an == ["Wokal", "Gitara akustyczna", "Pogłos"], "A ma wszystkie ścieżki we właściwej kolejności")
        check(bn == an, "B ma ten sam układ ścieżek co A")
        check([t["guid"] for t in a["tracks"]] == [t["guid"] for t in b["tracks"]], "GUID-y ścieżek zgodne")

        def items(res):
            return {i["guid"]: i for t in res["tracks"] for i in t["items"]}

        ia, ib = items(a), items(b)
        check(set(ia) == set(ib) and len(ia) == 2, "oba projekty mają te same 2 klipy")
        for g in ia:
            if g in ib:
                check(ia[g]["pos"] == ib[g]["pos"], f"pozycja klipu {g} zgodna ({ia[g]['pos']})")
                check(ib[g]["size"] is not None and ib[g]["size"] == ia[g]["size"],
                      f"plik audio klipu {g} istnieje u obu i ma ten sam rozmiar")
        vocal = [i for i in ia.values() if "vocal" in (i["file"] or "")]
        check(len(vocal) == 1 and vocal[0]["pos"] == 3, "przesunięcie klipu przez Bartka dotarło do Ani")
        gb = [i for i in ib.values() if "RMP_media" in (i["file"] or "")]
        check(len(gb) == 1, "u Bartka klip Ani wskazuje na pobrany plik w RMP_media")
        check(a["tracks"][0]["volpan"].startswith("0.5"), "Ania zmieniła głośność – u Ani")
        check(b["tracks"][0]["volpan"].startswith("0.5"), "Ania zmieniła głośność – dotarło do Bartka")
        check(all(i["color"] for i in ib.values() if "gitara" in (i["file"] or "")),
              "nowy klip Bartka pokolorowany kolorem autora")
        check(any("Multiplayer" in u for u in b["undo"]), "zmiany zdalne lądują w historii cofania")
        # projekt: markery/regiony, mapa tempa, master z efektami, wysyłki
        mk = lambda r: sorted((bool(m.get("rgn")), round(m["pos"], 3), m["name"]) for m in r["markers"] if "\U0001F4AC" not in m["name"])
        check(mk(b) == mk(a) and (True, 10, "Refren") in mk(b), "markery i regiony Ani dotarły do Bartka")
        check([round(t["bpm"]) for t in b.get("tempos", [])] == [140], "mapa tempa Ani dotarła do Bartka")
        check("JS limiter" in b.get("master", ""), "efekt na masterze Ani dotarł do Bartka")
        def send_src(r):
            bus = next((t for t in r["tracks"] if t["name"] == "Pogłos"), None)
            if not bus or not bus.get("auxrecv"):
                return None
            return r["tracks"][int(bus["auxrecv"].split()[0])]["name"]
        check(send_src(a) == "Gitara akustyczna", "wysyłka gitara → pogłos u Ani wskazuje właściwą ścieżkę")
        wa = next(t for t in a["tracks"] if t["name"] == "Wokal")
        fx = (wa.get("fx") or [{}])[0]
        check(abs(fx.get("p", [0, 0])[1] - 0.75) < 0.001, "gałka wtyczki przekręcona przez Bartka słychać u Ani")
        check(fx.get("gen") == 0, "wtyczka u Ani nie została przeładowana (zmiana gałki na żywo)")

        # stan serwera
        req = urllib.request.Request(server + f"/api/state?room={room}", headers={"X-RMP-Key": os.environ.get("RMP_PASSWORD", ""), "User-Agent": "sesja-e2e"})
        st = json.load(urllib.request.urlopen(req))
        check(len(st["tracks"]) == 3 and len(st["items"]) == 2, "serwer: 3 ścieżki, 2 klipy")
        check([c["text"] for c in st["chat"]] == ["Cześć Bartek, wrzuć gitarę!", "Refren od 0:12 jest za cichy"],
              "serwer: czat z polskimi znakami")
        authors = sorted(i["author"] for i in st["items"].values())
        check(authors == ["Ania", "Bartek"], "serwer: autorzy klipów zapamiętani")
        vocal_srv = [i for i in st["items"].values() if "vocal" in i["chunk"]][0]
        check(vocal_srv["author"] == "Ania" and vocal_srv["editor"] == "Bartek",
              "serwer: klip Ani ostatnio edytowany przez Bartka")
        if not external:
            files = os.listdir(os.path.join(tmp, "data", "test", "files"))
            check(any(f.startswith("vocal_take~") for f in files) and any(f.startswith("gitara~%d~" % (int(os.environ.get("RMP_BIG") or 200000) + 60044)) for f in files),
                  f"serwer: pełne wersje plików audio ({files})")

        print("\nWSZYSTKIE TESTY OK" if not fails else f"\nBŁĘDY: {len(fails)}")
        return 0 if not fails else 1
    finally:
        if srv:
            srv.terminate()
            srv.wait()
        if os.environ.get("KEEP") != "1":
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print("dane testu:", tmp)


if __name__ == "__main__":
    sys.exit(main())
