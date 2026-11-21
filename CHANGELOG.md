# Dziennik zmian

Nagłówki wersji aplikacji mają postać `## Sesja X.Y.Z` – sekcja trafia automatycznie
do opisu wydania na GitHubie.

## Sesja 1.6.0

- **Pozwolenia na ścieżki**: gdy dodasz nową ścieżkę w REAPERze, okno Sesji pyta „Dodaj do pokoju”,
  „Tylko u mnie” albo „Zawsze dodawaj”. Dopóki nie zdecydujesz, inni jej nie widzą, a ścieżki
  „tylko u mnie” nigdy nie wychodzą z Twojego komputera. Przełącznik jest w Ustawieniach → Pozwolenia
  w pokoju i w menu moda.
- **Koniec przycinania i „migotania” widoków** (Jak połączyć, REAPER, Zmiany, Ustawienia). Przyczyną było
  rozmycie tła pod każdym panelem i animowana zorza, przez które okno przerysowywało się w każdej
  klatce. Tło jest teraz statyczne, panele mają pełne kolory, a miernik i fala pod nazwą sesji ruszają się
  tylko wtedy, gdy ktoś coś robi.
- Spokojniejszy wygląd: krótsze, prostsze wejście widoków, bez rozmycia.
- Naprawione: kręciołki ładowania znowu się kręcą (nadpisywała je animacja ramki karty).
- Mod pokazuje nazwę sesji zamiast kodu z linku.

## Mod 1.6.0

- Pytanie o nowe ścieżki („Dodaj do pokoju” / „Tylko u mnie” / „Zawsze dodawaj”), ścieżki prywatne
  zapisane w projekcie, opcje w menu.
- Okno rysuje się płynnie tylko przy ruchu myszy i aktywności, a w spoczynku kilka razy na sekundę.
  REAPER ma więcej mocy na audio.
- Nazwa sesji z aplikacji w nagłówku.

## Sesja 1.5.1

- **„Otwórz w Sesji” na stronie zaproszenia**: kliknięcie otwiera aplikację (albo wyciąga ją
  na wierzch, jeśli już działa) od razu z wpisanym linkiem do sesji. Zostaje wpisać hasło i kliknąć
  „Dołącz”. Sesja bez hasła dołącza sama.
- Jeśli jesteś w innej sesji, aplikacja pyta, czy się przełączyć.
- Gdy aplikacji nie ma, strona podpowiada, żeby ją pobrać.

## Sesja 1.5.0

- **Utwórz sesję jednym kliknięciem**: wpisujesz nazwę i hasło, a aplikacja zakłada sesję na wspólnym
  serwerze Sesji (`sesja.krixishere.org`) i daje link do wysłania znajomym. Bez adresów IP, portów,
  Tailscale i zapory.
- **Dołącz przez link**: znajomy wkleja link, wpisuje hasło i jest w środku. Link otwarty w przeglądarce
  pokazuje stronę zaproszenia z instrukcją i przyciskiem pobrania.
- W Studiu widać nazwę sesji i panel „Zaproś znajomych” z linkiem i hasłem do skopiowania.
- Mod w REAPERze (1.5.0) sam przełącza się na sesję wybraną w aplikacji – bez restartu REAPERa.
- Każda sesja ma własne hasło (zapisane na serwerze jako skrót SHA-256 z solą).
- Ekran powitalny pyta już tylko o nick. Własny serwer, hostowanie u siebie i ręczny adres są
  w „Więcej opcji”.

## Sesja 1.4.0

- „Utwórz serwer w chmurze” prosto z aplikacji: wklejasz token Cloudflare, a Sesja sama wgrywa
  serwer na Twoje konto, ustawia hasło, adres workers.dev i (opcjonalnie) Twoją domenę.
  Bez terminala i wranglera.
- Studio bez sesji: trzy jasne drogi – serwer w chmurze (polecane), na moim komputerze, dołączam.
- Naprawione ciągłe „odświeżanie” i powtarzanie animacji w zakładkach (Jak połączyć, REAPER,
  Zmiany, Ustawienia, Komentarze) – widoki przebudowują się tylko przy realnej zmianie.
- Nowy wygląd: zorza w tle reagująca na aktywność, szklany pasek boczny, karty z reflektorem
  pod kursorem i świecącą krawędzią, przyciski z błyskiem, wejście widoków z rozmyciem,
  obracająca się ramka karty polecanej.

## Sesja 1.3.0

- Własny serwer na Cloudflare (`server/cloudflare`): darmowy Worker + Durable Objects pod Twoją
  domeną, np. `https://sesja.twojadomena.pl`. Wszyscy łączą się do jednego adresu – bez Tailscale,
  zapory Windows i włączonego komputera gospodarza. Wdrożenie: dwie komendy (`wrangler deploy`).
- Instrukcja „Jak połączyć” pokazuje drogę przez Cloudflare jako pierwszą.
- Mod 1.4.0 i aplikacja wysyłają nazwę pokoju w adresie zapytania (szybsze przekierowanie
  na serwerze Cloudflare; starsze serwery to ignorują).

## Sesja 1.2.0

- Zapora Windows: gospodarz widzi w Studiu ostrzeżenie, gdy zapora może blokować znajomych,
  i jednym przyciskiem „Odblokuj w zaporze Windows” dodaje zezwolenie (usuwa też blokadę
  powstałą po zamknięciu okienka zapory przy pierwszym uruchomieniu).
- Dokładniejsze błędy u dołączających: aplikacja rozróżnia „nie działa tam serwer”,
  „komputer gospodarza nie odpowiada” (zapora / Tailscale) i „złe hasło lub pokój”,
  i podpowiada, co zrobić.
- Przycisk „Połącz ponownie” i odliczanie do kolejnej automatycznej próby.

## Sesja 1.1.1

- W Studiu nad nazwą pokoju jest podpis „Pokój” – nie myli się już z nazwą zakładki.
- Błąd połączenia pokazuje się od razu (wcześniej znikał, gdy połączenie padło
  po otwarciu widoku) i podpowiada, co sprawdzić.

## Sesja 1.1.0

- Koniec z migającym oknem konsoli na Windows: mod w REAPERze uruchamia połączenia
  w tle, bez czarnego okienka co sekundę.
- Nowa zakładka „Jak połączyć” – instrukcja krok po kroku (Tailscale, zakładanie sesji,
  dołączanie), z animowanym schematem i odhaczaniem kroków.
- Osoba, która jest naraz w REAPERze i w aplikacji, pokazuje się raz – z plakietkami
  REAPER i Sesja.
- Więcej życia w interfejsie: fala pod nazwą pokoju i miernik w pasku bocznym reagują
  na zmiany od innych, przesuwany znacznik zakładki, pulsujący pierścień przy nagrywaniu,
  „equalizer” przy odtwarzaniu, płynne wejście paneli.
- Nowy wygląd okna moda w REAPERze (mod 1.3.0): żywy wskaźnik VU, karty osób
  z awatarami i plakietkami, zakładki z przesuwanym podświetleniem, animowane wpisy,
  powiadomienia o nowych wiadomościach i komentarzach.

## Sesja 1.0.1

- Naprawiony błąd „invalid args `resource` for command `install_mod`”, gdy REAPER był
  zainstalowany, ale jeszcze nigdy nie uruchomiony (nie miał folderu ustawień).
  Instalator prosi teraz o jednorazowe otwarcie REAPERa i sam przechodzi dalej,
  gdy folder ustawień się pojawi.
- Przycisk „Zainstaluj” czeka, aż REAPER zostanie zamknięty – inaczej REAPER przy
  zamykaniu nadpisałby zapisane właśnie ustawienia (nick, adres sesji).
- Linux: REAPER uruchomiony z aplikacji nie zostaje już jako „zombie” udający działający program.

## Sesja 1.0.0

- Aplikacja na Windows, macOS i Linuksa z instalatorem: na Windows to „Sesja Setup” (.exe)
  z wyborem języka, skrótami w menu Start i na pulpicie oraz deinstalatorem.
- Pięć języków: polski, angielski, niemiecki, hiszpański i francuski (zmiana w Ustawieniach,
  bez restartu). Mod w REAPERze mówi po polsku albo po angielsku – zgodnie z aplikacją.
- Instalator powitalny sam znajduje REAPERa (albo pozwala wskazać jego folder) i instaluje mod.
- Hostowanie sesji w aplikacji – bez instalowania Pythona. Aplikacja pokazuje adresy,
  które wysyłasz znajomym.
- Studio: kto jest online, kto nagrywa i co kto dodał do projektu.
- Czat, komentarze do klipów i lista wszystkich nagrań z odsłuchem i podglądem fali.
- Automatyczne aktualizacje i ten dziennik zmian.

## Mod 1.5.0

- Automatyczne przełączanie na sesję wybraną w aplikacji Sesja (plik `session.txt` obok skryptu).

## Mod 1.4.0

- Współpraca z serwerem na Cloudflare (pokój w adresie zapytania).

## Mod 1.3.0

- Windows: curl uruchamiany przez wscript bez okna konsoli (koniec z miganiem).
- Nowy wygląd okna, animacje, łączenie tej samej osoby z REAPERa i aplikacji.

## Mod 1.2.0

- Angielska wersja okna moda; język ustawia aplikacja Sesja.
- Komunikaty błędów serwera w języku użytkownika.

## Mod 1.1.0

- Komentarz do zaznaczonego klipu: pojawia się jako znacznik na samym klipie
  (np. przy wokalu) i na liście komentarzy u wszystkich.
- Lista online pokazuje osoby, które są w sesji przez aplikację.

## Mod 1.0.0

- Pierwsza wersja: synchronizacja ścieżek, klipów, FX, plików audio, czat, komentarze,
  kolory autorów i lista aktywności.
