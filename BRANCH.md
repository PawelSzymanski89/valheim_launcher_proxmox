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

**Tło** pobiera się raz i jest trzymane lokalnie. Panel podaje przy nim znacznik
czasu, który zmienia się wyłącznie przy podmianie pliku — dopiero wtedy launcher
pobiera je ponownie.

## Stan prac

- [x] `panel_client.dart` — manifest, pobieranie plików z weryfikacją `sha256`, różnica wobec stanu lokalnego, tło z pamięcią podręczną
- [x] `github_engine.dart` — wykrywanie i pobieranie wydania silnika (w obu modułach)
- [x] `crypto_config.dart` — `panelUrl` i `engineRepo` w konfiguracji, ze zgodnością wstecz
- [ ] wpięcie `PanelClient` w `valheim_files_service.dart` zamiast `FtpDownloader`
- [ ] `updater_module` — instalacja z paczki GitHuba zamiast z FTP
- [ ] generator — pola panelu zamiast FTP w kreatorze
- [ ] build i test na Windowsie (nie da się z macOS)
