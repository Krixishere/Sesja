// Bez okna konsoli w wersji wydanej na Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod cloud;
mod config;
mod firewall;
mod i18n;
mod reaper;
mod server;
mod session;
mod updater;

use config::Config;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

#[derive(Default)]
struct AppState {
    config: Mutex<Config>,
    session: Mutex<Option<session::Session>>,
    host: Mutex<Option<server::HostServer>>,
    /// Link sesja://… z przeglądarki, który czeka, aż interfejs go odbierze.
    pending_link: Mutex<Option<String>>,
}

/// Link „Otwórz w Sesji” ze strony zaproszenia: zapamiętaj, wyślij do interfejsu i pokaż okno.
fn handle_links<I: IntoIterator<Item = String>>(app: &AppHandle, urls: I) {
    use tauri::Emitter;
    let Some(link) = urls.into_iter().find(|u| u.starts_with("sesja://")) else { return };
    *app.state::<AppState>().pending_link.lock().unwrap() = Some(link.clone());
    let _ = app.emit("deep-link", link);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[tauri::command]
fn take_deep_link(st: State<AppState>) -> Option<String> {
    st.pending_link.lock().unwrap().take()
}

// ---------------------------------------------------------------- ustawienia

#[tauri::command]
fn get_config(st: State<AppState>) -> Config {
    st.config.lock().unwrap().clone()
}

#[tauri::command]
fn save_config(st: State<AppState>, mut cfg: Config) -> Result<Config, String> {
    cfg.room = config::safe(&cfg.room);
    cfg.password = config::safe(&cfg.password);
    cfg.host_password = config::safe(&cfg.host_password);
    cfg.nick = cfg.nick.trim().chars().take(40).collect();
    let s = cfg.server.trim().trim_end_matches('/').to_string();
    cfg.server = if s.is_empty() || s.starts_with("http://") || s.starts_with("https://") {
        s
    } else {
        format!("http://{s}")
    };
    if !i18n::LANGS.contains(&cfg.lang.as_str()) {
        cfg.lang = String::new();
    }
    i18n::set(&cfg.lang);
    config::save(&cfg)?;
    *st.config.lock().unwrap() = cfg.clone();
    Ok(cfg)
}

#[tauri::command]
fn app_info() -> Value {
    json!({
        "version": updater::VERSION,
        "mod_version": reaper::bundled_version(),
        "repo": updater::REPO,
        "os": std::env::consts::OS,
    })
}

#[tauri::command]
fn changelog() -> &'static str {
    include_str!("../../../CHANGELOG.md")
}

// ---------------------------------------------------------------- REAPER

#[tauri::command]
fn detect_reaper(st: State<AppState>) -> reaper::ReaperInfo {
    let cfg = st.config.lock().unwrap().clone();
    reaper::detect(cfg.reaper_exe.as_deref(), cfg.reaper_resource.as_deref())
}

#[tauri::command]
async fn pick_reaper_folder(app: AppHandle) -> Result<Option<reaper::ReaperInfo>, String> {
    let picked = app
        .dialog()
        .file()
        .set_title(i18n::t("pick_title"))
        .blocking_pick_folder();
    let Some(fp) = picked else { return Ok(None) };
    let path = fp.into_path().map_err(|e| e.to_string())?;
    let info = reaper::from_user_path(&path)?;
    let st = app.state::<AppState>();
    let mut cfg = st.config.lock().unwrap();
    cfg.reaper_exe = info.exe.clone();
    cfg.reaper_resource = info.resource.clone();
    let _ = config::save(&cfg);
    Ok(Some(info))
}

#[tauri::command]
fn remember_reaper(st: State<AppState>, exe: Option<String>, resource: Option<String>) -> Result<(), String> {
    let mut cfg = st.config.lock().unwrap();
    cfg.reaper_exe = exe;
    cfg.reaper_resource = resource;
    config::save(&cfg)
}

#[tauri::command]
fn install_mod(st: State<AppState>, resource: Option<String>, autostart: bool) -> Result<reaper::InstallReport, String> {
    // brak folderu ustawień = REAPER nie był jeszcze uruchomiony na tym komputerze
    let resource = resource.filter(|r| !r.trim().is_empty()).ok_or_else(|| i18n::t("run_reaper_first"))?;
    let cfg = st.config.lock().unwrap().clone();
    let conn = (!cfg.nick.is_empty()).then(|| reaper::Conn {
        server: &cfg.server,
        room: &cfg.room,
        user: &cfg.nick,
        password: &cfg.password,
        lang: i18n::current(),
        ask: cfg.ask_tracks,
        name: &cfg.room_name,
    });
    let rep = reaper::install(&resource, autostart, conn)?;
    let mut c = st.config.lock().unwrap();
    c.autostart_script = autostart;
    c.reaper_resource = Some(resource);
    let _ = config::save(&c);
    Ok(rep)
}

#[tauri::command]
fn uninstall_mod(resource: String) -> Result<(), String> {
    reaper::uninstall(&resource)
}

#[tauri::command]
fn reaper_running() -> bool {
    reaper::is_running()
}

#[tauri::command]
fn launch_reaper(st: State<AppState>) -> Result<(), String> {
    let exe = st.config.lock().unwrap().reaper_exe.clone();
    let info = reaper::detect(exe.as_deref(), None);
    let exe = info.exe.ok_or_else(|| i18n::t("no_reaper_path"))?;
    let r = if cfg!(target_os = "macos") {
        std::process::Command::new("open").arg(&exe).spawn()
    } else {
        std::process::Command::new(&exe).spawn()
    };
    let mut child = r.map_err(|e| i18n::tf("cant_launch", &[&"REAPER", &e]))?;
    // odbieramy zakończony proces, żeby nie wisiał jako „zombie” i nie udawał działającego REAPERa
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

// ---------------------------------------------------------------- sesja

#[tauri::command]
fn session_connect(app: AppHandle, st: State<AppState>) -> Result<(), String> {
    let cfg = st.config.lock().unwrap().clone();
    if cfg.nick.is_empty() || cfg.server.is_empty() || cfg.room.is_empty() {
        return Err(i18n::t("fill_profile"));
    }
    if let Some(res) = cfg.reaper_resource.as_deref() {
        let rc = reaper::Conn { server: &cfg.server, room: &cfg.room, user: &cfg.nick, password: &cfg.password, lang: i18n::current(), ask: cfg.ask_tracks, name: &cfg.room_name };
        let res = std::path::Path::new(res);
        let _ = reaper::write_handoff(res, &rc, true);
        if !reaper::is_running() {
            let _ = reaper::write_settings(res, &rc);
        }
    }
    let conn = session::Conn { server: cfg.server, room: cfg.room, user: cfg.nick, password: cfg.password };
    let mut s = st.session.lock().unwrap();
    if let Some(old) = s.take() {
        old.stop();
    }
    *s = Some(session::Session::start(app, conn));
    Ok(())
}

#[tauri::command]
async fn room_create(server: String, name: String, password: String) -> Result<Value, String> {
    let name: String = name.trim().chars().take(60).collect();
    let password = config::safe(&password);
    tauri::async_runtime::spawn_blocking(move || session::create_room(&server, &name, &password))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn room_info(server: String, room: String) -> Result<Value, String> {
    let room = config::safe(&room);
    tauri::async_runtime::spawn_blocking(move || session::room_info(&server, &room))
        .await
        .map_err(|e| e.to_string())?
}

/// Przekazuje bieżące ustawienia (np. „pytaj o nowe ścieżki”) do działającego moda.
#[tauri::command]
fn push_reaper_prefs(st: State<AppState>) {
    let cfg = st.config.lock().unwrap().clone();
    if let Some(res) = cfg.reaper_resource.as_deref() {
        let rc = reaper::Conn { server: &cfg.server, room: &cfg.room, user: &cfg.nick, password: &cfg.password, lang: i18n::current(), ask: cfg.ask_tracks, name: &cfg.room_name };
        let res = std::path::Path::new(res);
        let _ = reaper::write_handoff(res, &rc, false);
        if !reaper::is_running() {
            let _ = reaper::write_settings(res, &rc);
        }
    }
}

#[tauri::command]
fn public_server() -> &'static str {
    config::PUBLIC_SERVER
}

#[tauri::command]
fn session_disconnect(st: State<AppState>) {
    if let Some(s) = st.session.lock().unwrap().take() {
        s.stop();
    }
}

#[tauri::command]
fn session_state(st: State<AppState>) -> Option<session::Summary> {
    st.session.lock().unwrap().as_ref().map(|s| s.summary())
}

#[tauri::command]
fn send_chat(st: State<AppState>, text: String) -> Result<(), String> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Ok(());
    }
    let s = st.session.lock().unwrap();
    let s = s.as_ref().ok_or_else(|| i18n::t("not_connected"))?;
    s.send(json!({"t": "chat", "text": text}));
    Ok(())
}

#[tauri::command]
fn send_comment(
    st: State<AppState>,
    text: String,
    pos: f64,
    item: Option<String>,
    item_name: Option<String>,
) -> Result<(), String> {
    let s = st.session.lock().unwrap();
    let s = s.as_ref().ok_or_else(|| i18n::t("not_connected"))?;
    let id = format!(
        "app-{}",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
    );
    s.send(json!({"t": "comment", "id": id, "pos": pos.max(0.0), "text": text.trim(), "item": item, "itemName": item_name}));
    Ok(())
}

#[tauri::command]
fn delete_comment(st: State<AppState>, id: String) -> Result<(), String> {
    let s = st.session.lock().unwrap();
    let s = s.as_ref().ok_or_else(|| i18n::t("not_connected"))?;
    s.send(json!({"t": "comment_del", "id": id}));
    Ok(())
}

#[tauri::command]
async fn fetch_audio(app: AppHandle, id: String) -> Result<String, String> {
    let conn = {
        let st = app.state::<AppState>();
        let s = st.session.lock().unwrap();
        s.as_ref().ok_or_else(|| i18n::t("not_connected"))?.conn()
    };
    let cache = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    let p = tauri::async_runtime::spawn_blocking(move || session::fetch_file(&conn, &id, cache))
        .await
        .map_err(|e| e.to_string())??;
    Ok(p.to_string_lossy().into_owned())
}

// ---------------------------------------------------------------- hostowanie

#[tauri::command]
fn host_start(app: AppHandle, st: State<AppState>, port: u16, password: String) -> Result<Value, String> {
    let mut h = st.host.lock().unwrap();
    if let Some(old) = h.take() {
        old.stop();
        std::thread::sleep(std::time::Duration::from_millis(600));
    }
    let data = app.path().app_data_dir().map_err(|e| e.to_string())?.join("serwer");
    let srv = server::HostServer::start(port, config::safe(&password), data)?;
    let addrs = server::local_addresses(srv.port);
    *h = Some(srv);
    let mut cfg = st.config.lock().unwrap();
    cfg.host_port = port;
    cfg.host_password = config::safe(&password);
    let _ = config::save(&cfg);
    Ok(json!({"running": true, "port": port, "addresses": addrs}))
}

#[tauri::command]
fn host_stop(st: State<AppState>) {
    if let Some(h) = st.host.lock().unwrap().take() {
        h.stop();
    }
}

#[tauri::command]
fn host_status(st: State<AppState>) -> Value {
    match st.host.lock().unwrap().as_ref() {
        Some(h) => json!({"running": true, "port": h.port, "addresses": server::local_addresses(h.port)}),
        None => json!({"running": false}),
    }
}

/// Utworzenie / aktualizacja serwera Sesji na koncie Cloudflare użytkownika.
#[tauri::command]
async fn cloud_deploy(
    app: AppHandle,
    token: String,
    name: String,
    password: String,
    hostname: String,
) -> Result<Value, String> {
    let a = app.clone();
    let opts = cloud::Opts { token, name, password: config::safe(&password), hostname };
    tauri::async_runtime::spawn_blocking(move || cloud::deploy(Some(&a), cloud::API, &opts))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn firewall_status(port: u16) -> Value {
    firewall::status(port)
}

#[tauri::command]
async fn firewall_allow(port: u16) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || firewall::allow(port))
        .await
        .map_err(|e| e.to_string())?
}

// ---------------------------------------------------------------- aktualizacje, linki

#[tauri::command]
async fn check_update() -> Result<updater::UpdateInfo, String> {
    tauri::async_runtime::spawn_blocking(updater::check).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn install_update(app: AppHandle, url: String, name: String) -> Result<(), String> {
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || updater::install(&a, &url, &name))
        .await
        .map_err(|e| e.to_string())??;
    // instalator przejmuje aktualizację – zamykamy aplikację
    std::thread::sleep(std::time::Duration::from_millis(800));
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(i18n::t("bad_url"));
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    let dir = if p.is_dir() { p } else { p.parent().map(|x| x.to_path_buf()).unwrap_or(p) };
    app.opener().open_path(dir.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

/// Tryb bez okna: `sesja --serve [port] [--password HASLO] [--data KATALOG]`
/// – np. do postawienia serwera na VPS.
fn headless_server(args: &[String]) -> ! {
    let mut port = 8765u16;
    let mut password = String::new();
    let mut data = config::base_dir().join("serwer");
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--password" => {
                password = args.get(i + 1).cloned().unwrap_or_default();
                i += 1;
            }
            "--data" => {
                data = PathBuf::from(args.get(i + 1).cloned().unwrap_or_default());
                i += 1;
            }
            s => {
                if let Ok(p) = s.parse() {
                    port = p;
                }
            }
        }
        i += 1;
    }
    match server::HostServer::start(port, config::safe(&password), data.clone()) {
        Ok(_srv) => {
            println!("Sesja: server running on port {port} (data: {})", data.display());
            for a in server::local_addresses(port) {
                println!("  {}  ({})", a["url"].as_str().unwrap_or(""), a["kind"].as_str().unwrap_or(""));
            }
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(|a| a == "--serve").unwrap_or(false) {
        headless_server(&args[1..]);
    }
    let builder = tauri::Builder::default();
    // druga kopia aplikacji (np. kliknięty link sesja://) przekazuje link pierwszej i się zamyka
    #[cfg(any(windows, target_os = "linux"))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
        handle_links(app, argv);
    }));
    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage({
            let cfg = config::load();
            i18n::set(&cfg.lang);
            AppState { config: Mutex::new(cfg), ..Default::default() }
        })
        .setup(|app| {
            use tauri_plugin_deep_link::DeepLinkExt;
            // Linux (AppImage) i uruchomienia deweloperskie: zarejestruj sesja:// przy starcie
            #[cfg(any(windows, target_os = "linux"))]
            let _ = app.deep_link().register_all();
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |e| {
                handle_links(&handle, e.urls().into_iter().map(|u| u.to_string()));
            });
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                handle_links(app.handle(), urls.into_iter().map(|u| u.to_string()));
            }
            let st = app.state::<AppState>();
            let cfg = st.config.lock().unwrap().clone();
            if cfg.host_on_start {
                if let Ok(data) = app.path().app_data_dir() {
                    if let Ok(srv) =
                        server::HostServer::start(cfg.host_port, cfg.host_password.clone(), data.join("serwer"))
                    {
                        *st.host.lock().unwrap() = Some(srv);
                    }
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            app_info,
            changelog,
            detect_reaper,
            pick_reaper_folder,
            remember_reaper,
            install_mod,
            uninstall_mod,
            reaper_running,
            launch_reaper,
            session_connect,
            room_create,
            room_info,
            public_server,
            take_deep_link,
            push_reaper_prefs,
            session_disconnect,
            session_state,
            send_chat,
            send_comment,
            delete_comment,
            fetch_audio,
            host_start,
            host_stop,
            host_status,
            firewall_status,
            firewall_allow,
            cloud_deploy,
            check_update,
            install_update,
            open_url,
            open_path,
        ])
        .run(tauri::generate_context!())
        .expect("nie udało się uruchomić aplikacji Sesja");
}
