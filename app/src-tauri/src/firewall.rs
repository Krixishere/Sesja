//! Zapora Windows: znajomi łączą się do serwera w Sesji z zewnątrz, więc zapora musi
//! przepuszczać ruch przychodzący. Okienko „Zezwól na dostęp” pojawia się tylko raz –
//! zamknięte tworzy regułę BLOKUJĄCĄ dla programu, która ma pierwszeństwo przed zezwoleniem.
//! Dlatego „odblokowanie” usuwa stare reguły dla sesja.exe i dodaje zezwolenia
//! (dla programu i dla portu), za jednym potwierdzeniem administratora (UAC).

use serde_json::{json, Value};

#[cfg_attr(not(windows), allow(dead_code))]
pub fn rule_name(port: u16) -> String {
    format!("Sesja-{port}")
}

#[cfg(windows)]
fn hidden(cmd: &mut std::process::Command) -> &mut std::process::Command {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000) // CREATE_NO_WINDOW – bez migającej konsoli
}

/// Czy istnieje nasza reguła zezwalająca dla portu.
pub fn status(port: u16) -> Value {
    #[cfg(windows)]
    {
        let ok = hidden(std::process::Command::new("netsh").args([
            "advfirewall",
            "firewall",
            "show",
            "rule",
            &format!("name={}", rule_name(port)),
        ]))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
        json!({"applicable": true, "allowed": ok, "port": port})
    }
    #[cfg(not(windows))]
    {
        json!({"applicable": false, "allowed": true, "port": port})
    }
}

/// Polecenie (dla cmd /c) usuwające blokady programu i dodające zezwolenia.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn allow_script(port: u16, exe: &str) -> String {
    let name = rule_name(port);
    [
        format!("netsh advfirewall firewall delete rule name=all dir=in program=\"{exe}\""),
        format!("netsh advfirewall firewall delete rule name={name}"),
        format!(
            "netsh advfirewall firewall add rule name=\"Sesja\" dir=in action=allow program=\"{exe}\" enable=yes profile=any"
        ),
        format!(
            "netsh advfirewall firewall add rule name={name} dir=in action=allow protocol=TCP localport={port} profile=any"
        ),
    ]
    .join(" & ")
}

pub fn allow(port: u16) -> Result<Value, String> {
    #[cfg(windows)]
    {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let script = allow_script(port, &exe.to_string_lossy());
        // PowerShell uruchamia cmd z prawami administratora (okno UAC), bez okna konsoli.
        let ps = format!(
            "Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '/c {}'",
            script.replace('\'', "''")
        );
        let out = hidden(std::process::Command::new("powershell").args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &ps,
        ]))
        .output()
        .map_err(|e| e.to_string())?;
        let st = status(port);
        if st["allowed"].as_bool() == Some(true) {
            Ok(st)
        } else if !out.status.success() {
            Err(crate::i18n::t("fw_cancelled"))
        } else {
            Err(crate::i18n::t("fw_failed"))
        }
    }
    #[cfg(not(windows))]
    {
        Ok(status(port))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn script_quotes_paths_with_spaces() {
        let s = allow_script(8765, r"C:\Users\Jan Kowalski\AppData\Local\Sesja\sesja.exe");
        assert!(s.contains(r#"program="C:\Users\Jan Kowalski\AppData\Local\Sesja\sesja.exe""#));
        assert!(s.contains("localport=8765"));
        assert!(s.contains("delete rule name=all dir=in program="));
        assert_eq!(s.matches(" & ").count(), 3);
    }
}
