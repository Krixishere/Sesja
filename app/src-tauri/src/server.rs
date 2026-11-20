//! Wbudowany serwer sesji – ten sam protokół co server/rmp_server.py.
//! Dzięki temu gospodarz nie musi instalować Pythona: klika „Hostuj” w aplikacji.

use md5::{Digest, Md5};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

const MAX_OPS_PER_RESPONSE: usize = 400;
const MAX_LOG: usize = 20000;
const MAX_CHAT: usize = 500;
const ONLINE_TIMEOUT: f64 = 15.0;
const PALETTE: [&str; 16] = [
    "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6",
    "#bcf60c", "#fabebe", "#008080", "#e6beff", "#9a6324", "#fffac8", "#aaffc3", "#ffd8b1",
];

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn user_color(name: &str) -> &'static str {
    let h = Md5::digest(name.as_bytes());
    // tak jak w Pythonie: int(md5, 16) % 16 == ostatni nibble
    PALETTE[(h[15] & 0x0f) as usize]
}

fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 200
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '~' | '-'))
}

struct User {
    name: String,
    last: f64,
    presence: Value,
}

#[derive(Default)]
struct Room {
    dir: PathBuf,
    seq: u64,
    log: Vec<Value>,
    log_floor: u64,
    tracks: Map<String, Value>,
    items: Map<String, Value>,
    order: Vec<Value>,
    tempo: Value,
    comments: Map<String, Value>,
    chat: Vec<Value>,
    users: HashMap<String, User>,
    dirty: bool,
}

impl Room {
    fn open(dir: PathBuf) -> Room {
        let _ = fs::create_dir_all(dir.join("files"));
        let mut r = Room { dir, tempo: Value::Null, ..Default::default() };
        if let Ok(s) = fs::read_to_string(r.dir.join("state.json")) {
            if let Ok(d) = serde_json::from_str::<Value>(&s) {
                r.seq = d["seq"].as_u64().unwrap_or(0);
                r.log_floor = r.seq;
                r.tracks = d["tracks"].as_object().cloned().unwrap_or_default();
                r.items = d["items"].as_object().cloned().unwrap_or_default();
                r.order = d["order"].as_array().cloned().unwrap_or_default();
                r.tempo = d["tempo"].clone();
                r.comments = d["comments"].as_object().cloned().unwrap_or_default();
                r.chat = d["chat"].as_array().cloned().unwrap_or_default();
            }
        }
        r
    }

    fn save(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;
        let d = json!({
            "seq": self.seq, "tracks": self.tracks, "items": self.items, "order": self.order,
            "tempo": self.tempo, "comments": self.comments, "chat": self.chat,
        });
        let tmp = self.dir.join("state.json.tmp");
        if fs::write(&tmp, d.to_string()).is_ok() {
            let _ = fs::rename(&tmp, self.dir.join("state.json"));
        }
    }

    fn apply_op(&mut self, op: &Value) -> bool {
        let t = op["t"].as_str().unwrap_or("");
        let user = op["user"].clone();
        let ts = op["ts"].clone();
        let guid = op["guid"].as_str().unwrap_or("").to_string();
        match t {
            "track" if !guid.is_empty() => {
                let prev = self.tracks.get(&guid).cloned();
                self.tracks.insert(
                    guid.clone(),
                    json!({
                        "chunk": op["chunk"].as_str().unwrap_or(""),
                        "author": prev.as_ref().map(|p| p["author"].clone()).unwrap_or(user.clone()),
                        "created": prev.as_ref().map(|p| p["created"].clone()).unwrap_or(ts.clone()),
                        "editor": user, "ts": ts,
                    }),
                );
                if !self.order.iter().any(|g| g.as_str() == Some(&guid)) {
                    self.order.push(Value::String(guid));
                }
            }
            "track_del" => {
                self.tracks.remove(&guid);
                self.order.retain(|g| g.as_str() != Some(&guid));
                self.items.retain(|_, v| v["track"].as_str() != Some(&guid));
            }
            "item" if !guid.is_empty() => {
                let prev = self.items.get(&guid).cloned();
                self.items.insert(
                    guid,
                    json!({
                        "chunk": op["chunk"].as_str().unwrap_or(""), "track": op["track"],
                        "author": prev.as_ref().map(|p| p["author"].clone()).unwrap_or(user.clone()),
                        "created": prev.as_ref().map(|p| p["created"].clone()).unwrap_or(ts.clone()),
                        "editor": user, "ts": ts,
                    }),
                );
            }
            "item_del" => {
                self.items.remove(&guid);
            }
            "order" => {
                if let Some(l) = op["list"].as_array() {
                    self.order = l.iter().filter(|v| v.is_string()).cloned().collect();
                }
            }
            "tempo" => self.tempo = json!({"bpm": op["bpm"], "user": user, "ts": ts}),
            "comment" => {
                let Some(id) = op["id"].as_str() else { return false };
                self.comments.insert(
                    id.to_string(),
                    json!({
                        "id": id, "pos": op["pos"].as_f64().unwrap_or(0.0),
                        "text": op["text"].as_str().unwrap_or(""), "user": user, "ts": ts,
                        "item": op["item"], "itemName": op["itemName"],
                    }),
                );
            }
            "comment_del" => {
                if let Some(id) = op["id"].as_str() {
                    self.comments.remove(id);
                }
            }
            "chat" => {
                self.chat.push(json!({"user": user, "text": op["text"].as_str().unwrap_or(""), "ts": ts}));
                if self.chat.len() > MAX_CHAT {
                    let cut = self.chat.len() - MAX_CHAT;
                    self.chat.drain(..cut);
                }
            }
            _ => return false,
        }
        true
    }

    fn add_ops(&mut self, ops: &[Value], user: &str, cid: &str) {
        for op in ops {
            let Some(obj) = op.as_object() else { continue };
            let mut o = obj.clone();
            o.insert("user".into(), json!(user));
            o.insert("cid".into(), json!(cid));
            o.insert("ts".into(), json!(now()));
            let mut v = Value::Object(o);
            if !self.apply_op(&v) {
                continue;
            }
            self.seq += 1;
            v["seq"] = json!(self.seq);
            self.log.push(v);
            self.dirty = true;
        }
        if self.log.len() > MAX_LOG {
            let cut = self.log.len() - MAX_LOG;
            self.log_floor = self.log[cut - 1]["seq"].as_u64().unwrap_or(0);
            self.log.drain(..cut);
        }
    }

    fn ops_since(&self, since: u64) -> Option<(Vec<Value>, bool)> {
        if since < self.log_floor {
            return None;
        }
        let start = self.log.partition_point(|o| o["seq"].as_u64().unwrap_or(0) <= since);
        let end = (start + MAX_OPS_PER_RESPONSE).min(self.log.len());
        Some((self.log[start..end].to_vec(), end < self.log.len()))
    }

    fn online(&mut self) -> Vec<Value> {
        let t = now();
        self.users.retain(|_, u| t - u.last <= ONLINE_TIMEOUT);
        self.users
            .iter()
            .map(|(cid, u)| {
                let p = &u.presence;
                json!({
                    "cid": cid, "name": u.name, "color": user_color(&u.name),
                    "pos": p["pos"].as_f64().unwrap_or(0.0), "play": p["play"].as_bool().unwrap_or(false),
                    "rec": p["rec"].as_bool().unwrap_or(false), "sel": p["sel"].as_str().unwrap_or(""),
                    "app": p["app"].as_bool().unwrap_or(false),
                })
            })
            .collect()
    }

    fn file(&self, id: &str) -> PathBuf {
        self.dir.join("files").join(id)
    }
}

struct Shared {
    data: PathBuf,
    password: String,
    rooms: Mutex<HashMap<String, Arc<Mutex<Room>>>>,
}

impl Shared {
    fn room(&self, name: &str) -> Arc<Mutex<Room>> {
        let mut rooms = self.rooms.lock().unwrap();
        rooms
            .entry(name.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(Room::open(self.data.join(name)))))
            .clone()
    }
}

pub struct HostServer {
    stop: Arc<AtomicBool>,
    server: Arc<Server>,
    pub port: u16,
}

impl HostServer {
    pub fn start(port: u16, password: String, data: PathBuf) -> Result<HostServer, String> {
        fs::create_dir_all(&data).map_err(|e| e.to_string())?;
        let server = Server::http(("0.0.0.0", port))
            .map_err(|e| format!("Nie mogę uruchomić serwera na porcie {port}: {e}"))?;
        let server = Arc::new(server);
        let shared = Arc::new(Shared { data, password, rooms: Mutex::new(HashMap::new()) });
        let stop = Arc::new(AtomicBool::new(false));
        for _ in 0..8 {
            let server = server.clone();
            let shared = shared.clone();
            let stop = stop.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    match server.recv_timeout(Duration::from_millis(500)) {
                        Ok(Some(req)) => handle(&shared, req),
                        Ok(None) => {}
                        Err(_) => break,
                    }
                }
            });
        }
        {
            let shared = shared.clone();
            let stop = stop.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_secs(2));
                let rooms: Vec<_> = shared.rooms.lock().unwrap().values().cloned().collect();
                for r in rooms {
                    r.lock().unwrap().save();
                }
                if stop.load(Ordering::Relaxed) {
                    break;
                }
            });
        }
        Ok(HostServer { stop, server, port })
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.server.unblock();
    }
}

impl Drop for HostServer {
    fn drop(&mut self) {
        self.stop();
    }
}

fn json_response(code: u16, mut obj: Map<String, Value>) -> Response<std::io::Cursor<Vec<u8>>> {
    obj.remove("_end");
    obj.insert("_end".into(), Value::Bool(true)); // klient Lua sprawdza ten znacznik na końcu
    Response::from_data(Value::Object(obj).to_string().into_bytes())
        .with_status_code(code)
        .with_header(Header::from_bytes("Content-Type", "application/json; charset=utf-8").unwrap())
}

fn err(code: u16, msg: &str) -> Response<std::io::Cursor<Vec<u8>>> {
    let mut m = Map::new();
    m.insert("ok".into(), json!(false));
    m.insert("error".into(), json!(msg));
    json_response(code, m)
}

fn query(url: &str) -> (String, HashMap<String, String>) {
    let (path, q) = url.split_once('?').unwrap_or((url, ""));
    let mut map = HashMap::new();
    for pair in q.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            map.insert(k.to_string(), percent_decode(v));
        }
    }
    (path.to_string(), map)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn header<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn handle(sh: &Shared, mut req: Request) {
    let (path, q) = query(req.url());
    let method = req.method().clone();

    if path == "/" || path == "/api/ping" {
        let mut m = Map::new();
        m.insert("ok".into(), json!(true));
        m.insert("app".into(), json!("Sesja"));
        m.insert("auth".into(), json!(!sh.password.is_empty()));
        let _ = req.respond(json_response(200, m));
        return;
    }
    if !sh.password.is_empty() && header(&req, "X-RMP-Key") != Some(sh.password.as_str()) {
        let _ = req.respond(err(403, "Złe hasło serwera"));
        return;
    }

    match (method, path.as_str()) {
        (Method::Get, "/api/state") => {
            let Some(name) = q.get("room").filter(|r| safe_name(r)) else {
                let _ = req.respond(err(400, "Niepoprawna nazwa pokoju"));
                return;
            };
            let room = sh.room(name);
            let r = room.lock().unwrap();
            let mut m = Map::new();
            m.insert("ok".into(), json!(true));
            m.insert("seq".into(), json!(r.seq));
            m.insert("tracks".into(), Value::Object(r.tracks.clone()));
            m.insert("items".into(), Value::Object(r.items.clone()));
            m.insert("order".into(), Value::Array(r.order.clone()));
            m.insert("tempo".into(), r.tempo.clone());
            m.insert("comments".into(), Value::Array(r.comments.values().cloned().collect()));
            let from = r.chat.len().saturating_sub(200);
            m.insert("chat".into(), Value::Array(r.chat[from..].to_vec()));
            drop(r);
            let _ = req.respond(json_response(200, m));
        }
        (Method::Get, "/api/file") => {
            let (Some(name), Some(id)) = (q.get("room"), q.get("id")) else {
                let _ = req.respond(err(400, "Brak parametrów"));
                return;
            };
            if !safe_name(name) || !safe_name(id) {
                let _ = req.respond(err(400, "Zła nazwa"));
                return;
            }
            let p = sh.room(name).lock().unwrap().file(id);
            match fs::File::open(&p) {
                Ok(f) => {
                    let _ = req.respond(Response::from_file(f).with_header(
                        Header::from_bytes("Content-Type", "application/octet-stream").unwrap(),
                    ));
                }
                Err(_) => {
                    let _ = req.respond(err(404, "Brak pliku"));
                }
            }
        }
        (Method::Put, "/api/file") => {
            let (Some(name), Some(id)) = (q.get("room").cloned(), q.get("id").cloned()) else {
                let _ = req.respond(err(400, "Brak parametrów"));
                return;
            };
            if !safe_name(&name) || !safe_name(&id) {
                let _ = req.respond(err(400, "Zła nazwa"));
                return;
            }
            let expected = req.body_length();
            let dest = sh.room(&name).lock().unwrap().file(&id);
            let tmp = dest.with_extension(format!("part{}", std::process::id() as u64 + now() as u64));
            let res = (|| -> std::io::Result<u64> {
                let mut f = fs::File::create(&tmp)?;
                let n = std::io::copy(req.as_reader(), &mut f)?;
                f.flush()?;
                Ok(n)
            })();
            match res {
                Ok(n) if expected.map(|e| e as u64 == n).unwrap_or(true) => {
                    let _ = fs::rename(&tmp, &dest);
                    let mut m = Map::new();
                    m.insert("ok".into(), json!(true));
                    m.insert("id".into(), json!(id));
                    m.insert("size".into(), json!(n));
                    let _ = req.respond(json_response(200, m));
                }
                _ => {
                    let _ = fs::remove_file(&tmp);
                    let _ = req.respond(err(400, "Przerwany upload"));
                }
            }
        }
        (Method::Post, "/api/sync") => {
            let mut body = String::new();
            if req.as_reader().read_to_string(&mut body).is_err() {
                let _ = req.respond(err(400, "Zły JSON"));
                return;
            }
            let Ok(b) = serde_json::from_str::<Value>(&body) else {
                let _ = req.respond(err(400, "Zły JSON"));
                return;
            };
            let Some(name) = b["room"].as_str().filter(|r| safe_name(r)) else {
                let _ = req.respond(err(400, "Niepoprawna nazwa pokoju"));
                return;
            };
            let user: String = b["user"].as_str().unwrap_or("anon").chars().take(40).collect();
            let cid: String = b["cid"].as_str().unwrap_or("").chars().take(64).collect();
            let since = b["since"].as_u64().unwrap_or(0);
            let room = sh.room(name);
            let mut r = room.lock().unwrap();
            r.users.insert(
                cid.clone(),
                User { name: user.clone(), last: now(), presence: b["presence"].clone() },
            );
            if let Some(ops) = b["ops"].as_array() {
                r.add_ops(ops, &user, &cid);
            }
            let mut m = Map::new();
            m.insert("ok".into(), json!(true));
            m.insert("seq".into(), json!(r.seq));
            m.insert("users".into(), Value::Array(r.online()));
            m.insert("color".into(), json!(user_color(&user)));
            match r.ops_since(since) {
                None => {
                    m.insert("resync".into(), json!(true));
                    m.insert("ops".into(), json!([]));
                }
                Some((ops, more)) => {
                    m.insert("ops".into(), Value::Array(ops));
                    m.insert("more".into(), json!(more));
                }
            }
            let has = |id: &str| safe_name(id) && r.file(id).is_file();
            if let Some(check) = b["check"].as_array() {
                let missing: Vec<Value> = check
                    .iter()
                    .filter_map(|v| v.as_str())
                    .filter(|id| safe_name(id) && !has(id))
                    .map(|s| json!(s))
                    .collect();
                m.insert("missing".into(), Value::Array(missing));
            }
            if let Some(want) = b["want"].as_array() {
                let avail: Vec<Value> =
                    want.iter().filter_map(|v| v.as_str()).filter(|id| has(id)).map(|s| json!(s)).collect();
                m.insert("available".into(), Value::Array(avail));
            }
            drop(r);
            let _ = req.respond(json_response(200, m));
        }
        _ => {
            let _ = req.respond(err(404, "Nieznany adres"));
        }
    }
}

/// Adresy, pod którymi inni mogą się połączyć (LAN, Tailscale, ZeroTier…).
pub fn local_addresses(port: u16) -> Vec<Value> {
    let mut out = Vec::new();
    if let Ok(ifs) = if_addrs::get_if_addrs() {
        for i in ifs {
            if i.is_loopback() {
                continue;
            }
            let ip = i.ip();
            if !ip.is_ipv4() {
                continue;
            }
            let s = ip.to_string();
            let kind = if s.starts_with("100.") {
                "Tailscale"
            } else if s.starts_with("192.168.") || s.starts_with("10.") || s.starts_with("172.") {
                "sieć lokalna"
            } else {
                "inna sieć"
            };
            out.push(json!({"url": format!("http://{s}:{port}"), "kind": kind, "iface": i.name}));
        }
    }
    out.push(json!({"url": format!("http://127.0.0.1:{port}"), "kind": "ten komputer", "iface": "lo"}));
    out
}

#[allow(dead_code)]
pub fn data_dir(base: &Path) -> PathBuf {
    base.join("serwer")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colors_match_python() {
        // python: PALETTE[int(md5("Ania").hexdigest(),16) % 16]
        let h = Md5::digest("Ania".as_bytes());
        let last = h[15] & 0x0f;
        assert_eq!(user_color("Ania"), PALETTE[last as usize]);
    }

    #[test]
    fn decode() {
        assert_eq!(percent_decode("a%20b+c"), "a b c");
        assert_eq!(query("/api/file?room=x&id=a~1~ff.wav").1["id"], "a~1~ff.wav");
    }
}
