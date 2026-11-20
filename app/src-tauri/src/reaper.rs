//! Wykrywanie REAPERa i instalacja moda REAPER Multiplayer.

use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Skrypt moda jest wbudowany w aplikację – instalator zawsze wgrywa wersję zgodną z aplikacją.
pub const SCRIPT: &str = include_str!("../../../reaper/ReaperMultiplayer.lua");
const SCRIPT_DIR: &str = "Sesja";
const SCRIPT_FILE: &str = "ReaperMultiplayer.lua";
/// Stały identyfikator akcji w REAPERze (RS + 40 znaków hex).
pub const ACTION_ID: &str = "RS5e55a0000000000000000000000000000000c0de";
const ACTION_NAME: &str = "Custom: Sesja – REAPER Multiplayer";
const STARTUP_BEGIN: &str = "-- >>> Sesja (REAPER Multiplayer) – autostart";
const STARTUP_END: &str = "-- <<< Sesja";

#[derive(Serialize, Clone, Debug, Default)]
pub struct ReaperInfo {
    pub found: bool,
    pub exe: Option<String>,
    pub resource: Option<String>,
    pub portable: bool,
    pub script_installed: bool,
    pub script_version: Option<String>,
    pub bundled_version: String,
    pub autostart: bool,
    pub running: bool,
    pub checked: Vec<String>,
}

pub fn bundled_version() -> String {
    script_version(SCRIPT).unwrap_or_else(|| "?".into())
}

fn script_version(src: &str) -> Option<String> {
    src.lines()
        .find_map(|l| l.strip_prefix("-- @version ").map(|v| v.trim().to_string()))
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Miejsca, w których zwykle jest program REAPER.
fn exe_candidates() -> Vec<PathBuf> {
    let mut v = Vec::new();
    #[cfg(windows)]
    {
        use winreg::enums::*;
        use winreg::RegKey;
        for (root, key) in [
            (HKEY_LOCAL_MACHINE, "SOFTWARE\\REAPER"),
            (HKEY_CURRENT_USER, "SOFTWARE\\REAPER"),
            (HKEY_LOCAL_MACHINE, "SOFTWARE\\WOW6432Node\\REAPER"),
        ] {
            if let Ok(k) = RegKey::predef(root).open_subkey(key) {
                if let Ok(dir) = k.get_value::<String, _>("") {
                    v.push(PathBuf::from(dir).join("reaper.exe"));
                }
                if let Ok(dir) = k.get_value::<String, _>("InstallDir") {
                    v.push(PathBuf::from(dir).join("reaper.exe"));
                }
            }
        }
        for base in ["C:\\Program Files", "C:\\Program Files (x86)", "D:\\Program Files"] {
            v.push(PathBuf::from(base).join("REAPER (x64)").join("reaper.exe"));
            v.push(PathBuf::from(base).join("REAPER").join("reaper.exe"));
        }
        v.push(home().join("REAPER").join("reaper.exe"));
    }
    #[cfg(target_os = "macos")]
    {
        for name in ["REAPER.app", "REAPER64.app", "REAPER-ARM.app"] {
            v.push(PathBuf::from("/Applications").join(name));
            v.push(home().join("Applications").join(name));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        v.push(home().join("opt").join("REAPER").join("reaper"));
        v.push(PathBuf::from("/opt/REAPER/reaper"));
        v.push(PathBuf::from("/usr/local/bin/reaper"));
        v.push(PathBuf::from("/usr/bin/reaper"));
        v.push(home().join("REAPER").join("reaper"));
    }
    v
}

/// Domyślny folder zasobów REAPERa (tam są skrypty, reaper.ini itp.).
fn default_resource() -> Option<PathBuf> {
    #[cfg(windows)]
    let p = dirs::config_dir().map(|d| d.join("REAPER")); // %APPDATA%\REAPER
    #[cfg(target_os = "macos")]
    let p = dirs::home_dir().map(|d| d.join("Library/Application Support/REAPER"));
    #[cfg(all(unix, not(target_os = "macos")))]
    let p = dirs::home_dir().map(|d| d.join(".config/REAPER"));
    p
}

fn is_resource_dir(p: &Path) -> bool {
    p.join("reaper.ini").is_file()
}

/// Dla instalacji przenośnej (portable) folder zasobów to folder z programem.
fn resource_for_exe(exe: &Path) -> (Option<PathBuf>, bool) {
    if let Some(dir) = exe.parent() {
        if is_resource_dir(dir) {
            return (Some(dir.to_path_buf()), true);
        }
    }
    (default_resource().filter(|d| d.is_dir()), false)
}

fn fill_status(info: &mut ReaperInfo) {
    info.bundled_version = bundled_version();
    info.running = is_running();
    if let Some(res) = &info.resource {
        let script = Path::new(res).join("Scripts").join(SCRIPT_DIR).join(SCRIPT_FILE);
        if let Ok(src) = std::fs::read_to_string(&script) {
            info.script_installed = true;
            info.script_version = script_version(&src);
        }
        let startup = Path::new(res).join("Scripts").join("__startup.lua");
        info.autostart = std::fs::read_to_string(startup)
            .map(|s| s.contains(STARTUP_BEGIN))
            .unwrap_or(false);
    }
}

pub fn detect(saved_exe: Option<&str>, saved_res: Option<&str>) -> ReaperInfo {
    let mut info = ReaperInfo::default();
    // 1) ścieżka zapamiętana wcześniej
    if let Some(exe) = saved_exe {
        let p = PathBuf::from(exe);
        if p.exists() {
            info.found = true;
            info.exe = Some(exe.to_string());
            let res = saved_res
                .map(PathBuf::from)
                .filter(|r| r.is_dir())
                .or_else(|| resource_for_exe(&p).0);
            info.resource = res.map(|r| r.to_string_lossy().into_owned());
            fill_status(&mut info);
            return info;
        }
    }
    // 2) typowe lokalizacje
    for c in exe_candidates() {
        info.checked.push(c.to_string_lossy().into_owned());
        if c.exists() {
            let (res, portable) = resource_for_exe(&c);
            info.found = true;
            info.exe = Some(c.to_string_lossy().into_owned());
            info.resource = res.map(|r| r.to_string_lossy().into_owned());
            info.portable = portable;
            break;
        }
    }
    // 3) REAPER mógł być zainstalowany gdzie indziej, ale folder zasobów istnieje
    if !info.found {
        if let Some(res) = default_resource() {
            info.checked.push(res.to_string_lossy().into_owned());
            if is_resource_dir(&res) {
                info.found = true;
                info.resource = Some(res.to_string_lossy().into_owned());
            }
        }
    }
    fill_status(&mut info);
    info
}

/// Użytkownik wskazał folder (z programem REAPER albo folder zasobów).
pub fn from_user_path(p: &Path) -> Result<ReaperInfo, String> {
    let mut info = ReaperInfo::default();
    let exe_names = ["reaper.exe", "reaper", "REAPER.app", "REAPER64.app", "REAPER-ARM.app"];
    let mut exe = None;
    if p.is_file() || p.extension().map(|e| e == "app").unwrap_or(false) {
        exe = Some(p.to_path_buf());
    } else {
        for n in exe_names {
            let c = p.join(n);
            if c.exists() {
                exe = Some(c);
                break;
            }
        }
    }
    if let Some(e) = &exe {
        let (res, portable) = resource_for_exe(e);
        info.exe = Some(e.to_string_lossy().into_owned());
        info.resource = res.map(|r| r.to_string_lossy().into_owned());
        info.portable = portable;
        info.found = true;
    } else if is_resource_dir(p) {
        info.resource = Some(p.to_string_lossy().into_owned());
        info.found = true;
    } else {
        return Err(
            "W tym folderze nie ma programu REAPER ani pliku reaper.ini. Wskaż folder, w którym zainstalowany jest REAPER."
                .into(),
        );
    }
    if info.resource.is_none() {
        return Err(
            "Znaleziono REAPERa, ale nie jego folder ustawień. Uruchom REAPERa raz i spróbuj ponownie.".into(),
        );
    }
    fill_status(&mut info);
    Ok(info)
}

pub fn is_running() -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        Command::new("tasklist")
            .args(["/FI", "IMAGENAME eq reaper.exe", "/NH"])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("reaper.exe"))
            .unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        Command::new("pgrep")
            .args(["-x", "-i", "reaper"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
}

#[derive(Serialize)]
pub struct InstallReport {
    pub script_path: String,
    pub action_registered: bool,
    pub autostart: bool,
    pub settings_written: bool,
    pub warning: Option<String>,
    pub info: ReaperInfo,
}

pub struct Conn<'a> {
    pub server: &'a str,
    pub room: &'a str,
    pub user: &'a str,
    pub password: &'a str,
}

pub fn install(resource: &str, autostart: bool, conn: Option<Conn>) -> Result<InstallReport, String> {
    let res = PathBuf::from(resource);
    if !res.is_dir() {
        return Err(format!("Folder REAPERa nie istnieje: {resource}"));
    }
    let scripts = res.join("Scripts");
    let dir = scripts.join(SCRIPT_DIR);
    std::fs::create_dir_all(&dir).map_err(|e| format!("Nie mogę utworzyć {}: {e}", dir.display()))?;
    let script_path = dir.join(SCRIPT_FILE);
    std::fs::write(&script_path, SCRIPT)
        .map_err(|e| format!("Nie mogę zapisać skryptu: {e}"))?;

    register_action(&res)?;
    set_autostart(&res, autostart)?;

    let running = is_running();
    let mut settings_written = false;
    let mut warning = None;
    if let Some(c) = conn {
        write_settings(&res, &c)?;
        settings_written = true;
    }
    if running {
        warning = Some(
            "REAPER jest teraz uruchomiony. Zamknij go i otwórz ponownie, żeby zobaczył nową akcję i ustawienia."
                .into(),
        );
    }
    let mut info = detect(None, Some(resource));
    info.resource = Some(resource.to_string());
    fill_status(&mut info);
    Ok(InstallReport {
        script_path: script_path.to_string_lossy().into_owned(),
        action_registered: true,
        autostart,
        settings_written,
        warning,
        info,
    })
}

pub fn uninstall(resource: &str) -> Result<(), String> {
    let res = PathBuf::from(resource);
    let _ = std::fs::remove_dir_all(res.join("Scripts").join(SCRIPT_DIR));
    set_autostart(&res, false)?;
    let kb = res.join("reaper-kb.ini");
    if let Ok(s) = std::fs::read_to_string(&kb) {
        let out: Vec<&str> = s.lines().filter(|l| !l.contains(ACTION_ID)).collect();
        std::fs::write(&kb, out.join("\n") + "\n").map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Rejestruje skrypt jako akcję w REAPERze (reaper-kb.ini).
fn register_action(res: &Path) -> Result<(), String> {
    let kb = res.join("reaper-kb.ini");
    let current = std::fs::read_to_string(&kb).unwrap_or_default();
    let mut lines: Vec<String> = current
        .lines()
        .filter(|l| !l.contains(ACTION_ID))
        .map(|l| l.to_string())
        .collect();
    lines.push(format!(
        "SCR 4 0 {ACTION_ID} \"{ACTION_NAME}\" \"{SCRIPT_DIR}/{SCRIPT_FILE}\""
    ));
    std::fs::write(&kb, lines.join("\n") + "\n")
        .map_err(|e| format!("Nie mogę zapisać reaper-kb.ini: {e}"))
}

/// Dopisuje / usuwa uruchamianie skryptu przy starcie REAPERa (__startup.lua).
fn set_autostart(res: &Path, on: bool) -> Result<(), String> {
    let path = res.join("Scripts").join("__startup.lua");
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let mut out = String::new();
    let mut skipping = false;
    for l in current.lines() {
        if l.trim() == STARTUP_BEGIN {
            skipping = true;
            continue;
        }
        if skipping {
            if l.trim() == STARTUP_END {
                skipping = false;
            }
            continue;
        }
        out.push_str(l);
        out.push('\n');
    }
    if on {
        out.push_str(&format!(
            "{STARTUP_BEGIN}\nlocal sesja_cmd = reaper.NamedCommandLookup(\"_{ACTION_ID}\")\nif sesja_cmd ~= 0 then reaper.Main_OnCommand(sesja_cmd, 0) end\n{STARTUP_END}\n"
        ));
    }
    if out.trim().is_empty() && !path.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(res.join("Scripts")).map_err(|e| e.to_string())?;
    std::fs::write(&path, out).map_err(|e| format!("Nie mogę zapisać __startup.lua: {e}"))
}

/// Zapisuje nick/serwer/pokój w ustawieniach REAPERa, żeby skrypt łączył się sam.
pub fn write_settings(res: &Path, c: &Conn) -> Result<(), String> {
    let path = res.join("reaper-extstate.ini");
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let section = "[ReaperMultiplayer]";
    let values = [
        ("server", c.server),
        ("room", c.room),
        ("user", c.user),
        ("password", c.password),
    ];
    let mut out: Vec<String> = Vec::new();
    let mut in_ours = false;
    let mut seen_section = false;
    let mut written: Vec<&str> = Vec::new();
    for l in current.lines() {
        let t = l.trim();
        if t.starts_with('[') && t.ends_with(']') {
            if in_ours {
                for (k, v) in values.iter() {
                    if !written.contains(k) {
                        out.push(format!("{k}={v}"));
                    }
                }
            }
            in_ours = t == section;
            seen_section |= in_ours;
            out.push(l.to_string());
            continue;
        }
        if in_ours {
            if let Some((k, _)) = t.split_once('=') {
                if let Some((key, v)) = values.iter().find(|(key, _)| *key == k) {
                    out.push(format!("{key}={v}"));
                    written.push(key);
                    continue;
                }
            }
        }
        out.push(l.to_string());
    }
    if in_ours {
        for (k, v) in values.iter() {
            if !written.contains(k) {
                out.push(format!("{k}={v}"));
            }
        }
    }
    if !seen_section {
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push(section.to_string());
        for (k, v) in values.iter() {
            out.push(format!("{k}={v}"));
        }
    }
    std::fs::write(&path, out.join("\n") + "\n")
        .map_err(|e| format!("Nie mogę zapisać ustawień REAPERa: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_and_uninstall_roundtrip() {
        let dir = std::env::temp_dir().join(format!("sesja_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("reaper.ini"), "[REAPER]\n").unwrap();
        std::fs::write(dir.join("reaper-kb.ini"), "KEY 1 65 40044 0\n").unwrap();
        std::fs::write(
            dir.join("reaper-extstate.ini"),
            "[Other]\na=1\n[ReaperMultiplayer]\nuser=stary\ncolorize=0\n",
        )
        .unwrap();
        let conn = Conn { server: "http://1.2.3.4:8765", room: "pokoj", user: "Ania", password: "x" };
        let rep = install(dir.to_str().unwrap(), true, Some(conn)).unwrap();
        assert!(rep.info.script_installed);
        assert!(rep.info.autostart);
        let kb = std::fs::read_to_string(dir.join("reaper-kb.ini")).unwrap();
        assert!(kb.contains("KEY 1 65 40044 0"));
        assert_eq!(kb.matches(ACTION_ID).count(), 1);
        // ponowna instalacja nie dubluje wpisów
        install(dir.to_str().unwrap(), true, None).unwrap();
        let kb = std::fs::read_to_string(dir.join("reaper-kb.ini")).unwrap();
        assert_eq!(kb.matches(ACTION_ID).count(), 1);
        let st = std::fs::read_to_string(dir.join("Scripts/__startup.lua")).unwrap();
        assert_eq!(st.matches(STARTUP_BEGIN).count(), 1);
        let ext = std::fs::read_to_string(dir.join("reaper-extstate.ini")).unwrap();
        assert!(ext.contains("[Other]\na=1"));
        assert!(ext.contains("user=Ania") && !ext.contains("user=stary"));
        assert!(ext.contains("colorize=0") && ext.contains("room=pokoj"));
        uninstall(dir.to_str().unwrap()).unwrap();
        let kb = std::fs::read_to_string(dir.join("reaper-kb.ini")).unwrap();
        assert!(!kb.contains(ACTION_ID) && kb.contains("40044"));
        assert!(!dir.join("Scripts/Sesja").exists());
        let info = from_user_path(&dir).unwrap();
        assert!(info.found && !info.script_installed && !info.autostart);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
