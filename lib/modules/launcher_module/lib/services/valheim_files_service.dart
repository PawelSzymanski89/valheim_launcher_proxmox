import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto/crypto.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive_io.dart';
import 'package:server_launcher/services/i18n_service.dart';
import 'package:server_launcher/services/ftp_downloader.dart';
import 'package:server_launcher/services/crypto_config.dart';
import 'package:server_launcher/services/github_engine.dart';
import 'package:server_launcher/services/panel_client.dart';
import 'package:server_launcher/services/valheim_server_service.dart';
import 'package:path/path.dart' as p;

/// Represents a file entry described by the remote JSON manifest.
class RemoteFileEntry {
  final String relativePath; // e.g. 'BepInEx/plugins/some.dll' or 'doorstop_config.ini' relative to game root
  final int? size;
  final DateTime? modified;

  RemoteFileEntry({required this.relativePath, this.size, this.modified});

  factory RemoteFileEntry.fromJson(Map<String, dynamic> j) {
    var rel = j['relativePath'] as String? ?? j['path'] as String? ?? j['file'] as String? ?? '';
    int? size;
    DateTime? modified;
    if (j.containsKey('size')) {
      final s = j['size'];
      if (s is num) size = s.toInt();
      if (s is String) size = int.tryParse(s);
    }
    // Support both 'modified' and 'modifyTime' (patcher uses 'modifyTime')
    final rawModified = j['modified'] ?? j['modifyTime'];
    if (rawModified != null) {
      if (rawModified is String && rawModified.isNotEmpty) {
        modified = DateTime.tryParse(rawModified);
      } else if (rawModified is num) {
        final v = rawModified.toInt();
        if (v < 1000000000000) {
          modified = DateTime.fromMillisecondsSinceEpoch(v * 1000);
        } else {
          modified = DateTime.fromMillisecondsSinceEpoch(v);
        }
      }
    }

    // Normalize path: keep full relative path from game root
    rel = rel.replaceAll('\\', '/'); // normalize separators first
    // Remove leading slash if any
    if (rel.startsWith('/')) rel = rel.substring(1);

    return RemoteFileEntry(relativePath: rel.replaceAll('/', Platform.pathSeparator), size: size, modified: modified);
  }
}

/// Represents the entire manifest from the server.
class RemoteManifest {
  final String? version;
  final List<RemoteFileEntry> files;

  RemoteManifest({this.version, required this.files});

  factory RemoteManifest.fromJson(Map<String, dynamic> j) {
    String? ver;
    if (j.containsKey('version')) {
      ver = j['version'].toString();
    }
    
    final List<RemoteFileEntry> files = [];
    final jsonFiles = j['files'];
    if (jsonFiles is List) {
      for (final f in jsonFiles) {
        if (f is Map<String, dynamic>) {
          files.add(RemoteFileEntry.fromJson(f));
        }
      }
    }

    return RemoteManifest(version: ver, files: files);
  }
}

/// Represents a local file with metadata for comparison.
class LocalFileEntry {
  final String relativePath; // relative to game root (e.g. 'BepInEx/plugins/x.dll' or 'doorstop_config.ini')
  final int size;
  final DateTime modified;

  LocalFileEntry({required this.relativePath, required this.size, required this.modified});
}

/// Service responsible for locating local Valheim game files.
///
/// Currently focuses on Windows and searches for `valheim.exe` in the 10 most
/// common Steam installation locations. This is a best-effort heuristic; users
/// with custom Steam libraries may have the game elsewhere.
class ValheimFilesService {
  /// Panel mode: files from the last manifest fetch, keyed by forward-slash
  /// relative path, so downloads can verify the sha256 the manifest promised.
  Map<String, PanelFile> _panelFiles = {};

  GithubEngine _engine(DecryptedConfig cfg) => cfg.engineRepo.trim().isEmpty
      ? GithubEngine()
      : GithubEngine(repo: cfg.engineRepo.trim());

  // Helper to compare sizes with absolute and relative tolerances.
  bool _sizeMatchesInternal(int? remoteSize, int localSize, int sizeTolerance) {
    if (remoteSize == null) return true;
    final diff = (remoteSize - localSize).abs();
    final relTolerance = (remoteSize * 0.005).ceil();
    final effective = sizeTolerance > relTolerance ? sizeTolerance : relTolerance;
    final minAbs = 2;
    final finalTolerance = effective > minAbs ? effective : minAbs;
    return diff <= finalTolerance;
  }

  /// Wypakowuje doorstop.zip z assets do roota gry Valheim.
  /// Nadpisuje istniejące pliki (doorstop_config.ini, .doorstop_version, winhttp.dll).
  /// [gameRoot] - katalog główny gry gdzie jest valheim.exe
  Future<void> extractDoorstopToGameRoot(String gameRoot) async {
    try {
      if (kDebugMode) debugPrint('[ValheimFilesService] Extracting doorstop.zip to $gameRoot');

      // Wczytaj zip z assets
      final ByteData data = await rootBundle.load('assets/doorstop.zip');
      final bytes = data.buffer.asUint8List();

      // Zdekoduj archiwum
      final archive = ZipDecoder().decodeBytes(bytes);

      // Wypakuj każdy plik
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outputPath = '$gameRoot${Platform.pathSeparator}${filename.replaceAll('/', Platform.pathSeparator)}';
          final outputFile = File(outputPath);

          // Utwórz katalog nadrzędny jeśli nie istnieje
          await outputFile.parent.create(recursive: true);

          // Zapisz plik
          await outputFile.writeAsBytes(file.content as List<int>);
          if (kDebugMode) debugPrint('[ValheimFilesService] Extracted: $filename -> $outputPath');
        }
      }

      if (kDebugMode) debugPrint('[ValheimFilesService] Doorstop extraction completed');
    } catch (e) {
      if (kDebugMode) debugPrint('[ValheimFilesService] Error extracting doorstop.zip: $e');
      // Nie rzucamy wyjątku - kontynuujemy nawet jeśli ekstrakcja się nie uda
    }
  }

  /// Returns the first found absolute path to `valheim.exe` among common locations,
  /// or `null` if not found.
  ///
  /// The search is Windows-oriented; on non-Windows platforms this will always
  /// return null.
  Future<String?> findValheimExecutable() async {
    if (kDebugMode) debugPrint('[ValheimFilesService] Starting search for valheim.exe');
    if (!Platform.isWindows) {
      if (kDebugMode) debugPrint('[ValheimFilesService] Non-Windows platform detected. Skipping search.');
      return null;
    }

    // First, check cache. If it points to a valid valheim.exe, return it immediately.
    try {
      final cached = await readCachedExePath();
      if (cached != null && cached.isNotEmpty) {
        final cf = File(cached);
        if (await cf.exists()) return cf.path;
      }
    } catch (_) {}

    final candidates = _commonWindowsCandidates();
    if (kDebugMode) debugPrint('[ValheimFilesService] Candidates to check: ${candidates.length}');
    for (final path in candidates) {
      if (kDebugMode) debugPrint('[ValheimFilesService] Checking: $path');
      final file = File(path);
      if (await file.exists()) {
        if (kDebugMode) debugPrint('[ValheimFilesService] FOUND valheim.exe at: ${file.path}');
        return file.path;
      }
    }
    if (kDebugMode) debugPrint('[ValheimFilesService] valheim.exe NOT FOUND in common locations');
    return null;
  }

  /// Returns all existing matches among the common locations.
  Future<List<String>> findAllCandidates() async {
    if (kDebugMode) debugPrint('[ValheimFilesService] Gathering all existing candidates');
    if (!Platform.isWindows) {
      if (kDebugMode) debugPrint('[ValheimFilesService] Non-Windows platform detected. Returning empty list.');
      return <String>[];
    }
    final List<String> found = [];
    final candidates = _commonWindowsCandidates();
    if (kDebugMode) debugPrint('[ValheimFilesService] Candidates to check: ${candidates.length}');
    for (final path in candidates) {
      final exists = await File(path).exists();
      if (exists) {
        found.add(path);
        if (kDebugMode) debugPrint('[ValheimFilesService] Candidate exists: $path');
      } else {
        if (kDebugMode) debugPrint('[ValheimFilesService] Candidate missing: $path');
      }
    }
    if (kDebugMode) debugPrint('[ValheimFilesService] Found ${found.length} candidate(s)');
    return found;
  }

  /// 10 popular Windows Steam locations where Valheim might be installed.
  /// Note: We include both Steam and SteamLibrary on common drives.
  List<String> _commonWindowsCandidates() {
    final List<String> drives = _likelyDrives();

    // We will generate candidates from common Steam root patterns
    // and then map to the Valheim exe path.
    final List<String> steamRoots = [
      r"C:\\Program Files (x86)\\Steam",
      r"C:\\Program Files\\Steam",
      r"C:\\Steam",
      r"C:\\Program Files (x86)\\SteamLibrary",
      r"C:\\Games\\Steam",
    ];

    // Build base roots for additional drives (D:, E:), common patterns
    for (final d in drives) {
      // Skip C: as already covered above
      if (d.toUpperCase() == 'C') continue;
      // Only add patterns for drives that actually exist to avoid probing many invalid paths
      try {
        final root = '${d}:\\';
        if (!Directory(root).existsSync()) continue;
      } catch (_) {
        continue;
      }
      steamRoots.addAll([
        '$d:\\Steam',
        '$d:\\SteamLibrary',
        '$d:\\Games\\Steam',
      ]);
    }

    // Ensure uniqueness and cap to top few to keep the final candidate list tight
    final uniqueRoots = steamRoots.toSet().toList();
    if (kDebugMode) debugPrint('[ValheimFilesService] Steam roots considered: ${uniqueRoots.length}');

    final List<String> candidates = [];
    for (final root in uniqueRoots) {
      candidates.add(
        _joinWindows([root, 'steamapps', 'common', 'Valheim', 'valheim.exe']),
      );
    }

    // We only need the first 10 most common ones. To meet the requirement strictly,
    // we will return at least 10 by ordering typical ones first.
    final List<String> topOrdered = [
      r"C:\\Program Files (x86)\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"C:\\Program Files\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"C:\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"C:\\Program Files (x86)\\SteamLibrary\\steamapps\\common\\Valheim\\valheim.exe",
      r"C:\\Games\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"D:\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"D:\\SteamLibrary\\steamapps\\common\\Valheim\\valheim.exe",
      r"D:\\Games\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"E:\\Steam\\steamapps\\common\\Valheim\\valheim.exe",
      r"E:\\SteamLibrary\\steamapps\\common\\Valheim\\valheim.exe",
    ];

    // Merge topOrdered with generated candidates while preserving order and uniqueness
    final seen = <String>{};
    final merged = <String>[];
    for (final p in topOrdered.followedBy(candidates)) {
      if (seen.add(p)) merged.add(p);
    }

    if (kDebugMode) debugPrint('[ValheimFilesService] Generated candidate paths: ${merged.length}');

    // Keep only the first N significant candidates to avoid an excessively long list
    // while ensuring we have at least the requested 10 popular locations represented.
    return merged.take(30).toList();
  }

  List<String> _likelyDrives() {
    // Return all drive letters A..Z so search covers every possible drive letter.
    // We'll generate uppercase letters 'A'..'Z' and let the caller decide which ones actually exist.
    return List<String>.generate(26, (i) => String.fromCharCode(65 + i));
  }

  String _joinWindows(List<String> parts) {
    return parts.join('\\');
  }

  /// Pobiera plik `mods_list.json` z serwera FTP (ścieżka zdalna np. '/BepInEx/mods_list.json')
  /// i zapisuje go w katalogu gry Valheim (root folder, tam gdzie znajduje się valheim.exe).
  /// Tworzy jednokrotny backup (nadpisywany) o nazwie `mods_list.json.bak` jeśli plik już istnieje.
  /// Zwraca absolutną ścieżkę do zapisanego pliku.
  Future<String> downloadModsListFromFtp(String remotePath) async {
    // Tryb panelu: manifest przychodzi po HTTPS, zapisujemy go w tym samym
    // miejscu i formacie ('files': [{path,size,sha256}]), reszta łańcucha bez zmian.
    final panelCfg = await loadDecryptedConfig();
    if (panelCfg != null && panelCfg.usesPanel) {
      final exe = await findValheimExecutable();
      if (exe == null) throw Exception('Nie znaleziono Valheim.exe.');
      final target = File('${File(exe).parent.path}${Platform.pathSeparator}mods_list.json');
      final client = PanelClient(panelCfg.panelUrl);
      try {
        final m = await client.manifest();
        _panelFiles = {for (final f in m.files) f.path: f};
        await target.writeAsString(json.encode({
          'files': [
            for (final f in m.files)
              {'path': f.path, 'size': f.size, 'sha256': f.sha256}
          ]
        }));
        return target.path;
      } finally {
        client.close();
      }
    }

    // Wyciągnij nazwę pliku
    final remoteParts = remotePath.split(RegExp(r'[\\/]+'));
    final targetBaseName = remoteParts.isNotEmpty ? remoteParts.last : remotePath;

    // Znajdź valheim.exe
    final exe = await findValheimExecutable();
    if (exe == null) {
      throw Exception('Nie znaleziono Valheim.exe.');
    }
    final gameRoot = File(exe).parent.path;
    // Build the target path reliably
    final targetFile = File('$gameRoot${Platform.pathSeparator}$targetBaseName');
    final backupFile = File('${targetFile.path}.bak');

    // Jeśli istnieje lokalny plik, utwórz jednokrotny backup (nadpisując .bak)
    if (await targetFile.exists()) {
      try {
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
      } catch (_) {}
      try {
        await targetFile.rename(backupFile.path);
      } catch (e) {
        // fallback copy+delete
        try {
          await targetFile.copy(backupFile.path);
          try {
            await targetFile.delete();
          } catch (_) {}
        } catch (e2) {
          // If backup creation fails, continue; we'll still attempt download
          debugPrint('[ValheimFilesService] Backup failed: $e ; $e2');
        }
      }
    }

    // Wczytaj konfigurację FTP z zaszyfrowanego pliku
    final decrypted = await loadDecryptedConfig();
    if (decrypted == null) {
      // Przywróć backup jeśli utworzono i download się nie wykona
      try {
        if (await backupFile.exists()) {
          if (await targetFile.exists()) {
            try { await targetFile.delete(); } catch (_) {}
          }
          await backupFile.rename(targetFile.path);
        }
      } catch (_) {}
      throw Exception('Nie można wczytać zaszyfrowanej konfiguracji FTP.');
    }

    final downloader = FtpDownloader(decrypted.toFtpConfig());

    try {
      await downloader.connect();
      await downloader.download(remotePath, targetFile.path);
      await downloader.disconnect();
      return targetFile.path;
    } catch (e) {
      // Jeśli pobieranie się nie udało, spróbuj przywrócić backup
      try {
        if (await backupFile.exists()) {
          if (await targetFile.exists()) {
            try {
              await targetFile.delete();
            } catch (_) {}
          }
          await backupFile.rename(targetFile.path);
        }
      } catch (_) {}
      try {
        await downloader.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  /// Porównuje zdalną i lokalną listę plików i zwraca mapę z listami do pobrania i do usunięcia.
  /// Zgodna sygnatura z wcześniejszym API (używana przez LauncherCubit).
  /// Porównuje zdalną i lokalną listę plików i zwraca mapę z listami do pobrania i do usunięcia.
  /// Używa `compute` do wykonania operacji w osobnym izolacie, aby nie blokować UI (wideo).
  Future<Map<String, dynamic>> compareRemoteAndLocal(List<RemoteFileEntry> remoteList, List<LocalFileEntry> localList, {int sizeTolerance = 0}) async {
    return await compute<_CompareTaskParams, Map<String, dynamic>>(
      _compareRemoteAndLocalTask,
      _CompareTaskParams(remoteList, localList, sizeTolerance),
    );
  }

  /// Pobiera i parsuje zdalny manifest JSON z FTP (np. '/BepInEx/mods_list.json').
  /// Zwraca obiekt `RemoteManifest`.
  Future<RemoteManifest> loadRemoteManifestFromFtp(String remoteJsonPath) async {
    final decrypted = await loadDecryptedConfig();
    if (decrypted == null) throw Exception('Nie można wczytać zaszyfrowanej konfiguracji FTP.');

    if (decrypted.usesPanel) {
      final client = PanelClient(decrypted.panelUrl);
      try {
        final m = await client.manifest();
        _panelFiles = {for (final f in m.files) f.path: f};
        // Wersja = odcisk listy plików: zmienia się dokładnie wtedy, gdy
        // zmieniają się mody, więc cubit pomija sync przy braku zmian.
        final version = sha256
            .convert(utf8.encode(m.files.map((f) => '${f.path}:${f.sha256}').join('\n')))
            .toString()
            .substring(0, 16);
        return RemoteManifest(
          version: version,
          files: [
            for (final f in m.files)
              RemoteFileEntry(
                relativePath: f.path.replaceAll('/', Platform.pathSeparator),
                size: f.size,
              )
          ],
        );
      } finally {
        client.close();
      }
    }

    final downloader = FtpDownloader(decrypted.toFtpConfig());

    final tmp = Directory.systemTemp.createTempSync('mods_manifest_');
    final tmpFile = File('${tmp.path}${Platform.pathSeparator}mods_list.json');

    try {
      await downloader.connect();
      await downloader.download(remoteJsonPath, tmpFile.path);
      await downloader.disconnect();

      final content = await tmpFile.readAsString();
      // Dekoduj JSON na osobnym izolat żeby nie blokować UI (wideo).
      final decoded = await compute<String, dynamic>(json.decode, content);
      
      if (decoded is Map<String, dynamic>) {
        return RemoteManifest.fromJson(decoded);
      } else if (decoded is List) {
        // Wrap old format
        return RemoteManifest(files: decoded.map((e) => RemoteFileEntry.fromJson(e as Map<String, dynamic>)).toList());
      } else {
        throw Exception('Nieprawidłowy format manifestu');
      }
    } finally {
      try {
        await downloader.disconnect();
      } catch (_) {}
      try {
        if (await tmp.exists()) tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Listuje lokalne pliki modów na podstawie ścieżek z manifestu.
  /// Sprawdza które pliki z manifestu istnieją lokalnie i zwraca ich metadane.
  /// [gameRoot] - katalog główny gry (gdzie jest valheim.exe)
  /// [manifestPaths] - lista ścieżek względnych z manifestu (opcjonalna - jeśli pusta, skanuje BepInEx)
  /// Listuje lokalne pliki modów na podstawie ścieżek z manifestu.
  /// Używa `compute` do skanowania dysku w osobnym izolacie, aby nie blokować UI.
  Future<List<LocalFileEntry>> listLocalModFiles(String gameRoot, {List<String>? manifestPaths}) async {
    return await compute<_ScanTaskParams, List<LocalFileEntry>>(
        _listLocalFilesTask,
        _ScanTaskParams(gameRoot, manifestPaths)
    );
  }

  /// Stara funkcja dla kompatybilności - przekierowuje do listLocalModFiles
  Future<List<LocalFileEntry>> listLocalBepInExFiles(String gameRoot) async {
    return listLocalModFiles(gameRoot);
  }

  /// Pobiera wiele plików z FTP używając jednego połączenia FTP.
  /// `remoteBase` - folder bazowy na serwerze (np. '/BepInEx'),
  /// `entries` - lista RemoteFileEntry z relatywnymi ścieżkami względem remoteBase,
  /// `localBase` - lokalny folder docelowy (np. 'C:\...\Valheim'),
  /// `onProgress` - callback (completed, total, currentRemotePath, success)
  Future<void> downloadMultipleFromFtp({
    required String remoteBase,
    required List<RemoteFileEntry> entries,
    required String localBase,
    int sizeTolerance = 2,
    required void Function(int completed, int total, String current, bool success, RemoteFileEntry? item) onProgress,
    void Function(int active, int allowed)? onPoolInfo,
  }) async {
    if (entries.isEmpty) return;
    final decrypted = await loadDecryptedConfig();
    if (decrypted == null) throw Exception('Nie można wczytać zaszyfrowanej konfiguracji FTP.');

    if (decrypted.usesPanel) {
      // ponytail: pobieranie sekwencyjne — manifest to ~2 MB po HTTPS/2,
      // pula workerów wróci, jeśli mody kiedyś urosną o rząd wielkości.
      final client = PanelClient(decrypted.panelUrl);
      var completed = 0;
      try {
        for (final item in entries) {
          var rel = item.relativePath.replaceAll('\\', '/');
          if (rel.startsWith('/')) rel = rel.substring(1);
          final localPath =
              '$localBase${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
          final pf = _panelFiles[rel] ??
              PanelFile(path: rel, size: item.size ?? 0, sha256: '');
          var ok = false;
          for (var attempt = 1; attempt <= 3 && !ok; attempt++) {
            try {
              await client.downloadFile(pf, localPath);
              ok = true;
            } catch (e) {
              if (kDebugMode) debugPrint('[ValheimFilesService] Panel attempt $attempt ERROR $rel: $e');
              if (attempt < 3) await Future.delayed(const Duration(milliseconds: 300));
            }
          }
          if (ok) {
            completed++;
          } else {
            try {
              final f = File(localPath);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
          onProgress(completed, entries.length, '/$rel', ok, item);
          await Future.delayed(const Duration(milliseconds: 1));
        }
      } finally {
        client.close();
      }
      return;
    }

    final ftpCfg = decrypted.toFtpConfig();

    // Stała pula połączeń - zawsze maksimum dla szybkości pobierania
    const int maxPool = 8; // Zwiększona pula dla lepszej wydajności
    const int minPool = 2;
    final int total = entries.length;
    int allowedPool = maxPool; // Zawsze startujemy z max

    // Dynamiczne obniżanie puli tylko gdy są błędy połączenia
    final List<DateTime> connectErrorTimes = <DateTime>[];
    DateTime? poolCooldownUntil;
    const Duration errorWindow = Duration(minutes: 1);
    const Duration poolCooldown = Duration(seconds: 30);
    const int errorThreshold = 3;

    int activeWorkers = 0;
    void notifyPool() {
      if (onPoolInfo != null) onPoolInfo(activeWorkers, allowedPool);
    }

    void registerConnectError() {
      final now = DateTime.now();
      connectErrorTimes.removeWhere((t) => now.difference(t) > errorWindow);
      connectErrorTimes.add(now);
      final recentErrors = connectErrorTimes.length;
      final cooldownActive = poolCooldownUntil != null && now.isBefore(poolCooldownUntil!);
      if (recentErrors >= errorThreshold && !cooldownActive) {
        final prev = allowedPool;
        allowedPool = allowedPool > minPool ? allowedPool - 1 : minPool;
        poolCooldownUntil = now.add(poolCooldown);
        if (kDebugMode) debugPrint('[ValheimFilesService] Connection errors ($recentErrors in 1m). Reducing pool $prev -> $allowedPool');
        notifyPool();
      }
    }

    const int maxRetries = 3;
    int completedFiles = 0;
    int currentIndex = 0;
    DateTime lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);

    RemoteFileEntry? nextItem() {
      if (currentIndex >= entries.length) return null;
      final e = entries[currentIndex];
      currentIndex++;
      return e;
    }

    // Worker: osobne połączenie FTP/SFTP, pobiera pliki z kolejki dopóki są.
    Future<void> worker(int workerId) async {
      final downloader = FtpDownloader(ftpCfg);

      try {
        await downloader.connect();
        activeWorkers++;
        notifyPool();

        while (true) {
          final item = nextItem();
          if (item == null) break; // koniec kolejki

          var cleanRelPath = item.relativePath.replaceAll('\\', '/');
          if (cleanRelPath.startsWith('/')) cleanRelPath = cleanRelPath.substring(1);
          final remotePath = '/$cleanRelPath';
          final localPath = '$localBase${Platform.pathSeparator}${cleanRelPath.replaceAll('/', Platform.pathSeparator)}';
          
          int attempt = 0;
          bool ok = false;
          while (attempt < maxRetries && !ok) {
            attempt++;
            try {
              await downloader.download(remotePath, localPath);
              final localFile = File(localPath);
              final actualSize = await localFile.length();
              final expectedSize = item.size;
              final sizeOk = expectedSize == null || _sizeMatchesInternal(expectedSize, actualSize, sizeTolerance);
              if (!sizeOk) {
                if (kDebugMode) debugPrint('[ValheimFilesService][W$workerId] Size mismatch $remotePath expected=$expectedSize actual=$actualSize');
              }
              if (item.modified != null) {
                try { await localFile.setLastModified(item.modified!); } catch (_) {}
              }
              ok = sizeOk;
            } catch (e) {
              final msg = e.toString().toLowerCase();
              if (msg.contains('socket') || msg.contains('connection') || msg.contains('connect')) {
                registerConnectError();
              }
              if (kDebugMode) debugPrint('[ValheimFilesService][W$workerId] Attempt $attempt ERROR $remotePath: $e');
            }
            if (!ok && attempt < maxRetries) {
              await Future.delayed(const Duration(milliseconds: 300));
            }
          }

          if (ok) {
            completedFiles++;
            // Throttle progress updates to avoid UI stutter if many small files are processed
            final now = DateTime.now();
            if (completedFiles == total || (now.difference(lastProgressEmit).inMilliseconds > 120)) {
               lastProgressEmit = now;
               onProgress(completedFiles, entries.length, remotePath, true, item);
            }
          } else {
            onProgress(completedFiles, entries.length, remotePath, false, item);
            final localFile = File(localPath);
            try { if (await localFile.exists()) await localFile.delete(); } catch (_) {}
            if (kDebugMode) debugPrint('[ValheimFilesService][W$workerId] Failed $remotePath after $maxRetries attempts');
          }
          // Yield control to event loop for the video renderer
          await Future.delayed(const Duration(milliseconds: 1));
        }
      } finally {
        if (activeWorkers > 0) { activeWorkers--; notifyPool(); }
        try { await downloader.disconnect(); } catch (_) {}
      }
    }

    if (kDebugMode) debugPrint('[ValheimFilesService] Starting download: total=$total, pool=$allowedPool');
    notifyPool();

    // Uruchom wszystkich workerów równolegle
    final workerCount = total < maxPool ? total : maxPool; // Nie więcej workerów niż plików
    final futures = <Future<void>>[];
    for (int i = 0; i < workerCount; i++) {
      futures.add(worker(i + 1));
    }
    await Future.wait(futures);

    if (kDebugMode) debugPrint('[ValheimFilesService] Download complete: $completedFiles/$total');
    notifyPool();
  }

  Future<String?> _cacheFilePath() async {
    try {
      if (Platform.isWindows) {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          final dir = Directory('$appData${Platform.pathSeparator}schron_twarda_launcher');
          if (!await dir.exists()) await dir.create(recursive: true);
          return '${dir.path}${Platform.pathSeparator}cache.txt';
        }
      }
      // Fallback to temp directory
      final tmp = Directory.systemTemp;
      final dir = Directory('${tmp.path}${Platform.pathSeparator}schron_twarda_launcher');
      if (!await dir.exists()) await dir.create(recursive: true);
      return '${dir.path}${Platform.pathSeparator}cache.txt';
    } catch (_) {
      return null;
    }
  }

  Future<String?> readCachedExePath() async {
    try {
      final path = await _cacheFilePath();
      if (path == null) return null;
      final f = File(path);
      if (!await f.exists()) return null;
      final content = await f.readAsString();
      final trimmed = content.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCachedExePath(String exePath) async {
    try {
      final path = await _cacheFilePath();
      if (path == null) return;
      final f = File(path);
      await f.writeAsString(exePath);
    } catch (_) {}
  }

  /// Sprawdza na serwerze wersję updatera (plik '/launcher_files/updater.txt').
  /// Jeśli wersja różni się od zapisanej w SharedPreferences pod kluczem 'updater_version',
  /// pobiera '/launcher_files/updater.zip', rozpakowuje do katalogu '<appRoot>/updater',
  /// nadpisuje pliki, usuwa pobrany zip i zapisuje nową wersję w prefs.
  ///
  /// Callback onProgress: (progress: 0.0..1.0, statusMessage)
  Future<bool> checkAndRunUpdater({required void Function(double progress, String status) onProgress}) async {
    try {
      onProgress(0.0, I18n.instance.t('checking_updates'));

      final decrypted = await loadDecryptedConfig();
      if (decrypted == null) throw Exception(I18n.instance.t('ftp_invalid_config'));

      if (decrypted.usesPanel) {
        return _panelCheckAndRunUpdater(decrypted, onProgress: onProgress);
      }

      final ftpCfg = decrypted.toFtpConfig();

      if (kDebugMode) debugPrint('[Updater] Wczytano zaszyfrowany config: ${ftpCfg.host}');

      final tmp = Directory.systemTemp.createTempSync('updater_check_');
      final tmpTxt = File('${tmp.path}${Platform.pathSeparator}updater.txt');

      final downloader = FtpDownloader(ftpCfg);

      try {
        await downloader.connect();
        final remoteTxtPath = '/launcher_files/updater.txt';
        if (kDebugMode) debugPrint('[Updater] Pobieram remote file: $remoteTxtPath -> ${tmpTxt.path}');
        await downloader.download(remoteTxtPath, tmpTxt.path);
        await downloader.disconnect();
      } catch (e) {
        if (kDebugMode) debugPrint('[Updater] Błąd podczas pobierania updater.txt: $e');
        onProgress(0.0, I18n.instance.t('ftp_connection_error'));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }

      // Odczytaj wersję
      String remoteVersion;
      try {
        remoteVersion = (await tmpTxt.readAsString()).trim();
        if (kDebugMode) debugPrint('[Updater] Odczytano remoteVersion: "$remoteVersion" z ${tmpTxt.path}');
      } catch (e) {
        if (kDebugMode) debugPrint('[Updater] Nie udało się odczytać updater.txt: $e');
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        onProgress(0.0, I18n.instance.t('updater_read_error'));
        return false;
      }

      // Ustal docelowy katalog updater (appRoot) już teraz, by móc sprawdzić lokalną zawartość
      String appRoot;
      try {
        final resolved = Platform.resolvedExecutable;
        appRoot = File(resolved).parent.path;
        if (kDebugMode) debugPrint('[Updater] Platform.resolvedExecutable = $resolved; appRoot = $appRoot');
      } catch (_) {
        // Fallback do APPDATA
        final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
        appRoot = '$appData${Platform.pathSeparator}schron_twarda_launcher';
        try { final d = Directory(appRoot); if (!await d.exists()) await d.create(recursive: true); } catch (_) {}
        if (kDebugMode) debugPrint('[Updater] Fallback appRoot = $appRoot');
      }
      final destDir = Directory('$appRoot${Platform.pathSeparator}updater');
      if (kDebugMode) debugPrint('[Updater] destDir = ${destDir.path}');

      // Porównaj z lokalną wersją
      final prefs = await SharedPreferences.getInstance();
      final localVersion = prefs.getString('updater_version');
      if (kDebugMode) debugPrint('[Updater] Local stored version = ${localVersion ?? '<brak>'}');

      // Jeśli katalog updater istnieje i zawiera plik .exe, sprawdź czy możemy pominąć pobieranie.
      bool localHasExe = false;
      List<String> localExePaths = [];
      try {
        if (await destDir.exists()) {
          if (kDebugMode) debugPrint('[Updater] destDir istnieje. Przeglądam zawartość...');
          final entries = destDir.listSync(recursive: true);
          for (final e in entries) {
            if (e is File) {
              final name = e.path.split(Platform.pathSeparator).last.toLowerCase();
              if (name.endsWith('.exe')) {
                localHasExe = true;
                localExePaths.add(e.path);
              }
            }
          }
          if (kDebugMode) debugPrint('[Updater] Zawartość destDir: foundExe=${localHasExe}, exePaths=$localExePaths');
        } else {
          if (kDebugMode) debugPrint('[Updater] destDir nie istnieje');
        }
      } catch (err) {
        localHasExe = false;
        if (kDebugMode) debugPrint('[Updater] Błąd podczas sprawdzania destDir: $err');
      }

      // Decyzja: pominąć pobieranie tylko gdy localVersion==remoteVersion i localHasExe
      if (localVersion != null && localVersion == remoteVersion && localHasExe) {
        if (kDebugMode) debugPrint('[Updater] Warunek SKIP: lokalna wersja == zdalna (${localVersion}) i jest .exe w ${destDir.path}');
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        onProgress(1.0, I18n.instance.t('updater_up_to_date'));
        return false;
      }

      if (kDebugMode) {
        debugPrint('[Updater] Decyzja: będę pobierać updater ponieważ:');
        if (!localHasExe) debugPrint('  - brak lokalnego pliku .exe w ${destDir.path}');
        if (localVersion == null) debugPrint('  - brak zapisanej lokalnej wersji (updater_version)');
        if (localVersion != null && localVersion != remoteVersion) debugPrint('  - wersja lokalna różna od zdalnej (local=$localVersion, remote=$remoteVersion)');
      }

      // 2) Pobierz updater.zip do tymczasowego pliku
      onProgress(0.05, I18n.instance.t('downloading_updater'));
      final tmpZip = File('${tmp.path}${Platform.pathSeparator}updater.zip');
      try {
        final downloader2 = FtpDownloader(ftpCfg);
        await downloader2.connect();
        final remoteZipPath = '/launcher_files/updater.zip';
        if (kDebugMode) debugPrint('[Updater] Pobieram remoteZip: $remoteZipPath -> ${tmpZip.path}');
        await downloader2.download(remoteZipPath, tmpZip.path);
        await downloader2.disconnect();
      } catch (e) {
        if (kDebugMode) debugPrint('[Updater] Błąd podczas pobierania updater.zip: $e');
        onProgress(0.0, I18n.instance.t('updater_download_error'));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }

      onProgress(0.6, I18n.instance.t('unpacking_updater'));

      // 3) Rozpakuj zip do docelowego folderu updater
      // Wypakuj najpierw do tempDir przed nadpisaniem
      final unpackTemp = Directory('${tmp.path}${Platform.pathSeparator}unpack');
      if (!await unpackTemp.exists()) await unpackTemp.create(recursive: true);
      if (kDebugMode) debugPrint('[Updater] Rozpakowuję do temp: ${unpackTemp.path}');

      try {
        final bytes = await tmpZip.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        if (kDebugMode) debugPrint('[Updater] Archiwum zawiera ${archive.length} wpisów');
        for (final file in archive) {
          final filename = file.name;
          final outPath = '${unpackTemp.path}${Platform.pathSeparator}$filename'.replaceAll('/', Platform.pathSeparator);
          if (file.isFile) {
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>);
          } else {
            final d = Directory(outPath);
            if (!await d.exists()) await d.create(recursive: true);
          }
        }

        // Po rozpakowaniu przenieś (nadpisując) do destDir
        if (await destDir.exists()) {
          if (kDebugMode) debugPrint('[Updater] Usuwam istniejący destDir: ${destDir.path}');
          try { await destDir.delete(recursive: true); } catch (_) {}
        }
        if (kDebugMode) debugPrint('[Updater] Przenoszę unpackTemp ${unpackTemp.path} -> destDir ${destDir.path}');
        await unpackTemp.rename(destDir.path);
        if (kDebugMode) debugPrint('[Updater] Rozpakowywanie zakończone pomyślnie');
      } catch (e) {
        if (kDebugMode) debugPrint('[Updater] Błąd rozpakowywania: $e');
        onProgress(0.0, I18n.instance.t('updater_unpack_error', {'error': '$e'}));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        try { if (await unpackTemp.exists()) unpackTemp.delete(recursive: true); } catch (_) {}
        return false;
      }

      // 4) Usuń pobrany zip i tmp
      try { if (await tmpZip.exists()) await tmpZip.delete(); } catch (_) {}
      try { if (await tmpTxt.exists()) await tmpTxt.delete(); } catch (_) {}
      try { if (await tmp.exists()) await tmp.delete(recursive: true); } catch (_) {}
      if (kDebugMode) debugPrint('[Updater] Usunięto pliki tymczasowe');

      // 5) Zapisz nową wersję w prefs
      try {
        await prefs.setString('updater_version', remoteVersion);
        if (kDebugMode) debugPrint('[Updater] Zapisano updater_version = $remoteVersion do SharedPreferences');
      } catch (err) {
        if (kDebugMode) debugPrint('[Updater] Nie udało się zapisać updater_version: $err');
      }

      onProgress(1.0, I18n.instance.t('updater_updated'));
      return true;
    } catch (ex) {
      try { /* ignore cleanup attempts */ } catch (_) {}
      if (kDebugMode) debugPrint('[Updater] Unhandled error: $ex');
      onProgress(0.0, I18n.instance.t('updater_error', {'error': '$ex'}));
      return false;
    }
  }

  /// Sprawdza wersję launchera na serwerze (plik '/launcher_files/launcher.txt').
  /// Jeśli wersja różni się od aktualnej wersji aplikacji (z PackageInfo),
  /// uruchamia updater '<appRoot>/updater/schron_twarda_updater.exe' i zamyka aplikację.
  ///
  /// Callback onProgress: (progress: 0.0..1.0, statusMessage)
  /// Zwraca true jeśli uruchomiono updater i należy zakończyć aplikację.
  Future<bool> checkAndRunLauncherUpdate({
    required void Function(double progress, String status) onProgress,
    required String currentVersion, // format: "X.X.X+X"
  }) async {
    try {
      onProgress(0.0, I18n.instance.t('checking_updates'));

      final decrypted = await loadDecryptedConfig();
      if (decrypted == null) throw Exception(I18n.instance.t('ftp_invalid_config'));

      if (decrypted.usesPanel) {
        return _panelCheckAndRunLauncherUpdate(decrypted,
            onProgress: onProgress, currentVersion: currentVersion);
      }

      final ftpCfg = decrypted.toFtpConfig();

      if (kDebugMode) debugPrint('[LauncherUpdate] Wczytano zaszyfrowany config: ${ftpCfg.host}');

      // Pobierz launcher.txt do tymczasowego pliku
      final tmp = Directory.systemTemp.createTempSync('launcher_version_check_');
      final tmpTxt = File('${tmp.path}${Platform.pathSeparator}launcher.txt');

      try {
        final downloaderLauncher = FtpDownloader(ftpCfg);
        await downloaderLauncher.connect();
        final remoteTxtPath = '/launcher_files/launcher.txt';
        if (kDebugMode) debugPrint('[LauncherUpdate] Pobieram: $remoteTxtPath');
        await downloaderLauncher.download(remoteTxtPath, tmpTxt.path);
        await downloaderLauncher.disconnect();
      } catch (e) {
        if (kDebugMode) debugPrint('[LauncherUpdate] Błąd podczas pobierania launcher.txt: $e');
        onProgress(0.0, I18n.instance.t('launcher_ftp_error'));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }

      // Odczytaj zdalną wersję
      String remoteVersion;
      try {
        remoteVersion = (await tmpTxt.readAsString()).trim();
        if (kDebugMode) debugPrint('[LauncherUpdate] Zdalna wersja: "$remoteVersion", lokalna: "$currentVersion"');
      } catch (e) {
        if (kDebugMode) debugPrint('[LauncherUpdate] Nie udało się odczytać launcher.txt: $e');
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        onProgress(0.0, I18n.instance.t('launcher_read_error'));
        return false;
      }

      // Porównaj wersje (Robust compare)
      final normRemote = remoteVersion.trim();
      final normCurrent = currentVersion.trim();

      if (kDebugMode) {
        debugPrint('[LauncherUpdate] Rozpoczynam porównanie:');
        debugPrint('   - Serwer (manifest): "$normRemote" (len=${normRemote.length}, codeUnits=${normRemote.codeUnits})');
        debugPrint('   - Lokalny (PackageInfo): "$normCurrent" (len=${normCurrent.length}, codeUnits=${normCurrent.codeUnits})');
        debugPrint('   - Identyczne? ${normRemote == normCurrent}');
      }

      if (normRemote == normCurrent) {
        if (kDebugMode) debugPrint('[LauncherUpdate] Wersje SĄ IDENTYCZNE - brak aktualizacji');
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        onProgress(1.0, I18n.instance.t('launcher_up_to_date'));
        return false;
      }

      // If versions are different, check if they are valid before proceeding
      if (normRemote.isEmpty) {
        if (kDebugMode) debugPrint('[LauncherUpdate] BŁĄD: Zdalna wersja jest pusta!');
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }

      if (kDebugMode) debugPrint('[LauncherUpdate] WYKRYTO RÓŻNICĘ WERSJI - inicjuję aktualizację...');

      if (kDebugMode) debugPrint('[LauncherUpdate] Wykryto nową wersję! Uruchamiam updater...');
      onProgress(0.5, I18n.instance.t('new_launcher_version'));

      // Ustal ścieżkę do updatera
      String appRoot;
      try {
        final resolved = Platform.resolvedExecutable;
        appRoot = File(resolved).parent.path;
        if (kDebugMode) debugPrint('[LauncherUpdate] appRoot = $appRoot');
      } catch (_) {
        final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
        appRoot = '$appData${Platform.pathSeparator}schron_twarda_launcher';
        if (kDebugMode) debugPrint('[LauncherUpdate] Fallback appRoot = $appRoot');
      }

      // Szukamy updatera - dowolny .exe w folderze updater (przeszukiwanie rekurencyjne)
      final updaterDir = Directory('$appRoot${Platform.pathSeparator}updater');
      File? updaterExe;

      if (await updaterDir.exists()) {
        if (kDebugMode) debugPrint('[LauncherUpdate] Przeszukuję folder updatera (rekurencyjnie): ${updaterDir.path}');
        try {
          final entries = updaterDir.listSync(recursive: true);
          for (final e in entries) {
            if (e is File && e.path.toLowerCase().endsWith('.exe')) {
              // Pomijamy pliki pomocnicze jeśli by jakieś były, szukamy głównego exe
              final name = p.basename(e.path).toLowerCase();
              if (name.contains('update') || name.contains('patcher') || entries.length == 1) {
                updaterExe = e;
                if (kDebugMode) debugPrint('[LauncherUpdate] Znaleziono updater exe: ${e.path}');
                break;
              }
            }
          }
          // Jeśli nie znaleźliśmy po słowie kluczowym, bierzemy pierwszy lepszy .exe
          if (updaterExe == null) {
             for (final e in entries) {
               if (e is File && e.path.toLowerCase().endsWith('.exe')) {
                 updaterExe = e;
                 break;
               }
             }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[LauncherUpdate] Błąd skanowania folderu updatera: $e');
        }
      } else {
        if (kDebugMode) debugPrint('[LauncherUpdate] Folder updatera NIE istnieje: ${updaterDir.path}');
      }

      if (updaterExe == null) {
        if (kDebugMode) debugPrint('[LauncherUpdate] BŁĄD: Nie znaleziono żadnego .exe w ${updaterDir.path}');
        onProgress(0.0, I18n.instance.t('updater_missing'));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }

      // Uruchom updater
      try {
        // Ustal ścieżkę i dodaj cudzysłów dla ścieżek ze spacjami na Windows
        final String exePath = updaterExe.path;
        
        if (kDebugMode) debugPrint('[LauncherUpdate] Uruchamiam updater (detached): $exePath');
        onProgress(0.8, I18n.instance.t('launching_updater'));

        // Uruchom w trybie detached (updater będzie działał niezależnie)
        await Process.start(
          exePath,
          [],
          workingDirectory: updaterExe.parent.path,
          mode: ProcessStartMode.detached,
        );

        if (kDebugMode) debugPrint('[LauncherUpdate] Updater uruchomiony pomyślnie');
        onProgress(1.0, I18n.instance.t('updater_launched'));

        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}

        // Zwróć true - sygnał do zamknięcia aplikacji
        return true;
      } catch (e) {
        if (kDebugMode) debugPrint('[LauncherUpdate] Błąd uruchamiania updatera: $e');
        onProgress(0.0, I18n.instance.t('updater_launch_error', {'error': '$e'}));
        try { if (await tmp.exists()) tmp.delete(recursive: true); } catch (_) {}
        return false;
      }
    } catch (ex) {
      if (kDebugMode) debugPrint('[LauncherUpdate] Unhandled error: $ex');
      onProgress(0.0, I18n.instance.t('version_check_error', {'error': '$ex'}));
      return false;
    }
  }

  // ─── PANEL MODE ───────────────────────────────────────────────────────────
  // Updates come from the engine repository's GitHub releases instead of the
  // admin's FTP. The handover flow is unchanged: the launcher only detects and
  // starts the updater; the updater installs, because Windows cannot replace a
  // running exe.

  String get _appRoot {
    try {
      return File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      return '$appData${Platform.pathSeparator}schron_twarda_launcher';
    }
  }

  File? _findUpdaterExe(String appRoot) {
    final dir = Directory('$appRoot${Platform.pathSeparator}updater');
    if (!dir.existsSync()) return null;
    final exes = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.exe'))
        .toList();
    if (exes.isEmpty) return null;
    for (final f in exes) {
      final name = p.basename(f.path).toLowerCase();
      if (name.contains('update') || name.contains('patcher')) return f;
    }
    return exes.first;
  }

  /// Keeps `<appRoot>/updater` current with the engine repo's updater.zip.
  Future<bool> _panelCheckAndRunUpdater(DecryptedConfig cfg,
      {required void Function(double progress, String status) onProgress}) async {
    final engine = _engine(cfg);
    try {
      final release = await engine.latest(asset: 'updater');
      if (release == null) {
        // Brak sieci/wydania nie może zatrzymać startu gry.
        onProgress(1.0, I18n.instance.t('updater_up_to_date'));
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      final localVersion = prefs.getString('updater_version');
      final destDir = Directory('$_appRoot${Platform.pathSeparator}updater');
      final hasExe = _findUpdaterExe(_appRoot) != null;

      if (localVersion == release.tag && hasExe) {
        onProgress(1.0, I18n.instance.t('updater_up_to_date'));
        return false;
      }

      onProgress(0.05, I18n.instance.t('downloading_updater'));
      final tmp = Directory.systemTemp.createTempSync('updater_gh_');
      final tmpZip = File('${tmp.path}${Platform.pathSeparator}updater.zip');
      try {
        final got = await engine.download(release, tmpZip.path);
        if (!got) {
          onProgress(0.0, I18n.instance.t('updater_download_error'));
          return false;
        }

        onProgress(0.6, I18n.instance.t('unpacking_updater'));
        final unpack = Directory('${tmp.path}${Platform.pathSeparator}unpack');
        await unpack.create(recursive: true);
        final archive = ZipDecoder().decodeBytes(await tmpZip.readAsBytes());
        for (final f in archive) {
          final outPath =
              '${unpack.path}${Platform.pathSeparator}${f.name.replaceAll('/', Platform.pathSeparator)}';
          if (f.isFile) {
            final out = File(outPath);
            await out.parent.create(recursive: true);
            await out.writeAsBytes(f.content as List<int>);
          } else {
            await Directory(outPath).create(recursive: true);
          }
        }
        if (await destDir.exists()) {
          try { await destDir.delete(recursive: true); } catch (_) {}
        }
        await unpack.rename(destDir.path);

        await prefs.setString('updater_version', release.tag);
        onProgress(1.0, I18n.instance.t('updater_updated'));
        return true;
      } finally {
        try { if (tmp.existsSync()) tmp.deleteSync(recursive: true); } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Updater][panel] Error: $e');
      onProgress(0.0, I18n.instance.t('updater_error', {'error': '$e'}));
      return false;
    } finally {
      engine.close();
    }
  }

  /// Detects a newer launcher release and hands over to the updater.
  /// Returns true when the updater was started and the launcher must exit.
  Future<bool> _panelCheckAndRunLauncherUpdate(DecryptedConfig cfg,
      {required void Function(double progress, String status) onProgress,
      required String currentVersion}) async {
    final engine = _engine(cfg);
    try {
      final release = await engine.latest(asset: 'launcher');
      if (release == null || !release.isNewerThan(currentVersion)) {
        onProgress(1.0, I18n.instance.t('launcher_up_to_date'));
        return false;
      }

      if (kDebugMode) {
        debugPrint('[LauncherUpdate][panel] ${release.tag} > $currentVersion, starting updater');
      }
      onProgress(0.5, I18n.instance.t('new_launcher_version'));

      final updaterExe = _findUpdaterExe(_appRoot);
      if (updaterExe == null) {
        onProgress(0.0, I18n.instance.t('updater_missing'));
        return false;
      }

      onProgress(0.8, I18n.instance.t('launching_updater'));
      await Process.start(updaterExe.path, [],
          workingDirectory: updaterExe.parent.path,
          mode: ProcessStartMode.detached);
      onProgress(1.0, I18n.instance.t('updater_launched'));
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[LauncherUpdate][panel] Error: $e');
      onProgress(0.0, I18n.instance.t('version_check_error', {'error': '$e'}));
      return false;
    } finally {
      engine.close();
    }
  }
}

// ─── ISOLATE TASKS ──────────────────────────────────────────────────────────

class _CompareTaskParams {
  final List<RemoteFileEntry> remoteList;
  final List<LocalFileEntry> localList;
  final int sizeTolerance;
  _CompareTaskParams(this.remoteList, this.localList, this.sizeTolerance);
}

Map<String, dynamic> _compareRemoteAndLocalTask(_CompareTaskParams params) {
  final remoteList = params.remoteList;
  final localList = params.localList;
  final sizeTolerance = params.sizeTolerance;

  bool isBlacklisted(String path) {
    final s = path.toLowerCase().replaceAll('\\', '/');
    final black = [
      'config/wackysdatabase/cache/',
      'logoutput.log',
      'mods_list.json',
      'bepinex/cache/',
      'bepinex/dumpedassemblies/',
      '.doorstop_version',
      'doorstop_config.ini.bak',
    ];
    for (final pat in black) {
      if (s.contains(pat.toLowerCase())) return true;
    }
    return false;
  }

  String normalize(String p) {
    if (p.isEmpty) return '';
    var s = p.replaceAll('\\', '/').trim();
    s = s.replaceAll(RegExp(r'/+'), '/');
    s = s.replaceFirst(RegExp(r'^[./\\]+'), '');
    s = s.toLowerCase();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  bool sizeMatches(int? remoteSize, int localSize, int tolerance) {
    if (remoteSize == null) return true;
    final diff = (remoteSize - localSize).abs();
    final relTolerance = (remoteSize * 0.005).ceil();
    final effective = tolerance > relTolerance ? tolerance : relTolerance;
    const minAbs = 2;
    final finalTolerance = effective > minAbs ? effective : minAbs;
    return diff <= finalTolerance;
  }

  final filteredRemote = remoteList.where((r) {
    if (isBlacklisted(r.relativePath)) return false;
    if (r.size == 0 || r.size == null) {
      if (r.relativePath.endsWith('/') || r.relativePath.endsWith('\\')) return false;
      if (r.modified == null) return false;
    }
    return true;
  }).toList();
  
  final filteredLocal = localList.where((l) => !isBlacklisted(l.relativePath)).toList();

  final remoteMap = <String, RemoteFileEntry>{};
  for (final r in filteredRemote) remoteMap[normalize(r.relativePath)] = r;
  
  final localMap = <String, LocalFileEntry>{};
  for (final l in filteredLocal) localMap[normalize(l.relativePath)] = l;

  final toDelete = <LocalFileEntry>[];
  for (final l in filteredLocal) {
    if (!remoteMap.containsKey(normalize(l.relativePath))) toDelete.add(l);
  }

  final toDownload = <RemoteFileEntry>[];
  final downloadReasons = <String, String>{};
  
  for (final r in filteredRemote) {
    final key = normalize(r.relativePath);
    final local = localMap[key];

    if (local == null) {
      toDownload.add(r);
      downloadReasons[r.relativePath] = 'MISSING: locally absent (key=$key)';
      continue;
    }

    var needsDownload = false;
    String reason = '';

    if (r.size != null) {
      if (!sizeMatches(r.size, local.size, sizeTolerance)) {
        needsDownload = true;
        reason = 'SIZE_MISMATCH: remote=${r.size}, local=${local.size}';
      } else if (r.modified != null) {
        final diff = (r.modified!.millisecondsSinceEpoch ~/ 1000 - local.modified.millisecondsSinceEpoch ~/ 1000).abs();
        if (diff > 600) {
          needsDownload = true;
          reason = 'DATE_MISMATCH_LARGE: diff=${diff}s';
        }
      }
    } else if (r.modified != null) {
      final diff = (r.modified!.millisecondsSinceEpoch ~/ 1000 - local.modified.millisecondsSinceEpoch ~/ 1000).abs();
      if (diff > 300) {
        needsDownload = true;
        reason = 'DATE_ONLY_MISMATCH: diff=${diff}s';
      }
    }

    if (needsDownload) {
      toDownload.add(r);
      downloadReasons[r.relativePath] = reason;
    }
  }

  return {'toDownload': toDownload, 'toDelete': toDelete, 'downloadReasons': downloadReasons};
}

class _ScanTaskParams {
  final String gameRoot;
  final List<String>? manifestPaths;
  _ScanTaskParams(this.gameRoot, this.manifestPaths);
}

List<LocalFileEntry> _listLocalFilesTask(_ScanTaskParams params) {
  final gameRoot = params.gameRoot;
  final manifestPaths = params.manifestPaths;
  final List<LocalFileEntry> res = [];

  if (manifestPaths != null && manifestPaths.isNotEmpty) {
    for (final relPath in manifestPaths) {
      try {
        final f = File('$gameRoot${Platform.pathSeparator}$relPath');
        if (f.existsSync()) {
          final s = f.statSync();
          res.add(LocalFileEntry(relativePath: relPath, size: s.size, modified: s.modified));
        }
      } catch (_) {}
    }
    return res;
  }

  try {
    const List<String> managedRoot = ['doorstop_config.ini', 'winhttp.dll'];
    for (final rf in managedRoot) {
      final f = File('$gameRoot${Platform.pathSeparator}$rf');
      if (f.existsSync()) {
        final s = f.statSync();
        res.add(LocalFileEntry(relativePath: rf, size: s.size, modified: s.modified));
      }
    }

    final bepDir = Directory('$gameRoot${Platform.pathSeparator}BepInEx');
    if (bepDir.existsSync()) {
      final entities = bepDir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          try {
            final rel = entity.path.substring(gameRoot.length + 1).replaceAll('\\', '/');
            final s = entity.statSync();
            res.add(LocalFileEntry(relativePath: rel, size: s.size, modified: s.modified));
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  return res;
}

/// Normalizuje ścieżkę pliku do porównania (np. usuwa prowadzące i końcowe ukośniki).
String normalize(String path) {
  return path.trim().replaceAll('\\', '/');
}
