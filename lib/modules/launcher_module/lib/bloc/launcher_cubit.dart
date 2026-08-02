import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:server_launcher/services/valheim_files_service.dart';
import 'package:server_launcher/services/custom_mods_service.dart';
import 'package:server_launcher/services/i18n_service.dart';
import 'package:server_launcher/services/launcher_config_service.dart';

@immutable
class LauncherState {
  final bool isBusy;
  final String statusMessage;
  final String statusKey; // NEW: klucz tłumaczenia bieżącego statusu
  final Map<String, String> statusParams; // NEW: parametry do tłumaczenia
  final String? valheimExePath;
  final bool readyToLaunch;
  final bool gameRunning;
  final String progressFileName; // nazwa pliku aktualnie przetwarzanego (dla UI, by nie skakać)
  final double progress; // 0.0 - 1.0 dla progress bar
  final bool showProgress; // czy pokazywać progress bar
  final int downloadedBytes; // pobrane bajty
  final int totalBytes; // całkowita liczba bajtów do pobrania
  final bool locateCompleted; // czy wyszukiwanie lokalizacji zostało zakończone (by GUI wiedziało, czy pokazać picker)
  final int activeFtpConnections; // aktywne połączenia FTP (dla UI)
  final int allowedFtpPool; // dozwolona pula połączeń (dla UI)
  final bool autoConnectEnabled; // czy auto-connect do serwera jest włączony
  final bool audioMuted; // czy dźwięk tła jest wyciszony
  final LauncherConfig? launcherConfig; // konfiguracja launchera z pliku JSON
  final bool showPasswordCopiedToast; // flaga do pokazania toasta o skopiowaniu hasła

  const LauncherState({
    required this.isBusy,
    required this.statusMessage,
    required this.statusKey,
    required this.statusParams,
    required this.valheimExePath,
    required this.readyToLaunch,
    required this.progressFileName,
    this.progress = 0.0,
    this.showProgress = false,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.gameRunning = false,
    this.locateCompleted = false,
    this.activeFtpConnections = 0,
    this.allowedFtpPool = 0,
    this.autoConnectEnabled = false,
    this.audioMuted = false,
    this.launcherConfig,
    this.showPasswordCopiedToast = false,
  });

  // Zmieniono: usunięto const konstruktor initial z wywołaniem I18n (niedozwolone w const) – używamy fabryki runtime.
  factory LauncherState.initial() => LauncherState(
        isBusy: false,
        statusMessage: I18n.instance.t('ready'),
        statusKey: 'ready',
        statusParams: const {},
        valheimExePath: null,
        readyToLaunch: false,
        gameRunning: false,
        progressFileName: '',
        progress: 0.0,
        showProgress: false,
        downloadedBytes: 0,
        totalBytes: 0,
        locateCompleted: false,
        activeFtpConnections: 0,
        allowedFtpPool: 0,
        autoConnectEnabled: false,
        audioMuted: false,
        launcherConfig: null,
        showPasswordCopiedToast: false,
      );

  LauncherState copyWith({
    bool? isBusy,
    String? statusMessage,
    String? statusKey,
    Map<String, String>? statusParams,
    String? valheimExePath,
    bool? readyToLaunch,
    bool? gameRunning,
    String? progressFileName,
    double? progress,
    bool? showProgress,
    int? downloadedBytes,
    int? totalBytes,
    bool? locateCompleted,
    int? activeFtpConnections,
    int? allowedFtpPool,
    bool? autoConnectEnabled,
    bool? audioMuted,
    LauncherConfig? launcherConfig,
    bool? showPasswordCopiedToast,
  }) => LauncherState(
        isBusy: isBusy ?? this.isBusy,
        statusMessage: statusMessage ?? this.statusMessage,
        statusKey: statusKey ?? this.statusKey,
        statusParams: statusParams ?? this.statusParams,
        valheimExePath: valheimExePath ?? this.valheimExePath,
        readyToLaunch: readyToLaunch ?? this.readyToLaunch,
        gameRunning: gameRunning ?? this.gameRunning,
        progressFileName: progressFileName ?? this.progressFileName,
        progress: progress ?? this.progress,
        showProgress: showProgress ?? this.showProgress,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        locateCompleted: locateCompleted ?? this.locateCompleted,
        activeFtpConnections: activeFtpConnections ?? this.activeFtpConnections,
        allowedFtpPool: allowedFtpPool ?? this.allowedFtpPool,
        autoConnectEnabled: autoConnectEnabled ?? this.autoConnectEnabled,
        audioMuted: audioMuted ?? this.audioMuted,
        launcherConfig: launcherConfig ?? this.launcherConfig,
        showPasswordCopiedToast: showPasswordCopiedToast ?? this.showPasswordCopiedToast,
      );
}

class LauncherCubit extends Cubit<LauncherState> {
  final ValheimFilesService filesService;
  final CustomModsService _customModsService = CustomModsService();
  final LauncherConfigService _configService = LauncherConfigService();
  bool _syncInProgress = false;
  DateTime? _lastSyncCompletedAt;
  bool _lastSyncHadDownload = false;
  Process? _runningProcess;
  Timer? _processWatchTimer;
  Timer? _autoExitTimer;

  LauncherCubit([ValheimFilesService? service])
      : filesService = service ?? ValheimFilesService(),
        super(LauncherState.initial()) {
    // Listener na zmianę języka – retranslacja bieżącego statusu
    I18n.instance.addListener(_onLanguageChanged);
    // Wczytaj konfigurację i stan auto-connect
    _loadInitialConfig();
  }

  /// Wczytuje konfigurację z pliku JSON i stan auto-connect z SharedPreferences
  Future<void> _loadInitialConfig() async {
    try {
      final config = await _configService.loadConfig();
      final prefs = await SharedPreferences.getInstance();
      final autoConnect = prefs.getBool('auto_connect_enabled') ?? false;
      final audioMuted = prefs.getBool('audio_muted') ?? false;

      emit(state.copyWith(
        launcherConfig: config,
        autoConnectEnabled: autoConnect,
        audioMuted: audioMuted,
      ));

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Config loaded: ${config.serverName}, auto-connect: $autoConnect');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherCubit] Error loading initial config: $e');
      }
    }
  }

  void _onLanguageChanged() {
    // Retranslate current status using stored key & params
    final newMsg = I18n.instance.t(state.statusKey, state.statusParams);
    emit(state.copyWith(statusMessage: newMsg));
  }

  @override
  Future<void> close() {
    I18n.instance.removeListener(_onLanguageChanged);
    _autoExitTimer?.cancel();
    return super.close();
  }

  /// Zamyka launcher po opóźnieniu - używane po uruchomieniu gry
  /// Nie zabija procesu gry ponieważ jest uruchomiony w trybie detached
  void _scheduleAutoExit() {
    _autoExitTimer?.cancel();
    _autoExitTimer = Timer(const Duration(seconds: 5), () {
      if (kDebugMode) debugPrint('[LauncherCubit] Auto-exit after game start');
      exit(0); // Zamknij launcher - gra działająca w trybie detached nie zostanie zamknięta
    });
  }

  /// Przełącza stan auto-connect i zapisuje w SharedPreferences
  Future<void> toggleAutoConnect() async {
    try {
      final newValue = !state.autoConnectEnabled;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_connect_enabled', newValue);

      emit(state.copyWith(autoConnectEnabled: newValue));

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Auto-connect toggled to: $newValue');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherCubit] Error toggling auto-connect: $e');
      }
    }
  }

  /// Toggle audio mute state and persist preference
  Future<void> toggleAudioMuted() async {
    try {
      final newValue = !state.audioMuted;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('audio_muted', newValue);
      emit(state.copyWith(audioMuted: newValue));
      if (kDebugMode) debugPrint('[LauncherCubit] Audio muted toggled to: $newValue');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherCubit] Error toggling audio muted: $e');
      }
    }
  }

  // Helper do emisji statusu z kluczem + parametrami
  LauncherState _emitStatus(String key, {Map<String, String>? params, bool? isBusy, bool? readyToLaunch, String? progressFileName, bool? showProgress, double? progress, int? downloadedBytes, int? totalBytes, bool? locateCompleted, int? activeFtpConnections, int? allowedFtpPool, String? valheimExePath, bool? gameRunning}) {
    final translated = I18n.instance.t(key, params);
    final newState = state.copyWith(
      statusMessage: translated,
      statusKey: key,
      statusParams: params ?? const {},
      isBusy: isBusy,
      readyToLaunch: readyToLaunch,
      progressFileName: progressFileName,
      showProgress: showProgress,
      progress: progress,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      locateCompleted: locateCompleted,
      activeFtpConnections: activeFtpConnections,
      allowedFtpPool: allowedFtpPool,
      valheimExePath: valheimExePath,
      gameRunning: gameRunning,
    );
    emit(newState);
    return newState;
  }

  Future<void> locateValheimExe({bool force = false}) async {
    if (state.isBusy && !force) return;
    // POPRAWKA: użyj `_emitStatus` zamiast ręcznego emit, aby zachować statusKey
    _emitStatus('locating_game', isBusy: true, readyToLaunch: false, progressFileName: '', valheimExePath: state.valheimExePath, locateCompleted: false);
    try {
      final path = await filesService.findValheimExecutable();
      if (path != null) {
        _emitStatus('valheim_found', isBusy: false, valheimExePath: path, readyToLaunch: false, progressFileName: '', locateCompleted: true);
      } else {
        _emitStatus('valheim_not_found', isBusy: false, readyToLaunch: false, progressFileName: '', locateCompleted: true);
      }
    } catch (e) {
      _emitStatus('error_locating', params: {'error': '$e'}, isBusy: false, readyToLaunch: false, progressFileName: '', locateCompleted: true);
    }
  }

  /// Sekwencja: wykonaj synchronizację BepInEx względem manifestu na serwerze.
  Future<void> syncAndPrepare(
      {String remoteManifest = '/mods_list.json', bool force = false}) async {
    // Prevent re-entrancy using an internal flag. If already syncing and not forced, do nothing.
    if (_syncInProgress && !force) return;
    _syncInProgress = true;
    _emitStatus('verifying_remote_files', isBusy: true, readyToLaunch: false, progressFileName: '');
    // Always attempt to download and store mods_list.json into game folder (one-time save per sync).
    try {
      // downloadModsListFromFtp will locate valheim.exe to determine game root and save the file there.
      await filesService.downloadModsListFromFtp(remoteManifest);
      if (kDebugMode) debugPrint(
          '[LauncherCubit] Saved remote mods_list to game folder');
    } catch (e) {
      // If saving fails, we still proceed — loadRemoteManifestFromFtp will try to fetch manifest to parse.
      if (kDebugMode) debugPrint(
          '[LauncherCubit] Warning: downloadModsListFromFtp failed: $e');
    }
    try {
      // 1) Pobierz manifest z FTP (pierwsze połączenie / parsing)
      final remoteManifestObj = await filesService.loadRemoteManifestFromFtp(remoteManifest);
      final remoteList = remoteManifestObj.files;
      final serverVersion = remoteManifestObj.version;

      final prefs = await SharedPreferences.getInstance();
      final localVersion = prefs.getString('local_mods_version');

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Server version: $serverVersion, Local version: $localVersion');
      }

      // Jeśli wersje są identyczne i nie wymuszamy - pomijamy całą synchronizację
      if (serverVersion != null && localVersion == serverVersion && !force) {
        if (kDebugMode) debugPrint('[LauncherCubit] Versions match, skipping sync.');
        _emitStatus('ready_to_launch', isBusy: false, readyToLaunch: true, progressFileName: '', showProgress: false);
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[LauncherCubit] Remote manifest entries: ${remoteList.length}');
      }

      // POPRAWKA: użyj `_emitStatus` zamiast ręcznego emit, aby zachować statusKey
      _emitStatus('verifying_local_files', progressFileName: '');

      // 2) Listuj lokalne pliki modów (pełny skan BepInEx, aby wykryć sieroty)
      final exe = state.valheimExePath ??
          await filesService.findValheimExecutable();
      if (exe == null) {
        _emitStatus('valheim_exe_not_found', isBusy: false, readyToLaunch: false, progressFileName: '');
        return;
      }
      final gameRoot = File(exe).parent.path;
      if (kDebugMode) debugPrint('[LauncherCubit] Using gameRoot: $gameRoot');

      // Loader idzie tylko wtedy, gdy serwer faktycznie wysyła mody. Gdy nie
      // wysyła nic, zdejmujemy go razem z resztą — inaczej gracz zostaje z
      // doorstopem szukającym BepInEx-a, którego przed chwilą usunęliśmy.
      if (remoteList.isNotEmpty) {
        _emitStatus('extracting_doorstop', isBusy: true, showProgress: false, progressFileName: 'doorstop.zip');
        await filesService.extractDoorstopToGameRoot(gameRoot);
      } else {
        await filesService.removeDoorstopFromGameRoot(gameRoot);
      }

      final localList = await filesService.listLocalModFiles(gameRoot);

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Local mod files: ${localList.length}');
        for (var i = 0; i <
            (localList.length > 5 ? 5 : localList.length); i++) {
          debugPrint('[LauncherCubit] Local[${i}]: "${localList[i]
              .relativePath}" size=${localList[i].size} modified=${localList[i]
              .modified}');
        }
      }

      // POPRAWKA: użyj `_emitStatus` zamiast ręcznego emit, aby zachować statusKey
      _emitStatus('matching_versions', progressFileName: '');

      // 3) Użyj centralnej funkcji porównania z serwisu
      // Oddaj event loop UI przed synchroniczną pętlą 1371 plików
      await Future.delayed(Duration.zero);
      final comparison = await filesService.compareRemoteAndLocal(
          remoteList, localList, sizeTolerance: 2);
      

      // Zawsze używamy smart diff — pobieramy TYLKO pliki które się różnią (rozmiar/data).
      // Wersja służy TYLKO do pomijania synchronizacji gdy nic się nie zmieniło.
      if (serverVersion != null && localVersion != serverVersion) {
        if (kDebugMode) debugPrint('[LauncherCubit] Version mismatch ($localVersion -> $serverVersion). Running smart diff.');
      }
      final toDownload = List<RemoteFileEntry>.from(comparison['toDownload'] ?? <RemoteFileEntry>[]);
      final toDelete = List<LocalFileEntry>.from(comparison['toDelete'] ?? <LocalFileEntry>[]);
      final downloadReasons = Map<String, String>.from((comparison['downloadReasons'] as Map?) ?? {});

      // Record sync result: whether there are downloads to perform and timestamp
      _lastSyncHadDownload = toDownload.isNotEmpty;
      _lastSyncCompletedAt = DateTime.now();
      // Fire-and-forget: append the computed list of files to download into persistent log (InBackground)
      compute<_LogDownloadParams, void>(
        _logDownloadTask,
        _LogDownloadParams(toDownload, remoteManifest, downloadReasons, state.valheimExePath)
      ).catchError((_) => null);

      if (kDebugMode) {
        debugPrint('[LauncherCubit] toDelete=${toDelete
            .length}, toDownload=${toDownload.length}');
        for (var i = 0; i <
            (toDownload.length > 5 ? 5 : toDownload.length); i++) {
          debugPrint('[LauncherCubit] Will download: ${toDownload[i]
              .relativePath} size=${toDownload[i].size}');
        }
        for (var i = 0; i < (toDelete.length > 5 ? 5 : toDelete.length); i++) {
          debugPrint('[LauncherCubit] Will delete: ${toDelete[i]
              .relativePath} size=${toDelete[i].size}');
        }
      }

      // (Usuń blok usuwania przed pobraniami — operacje usuwania będą wykonane po pobraniu plików)

      // 5) Pobierz brakujące/zmienione pliki z FTP (drugie połączenie)
      if (toDownload.isNotEmpty) {
        // Oblicz całkowity rozmiar
        final totalBytes = toDownload.fold<int>(
            0, (sum, e) => sum + (e.size ?? 0));

        _emitStatus('downloading_files', progressFileName: '', showProgress: true, progress: 0.0, downloadedBytes: 0, totalBytes: totalBytes);

        final finishedPaths = <String>{};
        int currentDownloadedBytes = 0;

        // Throttle: emituj max raz na 120ms żeby nie blokować renderera wideo.
        DateTime _lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);
        String _lastFileName = '';
        double _lastProgressValue = 0.0;
        int _lastDownloadedBytes = 0;

        await filesService.downloadMultipleFromFtp(
          remoteBase: '/',
          entries: toDownload,
          localBase: gameRoot,
          onProgress: (completed, total, current, success, item) {
            if (item != null && !finishedPaths.contains(item.relativePath)) {
              finishedPaths.add(item.relativePath);
              currentDownloadedBytes += item.size ?? 0;
            }

            final name = current.split('/').isNotEmpty ? current.split('/').last : current;
            final progressValue = total > 0 ? completed / total : 0.0;

            // Zapisz aktualny stan
            _lastFileName = name;
            _lastProgressValue = progressValue;
            _lastDownloadedBytes = currentDownloadedBytes;

            // Throttle: emituj max raz na 250ms żeby nie blokować renderera wideo.
            final now = DateTime.now();
            if (now.difference(_lastProgressEmit).inMilliseconds >= 250 || completed == total) {
              _lastProgressEmit = now;
              if (kDebugMode) {
                debugPrint('[LauncherCubit] Progress: ${(_lastProgressValue * 100).toStringAsFixed(1)}% - $_lastFileName');
              }
              _emitStatus('downloading_progress', params: {
                'current': '$completed',
                'total': '$total',
                'percent': (progressValue * 100).toStringAsFixed(1),
              }, progressFileName: _lastFileName, progress: _lastProgressValue, downloadedBytes: _lastDownloadedBytes, totalBytes: totalBytes, showProgress: true);
            }
          },
          onPoolInfo: (active, allowed) {
            emit(state.copyWith(activeFtpConnections: active, allowedFtpPool: allowed));
          },
        );
        // reset UI pool info after downloads finish
        emit(state.copyWith(activeFtpConnections: 0, allowedFtpPool: 0));
      }

      // After downloads: recompute local list and delete/move files absent from remote manifest
      try {
        final refreshedLocal = await filesService.listLocalModFiles(gameRoot);
        final finalComparison = await filesService.compareRemoteAndLocal(
            remoteList, refreshedLocal, sizeTolerance: 2);
        final finalToDelete = List<LocalFileEntry>.from(finalComparison['toDelete'] ?? <LocalFileEntry>[]);

        if (finalToDelete.isNotEmpty) {
          final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
          final backupDir = Directory(
              '$gameRoot${Platform.pathSeparator}BepInEx_removed_backup_$ts');
          try {
            if (!await backupDir.exists()) await backupDir.create(
                recursive: true);
          } catch (_) {}

          int dIdx = 0;
          for (final f in finalToDelete) {
            dIdx++;
            final rel = f.relativePath;
            _emitStatus('deleting_items', params: {'current': '$dIdx', 'total': '${finalToDelete.length}'}, progressFileName: rel);
            // relativePath już zawiera pełną strukturę (np. 'BepInEx/plugins/x.dll' lub 'doorstop_config.ini')
            final file = File(
                '$gameRoot${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
            final targetPath = '${backupDir.path}${Platform.pathSeparator}${rel
                .replaceAll('/', Platform.pathSeparator)}';
            try {
              if (await file.exists()) {
                final targetFile = File(targetPath);
                try {
                  await targetFile.parent.create(recursive: true);
                  await file.rename(targetFile.path);
                } catch (moveErr) {
                  // fallback to copy+delete
                  try {
                    await file.copy(targetFile.path);
                    try {
                      await file.delete();
                    } catch (_) {}
                  } catch (copyErr) {
                    // last resort: attempt delete
                    try {
                      await file.delete();
                    } catch (_) {}
                  }
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}

      // Update local version in SharedPreferences after successful sync
      if (serverVersion != null) {
        await prefs.setString('local_mods_version', serverVersion);
        if (kDebugMode) debugPrint('[LauncherCubit] Local version updated to: $serverVersion');
      }

      // 8) Finalize
      _emitStatus('ready_to_launch', isBusy: false, readyToLaunch: true, progressFileName: '', showProgress: false, progress: 0.0, downloadedBytes: 0, totalBytes: 0, activeFtpConnections: 0);
    } catch (e) {
      _emitStatus('sync_error', params: {'error': '$e'}, isBusy: false, readyToLaunch: false, progressFileName: '');
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> fetchModsList(
      {String remotePath = '/BepInEx/mods_list.json', bool force = false}) async {
    // Allow forcing fetch even if cubit reports busy
    if (state.isBusy && !force) return;
    _emitStatus('connecting_ftp', isBusy: true, readyToLaunch: false, progressFileName: '');
    try {
      await filesService.downloadModsListFromFtp(remotePath);
      _emitStatus('ready_to_launch', isBusy: false, readyToLaunch: true, progressFileName: '');
    } catch (e) {
      _emitStatus('download_mods_error', params: {'error': '$e'}, isBusy: false, readyToLaunch: false, progressFileName: '');
    }
  }

  Future<void> _appendLaunchLog(String msg) async {
    try {
      final tmp = Directory.systemTemp;
      final f = File(
          '${tmp.path}${Platform.pathSeparator}schron_launcher_launch.log');
      final line = '${DateTime.now().toIso8601String()} - $msg\n';
      await f.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<bool> _isProcessRunningByImageName(String imageName) async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run(
            'tasklist', ['/FI', 'IMAGENAME eq $imageName']);
        final out = (res.stdout ?? '').toString().toLowerCase();
        return out.contains(imageName.toLowerCase());
      } else {
        // On non-Windows try pgrep. Case-insensitive because the bundle is
        // `valheim.app` while the process inside it is `Valheim`.
        final res = await Process.run('pgrep', ['-fi', imageName]);
        return (res.stdout ?? '')
            .toString()
            .trim()
            .isNotEmpty;
      }
    } catch (_) {
      return false;
    }
  }

  void _startPollingForProcessExit(String imageName) {
    _processWatchTimer?.cancel();
    _processWatchTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      final running = await _isProcessRunningByImageName(imageName);
      if (!running) {
        t.cancel();
        _processWatchTimer = null;
        emit(state.copyWith(gameRunning: false, readyToLaunch: true));
        await _appendLaunchLog(
            'Detected process exit by polling for $imageName');
      }
    });
  }

  /// Builds a steam://run URL encoding given args so Steam client can launch the game with args.
  String _buildSteamRunUrl(List<String> args) {
    // Valheim AppID is 892970
    final encoded = args.map((a) => Uri.encodeComponent(a)).join('%20');
    return 'steam://run/892970//$encoded';
  }

  /// Kopiuje hasło do serwera do schowka i ustawia flagę do pokazania toasta
  Future<void> _copyPasswordAndShowToast() async {
    if (state.launcherConfig == null ||
        state.launcherConfig!.serverPassword.isEmpty) {
      return;
    }

    try {
      // Kopiuj hasło do schowka
      await Clipboard.setData(
        ClipboardData(text: state.launcherConfig!.serverPassword),
      );

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Password copied to clipboard');
      }

      // Emituj stan z flagą showPasswordCopiedToast = true
      emit(state.copyWith(showPasswordCopiedToast: true));

      // Po krótkiej chwili zresetuj flagę
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!isClosed) {
          emit(state.copyWith(showPasswordCopiedToast: false));
        }
      });

      await _appendLaunchLog('Password copied to clipboard');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherCubit] Failed to copy password: $e');
      }
      await _appendLaunchLog('Failed to copy password to clipboard: $e');
    }
  }

  /// Na macOS „grą" jest katalog `valheim.app`, którego nie da się uruchomić
  /// wprost — wykonywalny plik siedzi w środku. Na Linuksie i Windowsie ścieżka
  /// jest już plikiem.
  String _unixGameBinary(String exe) {
    if (Platform.isMacOS && exe.endsWith('.app')) {
      final sep = Platform.pathSeparator;
      final name = exe.split(sep).last.replaceAll('.app', '');
      return '$exe${sep}Contents${sep}MacOS$sep$name';
    }
    return exe;
  }

  Future<void> launchGame() async {
    final exe = state.valheimExePath;
    if (exe == null || exe.isEmpty) {
      _emitStatus('game_executable_missing', params: {'exe': exe ?? ''}, progressFileName: '');
      await _appendLaunchLog('Launch aborted: exe path null/empty');
      return;
    }

    // Build launch arguments for auto-connect if enabled
    List<String> launchArgs = [];
    if (state.autoConnectEnabled && state.launcherConfig != null) {
      final config = state.launcherConfig!;

      // Validate server configuration
      if (!_configService.isValidAddress(config.serverAddress)) {
        _emitStatus('invalid_server_config', progressFileName: '');
        await _appendLaunchLog('Launch aborted: invalid server address: ${config.serverAddress}');
        return;
      }

      if (!_configService.isValidPort(config.serverPort)) {
        _emitStatus('invalid_server_config', progressFileName: '');
        await _appendLaunchLog('Launch aborted: invalid server port: ${config.serverPort}');
        return;
      }

      // Build Valheim command line arguments (Steam/Valheim use + prefix for these args)
      launchArgs = [
        '+connect',
        '${config.serverAddress}:${config.serverPort}',
        '+password',
        config.serverPassword,
      ];

      if (kDebugMode) {
        debugPrint('[LauncherCubit] Launching with auto-connect to ${config.serverAddress}:${config.serverPort}');
        // Mask password in debug output to avoid leaking secrets
        final maskedArgs = launchArgs.map((a) => a == config.serverPassword ? '***' : a).toList();
        debugPrint('[LauncherCubit] Using args: $maskedArgs');
      }
      await _appendLaunchLog('Auto-connecting to ${config.serverName} (${config.serverAddress}:${config.serverPort})');
      await _appendLaunchLog('Server password: ***');
    }

    try {
      final file = File(exe);
      final workDir = file.parent.path;

      // Verify the game is there before attempting to start. On macOS the "exe"
      // is `valheim.app`, a directory, so a file-only check would refuse to launch.
      if (!await file.exists() && !await Directory(exe).exists()) {
        _emitStatus('game_executable_missing', params: {'exe': exe}, progressFileName: '');
        if (kDebugMode) debugPrint(
            '[LauncherCubit] launchGame: exe not found at $exe');
        await _appendLaunchLog('Launch failed: exe not found at $exe');
        return;
      }

      _emitStatus('launching_game', progressFileName: '');
      try {
        // First try: start detached (this matched original working behaviour).
        // Before starting the game: if sibling custom_mods exists, copy into BepInEx.
        try {
          final gameRoot = workDir; // where valheim.exe resides
          await _customModsService.copyCustomModsToBepInEx(gameRoot);
          // Silent operation - no GUI feedback
        } catch (cmErr) {
          // Continue launching even if copy fails - silent
        }

        try {
          // Na macOS i Linuksie mody ładuje `run_bepinex.sh` — bierze grę jako
          // pierwszy argument, resztę przekazuje dalej, i sam ogarnia Apple
          // Silicon. Bez modów odpalamy grę wprost, żeby nie było skryptu
          // szukającego BepInEx-a, którego nie ma.
          final launcherScript = File('$workDir${Platform.pathSeparator}run_bepinex.sh');
          final useScript = !Platform.isWindows && await launcherScript.exists();
          final startExe = useScript ? launcherScript.path : _unixGameBinary(exe);
          final startArgs = useScript
              ? [exe.split(Platform.pathSeparator).last, ...launchArgs]
              : launchArgs;
          final detachedProc = await Process.start(
              startExe, startArgs, workingDirectory: workDir,
              mode: ProcessStartMode.detached,
              runInShell: false);
          await _appendLaunchLog(
              'Started detached process pid=${detachedProc.pid}');
          // We can't reliably monitor exitCode for detached across platforms, so poll by image name.
          final imageName = exe
              .split(Platform.pathSeparator)
              .last;
          emit(state.copyWith(statusMessage: I18n.instance.t('game_started'), statusKey: 'game_started', statusParams: const {}, progressFileName: '', gameRunning: true, readyToLaunch: false));

          // Kopiuj hasło do schowka i pokaż toast, jeśli hasło jest podane
          await _copyPasswordAndShowToast();

          _startPollingForProcessExit(imageName);
          
          // Auto-zamknij launcher po 5 sekundach
          _scheduleAutoExit();
          return;
        } catch (detErr) {
          // Detached start failed -> fallback to monitored start (non-detached) so we can observe exitCode.
          await _appendLaunchLog(
              'Detached start failed: $detErr; falling back to monitored start');
          if (kDebugMode) debugPrint(
              '[LauncherCubit] Detached start failed: $detErr; trying monitored start');
          try {
            _runningProcess = await Process.start(
                exe, launchArgs, workingDirectory: workDir, runInShell: false);
            emit(state.copyWith(statusMessage: I18n.instance.t('game_started'), statusKey: 'game_started', statusParams: const {}, progressFileName: '', gameRunning: true, readyToLaunch: false));
            await _appendLaunchLog(
                'Started process (monitoring) pid=${_runningProcess?.pid}');

            // Kopiuj hasło do schowka i pokaż toast, jeśli hasło jest podane
            await _copyPasswordAndShowToast();

            _runningProcess?.exitCode.then((code) async {
              await _appendLaunchLog('Process exited with code $code');
              _runningProcess = null;
              emit(state.copyWith(gameRunning: false, readyToLaunch: true));
            });
            
            // Auto-zamknij launcher po 5 sekundach
            _scheduleAutoExit();
            return;
          } catch (pErr) {
            await _appendLaunchLog('Monitored Process.start failed: $pErr');
            rethrow;
          }
        }
      } catch (e) {
        // Fallback: on Windows try 'cmd /c start "" /D "workDir" "path"'
        if (kDebugMode) debugPrint(
            '[LauncherCubit] launchGame: detached start failed: $e; trying cmd start fallback');
        await _appendLaunchLog(
            'detached start failed: $e; trying cmd fallback');
        try {
          if (Platform.isWindows) {
            // Use /D to set working directory and pass exe with args
            final quotedExe = '"' + exe + '"';
            final quotedWorkDir = '"' + workDir + '"';
            // Ensure args containing spaces are quoted for cmd start
            final cmdSafeArgs = launchArgs.map((a) => a.contains(' ') ? '"' + a + '"' : a).toList();
            // Build cmd args: /c start "" /D "workDir" "exe" arg1 arg2 ...
            final cmdArgs = ['/c', 'start', '', '/D', quotedWorkDir, quotedExe, ...cmdSafeArgs];
            if (kDebugMode) debugPrint(
                '[LauncherCubit] launchGame: cmd fallback args: $cmdArgs');
            await _appendLaunchLog(
                'cmd fallback args: $cmdArgs');
            await Process.start('cmd', cmdArgs);
            emit(state.copyWith(statusMessage: I18n.instance.t('game_started'), statusKey: 'game_started', statusParams: const {}, progressFileName: '', gameRunning: true, readyToLaunch: false));
            await _appendLaunchLog(
                'Started via cmd fallback (no monitor available)');

            // Kopiuj hasło do schowka i pokaż toast, jeśli hasło jest podane
            await _copyPasswordAndShowToast();

            final imageName = exe
                .split(Platform.pathSeparator)
                .last;
            _startPollingForProcessExit(imageName);
            
            // Auto-zamknij launcher po 5 sekundach
            _scheduleAutoExit();
            return;
           }
        } catch (e2) {
          if (kDebugMode) debugPrint(
              '[LauncherCubit] launchGame: fallback failed: $e2');
          await _appendLaunchLog('cmd fallback failed: $e2');

          // As an additional fallback, try launching via Steam protocol which sometimes forwards args correctly
          try {
            if (state.autoConnectEnabled && state.launcherConfig != null && Platform.isWindows) {
              final steamUrl = _buildSteamRunUrl(launchArgs);
              await _appendLaunchLog('Attempting Steam protocol fallback: $steamUrl');
              // Use explorer.exe to open the steam:// URL
              await Process.start('explorer.exe', [steamUrl]);
              emit(state.copyWith(statusMessage: I18n.instance.t('game_started'), statusKey: 'game_started', statusParams: const {}, progressFileName: '', gameRunning: true, readyToLaunch: false));
              await _appendLaunchLog('Started via Steam protocol fallback');
              // Copy password to clipboard as before
              await _copyPasswordAndShowToast();
              return;
            }
          } catch (steamErr) {
            await _appendLaunchLog('Steam fallback failed: $steamErr');
          }

           // Additional diagnostic attempt: run without detached to capture output
           try {
             await _appendLaunchLog(
                 'Attempting diagnostic run (Process.run) to capture stdout/stderr');
             final result = await Process.run(
                 exe, [], workingDirectory: workDir);
             await _appendLaunchLog(
                 'Diagnostic run exitCode=${result.exitCode} stdout=${result
                     .stdout} stderr=${result.stderr}');
             if (result.exitCode == 0) {
               emit(state.copyWith(statusMessage: I18n.instance.t('game_started'), statusKey: 'game_started', statusParams: const {}, progressFileName: ''));
               await _appendLaunchLog('Diagnostic run succeeded');
               return;
             } else {
               emit(state.copyWith(
                   statusMessage: I18n.instance.t('failed_to_launch', {'error': '$e'}),
                   progressFileName: ''));
             }
           } catch (diagEx) {
             await _appendLaunchLog('Diagnostic run failed: $diagEx');
             if (kDebugMode) debugPrint(
                 '[LauncherCubit] Diagnostic run failed: $diagEx');
           }
           rethrow;
         }
         rethrow;
       }
     } catch (e) {
       _emitStatus('failed_to_launch', params: {'error': '$e'}, progressFileName: '');
       await _appendLaunchLog('Launch error: $e');
     }
   }

  Future<void> runUpdaterThenLocate() async {
    // If already busy, don't start a second updater
    if (state.isBusy) return;

    _emitStatus('checking_updates', isBusy: true, showProgress: true, progress: 0.0, progressFileName: 'updater.zip', locateCompleted: false);
    try {
      // Krok 1: Sprawdź i zaktualizuj updater
      final updated = await filesService.checkAndRunUpdater(onProgress: (p, s) {
        emit(state.copyWith(statusMessage: s, statusKey: state.statusKey, statusParams: state.statusParams, isBusy: true, showProgress: true, progress: p, progressFileName: 'updater'));
      });

      if (kDebugMode) debugPrint(
          '[LauncherCubit] checkAndRunUpdater zakończone: updated=$updated');

      // Krok 2: Po aktualizacji updatera sprawdź wersję launchera
      _emitStatus('checking_updates', isBusy: true, showProgress: true, progress: 0.0, progressFileName: 'launcher');

      // Pobierz aktualną wersję z version.txt (wstrzykniętego przez generator)
      // Fallback do PackageInfo gdy version.txt nie istnieje (legacy/debug mode)
      String currentVersion = '0.0.0+0'; // domyślna wartość
      try {
        final resolved = Platform.resolvedExecutable;
        final exeDir = File(resolved).parent.path;
        final versionFile = File('$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}version.txt');
        if (await versionFile.exists()) {
          currentVersion = (await versionFile.readAsString()).trim();
          if (kDebugMode) debugPrint('[LauncherCubit] Wersja z version.txt: $currentVersion');
        } else {
          // Fallback: PackageInfo (baked into binary)
          final packageInfo = await PackageInfo.fromPlatform();
          currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
          if (kDebugMode) debugPrint('[LauncherCubit] Wersja z PackageInfo (fallback): $currentVersion');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[LauncherCubit] Błąd odczytu wersji: $e');
      }

      final shouldExit = await filesService.checkAndRunLauncherUpdate(
        onProgress: (p, s) {
          emit(state.copyWith(statusMessage: s, statusKey: state.statusKey, statusParams: state.statusParams, isBusy: true, showProgress: true, progress: p, progressFileName: 'launcher'));
        },
        currentVersion: currentVersion,
      );

      if (kDebugMode) debugPrint(
          '[LauncherCubit] checkAndRunLauncherUpdate zakończone: shouldExit=$shouldExit');

      // Jeśli updater launchera został uruchomiony, zamknij aplikację
      if (shouldExit) {
        _emitStatus('closing_app', isBusy: false, showProgress: false);
        // Daj chwilę na wyświetlenie komunikatu
        await Future.delayed(const Duration(milliseconds: 500));
        // Zamknij aplikację
        exit(0);
      }

      // Krok 3: Szukaj Valheim
      _emitStatus(updated ? 'updater_installed_checking' : 'checking_game', isBusy: true, showProgress: false, progress: 0.0, progressFileName: '');

      final path = await filesService.findValheimExecutable();
      if (path == null) {
        _emitStatus('valheim_not_found', isBusy: false, readyToLaunch: false, progressFileName: '', locateCompleted: true);
        return;
      }

      // Znaleziono Valheim - zapisz ścieżkę
      _emitStatus('valheim_found', isBusy: true, valheimExePath: path, readyToLaunch: false, progressFileName: '', locateCompleted: true);

      // Doorstop wypakowuje się w syncAndPrepare — dopiero tam wiadomo, czy serwer
      // w ogóle wysyła mody. Serwer bez modów dla graczy oznacza czystą grę, a
      // zostawiony loader bez BepInEx to tylko ładowarka w próżnię.

      // Krok 5: Automatycznie rozpocznij synchronizację modów
      if (kDebugMode) debugPrint('[LauncherCubit] Starting automatic mod sync...');
      await syncAndPrepare(force: true);

    } catch (e) {
      _emitStatus('update_error_checking', params: {'error': '$e'}, isBusy: false, showProgress: false, locateCompleted: true);
    }
  }

  /// Appends the list of files that will be downloaded to a persistent log file.
  /// File location: system temp directory / to_download_log
  Future<void> _appendToDownloadLog(List<RemoteFileEntry> entries, String remoteManifest, {Map<String, String>? downloadReasons}) async {
    try {
      // Prefer writing next to our launcher exe (easy access). If that fails (e.g. permission),
      // then fallback to game root (valheim.exe), then temp. Also record where we actually wrote the file.
      final filename = 'download_decisions.log';
      String? writtenPath;

      // 1) Try launcher exe folder first
      try {
        final resolved = Platform.resolvedExecutable;
        final exeDir = File(resolved).parent.path;
        final tryFile = File('$exeDir${Platform.pathSeparator}$filename');
        try {
          await tryFile.parent.create(recursive: true);
          await tryFile.writeAsString('', mode: FileMode.append); // touch file
          writtenPath = tryFile.path;
        } catch (e) {
          // permission or IO error -> fallthrough
          writtenPath = null;
        }
      } catch (_) {
        writtenPath = null;
      }

      // 2) If not written, try game root (valheim.exe parent)
      if (writtenPath == null) {
        try {
          final exe = await filesService.findValheimExecutable();
          if (exe != null && exe.isNotEmpty) {
            final gameDir = File(exe).parent.path;
            final tryFile = File('$gameDir${Platform.pathSeparator}$filename');
            try {
              await tryFile.parent.create(recursive: true);
              await tryFile.writeAsString('', mode: FileMode.append);
              writtenPath = tryFile.path;
            } catch (_) {
              writtenPath = null;
            }
          }
        } catch (_) {
          writtenPath = null;
        }
      }

      // 3) Last resort: system temp
      final baseDir = writtenPath == null ? Directory.systemTemp.path : File(writtenPath).parent.path;
      final f = File('$baseDir${Platform.pathSeparator}$filename');

      final sepHeader = '===== SESSION ${DateTime.now().toIso8601String()} MANIFEST=$remoteManifest =====';
      final sepFooter = '===== END SESSION (${entries.length} files to download) =====';

      final sb = StringBuffer();
      sb.writeln(sepHeader);
      sb.writeln('Total files to download: ${entries.length}');
      sb.writeln('');
      
      for (final e in entries) {
        final reason = downloadReasons?[e.relativePath] ?? 'UNKNOWN';
        sb.writeln('FILE: ${e.relativePath}');
        sb.writeln('  REASON: $reason');
        sb.writeln('  REMOTE: size=${e.size ?? '<unknown>'} modified=${e.modified?.toIso8601String() ?? '<unknown>'}');
        sb.writeln('');
      }
      
      sb.writeln(sepFooter);
      sb.writeln('');
      sb.writeln('');

      // Ensure directory exists (most likely it does) — parent creation is no-op if already exists
      try { await f.parent.create(recursive: true); } catch (_) {}
      await f.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
      
      if (kDebugMode) debugPrint('[LauncherCubit] Download decisions logged to: ${f.path}');
    } catch (_) {
      // ignore logging failures
    }
  }
}

// ─── LOGGING ISOLATE ────────────────────────────────────────────────────────

class _LogDownloadParams {
  final List<RemoteFileEntry> entries;
  final String remoteManifest;
  final Map<String, String>? downloadReasons;
  final String? valheimExePath;
  _LogDownloadParams(this.entries, this.remoteManifest, this.downloadReasons, this.valheimExePath);
}

Future<void> _logDownloadTask(_LogDownloadParams params) async {
  final entries = params.entries;
  if (entries.isEmpty) return;
  
  try {
    const filename = 'download_decisions.log';
    String? writtenPath;

    // 1) Try launcher exe folder
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir${Platform.pathSeparator}$filename');
      await f.parent.create(recursive: true);
      writtenPath = f.path;
    } catch (_) {}

    // 2) Try game root
    if (writtenPath == null && params.valheimExePath != null) {
      try {
        final gameDir = File(params.valheimExePath!).parent.path;
        final f = File('$gameDir${Platform.pathSeparator}$filename');
        await f.parent.create(recursive: true);
        writtenPath = f.path;
      } catch (_) {}
    }

    // 3) Temp
    final baseDir = writtenPath == null ? Directory.systemTemp.path : File(writtenPath).parent.path;
    final f = File('$baseDir${Platform.pathSeparator}$filename');

    final sb = StringBuffer();
    sb.writeln('===== SESSION ${DateTime.now().toIso8601String()} MANIFEST=${params.remoteManifest} =====');
    sb.writeln('Total files to download: ${entries.length}');
    sb.writeln('');
    
    for (final e in entries) {
      final reason = params.downloadReasons?[e.relativePath] ?? 'UNKNOWN';
      sb.writeln('FILE: ${e.relativePath}');
      sb.writeln('  REASON: $reason');
      sb.writeln('  REMOTE: size=${e.size ?? '<unknown>'} modified=${e.modified?.toIso8601String() ?? '<unknown>'}');
      sb.writeln('');
    }
    
    sb.writeln('===== END SESSION (${entries.length} files) =====\n\n');
    
    await f.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
  } catch (_) {}
}
