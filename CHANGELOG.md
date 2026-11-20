# Dziennik zmian

Nagłówki wersji aplikacji mają postać `## Sesja X.Y.Z` – sekcja trafia automatycznie
do opisu wydania na GitHubie.

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
