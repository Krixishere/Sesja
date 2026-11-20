# Serwer Sesji na Cloudflare

Wszyscy łączą się do jednego adresu, np. `https://sesja.twojadomena.pl`. Tailscale,
zapora Windows i router przestają mieć znaczenie, a Twój komputer nie musi być włączony.
Mod w REAPERze i aplikacja Sesja działają z tym serwerem bez żadnych zmian – wpisujesz
tylko adres.

Działa na **darmowym planie Cloudflare** (Workers + Durable Objects, bez R2 i bez karty).

## Wdrożenie (raz, ok. 5 minut)

Potrzebujesz Node.js 18+ i konta Cloudflare z Twoją domeną.

```bash
cd server/cloudflare
npm install
npx wrangler login          # otworzy przeglądarkę – zaloguj się do Cloudflare
```

Otwórz `wrangler.toml` i odkomentuj linię `routes`, wpisując swoją subdomenę:

```toml
routes = [{ pattern = "sesja.twojadomena.pl", custom_domain = true }]
```

Opcjonalnie ustaw hasło serwera (tylko litery, cyfry i `. _ -`):

```bash
npx wrangler secret put PASSWORD
```

Wdróż:

```bash
npx wrangler deploy
```

Gotowe. Otwórz `https://sesja.twojadomena.pl` w przeglądarce – zobaczysz „Sesja – serwer działa”.
Bez własnej domeny też zadziała adres `https://sesja-server.<twoje-konto>.workers.dev`,
który wrangler wypisze po wdrożeniu.

## Łączenie

U każdego (także u Ciebie) w aplikacji Sesja: **Studio → Dołączam do sesji** (albo
**Ustawienia → Adres serwera**): adres `https://sesja.twojadomena.pl`, ten sam pokój
i to samo hasło. Nikt nie klika „Uruchom serwer” – serwerem jest Cloudflare.

## Limity darmowego planu

- 100 000 zapytań dziennie (każda osoba z otwartą sesją wysyła ok. 1 zapytanie na sekundę –
  to wystarcza na kilka godzin wspólnej pracy kilku osób dziennie; plan płatny 5 $ ma 10 mln),
- jeden plik audio do ok. 95 MB (limit wielkości zapytania w Workers),
- 5 GB miejsca na projekty i nagrania łącznie.

## Test lokalny

```bash
npx wrangler dev --port 8799
RMP_SERVER_URL=http://127.0.0.1:8799 python3 ../../tests/run_e2e.py
```
