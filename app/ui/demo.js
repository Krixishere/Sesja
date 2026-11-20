/* Tryb podglądu w zwykłej przeglądarce (bez Tauri): przykładowe dane, żeby obejrzeć interfejs.
   W aplikacji ten plik nic nie robi, bo window.__TAURI__ już istnieje. */
(function () {
  if (window.__TAURI__) return;
  const params = new URLSearchParams(location.search);
  const now = Date.now() / 1000;
  const listeners = {};
  const colors = { Ania: "#f58231", Bartek: "#46f0f0", Kuba: "#bcf60c" };
  const cfg = {
    onboarded: params.get("demo") !== "onboard", nick: "Ania", server: "http://100.101.102.103:8765", room: "nowy_singiel",
    password: "", reaper_exe: null, reaper_resource: null, auto_update: false, autostart_script: true,
    host_port: 8765, host_password: "", host_on_start: false, lang: params.get("lang") || "",
  };
  const reaper = {
    found: params.get("reaper") !== "missing", exe: "C:\\Program Files\\REAPER (x64)\\reaper.exe",
    resource: "C:\\Users\\Ania\\AppData\\Roaming\\REAPER", portable: false, script_installed: true,
    script_version: "1.0.0", bundled_version: "1.1.0", autostart: true, running: false,
    checked: ["HKLM\\SOFTWARE\\REAPER", "C:\\Program Files\\REAPER (x64)\\reaper.exe", "C:\\Program Files\\REAPER\\reaper.exe", "C:\\Program Files (x86)\\REAPER\\reaper.exe", "D:\\Program Files\\REAPER (x64)\\reaper.exe", "C:\\Users\\Ania\\REAPER\\reaper.exe"],
  };
  const tr = (guid, name, author, editor) => ({ guid, name, author, editor, created: now - 4000, ts: now - 300 });
  const it = (guid, name, track, pos, len, author, file, ago) => ({ guid, name, track, pos, len, file, midi: false, author, editor: author, created: now - ago, ts: now - ago });
  const ev = (kind, user, text, ago, extra = {}) => ({ kind, user, text, ts: now - ago, pos: null, id: null, item: null, item_name: null, action: null, name: null, track: null, bpm: null, mine: user === "Ania", ...extra });
  const act = (user, action, ago, name, track, pos) => ev("act", user, "", ago, { action, name, track, pos });
  const session = {
    status: "on", error: null, room: "nowy_singiel", server: "http://100.101.102.103:8765", me: "Ania", my_color: "#f58231",
    users: [
      { cid: "a", name: "Ania", color: "#f58231", pos: 72.4, play: false, rec: false, sel: "Wokal główny", app: false },
      { cid: "b", name: "Bartek", color: "#46f0f0", pos: 41.2, play: false, rec: true, sel: "Gitara akustyczna", app: false },
      { cid: "c", name: "Kuba", color: "#bcf60c", pos: 12.0, play: true, rec: false, sel: "", app: false },
    ],
    tracks: [
      tr("t1", "Wokal główny", "Ania", "Ania"), tr("t2", "Chórki", "Ania", "Kuba"),
      tr("t3", "Gitara akustyczna", "Bartek", "Bartek"), tr("t4", "Bas", "Kuba", "Kuba"), tr("t5", "Bębny", "Kuba", "Bartek"),
    ],
    items: [
      it("i1", "wokal_zwrotka_take4", "t1", 12.5, 31.2, "Ania", "w~1~a.wav", 420),
      it("i2", "wokal_refren_take2", "t1", 48.0, 22.0, "Ania", "w~2~b.wav", 260),
      it("i3", "gitara_intro", "t3", 0, 16.0, "Bartek", "g~1~c.wav", 1800),
      it("i4", "gitara_zwrotka", "t3", 12.5, 35.5, "Bartek", "g~2~d.wav", 90),
      it("i5", "bas_DI", "t4", 0, 96.0, "Kuba", "b~1~e.wav", 3600),
      it("i6", "chorki_oo", "t2", 48.0, 22.0, "Kuba", "c~1~f.wav", 140),
    ],
    feed: [
      ev("chat", "Kuba", "Bas wrzucony, zobaczcie czy nie za głośno", 3500),
      act("Kuba", "item_add", 3600, "bas_DI", "Bas", 0),
      act("Bartek", "item_add", 1800, "gitara_intro", "Gitara akustyczna", 0),
      ev("chat", "Ania", "Super! Dogrywam wokal do zwrotki", 600),
      act("Ania", "item_add", 420, "wokal_zwrotka_take4", "Wokal główny", 12.5),
      ev("comment", "Bartek", "Tu wejdź pół taktu później, będzie lepiej siedzieć z gitarą", 380, { pos: 24.0, id: "c1", item: "i1", item_name: "wokal_zwrotka_take4" }),
      act("Ania", "item_add", 260, "wokal_refren_take2", "Wokal główny", 48),
      act("Kuba", "track_edit", 150, "Chórki"),
      ev("chat", "Bartek", "Nagrywam drugą zwrotkę, dajcie mi 5 minut", 100),
      act("Bartek", "item_edit", 90, "gitara_zwrotka", "Gitara akustyczna"),
    ],
    comments: [],
    seq: 120,
    colors,
  };
  session.comments = session.feed.filter((e) => e.kind === "comment");
  const host = { running: params.get("host") === "1", port: 8765, addresses: [
    { url: "http://100.101.102.103:8765", kind: "tailscale" }, { url: "http://192.168.1.24:8765", kind: "lan" }, { url: "http://127.0.0.1:8765", kind: "local" }] };
  let connected = false;
  const changelog = "# Dziennik zmian\n\n## 1.0.0 — aplikacja Sesja\n\n- Instalator, który sam znajduje REAPERa.\n- Hostowanie sesji w aplikacji.\n\n## Mod 1.1.0\n\n- Komentarze do klipów.";
  const api = {
    get_config: () => cfg,
    save_config: ({ cfg: c }) => Object.assign(cfg, c),
    app_info: () => ({ version: "1.0.0", mod_version: "1.1.0", repo: "krixishere/repomulitplayer", os: "windows" }),
    changelog: () => changelog,
    detect_reaper: () => new Promise((r) => setTimeout(() => r(reaper), 300)),
    pick_reaper_folder: () => ({ ...reaper, found: true }),
    install_mod: ({ autostart }) => ({ script_path: "", action_registered: true, autostart, settings_written: true, warning: null, info: { ...reaper, script_version: "1.1.0", autostart } }),
    uninstall_mod: () => null,
    host_status: () => host,
    host_start: () => (host.running = true, host),
    host_stop: () => (host.running = false, null),
    session_connect: () => { connected = true; setTimeout(() => emit("session", session), 50); },
    session_disconnect: () => { connected = false; },
    session_state: () => (connected ? session : null),
    send_chat: ({ text }) => { session.feed.push(ev("chat", "Ania", text, 0)); setTimeout(() => emit("session", { ...session, feed: [...session.feed] }), 200); },
    send_comment: () => null,
    delete_comment: () => null,
    fetch_audio: () => Promise.reject("Podgląd w przeglądarce nie odtwarza nagrań."),
    check_update: () => ({ current: "1.0.0", latest: "v1.0.0", newer: false, notes: "", releases: [] }),
    open_url: ({ url }) => window.open(url, "_blank"),
    launch_reaper: () => null,
    open_path: () => null,
  };
  function emit(ev, payload) { (listeners[ev] || []).forEach((cb) => cb({ payload })); }
  window.__TAURI__ = {
    core: {
      invoke: (cmd, args) => Promise.resolve().then(() => api[cmd](args || {})),
      convertFileSrc: (p) => p,
    },
    event: { listen: (ev, cb) => { (listeners[ev] ||= []).push(cb); return Promise.resolve(() => {}); } },
  };
})();
