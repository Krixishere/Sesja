//! Klient sesji w aplikacji: łączy się z serwerem tak samo jak skrypt w REAPERze,
//! ale tylko czyta projekt (kto co dodał, nagrania, komentarze) i obsługuje czat.

use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use crate::i18n::{self, t, tf};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Debug)]
pub struct Conn {
    pub server: String,
    pub room: String,
    pub user: String,
    pub password: String,
}

#[derive(Serialize, Clone, Default)]
pub struct Track {
    pub guid: String,
    pub name: String,
    pub author: String,
    pub editor: String,
    pub created: f64,
    pub ts: f64,
}

#[derive(Serialize, Clone, Default)]
pub struct Item {
    pub guid: String,
    pub name: String,
    pub track: String,
    pub pos: f64,
    pub len: f64,
    pub file: Option<String>,
    pub midi: bool,
    pub author: String,
    pub editor: String,
    pub created: f64,
    pub ts: f64,
}

#[derive(Serialize, Clone)]
pub struct Entry {
    pub kind: String, // act | chat | comment
    /// Dla kind == "act": track_add, track_edit, track_del, item_add, item_edit, item_del,
    /// order, tempo, comment_del – interfejs zamienia to na zdanie w swoim języku.
    pub action: Option<String>,
    /// Nazwa ścieżki / klipu, którego dotyczy zmiana.
    pub name: Option<String>,
    /// Nazwa ścieżki, na której leży klip.
    pub track: Option<String>,
    pub bpm: Option<f64>,
    pub user: String,
    pub text: String,
    pub ts: f64,
    pub pos: Option<f64>,
    pub id: Option<String>,
    pub item: Option<String>,
    pub item_name: Option<String>,
    pub mine: bool,
}

#[derive(Serialize, Clone, Default)]
pub struct Summary {
    pub status: String, // off | connecting | on | error
    pub error: Option<String>,
    pub room: String,
    pub server: String,
    pub me: String,
    pub my_color: String,
    pub users: Vec<Value>,
    pub tracks: Vec<Track>,
    pub items: Vec<Item>,
    pub feed: Vec<Entry>,
    pub comments: Vec<Entry>,
    pub seq: u64,
    /// Kolor każdej osoby, która coś dodała (ten sam co w REAPERze).
    pub colors: HashMap<String, String>,
}

struct Model {
    conn: Conn,
    cid: String,
    status: String,
    error: Option<String>,
    loaded: bool,
    last_seq: u64,
    tracks: HashMap<String, Track>,
    order: Vec<String>,
    items: HashMap<String, Item>,
    comments: Vec<Entry>,
    feed: VecDeque<Entry>,
    users: Vec<Value>,
    my_color: String,
    outbox: Vec<Value>,
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    for q in ['"', '\'', '`'] {
        if s.len() >= 2 && s.starts_with(q) && s.ends_with(q) {
            return s[1..s.len() - 1].to_string();
        }
    }
    s.to_string()
}

/// Wartość pierwszej linii z kluczem na głębokości 1 chunka REAPERa.
pub fn chunk_field(chunk: &str, key: &str) -> Option<String> {
    let mut depth = 0i32;
    for raw in chunk.lines() {
        let l = raw.trim_start();
        if depth == 1 {
            let (k, rest) = l.split_once(char::is_whitespace).unwrap_or((l, ""));
            if k == key {
                return Some(rest.trim().to_string());
            }
        }
        if l.starts_with('<') {
            depth += 1;
        } else if l == ">" {
            depth -= 1;
        }
    }
    None
}

fn file_ref(chunk: &str) -> Option<String> {
    let i = chunk.find("FILE \"rmp:")?;
    let rest = &chunk[i + 10..];
    rest.split('"').next().map(|s| s.to_string())
}

impl Model {
    fn track_name(&self, chunk: &str) -> String {
        let n = unquote(&chunk_field(chunk, "NAME").unwrap_or_default());
        if n.is_empty() {
            "bez nazwy".into()
        } else {
            n
        }
    }

    fn push_act(
        &mut self,
        user: &str,
        action: &str,
        name: Option<String>,
        track: Option<String>,
        pos: Option<f64>,
        bpm: Option<f64>,
        ts: f64,
    ) {
        // łączymy serię drobnych zmian tej samej osoby w jeden wpis
        if let Some(last) = self.feed.back_mut() {
            if last.kind == "act"
                && last.user == user
                && last.action.as_deref() == Some(action)
                && last.name == name
                && ts - last.ts < 30.0
            {
                last.ts = ts;
                last.bpm = bpm;
                return;
            }
        }
        self.push_entry("act", user, String::new(), ts);
        if let Some(e) = self.feed.back_mut() {
            e.action = Some(action.into());
            e.name = name;
            e.track = track;
            e.pos = pos;
            e.bpm = bpm;
        }
    }

    fn push_entry(&mut self, kind: &str, user: &str, text: String, ts: f64) {
        let mine = user == self.conn.user;
        self.feed.push_back(Entry {
            kind: kind.into(),
            action: None,
            name: None,
            track: None,
            bpm: None,
            user: user.into(),
            text,
            ts,
            pos: None,
            id: None,
            item: None,
            item_name: None,
            mine,
        });
        while self.feed.len() > 500 {
            self.feed.pop_front();
        }
    }

    fn load_state(&mut self, st: &Value) {
        self.tracks.clear();
        self.items.clear();
        self.comments.clear();
        if let Some(t) = st["tracks"].as_object() {
            for (g, v) in t {
                let chunk = v["chunk"].as_str().unwrap_or("");
                self.tracks.insert(
                    g.clone(),
                    Track {
                        guid: g.clone(),
                        name: self.track_name(chunk),
                        author: v["author"].as_str().unwrap_or("?").into(),
                        editor: v["editor"].as_str().unwrap_or("?").into(),
                        created: v["created"].as_f64().unwrap_or(0.0),
                        ts: v["ts"].as_f64().unwrap_or(0.0),
                    },
                );
            }
        }
        self.order = st["order"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if let Some(t) = st["items"].as_object() {
            for (g, v) in t {
                let it = item_from(g, v["chunk"].as_str().unwrap_or(""), v["track"].as_str().unwrap_or(""));
                self.items.insert(
                    g.clone(),
                    Item {
                        author: v["author"].as_str().unwrap_or("?").into(),
                        editor: v["editor"].as_str().unwrap_or("?").into(),
                        created: v["created"].as_f64().unwrap_or(0.0),
                        ts: v["ts"].as_f64().unwrap_or(0.0),
                        ..it
                    },
                );
            }
        }
        if let Some(cs) = st["comments"].as_array() {
            for c in cs {
                self.comments.push(comment_entry(c, &self.conn.user));
            }
        }
        self.feed.clear();
        if let Some(chat) = st["chat"].as_array() {
            for c in chat {
                let user = c["user"].as_str().unwrap_or("?").to_string();
                let text = c["text"].as_str().unwrap_or("").to_string();
                self.push_entry("chat", &user, text, c["ts"].as_f64().unwrap_or(0.0));
            }
        }
        self.last_seq = st["seq"].as_u64().unwrap_or(0);
        self.loaded = true;
    }

    fn apply(&mut self, op: &Value) {
        let t = op["t"].as_str().unwrap_or("");
        let user = op["user"].as_str().unwrap_or("?").to_string();
        let ts = op["ts"].as_f64().unwrap_or_else(now);
        let guid = op["guid"].as_str().unwrap_or("").to_string();
        match t {
            "track" => {
                let name = self.track_name(op["chunk"].as_str().unwrap_or(""));
                let existed = self.tracks.contains_key(&guid);
                let e = self.tracks.entry(guid.clone()).or_insert_with(|| Track {
                    guid: guid.clone(),
                    author: user.clone(),
                    created: ts,
                    ..Default::default()
                });
                e.name = name.clone();
                e.editor = user.clone();
                e.ts = ts;
                if !self.order.contains(&guid) {
                    self.order.push(guid);
                }
                let action = if existed { "track_edit" } else { "track_add" };
                self.push_act(&user, action, Some(name), None, None, None, ts);
            }
            "track_del" => {
                let name = self.tracks.remove(&guid).map(|t| t.name).unwrap_or_else(|| "?".into());
                self.order.retain(|g| g != &guid);
                self.items.retain(|_, it| it.track != guid);
                self.push_act(&user, "track_del", Some(name), None, None, None, ts);
            }
            "item" => {
                let it = item_from(&guid, op["chunk"].as_str().unwrap_or(""), op["track"].as_str().unwrap_or(""));
                let prev = self.items.get(&guid).cloned();
                let tname = self.tracks.get(&it.track).map(|t| t.name.clone()).unwrap_or_else(|| "?".into());
                let action = if prev.is_some() { "item_edit" } else { "item_add" };
                let (iname, ipos) = (it.name.clone(), it.pos);
                self.items.insert(
                    guid.clone(),
                    Item {
                        author: prev.as_ref().map(|p| p.author.clone()).unwrap_or(user.clone()),
                        created: prev.as_ref().map(|p| p.created).unwrap_or(ts),
                        editor: user.clone(),
                        ts,
                        ..it
                    },
                );
                self.push_act(&user, action, Some(iname), Some(tname), Some(ipos), None, ts);
            }
            "item_del" => {
                let name = self.items.remove(&guid).map(|i| i.name).unwrap_or_else(|| "?".into());
                self.push_act(&user, "item_del", Some(name), None, None, None, ts);
            }
            "order" => self.push_act(&user, "order", None, None, None, None, ts),
            "tempo" => self.push_act(&user, "tempo", None, None, None, op["bpm"].as_f64(), ts),
            "chat" => {
                let text = op["text"].as_str().unwrap_or("").to_string();
                self.push_entry("chat", &user, text, ts);
            }
            "comment" => {
                let mut c = op.clone();
                c["user"] = json!(user);
                c["ts"] = json!(ts);
                let e = comment_entry(&c, &self.conn.user);
                self.comments.retain(|x| x.id != e.id);
                self.comments.push(e.clone());
                self.feed.push_back(e);
            }
            "comment_del" => {
                let id = op["id"].as_str().map(String::from);
                self.comments.retain(|x| x.id != id);
                self.push_act(&user, "comment_del", None, None, None, None, ts);
            }
            _ => {}
        }
    }

    fn summary(&self) -> Summary {
        let mut tracks: Vec<Track> = Vec::new();
        for g in &self.order {
            if let Some(t) = self.tracks.get(g) {
                tracks.push(t.clone());
            }
        }
        for (g, t) in &self.tracks {
            if !self.order.contains(g) {
                tracks.push(t.clone());
            }
        }
        let mut items: Vec<Item> = self.items.values().cloned().collect();
        items.sort_by(|a, b| b.created.partial_cmp(&a.created).unwrap_or(std::cmp::Ordering::Equal));
        let mut comments = self.comments.clone();
        comments.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap_or(std::cmp::Ordering::Equal));
        let mut colors = HashMap::new();
        let mut add = |n: &str| {
            colors.entry(n.to_string()).or_insert_with(|| crate::server::user_color(n).to_string());
        };
        for t in self.tracks.values() { add(&t.author); add(&t.editor); }
        for i in self.items.values() { add(&i.author); add(&i.editor); }
        for e in self.feed.iter().chain(self.comments.iter()) { add(&e.user); }
        add(&self.conn.user);
        for u in &self.users {
            if let (Some(n), Some(c)) = (u["name"].as_str(), u["color"].as_str()) {
                colors.insert(n.to_string(), c.to_string());
            }
        }
        Summary {
            colors,
            status: self.status.clone(),
            error: self.error.clone(),
            room: self.conn.room.clone(),
            server: self.conn.server.clone(),
            me: self.conn.user.clone(),
            my_color: self.my_color.clone(),
            users: self.users.clone(),
            tracks,
            items,
            feed: self.feed.iter().cloned().collect(),
            comments,
            seq: self.last_seq,
        }
    }
}

fn item_from(guid: &str, chunk: &str, track: &str) -> Item {
    let mut name = unquote(&chunk_field(chunk, "NAME").unwrap_or_default());
    if name.is_empty() {
        name = "klip".into();
    }
    Item {
        guid: guid.into(),
        name,
        track: track.into(),
        pos: chunk_field(chunk, "POSITION").and_then(|v| v.parse().ok()).unwrap_or(0.0),
        len: chunk_field(chunk, "LENGTH").and_then(|v| v.parse().ok()).unwrap_or(0.0),
        file: file_ref(chunk),
        midi: chunk.contains("<SOURCE MIDI"),
        ..Default::default()
    }
}

fn comment_entry(c: &Value, me: &str) -> Entry {
    let user = c["user"].as_str().unwrap_or("?").to_string();
    Entry {
        kind: "comment".into(),
        action: None,
        name: None,
        track: None,
        bpm: None,
        mine: user == me,
        user,
        text: c["text"].as_str().unwrap_or("").into(),
        ts: c["ts"].as_f64().unwrap_or(0.0),
        pos: c["pos"].as_f64(),
        id: c["id"].as_str().map(String::from),
        item: c["item"].as_str().map(String::from),
        item_name: c["itemName"].as_str().map(String::from),
    }
}

pub struct Session {
    model: Arc<Mutex<Model>>,
    stop: Arc<AtomicBool>,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(6))
        .timeout(Duration::from_secs(30))
        .build()
}

fn url(conn: &Conn, path: &str) -> String {
    format!("{}{}", conn.server.trim_end_matches('/'), path)
}

/// Wynik zapytania: JSON albo czytelny komunikat błędu.
fn call(req: ureq::Request, body: Option<&Value>, conn: &Conn) -> Result<Value, String> {
    let req = if conn.password.is_empty() { req } else { req.set("X-RMP-Key", &conn.password) };
    let res = match body {
        Some(b) => req.send_json(b.clone()),
        None => req.call(),
    };
    match res {
        Ok(r) => r.into_json::<Value>().map_err(|e| tf("bad_response", &[&e])),
        Err(ureq::Error::Status(_, r)) => {
            let v: Value = r.into_json().unwrap_or(json!({}));
            Err(i18n::server_error(&v))
        }
        Err(e) => Err(tf("cant_connect", &[&conn.server, &short_err(&e.to_string())])),
    }
}

fn short_err(s: &str) -> String {
    if s.contains("Connection refused") || s.contains("refused") {
        t("refused")
    } else if s.contains("timed out") || s.contains("Timeout") {
        t("timeout")
    } else {
        s.chars().take(120).collect()
    }
}

impl Session {
    pub fn start(app: AppHandle, conn: Conn) -> Session {
        let cid = format!("app-{:x}", (now() * 1000.0) as u64);
        let model = Arc::new(Mutex::new(Model {
            conn: conn.clone(),
            cid,
            status: "connecting".into(),
            error: None,
            loaded: false,
            last_seq: 0,
            tracks: HashMap::new(),
            order: Vec::new(),
            items: HashMap::new(),
            comments: Vec::new(),
            feed: VecDeque::new(),
            users: Vec::new(),
            my_color: crate::server::user_color(&conn.user).into(),
            outbox: Vec::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        {
            let model = model.clone();
            let stop = stop.clone();
            std::thread::spawn(move || run(app, model, stop, conn));
        }
        Session { model, stop }
    }

    pub fn summary(&self) -> Summary {
        self.model.lock().unwrap().summary()
    }

    pub fn send(&self, op: Value) {
        self.model.lock().unwrap().outbox.push(op);
    }

    pub fn conn(&self) -> Conn {
        self.model.lock().unwrap().conn.clone()
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(app: AppHandle, model: Arc<Mutex<Model>>, stop: Arc<AtomicBool>, conn: Conn) {
    let agent = agent();
    let emit = |m: &Model| {
        let _ = app.emit("session", m.summary());
    };
    while !stop.load(Ordering::Relaxed) {
        let loaded = model.lock().unwrap().loaded;
        if !loaded {
            let res = call(agent.get(&url(&conn, &format!("/api/state?room={}", conn.room))), None, &conn);
            let mut m = model.lock().unwrap();
            match res {
                Ok(st) if st["ok"].as_bool() == Some(true) => {
                    m.load_state(&st);
                    m.status = "on".into();
                    m.error = None;
                }
                Ok(st) => {
                    m.status = "error".into();
                    m.error = Some(i18n::server_error(&st));
                }
                Err(e) => {
                    m.status = "error".into();
                    m.error = Some(e);
                }
            }
            emit(&m);
            let failed = !m.loaded;
            drop(m);
            if failed {
                sleep_unless(&stop, 3000);
            }
            continue;
        }
        let (body, sent) = {
            let mut m = model.lock().unwrap();
            let ops: Vec<Value> = m.outbox.drain(..).collect();
            let body = json!({
                "room": conn.room, "user": conn.user, "cid": m.cid, "since": m.last_seq,
                "ops": ops, "presence": {"app": true, "pos": 0, "play": false, "rec": false, "sel": ""},
            });
            (body, ops)
        };
        let res = call(agent.post(&url(&conn, "/api/sync")), Some(&body), &conn);
        let mut more = false;
        {
            let mut m = model.lock().unwrap();
            match res {
                Ok(r) if r["ok"].as_bool() == Some(true) => {
                    m.status = "on".into();
                    m.error = None;
                    m.users = r["users"].as_array().cloned().unwrap_or_default();
                    if let Some(c) = r["color"].as_str() {
                        m.my_color = c.into();
                    }
                    if r["resync"].as_bool() == Some(true) {
                        m.loaded = false;
                    } else {
                        if let Some(ops) = r["ops"].as_array() {
                            for op in ops {
                                m.apply(op);
                                m.last_seq = m.last_seq.max(op["seq"].as_u64().unwrap_or(0));
                            }
                        }
                        more = r["more"].as_bool() == Some(true);
                        if !more {
                            m.last_seq = m.last_seq.max(r["seq"].as_u64().unwrap_or(0));
                        }
                    }
                }
                Ok(r) => {
                    m.status = "error".into();
                    m.error = Some(i18n::server_error(&r));
                    m.outbox.splice(0..0, sent);
                }
                Err(e) => {
                    m.status = "error".into();
                    m.error = Some(e);
                    m.outbox.splice(0..0, sent);
                }
            }
            emit(&m);
        }
        if !more {
            // krótsza pauza, gdy w kolejce czeka wiadomość do wysłania
            for _ in 0..15 {
                if stop.load(Ordering::Relaxed) || !model.lock().unwrap().outbox.is_empty() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn sleep_unless(stop: &AtomicBool, ms: u64) {
    let mut t = 0;
    while t < ms && !stop.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(100));
        t += 100;
    }
}

/// Pobiera plik audio z serwera do pamięci podręcznej (do odsłuchu w aplikacji).
pub fn fetch_file(conn: &Conn, id: &str, cache: PathBuf) -> Result<PathBuf, String> {
    if !id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '~' | '-')) {
        return Err(t("bad_name"));
    }
    let dir = cache.join("audio").join(&conn.room);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let dest = dir.join(id);
    if dest.is_file() {
        return Ok(dest);
    }
    let req = agent().get(&url(conn, &format!("/api/file?room={}&id={}", conn.room, id)));
    let req = if conn.password.is_empty() { req } else { req.set("X-RMP-Key", &conn.password) };
    let resp = req.call().map_err(|e| match e {
        ureq::Error::Status(404, _) => t("file_pending"),
        e => short_err(&e.to_string()),
    })?;
    let tmp = dest.with_extension("part");
    let mut f = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    std::io::copy(&mut resp.into_reader(), &mut f).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_item_chunk() {
        let c = "<ITEM\nPOSITION 12.5\nLENGTH 4\nNAME \"wokal take 3\"\n<SOURCE WAVE\nFILE \"rmp:wokal~10~abcd1234.wav\"\n>\n>";
        let it = item_from("{G}", c, "{T}");
        assert_eq!(it.name, "wokal take 3");
        assert_eq!(it.pos, 12.5);
        assert_eq!(it.len, 4.0);
        assert_eq!(it.file.as_deref(), Some("wokal~10~abcd1234.wav"));
        assert!(!it.midi);
    }
}
