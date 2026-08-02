import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:ftpconnect/ftpconnect.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:archive/archive.dart';
import 'crypto_config.dart';
import 'github_engine.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // initialize window_manager
  await windowManager.ensureInitialized();

  // configure window options: remove native frame (frameless), center, and show
  WindowOptions windowOptions = const WindowOptions(
    center: true,
    skipTaskbar: false,
    title: 'Updater',
    // make frameless - remove default controls
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // set size to half of current window size (reduce window by half)
    Size initialSize = const Size(400, 300);
    try {
      final currentSize = await windowManager.getSize();
      initialSize = Size(currentSize.width / 2, currentSize.height / 2);
    } catch (_) {
      // fallback
      initialSize = const Size(400, 300);
    }
    await windowManager.setSize(initialSize);
    await windowManager.setMinimumSize(initialSize);
    await windowManager.setMaximumSize(initialSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Updater',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0A06),
        fontFamily: 'Norse',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4A017),
          secondary: Color(0xFF8B6914),
          surface: Color(0xFF1A1410),
          onPrimary: Colors.black,
          onSurface: Colors.white70,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Color(0xFFD4A017),
          linearTrackColor: Color(0xFF2A2010),
        ),
      ),
      home: const UpdaterPage(),
    );
  }
}

class UpdaterPage extends StatefulWidget {
  const UpdaterPage({super.key});

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage> {
  String _message = 'Przygotowywanie...';
  double _progress = 0.0;
  bool _working = false;
  bool _extractionSuccess = false;
  String? _ftpHost;
  int _ftpPort = 21;
  String? _ftpUser;
  String? _ftpPass;
  DecryptedConfig? _cfg;
  String _serverName = 'Updater';
  String _launcherExeName = 'server_launcher.exe';

  // paths
  late final Directory appDir;
  late final File localZipFile;
  late final Directory parentDir; // Dodajemy zmienną dla katalogu nadrzędnego

  @override
  void initState() {
    super.initState();
    appDir = Directory.current;
    parentDir = appDir.parent; // Ustawiamy katalog nadrzędny
    localZipFile = File(p.join(appDir.path, 'launcher.zip'));
    _startProcess();
  }

  Future<void> _startProcess() async {
    setState(() {
      _working = true;
      _message = 'wczytywanie konfiguracji ftp...';
      _progress = 0.05;
    });

    try {
      await _loadFtpConfig();

      // remove local zip if exists
      if (await localZipFile.exists()) {
        setState(() => _message = 'usuwanie starego launcher.zip...');
        await localZipFile.delete();
        setState(() => _progress = 0.1);
      }

      // download via FTP
      setState(() => _message = 'laczenie z serwerem ftp...');
      await _downloadLauncher();

      setState(() {
        _message = 'wypakowywanie...';
        _progress = 0.6;
      });

      // Paczka z GitHuba jest neutralna (placeholder w panel_config.json) —
      // config wstrzyknięty przez panel serwera musi przeżyć aktualizację.
      String? savedConfig;
      try {
        final cfgFile = launcherConfigFile();
        if (await cfgFile.exists()) {
          final raw = await cfgFile.readAsString();
          if (raw.contains('"panelUrl"') && !raw.contains('"panelUrl": ""') &&
              !raw.contains('"panelUrl":""')) {
            savedConfig = raw;
          }
        }
      } catch (_) {}

      // extract and overwrite
      await _extractZipOverwrite(localZipFile, parentDir); // Zmieniamy appDir na parentDir

      if (savedConfig != null) {
        try {
          await launcherConfigFile().writeAsString(savedConfig);
        } catch (_) {}
      }
      await _renameToServerName();

      setState(() {
        _message = 'uruchamianie...';
        _progress = 0.95;
      });

      // launch process
      await _launchLauncherExe();

      setState(() {
        _message = 'gotowe. zamykam...';
        _progress = 1.0;
        _extractionSuccess = true;
      });

      // give user a moment and close app (dispose will clean zip)
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        // close window
        exit(0);
      }
    } catch (e) {
      // normalize error messages to short ASCII phrases
      String short;
      final s = e?.toString() ?? '';
      if (s.contains('550') || s.toLowerCase().contains('not found') || s.toLowerCase().contains('no such file')) {
        short = 'brak plikow na serwerze';
      } else if (s.toLowerCase().contains('download') || s.toLowerCase().contains('wcet')) {
        short = 'nie udalo sie pobrac';
      } else if (s.toLowerCase().contains('extract') || s.toLowerCase().contains('expand-archive') || s.toLowerCase().contains('wypakowywania')) {
        short = 'nie udalo sie wypakowac';
      } else if (s.toLowerCase().contains('schron_twarda_launcher.exe') || s.toLowerCase().contains('nie znaleziono')) {
        short = 'nie znaleziono launcher.exe';
      } else if (s.toLowerCase().contains('brak konfiguracji')) {
        short = 'brak konfiguracji ftp';
      } else {
        short = 'nie udalo sie';
      }
      setState(() {
        _message = short;
        _working = false;
      });
    }
  }

  String? _launcherRemote;

  Future<void> _loadFtpConfig() async {
    final cfg = await loadDecryptedConfig();
    if (cfg == null) {
      throw 'brak konfiguracji ftp'; // No encrypted config found or failed to load/decrypt
    }

    _cfg = cfg;
    _ftpHost = cfg.ftpHost;
    _ftpPort = cfg.ftpPort;
    _ftpUser = cfg.ftpUser;
    _ftpPass = cfg.ftpPassword;
    _serverName = cfg.serverName.isNotEmpty ? cfg.serverName : 'Updater';
    _launcherExeName = '${_serverName} Launcher.exe';
    _launcherRemote = null; // use default path
  }

  Future<void> _downloadLauncher() async {
    // Tryb panelu: launcher.zip przychodzi z wydania na GitHubie silnika,
    // nie z FTP admina — jedno wydanie trafia do wszystkich serwerów naraz.
    final cfg = _cfg;
    if (cfg != null && cfg.usesPanel) {
      setState(() => _message = 'pobieranie launchera (github)...');
      final engine = cfg.engineRepo.trim().isEmpty
          ? GithubEngine()
          : GithubEngine(repo: cfg.engineRepo.trim());
      final tmpFile = File(localZipFile.path + '.downloading');
      try {
        final release = await engine.latest(asset: 'launcher');
        if (release == null) throw 'brak plikow na serwerze';
        if (await tmpFile.exists()) await tmpFile.delete();
        final ok = await engine.download(release, tmpFile.path,
            onProgress: (got, total) {
          if (total > 0) setState(() => _progress = 0.1 + 0.3 * got / total);
        });
        if (!ok) throw 'nie udalo sie pobrac';
        await tmpFile.rename(localZipFile.path);
        setState(() => _progress = 0.4);
        return;
      } catch (e) {
        if (await tmpFile.exists()) try { await tmpFile.delete(); } catch (_) {}
        rethrow;
      } finally {
        engine.close();
      }
    }

    if (_ftpHost == null || _ftpUser == null || _ftpPass == null) {
      throw 'brak konfiguracji ftp';
    }

    final remotePath = _launcherRemote ?? '/launcher_files/launcher.zip';

    // Use PowerShell to download via FTP with credentials
    final useSftp = (_ftpPort == 2022 || _ftpPort == 22);
    final protocol = useSftp ? 'sftp' : 'ftp';
    final hostPart = '$_ftpHost:$_ftpPort';
    final path = (remotePath.isNotEmpty && !remotePath.startsWith('/')) ? '/$remotePath' : remotePath;
    final ftpUrl = '$protocol://$hostPart$path';

    setState(() => _message = 'Pobieranie launcher.zip (via $protocol)...');

    final tmpPath = localZipFile.path + '.downloading';
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) await tmpFile.delete();

    try {
      if (useSftp) {
        // --- SFTP via dartssh2 ---
        final socket = await SSHSocket.connect(_ftpHost!, _ftpPort, timeout: const Duration(seconds: 15));
        final client = SSHClient(socket, username: _ftpUser!, onPasswordRequest: () => _ftpPass!);
        await client.authenticated;
        final sftp = await client.sftp();
        final remoteFile = await sftp.open(path);
        // Stream with 32768 chunk (server max) to prevent premature EOF
        final builder = BytesBuilder(copy: false);
        await for (final chunk in remoteFile.read(chunkSize: 32768)) {
          builder.add(chunk);
        }
        await remoteFile.close();
        await tmpFile.writeAsBytes(builder.takeBytes(), flush: true);
        client.close();
      } else {
        // --- FTP via ftpconnect ---
        final ftp = FTPConnect(_ftpHost!, user: _ftpUser!, pass: _ftpPass!, port: _ftpPort);
        await ftp.connect();
        await ftp.setTransferType(TransferType.binary);
        ftp.transferMode = TransferMode.passive;
        final success = await ftp.downloadFile(path, tmpFile);
        await ftp.disconnect();
        if (!success) throw 'Błąd transferu FTP';
      }
    } catch (e) {
      if (await tmpFile.exists()) try { await tmpFile.delete(); } catch (_) {}
      final errMsg = e.toString().toLowerCase();
      if (errMsg.contains('550') || errMsg.contains('not found')) {
        throw 'brak plikow na serwerze';
      }
      throw 'nie udalo sie pobrac (${e.runtimeType})';
    }

    // rename tmp to final
    await tmpFile.rename(localZipFile.path);
    setState(() => _progress = 0.4);
  }

  Future<void> _extractZipOverwrite(File zipFile, Directory targetDir) async {
    if (!await zipFile.exists()) throw 'Pobrany plik launcher.zip nie istnieje';

    setState(() => _message = 'wypakowywanie...');

    // Use PowerShell Expand-Archive with -Force to overwrite
    final zipPath = zipFile.path;
    final dest = targetDir.path;

    final ps = [
      '-NoProfile',
      '-Command',
      'Expand-Archive -LiteralPath "${zipPath}" -DestinationPath "${dest}" -Force'
    ];

    final proc = await Process.start('powershell', ps);
    // capture output while showing indeterminate progress
    final stdoutFuture = proc.stdout.transform(const Utf8Decoder()).join();
    final stderrFuture = proc.stderr.transform(const Utf8Decoder()).join();

    // simple progress animation while extracting
    final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      setState(() => _progress = (_progress + 0.02) % 0.95);
    });

    final exitCode = await proc.exitCode;
    await stdoutFuture;
    await stderrFuture;
    timer.cancel();

    if (exitCode != 0) {
      throw 'nie udalo sie wypakowac';
    }

    setState(() => _progress = 0.9);
  }

  /// The engine on GitHub ships as `server_launcher.exe`, but the panel hands the
  /// player a build named after the server. Without this the update would drop the
  /// neutral name next to the old one and we would start yesterday's binary.
  Future<void> _renameToServerName() async {
    try {
      final wanted = _launcherExeName;
      if (wanted.isEmpty || wanted == 'server_launcher.exe') return;
      final fresh = File(p.join(parentDir.path, 'server_launcher.exe'));
      if (!await fresh.exists()) return;
      final target = File(p.join(parentDir.path, wanted));
      if (await target.exists()) await target.delete();
      await fresh.rename(target.path);
    } catch (_) {}
  }

  Future<void> _launchLauncherExe() async {
    final exeName = _launcherExeName;
    final exePath = p.join(parentDir.path, exeName);
    final exeFile = File(exePath);
    if (!await exeFile.exists()) {
      // Try to find recursively (any *Launcher.exe)
      final found = await _findFileRecursive(parentDir, exeName);
      if (found != null) {
        await Process.start(found.path, [], mode: ProcessStartMode.detached);
        return;
      }
      // Last resort — look for any *launcher*.exe
      final any = await _findLauncherExe(parentDir);
      if (any != null) {
        await Process.start(any.path, [], mode: ProcessStartMode.detached);
        return;
      }
      throw 'nie znaleziono launcher.exe';
    }
    await Process.start(exePath, [], mode: ProcessStartMode.detached);
  }

  Future<File?> _findLauncherExe(Directory dir) async {
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path).toLowerCase();
          if (name.endsWith('.exe') && name.contains('launcher')) return entity;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<File?> _findFileRecursive(Directory dir, String name) async {
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && p.basename(entity.path).toLowerCase() == name.toLowerCase()) return entity;
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    // after launching and successful extraction, remove downloaded zip
    if (_extractionSuccess) {
      localZipFile.exists().then((exists) async {
        if (exists) {
          try {
            await localZipFile.delete();
          } catch (_) {}
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: Column(
        children: [
          // custom frameless title bar using window_manager for dragging
          GestureDetector(
            onPanStart: (details) async {
              // start native dragging
              try {
                await windowManager.startDragging();
              } catch (_) {}
            },
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              color: const Color(0xFF1E1E1E),
              child: Row(children: [
                Image.asset('assets/images/logo.png', height: 28),
                const SizedBox(width: 10),
                Expanded(child: Text('$_serverName Updater', style: const TextStyle(color: Colors.white, fontSize: 16))),
                InkWell(
                  onTap: () => _showAboutDialog(context),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: Icon(Icons.info_outline, color: Colors.white70, size: 20),
                  ),
                ),
                InkWell(
                  onTap: () => exit(0),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ]),
            ),
          ),

          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    // logo zostało przeniesione tylko na pasek tytułu
                    const SizedBox(height: 8),
                    // komunikat z możliwością przewijania jeśli jest za długi
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Scrollbar(
                          key: ValueKey(_message),
                          thumbVisibility: false,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                            child: Text(
                              _message,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 300,
                      child: LinearProgressIndicator(
                        value: _progress <= 0 ? null : _progress,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _working
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent),
                          )
                        : ElevatedButton(
                            onPressed: _startProcess,
                            child: const Text('Uruchom ponownie'),
                          )
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF444444), width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blueAccent),
            SizedBox(width: 12),
            Text('Informacja / Information',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontFamily: 'Norse')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Valheim® jest zarejestrowanym znakiem towarowym Iron Gate AB. '
              'Niniejsza aplikacja jest niezależnym narzędziem i używa nazwy '
              'Valheim wyłącznie w celu identyfikacji.\n\n'
              'Valheim® is a registered trademark of Iron Gate AB. '
              'This application is an independent, unofficial tool used '
              'solely for identification purposes.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            Divider(height: 24, color: Colors.white12),
            Text(
              'Launcher created with Valheim Launcher Generator\n'
              'https://github.com/PawelSzymanski89/valheim_launcher_generator',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, fontFamily: 'Norse'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK',
                style:
                    TextStyle(color: Colors.blueAccent, fontFamily: 'Norse')),
          ),
        ],
      ),
    );
  }
}
