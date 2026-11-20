# REAPER Multiplayer

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
lua5.4 tests/test_chunks.lua      # przetwarzanie chunków REAPERa, JSON
python3 tests/run_e2e.py          # serwer + dwa klienty (atrapa API REAPERa) przez prawdziwego curla
```

Test end-to-end symuluje dwie osoby: Ania ma ścieżkę z wokalem, Bartek dołącza, dogrywa gitarę,
przesuwa klip Ani, zmienia nazwę ścieżki; Ania pisze na czacie i ścisza wokal. Na końcu oba projekty
muszą być identyczne, a pliki audio pobrane u obu osób.
