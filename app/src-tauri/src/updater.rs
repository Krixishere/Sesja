//! Automatyczne aktualizacje i dziennik zmian z wydań na GitHubie.

use serde::Serialize;
use serde_json::Value;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

pub const REPO: &str = "krixishere/repomulitplayer";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Serialize, Clone)]
pub struct Release {
    pub tag: String,
    pub name: String,
    pub body: String,
    pub date: String,
    pub url: String,
}

#[derive(Serialize, Clone)]
pub struct UpdateInfo {
    pub current: String,
    pub latest: Option<String>,
    pub newer: bool,
    pub asset_name: Option<String>,
    pub asset_url: Option<String>,
    pub notes: String,
    pub releases: Vec<Release>,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).build()
}

/// "v1.2.3" -> [1,2,3]
pub fn parse_ver(s: &str) -> Vec<u64> {
    s.trim_start_matches(['v', 'V'])
        .split(['.', '-', '+'])
        .take(3)
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

pub fn is_newer(latest: &str, current: &str) -> bool {
    let (a, b) = (parse_ver(latest), parse_ver(current));
    for i in 0..3 {
        let (x, y) = (*a.get(i).unwrap_or(&0), *b.get(i).unwrap_or(&0));
        if x != y {
            return x > y;
        }
    }
    false
}

fn pick_asset(assets: &[Value]) -> Option<(String, String)> {
    let suffixes: &[&str] = if cfg!(windows) {
        &["-setup.exe", ".exe", ".msi"]
    } else if cfg!(target_os = "macos") {
        &[".dmg"]
    } else {
        &[".AppImage", ".deb"]
    };
    for suf in suffixes {
        for a in assets {
            let name = a["name"].as_str().unwrap_or("");
            if name.ends_with(suf) && !name.ends_with(".sig") {
                return Some((name.to_string(), a["browser_download_url"].as_str()?.to_string()));
            }
        }
    }
    None
}

pub fn check() -> Result<UpdateInfo, String> {
    let resp = agent()
        .get(&format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))
        .set("User-Agent", "Sesja-updater")
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| format!("Nie udało się sprawdzić aktualizacji: {e}"))?;
    let list: Vec<Value> = resp.into_json().map_err(|e| e.to_string())?;
    let releases: Vec<&Value> = list
        .iter()
        .filter(|r| !r["draft"].as_bool().unwrap_or(false) && !r["prerelease"].as_bool().unwrap_or(false))
        .collect();
    let latest = releases.first();
    let latest_tag = latest.and_then(|r| r["tag_name"].as_str()).map(String::from);
    let newer = latest_tag.as_deref().map(|t| is_newer(t, VERSION)).unwrap_or(false);
    let asset = latest.and_then(|r| r["assets"].as_array()).and_then(|a| pick_asset(a));
    Ok(UpdateInfo {
        current: VERSION.into(),
        latest: latest_tag,
        newer,
        notes: latest.and_then(|r| r["body"].as_str()).unwrap_or("").into(),
        asset_name: asset.as_ref().map(|a| a.0.clone()),
        asset_url: asset.map(|a| a.1),
        releases: releases
            .iter()
            .map(|r| Release {
                tag: r["tag_name"].as_str().unwrap_or("").into(),
                name: r["name"].as_str().unwrap_or("").into(),
                body: r["body"].as_str().unwrap_or("").into(),
                date: r["published_at"].as_str().unwrap_or("").into(),
                url: r["html_url"].as_str().unwrap_or("").into(),
            })
            .collect(),
    })
}

/// Pobiera instalator nowej wersji (z postępem) i go uruchamia.
pub fn install(app: &AppHandle, url: &str, name: &str) -> Result<(), String> {
    if !url.starts_with(&format!("https://github.com/{REPO}/releases/download/")) {
        return Err("Nieznane źródło aktualizacji".into());
    }
    let safe: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .collect();
    let dest: PathBuf = std::env::temp_dir().join(if safe.is_empty() { "sesja-update".into() } else { safe });
    let resp = agent()
        .get(url)
        .set("User-Agent", "Sesja-updater")
        .call()
        .map_err(|e| format!("Pobieranie nie powiodło się: {e}"))?;
    let total: u64 = resp.header("Content-Length").and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut reader = resp.into_reader();
    let mut f = std::fs::File::create(&dest).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 64 * 1024];
    let mut done: u64 = 0;
    let mut last_emit = 0u64;
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        f.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if done - last_emit > 256 * 1024 {
            last_emit = done;
            let _ = app.emit("update-progress", (done, total));
        }
    }
    drop(f);
    let _ = app.emit("update-progress", (done, total.max(done)));
    launch(&dest)
}

fn launch(path: &PathBuf) -> Result<(), String> {
    use std::process::Command;
    let p = path.to_string_lossy().to_string();
    let r = if cfg!(windows) {
        if p.ends_with(".msi") {
            Command::new("msiexec").args(["/i", &p]).spawn()
        } else {
            Command::new(&p).spawn()
        }
    } else if cfg!(target_os = "macos") {
        Command::new("open").arg(&p).spawn()
    } else {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
        }
        Command::new("xdg-open").arg(path.parent().unwrap_or(path)).spawn()
    };
    r.map(|_| ()).map_err(|e| format!("Nie mogę uruchomić instalatora: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn versions() {
        assert!(is_newer("v1.2.0", "1.1.9"));
        assert!(is_newer("1.10.0", "1.9.3"));
        assert!(!is_newer("v1.0.0", "1.0.0"));
        assert!(!is_newer("v0.9.0", "1.0.0"));
    }
}
