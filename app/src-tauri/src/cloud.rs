//! „Utwórz serwer w chmurze”: wgrywa serwer Sesji (server/cloudflare/src/index.js)
//! na konto Cloudflare użytkownika przez API – bez terminala i wranglera.
//! Potrzebny jest tylko token API z szablonu „Edit Cloudflare Workers”.

use serde_json::{json, Value};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

pub const API: &str = "https://api.cloudflare.com/client/v4";
pub const WORKER_JS: &str = include_str!("../../../server/cloudflare/src/index.js");
const COMPAT_DATE: &str = "2025-09-01";

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        .build()
}

/// Odpowiedź API Cloudflare: {success, errors:[{code,message}], result}
fn cf(res: Result<ureq::Response, ureq::Error>) -> Result<Value, String> {
    let v: Value = match res {
        Ok(r) => r.into_json().map_err(|e| e.to_string())?,
        Err(ureq::Error::Status(code, r)) => {
            let v: Value = r.into_json().unwrap_or(json!({}));
            if v["errors"].is_array() {
                v
            } else {
                return Err(format!("HTTP {code}"));
            }
        }
        Err(e) => return Err(crate::i18n::tf("cant_connect", &[&"api.cloudflare.com", &e])),
    };
    if v["success"].as_bool() == Some(true) {
        Ok(v["result"].clone())
    } else {
        let msg = v["errors"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|e| format!("{} ({})", e["message"].as_str().unwrap_or("?"), e["code"]))
                    .collect::<Vec<_>>()
                    .join("; ")
            })
            .unwrap_or_else(|| "?".into());
        Err(msg)
    }
}

pub struct Opts {
    pub token: String,
    pub name: String,
    pub password: String,
    /// np. "sesja.mojadomena.pl" – pusty = tylko adres workers.dev
    pub hostname: String,
}

fn step(app: Option<&AppHandle>, id: &str, state: &str, detail: &str) {
    if let Some(a) = app {
        let _ = a.emit("cloud-progress", json!({"step": id, "state": state, "detail": detail}));
    }
}

/// Treść multipart do wgrania skryptu (moduł ES + metadane z Durable Object).
fn multipart(metadata: &Value) -> (String, Vec<u8>) {
    let boundary = format!("----sesja{:x}", std::process::id() as u64 * 7919 + 17);
    let mut body = Vec::new();
    let mut part = |name: &str, filename: Option<&str>, ctype: &str, data: &[u8]| {
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        match filename {
            Some(f) => body.extend_from_slice(
                format!("Content-Disposition: form-data; name=\"{name}\"; filename=\"{f}\"\r\n").as_bytes(),
            ),
            None => body.extend_from_slice(format!("Content-Disposition: form-data; name=\"{name}\"\r\n").as_bytes()),
        }
        body.extend_from_slice(format!("Content-Type: {ctype}\r\n\r\n").as_bytes());
        body.extend_from_slice(data);
        body.extend_from_slice(b"\r\n");
    };
    part("metadata", None, "application/json", metadata.to_string().as_bytes());
    part("index.js", Some("index.js"), "application/javascript+module", WORKER_JS.as_bytes());
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    (boundary, body)
}

fn safe_label(s: &str) -> String {
    let mut out: String = s
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    out.trim_matches('-').chars().take(40).collect()
}

/// Cały proces. `api` pozwala testom podstawić atrapę API Cloudflare.
pub fn deploy(app: Option<&AppHandle>, api: &str, o: &Opts) -> Result<Value, String> {
    let ag = agent();
    let auth = format!("Bearer {}", o.token.trim());
    let get = |path: &str| ag.get(&format!("{api}{path}")).set("Authorization", &auth);
    let name = {
        let n = safe_label(&o.name);
        if n.is_empty() { "sesja-server".to_string() } else { n }
    };

    // 1) konto
    step(app, "account", "run", "");
    let accounts = cf(get("/accounts?per_page=50").call()).map_err(|e| {
        step(app, "account", "fail", &e);
        crate::i18n::tf("cf_token_bad", &[&e])
    })?;
    let acc = accounts.as_array().and_then(|a| a.first()).cloned().ok_or_else(|| {
        step(app, "account", "fail", "");
        crate::i18n::t("cf_no_account")
    })?;
    let acc_id = acc["id"].as_str().unwrap_or("").to_string();
    step(app, "account", "ok", acc["name"].as_str().unwrap_or(""));

    // 2) wgranie serwera (z migracją Durable Object przy pierwszym razie)
    step(app, "upload", "run", "");
    let script_path = format!("{api}/accounts/{acc_id}/workers/scripts/{name}");
    let upload = |with_migration: bool| {
        let mut meta = json!({
            "main_module": "index.js",
            "compatibility_date": COMPAT_DATE,
            "bindings": [{"type": "durable_object_namespace", "name": "ROOMS", "class_name": "Room"}],
        });
        if with_migration {
            meta["migrations"] = json!({"new_tag": "v1", "new_sqlite_classes": ["Room"]});
        }
        let (boundary, body) = multipart(&meta);
        cf(ag
            .put(&script_path)
            .set("Authorization", &auth)
            .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
            .send_bytes(&body))
    };
    // ponowne wdrożenie: migracja v1 już istnieje – wtedy wgrywamy bez niej
    let up = upload(true).or_else(|e| {
        if e.to_lowercase().contains("migration") || e.to_lowercase().contains("tag") {
            upload(false)
        } else {
            Err(e)
        }
    });
    up.map_err(|e| {
        step(app, "upload", "fail", &e);
        crate::i18n::tf("cf_upload_failed", &[&e])
    })?;
    step(app, "upload", "ok", &name);

    // 3) hasło serwera (sekret)
    if !o.password.is_empty() {
        step(app, "secret", "run", "");
        cf(ag
            .put(&format!("{script_path}/secrets"))
            .set("Authorization", &auth)
            .send_json(json!({"name": "PASSWORD", "text": o.password, "type": "secret_text"})))
        .map_err(|e| {
            step(app, "secret", "fail", &e);
            e
        })?;
        step(app, "secret", "ok", "");
    }

    // 4) adres workers.dev
    step(app, "subdomain", "run", "");
    let sub = match cf(get(&format!("/accounts/{acc_id}/workers/subdomain")).call()) {
        Ok(v) if v["subdomain"].as_str().map(|s| !s.is_empty()).unwrap_or(false) => {
            v["subdomain"].as_str().unwrap().to_string()
        }
        _ => {
            // konto bez subdomeny workers.dev – zakładamy ją
            let base = safe_label(acc["name"].as_str().unwrap_or("sesja"));
            let want = format!("{}-{:x}", if base.is_empty() { "sesja".into() } else { base }, std::process::id() % 4096);
            let v = cf(ag
                .put(&format!("{api}/accounts/{acc_id}/workers/subdomain"))
                .set("Authorization", &auth)
                .send_json(json!({"subdomain": want})))
            .map_err(|e| {
                step(app, "subdomain", "fail", &e);
                e
            })?;
            v["subdomain"].as_str().unwrap_or(&want).to_string()
        }
    };
    let _ = cf(ag
        .post(&format!("{script_path}/subdomain"))
        .set("Authorization", &auth)
        .send_json(json!({"enabled": true, "previews_enabled": false})));
    let workers_dev = format!("https://{name}.{sub}.workers.dev");
    step(app, "subdomain", "ok", &workers_dev);

    // 5) własna domena (opcjonalnie)
    let mut url = workers_dev.clone();
    let host = o.hostname.trim().trim_start_matches("https://").trim_start_matches("http://").trim_end_matches('/').to_lowercase();
    let mut domain_error = None;
    if !host.is_empty() {
        step(app, "domain", "run", &host);
        let res = (|| -> Result<(), String> {
            let zones = cf(get("/zones?per_page=50").call())?;
            let zone = zones
                .as_array()
                .into_iter()
                .flatten()
                .filter(|z| {
                    let zn = z["name"].as_str().unwrap_or("");
                    host == zn || host.ends_with(&format!(".{zn}"))
                })
                .max_by_key(|z| z["name"].as_str().unwrap_or("").len())
                .cloned()
                .ok_or_else(|| crate::i18n::tf("cf_no_zone", &[&host]))?;
            cf(ag
                .put(&format!("{api}/accounts/{acc_id}/workers/domains"))
                .set("Authorization", &auth)
                .send_json(json!({
                    "environment": "production", "hostname": host, "service": name,
                    "zone_id": zone["id"],
                })))?;
            Ok(())
        })();
        match res {
            Ok(()) => {
                url = format!("https://{host}");
                step(app, "domain", "ok", &url);
            }
            Err(e) => {
                // serwer i tak działa pod workers.dev – domena nie blokuje całości
                step(app, "domain", "fail", &e);
                domain_error = Some(e);
            }
        }
    }

    // 6) czy serwer odpowiada (nowy adres potrzebuje chwili); w testach z atrapą API pomijamy
    step(app, "check", "run", &url);
    let mut alive = false;
    for _ in 0..(if api == API { 12 } else { 0 }) {
        if let Ok(r) = ag.get(&format!("{url}/api/ping")).call() {
            if r.into_json::<Value>().map(|v| v["app"] == "Sesja").unwrap_or(false) {
                alive = true;
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(2500));
    }
    step(app, "check", if alive { "ok" } else { "wait" }, &url);
    Ok(json!({"url": url, "workers_dev": workers_dev, "alive": alive, "domain_error": domain_error, "name": name}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    /// Atrapa API Cloudflare: sprawdza kształt zapytań, które wysyła deploy().
    #[test]
    fn deploys_against_mock_api() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");
        let base2 = base.clone();
        let handle = std::thread::spawn(move || {
            let mut seen = Vec::new();
            let mut first_upload = true;
            for mut req in server.incoming_requests() {
                let url = req.url().to_string();
                let method = req.method().to_string();
                let auth = req.headers().iter().find(|h| h.field.equiv("Authorization")).map(|h| h.value.to_string());
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                seen.push(format!("{method} {url}"));
                let ok = |r: Value| json!({"success": true, "errors": [], "result": r}).to_string();
                let resp = if auth.as_deref() != Some("Bearer tok") {
                    json!({"success": false, "errors": [{"code": 10000, "message": "Authentication error"}]}).to_string()
                } else if url.starts_with("/accounts?") {
                    ok(json!([{"id": "acc1", "name": "Krix Studio"}]))
                } else if method == "PUT" && url == "/accounts/acc1/workers/scripts/sesja-server" {
                    assert!(body.contains("\"main_module\":\"index.js\""));
                    assert!(body.contains("durable_object_namespace"));
                    assert!(body.contains("export class Room"));
                    if first_upload && body.contains("new_sqlite_classes") {
                        first_upload = false;
                        // udajemy ponowne wdrożenie: migracja już była
                        json!({"success": false, "errors": [{"code": 10074, "message": "migration tag precondition failed"}]}).to_string()
                    } else {
                        assert!(!body.contains("new_sqlite_classes"));
                        ok(json!({"id": "sesja-server"}))
                    }
                } else if url.ends_with("/secrets") {
                    assert!(body.contains("PASSWORD"));
                    ok(json!({}))
                } else if url == "/accounts/acc1/workers/subdomain" {
                    ok(json!({"subdomain": "krix"}))
                } else if url.ends_with("/subdomain") {
                    ok(json!({}))
                } else if url.starts_with("/zones") {
                    ok(json!([{"id": "z1", "name": "mojadomena.pl"}, {"id": "z2", "name": "inna.pl"}]))
                } else if url == "/accounts/acc1/workers/domains" {
                    assert!(body.contains("\"zone_id\":\"z1\"") && body.contains("sesja.mojadomena.pl"));
                    ok(json!({}))
                } else {
                    ok(json!({}))
                };
                let last = url == "/accounts/acc1/workers/domains";
                let _ = req.respond(tiny_http::Response::from_string(resp));
                if last {
                    break;
                }
            }
            seen
        });
        let o = Opts { token: "tok".into(), name: "Sesja Server".into(), password: "abc".into(), hostname: "Sesja.mojadomena.pl".into() };
        // sprawdzanie „czy żyje” idzie pod prawdziwy adres – tu go nie ma, więc wynik alive=false jest oczekiwany
        let r = std::thread::spawn(move || deploy(None, &base2, &o)).join().unwrap();
        let seen = handle.join().unwrap();
        let r = r.unwrap();
        assert_eq!(r["url"], "https://sesja.mojadomena.pl");
        assert_eq!(r["workers_dev"], "https://sesja-server.krix.workers.dev");
        assert!(seen.iter().any(|s| s.starts_with("PUT /accounts/acc1/workers/scripts/sesja-server")));
        let _ = base;
    }

    #[test]
    fn bad_token_gives_clear_error() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        std::thread::spawn(move || {
            if let Some(req) = server.incoming_requests().next() {
                let _ = req.respond(
                    tiny_http::Response::from_string(
                        json!({"success": false, "errors": [{"code": 9109, "message": "Invalid access token"}]}).to_string(),
                    )
                    .with_status_code(403),
                );
            }
        });
        let o = Opts { token: "zly".into(), name: "x".into(), password: "".into(), hostname: "".into() };
        let e = deploy(None, &format!("http://127.0.0.1:{port}"), &o).unwrap_err();
        assert!(e.contains("Invalid access token"), "{e}");
    }
}
