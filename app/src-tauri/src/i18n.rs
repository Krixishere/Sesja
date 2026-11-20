//! Komunikaty z części Rust (błędy, ostrzeżenia) w językach aplikacji.
//! Interfejs ma własne tłumaczenia w ui/i18n.js; tutaj tylko to, co powstaje w Ruście.

use std::sync::atomic::{AtomicUsize, Ordering};

pub const LANGS: [&str; 5] = ["pl", "en", "de", "es", "fr"];
static LANG: AtomicUsize = AtomicUsize::new(1);

pub fn set(code: &str) {
    let i = LANGS.iter().position(|l| *l == code).unwrap_or(1);
    LANG.store(i, Ordering::Relaxed);
}

pub fn current() -> &'static str {
    LANGS[LANG.load(Ordering::Relaxed)]
}

// klucz, [pl, en, de, es, fr]; {0}, {1} – parametry
const TABLE: &[(&str, [&str; 5])] = &[
    ("save_settings", ["Nie udało się zapisać ustawień: {0}", "Could not save settings: {0}", "Einstellungen konnten nicht gespeichert werden: {0}", "No se pudieron guardar los ajustes: {0}", "Impossible d’enregistrer les réglages : {0}"]),
    ("no_reaper_here", ["W tym folderze nie ma programu REAPER ani pliku reaper.ini. Wskaż folder, w którym zainstalowany jest REAPER.", "This folder has neither the REAPER program nor reaper.ini. Choose the folder where REAPER is installed.", "In diesem Ordner gibt es weder REAPER noch reaper.ini. Wähle den Ordner, in dem REAPER installiert ist.", "Esta carpeta no contiene REAPER ni reaper.ini. Elige la carpeta donde está instalado REAPER.", "Ce dossier ne contient ni REAPER ni reaper.ini. Choisis le dossier où REAPER est installé."]),
    ("no_resource", ["Znaleziono REAPERa, ale nie jego folder ustawień. Uruchom REAPERa raz i spróbuj ponownie.", "Found REAPER, but not its settings folder. Start REAPER once and try again.", "REAPER gefunden, aber nicht seinen Einstellungsordner. Starte REAPER einmal und versuche es erneut.", "Se encontró REAPER, pero no su carpeta de ajustes. Abre REAPER una vez e inténtalo de nuevo.", "REAPER trouvé, mais pas son dossier de réglages. Lance REAPER une fois puis réessaie."]),
    ("no_folder", ["Folder REAPERa nie istnieje: {0}", "REAPER folder does not exist: {0}", "REAPER-Ordner existiert nicht: {0}", "La carpeta de REAPER no existe: {0}", "Le dossier REAPER n’existe pas : {0}"]),
    ("write_failed", ["Nie mogę zapisać {0}: {1}", "Cannot write {0}: {1}", "{0} kann nicht geschrieben werden: {1}", "No se puede escribir {0}: {1}", "Impossible d’écrire {0} : {1}"]),
    ("reaper_running", ["REAPER jest teraz uruchomiony. Zamknij go i otwórz ponownie, żeby zobaczył nową akcję i ustawienia.", "REAPER is running right now. Close and reopen it so it picks up the new action and settings.", "REAPER läuft gerade. Schließe und öffne ihn erneut, damit er die neue Aktion und Einstellungen übernimmt.", "REAPER está abierto ahora. Ciérralo y vuelve a abrirlo para que cargue la nueva acción y los ajustes.", "REAPER est ouvert. Ferme-le puis rouvre-le pour qu’il prenne en compte la nouvelle action et les réglages."]),
    ("run_reaper_first", ["REAPER nie był jeszcze uruchomiony na tym komputerze, więc nie ma folderu ustawień. Otwórz REAPERa raz, zamknij go i spróbuj ponownie.", "REAPER hasn’t been started on this computer yet, so its settings folder doesn’t exist. Open REAPER once, close it and try again.", "REAPER wurde auf diesem Computer noch nie gestartet, daher fehlt sein Einstellungsordner. Öffne REAPER einmal, schließe ihn und versuche es erneut.", "REAPER aún no se ha abierto en este ordenador, así que no existe su carpeta de ajustes. Abre REAPER una vez, ciérralo e inténtalo de nuevo.", "REAPER n’a encore jamais été lancé sur cet ordinateur, son dossier de réglages n’existe donc pas. Ouvre REAPER une fois, ferme-le puis réessaie."]),
    ("fw_cancelled", ["Zapora nie została zmieniona – okno uprawnień administratora zostało zamknięte.", "The firewall wasn’t changed – the administrator prompt was closed.", "Die Firewall wurde nicht geändert – die Administrator-Abfrage wurde geschlossen.", "No se cambió el cortafuegos: se cerró la ventana de permisos de administrador.", "Le pare-feu n’a pas été modifié : la demande d’autorisation administrateur a été fermée."]),
    ("fw_failed", ["Nie udało się dodać reguły zapory. Dodaj ręcznie zezwolenie dla Sesji w „Zapora Windows Defender → Zezwalaj aplikacji”.", "Couldn’t add the firewall rule. Allow Sesja manually in “Windows Defender Firewall → Allow an app”.", "Die Firewall-Regel konnte nicht hinzugefügt werden. Erlaube Sesja manuell unter „Windows Defender Firewall → App zulassen“.", "No se pudo añadir la regla. Permite Sesja manualmente en «Firewall de Windows Defender → Permitir una aplicación».", "Impossible d’ajouter la règle. Autorise Sesja manuellement dans « Pare-feu Windows Defender → Autoriser une application »."]),
    ("pick_title", ["Wskaż folder, w którym jest zainstalowany REAPER", "Choose the folder where REAPER is installed", "Wähle den Ordner, in dem REAPER installiert ist", "Elige la carpeta donde está instalado REAPER", "Choisis le dossier où REAPER est installé"]),
    ("no_reaper_path", ["Nie znam ścieżki do REAPERa.", "I don’t know where REAPER is installed.", "Der Pfad zu REAPER ist unbekannt.", "No sé dónde está instalado REAPER.", "Je ne sais pas où REAPER est installé."]),
    ("cant_launch", ["Nie mogę uruchomić {0}: {1}", "Cannot start {0}: {1}", "{0} kann nicht gestartet werden: {1}", "No se puede iniciar {0}: {1}", "Impossible de lancer {0} : {1}"]),
    ("fill_profile", ["Uzupełnij nick, adres serwera i pokój w ustawieniach.", "Fill in your nickname, server address and room in Settings.", "Gib in den Einstellungen Nickname, Serveradresse und Raum ein.", "Completa tu apodo, la dirección del servidor y la sala en Ajustes.", "Renseigne ton pseudo, l’adresse du serveur et le salon dans les Réglages."]),
    ("not_connected", ["Nie jesteś połączony z sesją.", "You are not connected to a session.", "Du bist mit keiner Session verbunden.", "No estás conectado a ninguna sesión.", "Tu n’es connecté à aucune session."]),
    ("bad_url", ["Niedozwolony adres.", "This address is not allowed.", "Diese Adresse ist nicht erlaubt.", "Esta dirección no está permitida.", "Cette adresse n’est pas autorisée."]),
    ("port_busy", ["Nie mogę uruchomić serwera na porcie {0}: {1}", "Cannot start the server on port {0}: {1}", "Server kann auf Port {0} nicht gestartet werden: {1}", "No se puede iniciar el servidor en el puerto {0}: {1}", "Impossible de démarrer le serveur sur le port {0} : {1}"]),
    ("bad_response", ["Zła odpowiedź serwera: {0}", "Invalid server response: {0}", "Ungültige Serverantwort: {0}", "Respuesta del servidor no válida: {0}", "Réponse du serveur invalide : {0}"]),
    ("cant_connect", ["Nie można połączyć z {0}: {1}", "Cannot connect to {0}: {1}", "Keine Verbindung zu {0}: {1}", "No se puede conectar con {0}: {1}", "Connexion impossible à {0} : {1}"]),
    ("refused", ["serwer nie odpowiada (czy jest uruchomiony?)", "the server is not responding (is it running?)", "der Server antwortet nicht (läuft er?)", "el servidor no responde (¿está en marcha?)", "le serveur ne répond pas (est-il lancé ?)"]),
    ("timeout", ["przekroczono czas oczekiwania", "the connection timed out", "Zeitüberschreitung der Verbindung", "se agotó el tiempo de espera", "délai de connexion dépassé"]),
    ("file_pending", ["Ten plik nie dotarł jeszcze na serwer.", "This file hasn’t reached the server yet.", "Diese Datei ist noch nicht auf dem Server.", "Este archivo aún no ha llegado al servidor.", "Ce fichier n’est pas encore arrivé sur le serveur."]),
    ("bad_name", ["Zła nazwa pliku.", "Invalid file name.", "Ungültiger Dateiname.", "Nombre de archivo no válido.", "Nom de fichier invalide."]),
    ("update_check", ["Nie udało się sprawdzić aktualizacji: {0}", "Could not check for updates: {0}", "Suche nach Updates fehlgeschlagen: {0}", "No se pudieron buscar actualizaciones: {0}", "Impossible de vérifier les mises à jour : {0}"]),
    ("update_source", ["Nieznane źródło aktualizacji.", "Unknown update source.", "Unbekannte Update-Quelle.", "Origen de actualización desconocido.", "Source de mise à jour inconnue."]),
    ("download_failed", ["Pobieranie nie powiodło się: {0}", "Download failed: {0}", "Download fehlgeschlagen: {0}", "La descarga falló: {0}", "Le téléchargement a échoué : {0}"]),
    // błędy serwera (pole "code" w odpowiedzi)
    ("srv_bad_password", ["Złe hasło serwera.", "Wrong server password.", "Falsches Server-Passwort.", "Contraseña del servidor incorrecta.", "Mot de passe du serveur incorrect."]),
    ("srv_bad_room", ["Niepoprawna nazwa pokoju.", "Invalid room name.", "Ungültiger Raumname.", "Nombre de sala no válido.", "Nom de salon invalide."]),
    ("srv_other", ["Błąd serwera: {0}", "Server error: {0}", "Serverfehler: {0}", "Error del servidor: {0}", "Erreur du serveur : {0}"]),
];

pub fn t(key: &str) -> String {
    let i = LANG.load(Ordering::Relaxed);
    TABLE
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, v)| v[i].to_string())
        .unwrap_or_else(|| key.to_string())
}

pub fn tf(key: &str, args: &[&dyn std::fmt::Display]) -> String {
    let mut s = t(key);
    for (n, a) in args.iter().enumerate() {
        s = s.replace(&format!("{{{n}}}"), &a.to_string());
    }
    s
}

/// Komunikat dla błędu zwróconego przez serwer (pole "code").
pub fn server_error(v: &serde_json::Value) -> String {
    match v["code"].as_str() {
        Some("bad_password") => t("srv_bad_password"),
        Some("bad_room") => t("srv_bad_room"),
        _ => tf("srv_other", &[&v["error"].as_str().unwrap_or("?")]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_key_has_all_languages() {
        for (k, v) in TABLE {
            for (i, s) in v.iter().enumerate() {
                assert!(!s.is_empty(), "{k} / {}", LANGS[i]);
                let params = v[1].matches('{').count();
                assert_eq!(s.matches('{').count(), params, "parametry w {k} / {}", LANGS[i]);
            }
        }
        set("de");
        assert_eq!(current(), "de");
        assert_eq!(tf("no_folder", &[&"X"]), "REAPER-Ordner existiert nicht: X");
        set("xx");
        assert_eq!(current(), "en");
    }
}
