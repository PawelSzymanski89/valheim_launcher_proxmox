# feat/no-ftp — launcher bez FTP, aktualizacje silnika z GitHuba

Fork `valheim_launcher_generator` przystosowany do serwera stawianego przez
[valheim-proxmox](https://github.com/PawelSzymanski89/valheim-proxmox).

## Co się zmienia wobec oryginału

**Nie ma FTP.** Oryginał wkłada konto FTP do każdego pliku wykonywalnego gracza —
zaszyfrowane, ale klucz jedzie w tej samej binarce, a sam protokół leci otwartym
tekstem. Tutaj launcher rozmawia z panelem po HTTPS i **nie ma żadnego konta**:

| Adres | Co daje |
|---|---|
| `GET /api/launcher/manifest` | dane serwera, lista modów, każdy plik z `sha256` i rozmiarem |
| `GET /api/launcher/files/<ścieżka>` | pojedynczy plik moda |
| `GET /api/launcher/background` | tło launchera |

Panel liczy manifest **na żywo z dysku** przy każdym zapytaniu, więc **Patcher
jest niepotrzebny** — nie ma kroku, w którym admin skanuje serwer i publikuje
manifest ręcznie. Zainstalowanie moda w panelu wystarcza.

Gdy admin wyłączy launcher, adresy oddają **404**, a nie pustą listę.

**Aktualizacje silnika idą z GitHuba.** `GithubEngine` pyta
`/releases/latest` tego repozytorium i porównuje tag z `version.txt` wstrzykniętym
do buildu. Dzięki temu nowy silnik trafia **do wszystkich serwerów naraz**, bez
wgrywania czegokolwiek przez adminów.

Przepływ aktualizacji zostaje taki jak w oryginale, bo Windows nie pozwala
podmienić działającego pliku: **launcher wykrywa nowszą wersję → uruchamia updater
→ kończy się → updater podmienia pliki i uruchamia launcher z powrotem.**

**Adres serwera przychodzi z manifestu, nie z buildu.** To jedyna rzecz, której
launcher nie wyliczy sam, i jedyna, która się zmienia: na łączu domowym numer IP
wędruje, DDNS za nim nadąża, a adres wkompilowany w plik wykonywalny jest zły
następnego ranka. Dlatego **w launcherze zapieczony jest wyłącznie adres panelu**
(nazwa domenowa), a nazwa serwera gry, port, wymóg hasła, lista modów i tło
przychodzą przy każdym starcie. Admin zmienia adres w panelu i zmiana dociera do
wszystkich graczy bez przebudowywania czegokolwiek.

**Tło** pobiera się raz i jest trzymane lokalnie. Panel podaje przy nim znacznik
czasu, który zmienia się wyłącznie przy podmianie pliku — dopiero wtedy launcher
pobiera je ponownie.

## Wydawanie — bez kreatora

Kreator (wizard) jest na tym forku zbędny: istniał po to, żeby zapiekać konto
FTP i sekrety w binarki na maszynie admina. W trybie panelu konfiguracja to
**trzy jawne pola** (`serverName`, `panelUrl`, `engineRepo`) — żadne nie jest
tajemnicą, więc leżą plaintextem w `assets/panel_config.json`, a całe
szyfrowanie (salt + APP_SECRET) zostaje tylko jako zgodność wstecz.

Wydanie robi GitHub Actions (`.github/workflows/release.yml`): push tagu `v*`
buduje oba moduły na Windowsie i publikuje release z `launcher.zip` i
`updater.zip` — **neutralne**, bez adresu żadnego serwera. Konfigurację
wstrzykuje panel: `/api/launcher/download` bierze silnik z GitHuba, podmienia
`panel_config.json` w zipie i serwuje graczom gotową paczkę. Updater czyta
config launchera obok siebie i zachowuje go przy podmianie silnika, więc
aktualizacja z GitHuba nie kasuje przypisania do serwera.

## Stan prac

- [x] `panel_client.dart` — manifest, pobieranie plików z weryfikacją `sha256`, różnica wobec stanu lokalnego, tło z pamięcią podręczną
- [x] `github_engine.dart` — wykrywanie i pobieranie wydania silnika (w obu modułach)
- [x] `crypto_config.dart` — `panelUrl` i `engineRepo` w konfiguracji, ze zgodnością wstecz
- [x] wpięcie `PanelClient` w `valheim_files_service.dart` zamiast `FtpDownloader` — tryb panelu włącza się sam, gdy config ma `panelUrl`; ścieżki FTP zostają dla configów z oryginalnego generatora
- [x] `updater_module` — instalacja z paczki GitHuba zamiast z FTP (release niesie `launcher.zip` i `updater.zip`, wybór po nazwie assetu)
- [x] generator — krok 3 zbiera adres panelu i repo silnika zamiast konta FTP; test połączenia odpytuje `/api/launcher/manifest` (404 = panel żyje, launcher wyłączony). **Uwaga:** po dodaniu release'ów z CI kreator jest w praktyce zbędny — zostaje jako zgodność wstecz.
- [x] plaintext `assets/panel_config.json` przed ścieżką szyfrowaną w obu modułach
- [x] `.github/workflows/release.yml` — tag `v*` → build na Windowsie → release z `launcher.zip` + `updater.zip`
- [ ] pierwszy release: ustawić repository variable `PANEL_URL`, puścić tag `v1.0.0`, sprawdzić pełny obieg aktualizacji na Windowsie
