//! Ustawienia aplikacji zapisywane w katalogu konfiguracji użytkownika.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    /// Czy użytkownik przeszedł już przez instalator powitalny.
    pub onboarded: bool,
    pub nick: String,
    /// Adres serwera, np. http://100.101.102.103:8765
    pub server: String,
    pub room: String,
    pub password: String,
    pub reaper_exe: Option<String>,
    pub reaper_resource: Option<String>,
    pub auto_update: bool,
    pub autostart_script: bool,
    /// Ustawienia serwera hostowanego w aplikacji.
    pub host_port: u16,
    pub host_password: String,
    pub host_on_start: bool,
    /// Język interfejsu: pl, en, de, es, fr; pusty = wykryj z systemu.
    pub lang: String,
    /// Adres serwera utworzonego w chmurze (Cloudflare), jeśli taki jest.
    pub cloud_url: String,
    /// Nazwa sesji założonej przez „Utwórz sesję” (pokój to wtedy losowy kod z linku).
    pub room_name: String,
    /// Mod pyta, zanim nowa ścieżka trafi do pokoju.
    pub ask_tracks: bool,
    /// Klucze gospodarza do sesji, które założyłeś: kod sesji -> klucz.
    pub admin_keys: std::collections::HashMap<String, String>,
}

/// Domyślny, wspólny serwer Sesji – wszyscy zakładają i dołączają do sesji tutaj.
pub const PUBLIC_SERVER: &str = "https://sesja.krixishere.org";

impl Default for Config {
    fn default() -> Self {
        Config {
            onboarded: false,
            nick: String::new(),
            server: PUBLIC_SERVER.into(),
            room: String::new(),
            password: String::new(),
            reaper_exe: None,
            reaper_resource: None,
            auto_update: true,
            autostart_script: true,
            host_port: 8765,
            host_password: String::new(),
            host_on_start: false,
            lang: String::new(),
            cloud_url: String::new(),
            room_name: String::new(),
            ask_tracks: true,
            admin_keys: Default::default(),
        }
    }
}

pub fn base_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Sesja")
}

fn path() -> PathBuf {
    base_dir().join("config.json")
}

pub fn load() -> Config {
    std::fs::read_to_string(path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(cfg: &Config) -> Result<(), String> {
    let p = path();
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let s = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    std::fs::write(&p, s).map_err(|e| crate::i18n::tf("save_settings", &[&e]))
}

/// Tylko znaki bezpieczne w nazwie pokoju / haśle (tak samo jak w skrypcie Lua).
pub fn safe(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .collect()
}
