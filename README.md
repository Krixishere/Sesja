# Sesja – REAPER Multiplayer

Wspólna praca nad **jednym projektem REAPERa** przez internet: Ty w Warszawie, kumpel w Łodzi.
Każdy ma swojego REAPERa, a zmiany, nagrania, czat i komentarze trafiają do wszystkich same.

Projekt składa się z trzech części:

| Część | Co robi |
|---|---|
| **Aplikacja Sesja** (`app/`, Rust + Tauri) | Instalator, który sam szuka REAPERa i instaluje mod; wbudowany serwer („Zakładam sesję”); studio z listą osób, ścieżek i aktywności; czat; komentarze do klipów; odsłuch nagrań z falą dźwięku; auto-aktualizacje, dziennik zmian, wsparcie twórcy |
| **Mod do REAPERa** (`reaper/ReaperMultiplayer.lua`) | Synchronizuje projekt, wysyła i pobiera audio, okno z czatem i komentarzami w samym REAPERze |
| **Serwer w Pythonie** (`server/rmp_server.py`) | Ten sam protokół co serwer w aplikacji – do postawienia na VPS bez instalowania aplikacji |

## Aplikacja Sesja

### Pierwsze uruchomienie

1. Animacja powitalna, potem aplikacja **szuka REAPERa** (rejestr Windows, `Program Files`,
   `/Applications`, `~/.config/REAPER`, wersje przenośne).
2. Jeśli go nie znajdzie, pokaże komunikat „Nie znaleziono REAPERa”. Wtedy możesz
   **wskazać folder REAPERa** albo przejść na stronę pobierania.
3. Podajesz nick i wybierasz: **Zakładam sesję** (serwer startuje w aplikacji) albo **Dołączam** (adres od znajomego).
4. **Instalacja moda**: skrypt trafia do `Scripts/Sesja/`, akcja do menu *Actions*, opcjonalnie
   autostart z REAPERem, a Twój nick i adres sesji do ustawień REAPERa. Mod łączy się sam.

### Menu

- **Studio**: kto jest w sesji (nagrywa / odtwarza / gdzie stoi kursor), ścieżki z autorami, „Co się dzieje”,
  adresy Twojego serwera do skopiowania.
- **Wiadomości**: czat (ten sam co w oknie moda w REAPERze).
- **Nagrania**: wszystkie klipy audio z odsłuchem, falą dźwięku i filtrem po autorze.
- **Komentarze**: przypięte do miejsca w utworze albo do konkretnego klipu (np. wokalu). W REAPERze
  komentarz do klipu pojawia się jako znacznik na samym klipie.
- **REAPER**: stan instalacji, aktualizacja moda, autostart, odinstalowanie.
- **Zmiany**: dziennik zmian (z wydań na GitHubie albo z `CHANGELOG.md`).
- **Wspieraj**: kod źródłowy, zgłaszanie błędów i linki do wsparcia twórcy.
  Linki ustawiasz w `app/ui/app.js` (stała `LINKS`). **Podmień je na własne konta przed pierwszym wydaniem.**
- **Ustawienia**: profil, własny serwer (port, hasło, start z aplikacją), auto-aktualizacje.

### Budowanie

Wymagany Rust (stable) i Node.js 18+ (tylko do narzędzia `tauri`). Na Linuksie dodatkowo
`libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev`.

```bash
cd app
npx @tauri-apps/cli@2 dev      # uruchomienie w trybie deweloperskim
npx @tauri-apps/cli@2 build    # instalatory: .exe/.msi (Windows), .dmg (macOS), .AppImage/.deb (Linux)
```

Interfejs to zwykłe HTML/CSS/JS w `app/ui/` (bez kroku budowania). Podgląd w przeglądarce
z przykładowymi danymi: `python3 -m http.server -d app/ui` i otwórz `index.html`
(`?demo=onboard` pokazuje instalator powitalny).

### Wydania i auto-aktualizacje

1. Podnieś wersję w `app/src-tauri/Cargo.toml` i `app/src-tauri/tauri.conf.json`, dopisz zmiany do `CHANGELOG.md`.
2. `git tag v1.0.1 && git push origin v1.0.1`.
3. GitHub Actions (`.github/workflows/release.yml`) zbuduje instalatory na Windows, macOS i Linuksa
   i opublikuje wydanie. Zainstalowane aplikacje przy starcie zobaczą nową wersję i zaproponują instalację.

Instalatory nie są podpisane certyfikatem, więc Windows SmartScreen i macOS Gatekeeper przy pierwszym
uruchomieniu pokażą ostrzeżenie.

### Serwer bez okna (np. na VPS)

```bash
sesja --serve 8765 --password Haslo123 --data /var/lib/sesja
```

---

# Mod do REAPERa – szczegóły

Wspólna praca nad **jednym projektem REAPERa** przez internet: Ty w Warszawie, kumpel w Łodzi.
Każdy ma swojego REAPERa, a skrypt sam wysyła zmiany na serwer i pobiera zmiany innych.
Nie trzeba ręcznie przesyłać plików, eksportować stemów ani wysyłać projektu mailem.

## Co synchronizuje

| Co | Jak |
|---|---|
| Ścieżki (nazwa, głośność, pan, mute/solo, kolor, foldery, wysyłki, **wtyczki FX i ich ustawienia**, automatyka) | automatycznie |
| Klipy audio i MIDI (pozycja, długość, fade'y, take'i, FX na take'ach, nuty MIDI) | automatycznie |
| **Nagrane pliki audio** | wysyłane w tle na serwer i pobierane przez resztę do folderu `RMP_media` obok projektu |
| Kolejność ścieżek, tempo projektu | automatycznie |
| Czat | okno skryptu |
| Komentarze w miejscu na osi czasu | okno skryptu → pojawiają się u wszystkich jako markery 💬 |

Nie synchronizuje się to, co jest „Twoje”: zaznaczenie, wysokość ścieżek, uzbrojenie do nagrywania,
wejścia/wyjścia karty dźwiękowej i pozycje okien wtyczek.

### Kto co zrobił

- **Lista aktywności**: „Ania dodaje klip „wokal_take3” na ścieżce „Wokal” @ 1:12”, „Bartek zmienia ścieżkę „Gitara””…
- **Inspektor**: zaznacz klip albo ścieżkę – na górze okna widać, kto ją dodał i kto ostatnio zmieniał.
- **Kolory autorów**: Twoje nowe klipy dostają Twój kolor (można wyłączyć w Menu).
- **Online**: kto jest połączony, czy odtwarza (▶) albo nagrywa (● REC) i w którym miejscu.
- Zmiany od innych trafiają do historii cofania jako „Multiplayer: zmiany od …”.

## Jak to działa

```
 REAPER (Warszawa) ──┐                     ┌── REAPER (Łódź)
   skrypt Lua        │   HTTP (curl)       │     skrypt Lua
                     └──►  serwer RMP  ◄───┘
                          (Python, 1 plik)
                          log zmian + stan projektu + pliki audio
```

Co ~1 s skrypt sprawdza, czy projekt się zmienił. Jeśli tak – wysyła zmienione ścieżki/klipy,
a w tej samej odpowiedzi dostaje zmiany od innych. Gdy dwie osoby zmienią ten sam klip w tej
samej chwili, wygrywa zmiana, która dotarła na serwer później (u wszystkich tak samo).

## Instalacja

### 1. Serwer (raz, na jednym komputerze)

Potrzebny tylko Python 3.8+ (bez dodatkowych bibliotek):

```bash
python3 server/rmp_server.py --port 8765 --password MojeHaslo123
```

Pliki projektu i audio lądują w katalogu `rmp_data/`. Podgląd pokoi: otwórz `http://adres:8765/` w przeglądarce.

**Jak połączyć Warszawę z Łodzią** – wybierz jedno:

- **Tailscale / ZeroTier (najprościej)** – obaj instalujecie Tailscale, serwer uruchamia jedna osoba
  u siebie, druga łączy się na jej adres Tailscale, np. `http://100.101.102.103:8765`. Bez konfiguracji routera.
- **VPS** (np. najtańszy serwer w chmurze) – uruchom tam serwer, obaj łączycie się na jego publiczny IP.
  Możesz też użyć Dockera: `docker build -t rmp server && docker run -p 8765:8765 -v rmp:/data rmp`.
- **Przekierowanie portu 8765** na routerze osoby, która trzyma serwer.

Hasło może zawierać tylko litery, cyfry oraz `. _ -`. Ruch to zwykłe HTTP – jeśli łączysz się przez
publiczny internet, najlepiej przez Tailscale albo za proxy z HTTPS (adres `https://...` też działa).

### 2. Skrypt w REAPERze (każdy uczestnik)

1. Skopiuj `reaper/ReaperMultiplayer.lua` do folderu `Scripts` REAPERa
   (*Options → Show REAPER resource path*).
2. *Actions → Show action list → New action → Load ReaScript…* → wybierz plik.
3. Uruchom akcję **ReaperMultiplayer**. Za pierwszym razem podaj:
   - adres serwera, np. `http://100.101.102.103:8765`,
   - nazwę pokoju (np. `nowy_singiel`) – wszyscy w tym samym pokoju pracują nad tym samym projektem,
   - swój nick i hasło serwera.

Wymagany jest `curl` – jest wbudowany w Windows 10/11, macOS i Linuksa.

### 3. Praca

- **Pierwsza osoba** w pokoju otwiera swój projekt i się łączy – jej projekt trafia na serwer.
- **Kolejne osoby** najlepiej łączą się z **pustym, zapisanym projektem** (żeby audio miało gdzie się pobrać).
  Jeśli masz otwarty projekt z innymi ścieżkami, skrypt zapyta: wczytać projekt z serwera (TAK)
  czy dołączyć swoje ścieżki do wspólnego (NIE).
- Nagrywasz normalnie. Podczas nagrywania zmiany innych czekają i wchodzą po zatrzymaniu,
  żeby nic Ci nie przeszkodziło w trakcie take'a.
- Czat: pisz w polu na dole i Enter. Przycisk **„Komentarz @ 1:23”** przypina wiadomość do pozycji kursora.
  Kliknięcie komentarza na liście przenosi kursor w to miejsce, prawy klik – usuwa.

## Ograniczenia (wersja 1.0)

- Gdy okno skryptu ma fokus, klawisze idą do pola czatu (spacja nie uruchamia odtwarzania).
  Kliknij w okno aranżacji, żeby wrócić do skrótów REAPERa.
- Ścieżka master, markery/regiony i mapa tempa (zmiany tempa w trakcie utworu) nie są synchronizowane –
  tylko podstawowe tempo projektu.
- To nie jest wspólne granie na żywo (latencja internetu) – to wspólna praca nad projektem, jak w Google Docs.
- Bardzo duże projekty (setki ścieżek) mogą odczuwalnie obciążać skrypt przy każdej zmianie.
- Wtyczki muszą być zainstalowane u wszystkich, inaczej REAPER pokaże je jako brakujące.

## Testy

```bash
lua5.4 tests/test_chunks.lua                  # przetwarzanie chunków REAPERa, JSON
python3 tests/run_e2e.py                      # serwer w Pythonie + dwa klienty (atrapa API REAPERa)
RMP_SERVER=rust python3 tests/run_e2e.py      # to samo z serwerem wbudowanym w aplikację
cargo test --manifest-path app/src-tauri/Cargo.toml
```

Test end-to-end symuluje dwie osoby: Ania ma ścieżkę z wokalem, Bartek dołącza, dogrywa gitarę,
przesuwa klip Ani, zmienia nazwę ścieżki; Ania pisze na czacie i ścisza wokal. Na końcu oba projekty
muszą być identyczne, a pliki audio pobrane u obu osób.

## Licencja

Kod: MIT (plik `LICENSE`). Czcionki Bricolage Grotesque i Instrument Sans: SIL Open Font License 1.1.
