import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:dartssh2/dartssh2.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'generator/config_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'utils/crypto_service.dart';
import 'utils/shared_salt.dart';
import 'utils/profile_service.dart';
import 'package:archive/archive_io.dart';

/// Result of a single module build.
class ModuleBuildResult {
  final String moduleName;
  final bool success;
  final String? exePath;
  final String? error;
  const ModuleBuildResult({
    required this.moduleName,
    required this.success,
    this.exePath,
    this.error,
  });
}

/// Orchestrates the full build pipeline:
///   1. Writes config_encrypted.json into each module's assets/
///   2. Runs `flutter build windows` for each module
///   3. Copies output exe to output/{serverName}/
///   4. Saves profile to profiles/{serverName}.json
class BuildService {
  final GeneratorConfig config;
  final void Function(String message) onLog;
  final void Function(double progress) onProgress;

  void _logOutput(String line) {
    onLog('  $line');
  }

  /// Inkrementuje wersję w pubspec.yaml o 0.0.1 oraz numer builda o 1.
  Future<void> _incrementVersion(String modulePath) async {
    final pubspecFile = File(p.join(modulePath, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) return;

    try {
      final content = await pubspecFile.readAsString();
      final lines = content.split('\n');
      final newLines = <String>[];
      bool updated = false;

      for (var line in lines) {
        if (line.trim().startsWith('version:') && !updated) {
          final parts = line.split(':');
          if (parts.length == 2) {
            var versionStr = parts[1].trim();
            // Obsługa formatu X.Y.Z+B
            final versionParts = versionStr.split('+');
            var semVer = versionParts[0];
            var buildNum = versionParts.length > 1 ? int.tryParse(versionParts[1]) ?? 0 : 0;

            final semParts = semVer.split('.');
            if (semParts.length == 3) {
              int patch = int.tryParse(semParts[2]) ?? 0;
              semVer = '${semParts[0]}.${semParts[1]}.${patch + 1}';
            }
            
            final newVersion = '$semVer+${buildNum + 1}';
            newLines.add('version: $newVersion');
            onLog('  📈 Podbito wersję w ${p.basename(modulePath)}: $versionStr -> $newVersion');
            updated = true;
            continue;
          }
        }
        newLines.add(line);
      }

      if (updated) {
        await pubspecFile.writeAsString(newLines.join('\n'));
      }
    } catch (e) {
      onLog('  ⚠️ Błąd podczas inkrementacji wersji w $modulePath: $e');
    }
  }

  BuildService({
    required this.config,
    required this.onLog,
    required this.onProgress,
  });

  // Paths relative to generator project root
  static String get _generatorRoot {
    // When running as compiled exe: exe is in build/windows/runner/Release/
    // Project root is 4 levels up. In debug: Directory.current is the project root.
    final exe = Platform.resolvedExecutable;
    final exeDir = File(exe).parent;
    // Heuristic: go up until we find pubspec.yaml for the generator
    Directory dir = exeDir;
    for (int i = 0; i < 6; i++) {
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        if (content.contains('valheim_launcher_generator')) return dir.path;
      }
      dir = dir.parent;
    }
    return Directory.current.path;
  }

  String get _modulesRoot => p.join(_generatorRoot, 'lib', 'modules');
  String get _outputRoot => p.join(_generatorRoot, 'output');
  String get _profilesRoot => p.join(_generatorRoot, 'profiles');
  String get _templatesRoot => p.join(_generatorRoot, 'templates');

  /// Returns true if pre-compiled templates exist for all 3 modules.
  bool get _hasTemplates {
    const templateNames = ['launcher', 'patcher', 'updater'];
    for (final name in templateNames) {
      final templateDir = Directory(p.join(_templatesRoot, name));
      if (!templateDir.existsSync()) return false;
    }
    return true;
  }

  /// On Windows, MSBuild fails when paths exceed 260 chars.
  /// We create a junction from C:\vlg\{l|p|u} → actual module path.
  /// No files are copied — it's a filesystem pointer.
  Future<String> _junctionWorkDir(String modDir, String shortAlias) async {
    if (!Platform.isWindows) return modDir;

    final junctionPath = p.join(r'C:\vlg', shortAlias);

    try {
      await Directory(r'C:\vlg').create(recursive: true);

      // Remove stale junction if exists
      final jDir = Directory(junctionPath);
      if (await jDir.exists()) {
        await Process.run('rmdir', [junctionPath], runInShell: true);
      }

      final result = await Process.run(
        'cmd', ['/c', 'mklink', '/J', junctionPath, modDir],
        runInShell: false,
      );

      if (result.exitCode == 0) {
        onLog('  🔗 Junction: $junctionPath → $modDir');
        return junctionPath;
      }
      onLog('  ⚠️ Nie udało się utworzyć junction (${result.stderr}), używam pełnej ścieżki');
    } catch (e) {
      onLog('  ⚠️ Junction error: $e, używam pełnej ścieżki');
    }
    return modDir; // fallback to original
  }

  Future<void> _removeJunction(String junctionPath) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('rmdir', [junctionPath], runInShell: true);
    } catch (_) {}
  }

  /// Main entry point — runs the full build pipeline.
  /// Automatically detects template mode (pre-compiled) vs legacy flutter build.
  Future<List<ModuleBuildResult>> run() async {
    final results = <ModuleBuildResult>[];
    double prog = 0.0;

    final useTemplates = _hasTemplates;

    if (useTemplates) {
      onLog('⚡ Tryb PRE-COMPILED — szablony znalezione w templates/');
      onLog('   (Flutter SDK nie jest wymagany)');
    } else {
      // ── Flutter pre-check (legacy mode only) ───────────────────
      onLog('🔍 Sprawdzam Flutter SDK (brak szablonów – tryb kompilacji)...');
      final flutterCheck = await Process.run(
        'flutter', ['--version', '--machine'],
        runInShell: true,
      );
      if (flutterCheck.exitCode != 0) {
        onLog('');
        onLog('❌ Flutter SDK nie znaleziony w PATH!');
        onLog('');
        onLog('  Brak szablonów w templates/ i brak Flutter SDK.');
        onLog('  Opcja A: uruchom scripts/build_templates.ps1 (jednorazowo)');
        onLog('  Opcja B: zainstaluj Flutter SDK');
        onLog('');
        results.add(ModuleBuildResult(
          moduleName: 'flutter_check',
          success: false,
          error: 'Brak szablonów i brak Flutter SDK. Uruchom scripts/build_templates.ps1 lub zainstaluj Flutter.',
        ));
        return results;
      }
      try {
        final versionInfo = jsonDecode(flutterCheck.stdout as String) as Map;
        onLog('  ✅ Flutter ${versionInfo['frameworkVersion']} (Dart ${versionInfo['dartSdkVersion']})');
      } catch (_) {
        onLog('  ✅ Flutter SDK znaleziony');
      }
    }
    onProgress(prog += 0.02);

    onLog('🔐 Generowanie zaszyfrowanego configa...');
    final encryptedJson = config.toEncryptedJson();
    final encryptedPayload = jsonEncode({'data': encryptedJson});
    onProgress(prog += 0.05);

    // Save profile
    onLog('💾 Zapisywanie profilu...');
    await _saveProfile(encryptedPayload);
    onProgress(prog += 0.05);

    // Save salt if requested
    if (config.saveSalt) {
      await SharedSalt.save(config.salt);
      onLog('🔑 Salt zapisany w rejestrze.');
    }

    // Encrypted salt for manifest.sig
    final encryptedSalt = CryptoService.encryptSalt(config.salt);

    final modules = [
      _ModuleSpec(
        name: 'launcher',
        dir: p.join(_modulesRoot, 'launcher_module'),
        shortAlias: 'l',
        exeName: 'server_launcher',
        outputAs: '${config.serverName} Launcher',
        weight: 0.25,
      ),
      _ModuleSpec(
        name: 'patcher',
        dir: p.join(_modulesRoot, 'patcher_module'),
        shortAlias: 'p',
        exeName: 'server_patcher',
        outputAs: '${config.serverName} Patcher',
        weight: 0.25,
      ),
      _ModuleSpec(
        name: 'updater',
        dir: p.join(_modulesRoot, 'updater_module'),
        shortAlias: 'u',
        exeName: 'server_updater',
        outputAs: '${config.serverName} Updater',
        weight: 0.25,
      ),
    ];

    for (final mod in modules) {
      onLog('\n📦 ${useTemplates ? "Generowanie" : "Budowanie"} ${mod.outputAs}.exe...');
      final result = useTemplates
          ? await _buildModuleFromTemplate(mod, encryptedPayload, encryptedSalt)
          : await _buildModule(mod, encryptedPayload);
      results.add(result);
      prog += mod.weight;
      onProgress(prog.clamp(0.0, 0.95));
      if (result.success) {
        onLog('  ✅ ${mod.outputAs}.exe → ${result.exePath}');
      } else {
        onLog('  ❌ Błąd ${mod.name}: ${result.error}');
        onProgress(1.0);
        return results;
      }
    }

    onProgress(1.0);
    return results;
  }

  // ── Pre-compiled template build ─────────────────────────────────

  /// Builds a module from a pre-compiled template:
  /// 1. Copies template to output folder
  /// 2. Replaces config_encrypted.json and manifest.sig in flutter_assets
  /// 3. Replaces background video (launcher only)
  /// 4. Generates and replaces logo icon
  /// 5. Renames the exe
  Future<ModuleBuildResult> _buildModuleFromTemplate(
    _ModuleSpec mod,
    String encryptedPayload,
    String encryptedSalt,
  ) async {
    try {
      final templateDir = Directory(p.join(_templatesRoot, mod.name));
      if (!templateDir.existsSync()) {
        return ModuleBuildResult(
          moduleName: mod.name,
          success: false,
          error: 'Szablon nie istnieje: ${templateDir.path}',
        );
      }

      // Increment launcher version BEFORE reading it (so each Generate bumps build num).
      // All modules share the launcher version for output folder + upload consistency.
      if (mod.name == 'launcher') {
        await _incrementVersion(p.join(_modulesRoot, 'launcher_module'));
      }

      // Determine version from launcher module pubspec (shared version)
      final releaseVersion = _readVersion(p.join(_modulesRoot, 'launcher_module'));
      final outDir = Directory(p.join(_outputRoot, config.serverName, 'v$releaseVersion', mod.outputAs));

      // 1. Copy entire template to output
      onLog('  📋 Kopiowanie szablonu ${mod.name}...');
      if (await outDir.exists()) {
        await outDir.delete(recursive: true);
      }
      await outDir.create(recursive: true);
      await _copyDirContents(templateDir, outDir);

      // 2. Locate flutter_assets in the copied output
      final assetsPath = p.join(outDir.path, 'data', 'flutter_assets', 'assets');
      final assetsDir = Directory(assetsPath);
      if (!await assetsDir.exists()) {
        await assetsDir.create(recursive: true);
      }

      // 3. Inject config_encrypted.json
      onLog('  📝 Wstrzykuję config_encrypted.json...');
      await File(p.join(assetsPath, 'config_encrypted.json'))
          .writeAsString(encryptedPayload);

      // 4. Inject manifest.sig (encrypted salt)
      onLog('  🔐 Wstrzykuję manifest.sig...');
      await File(p.join(assetsPath, 'manifest.sig'))
          .writeAsString(encryptedSalt);

      // 4b. Inject version.txt (so launcher knows its own version at runtime)
      onLog('  📌 Wstrzykuję version.txt → $releaseVersion');
      await File(p.join(assetsPath, 'version.txt'))
          .writeAsString(releaseVersion);

      // 5. Inject background video (launcher only)
      if (mod.name == 'launcher' && config.backgroundPath.isNotEmpty) {
        final bgSrc = File(config.backgroundPath);
        if (await bgSrc.exists()) {
          final videoDir = Directory(p.join(assetsPath, 'video'));
          await videoDir.create(recursive: true);
          final destPath = p.join(videoDir.path, 'background.mp4');

          onLog('  🎬 Kompresja tła ffmpeg: ${p.basename(config.backgroundPath)}...');
          final compressResult = await _compressVideo(config.backgroundPath, destPath);
          if (compressResult) {
            final srcSize = await bgSrc.length();
            final destSize = await File(destPath).length();
            onLog('  🎬 Tło skompresowane: ${_fmtSize(srcSize)} → ${_fmtSize(destSize)}');
          } else {
            onLog('  ⚠️ ffmpeg niedostępny — kopiuję tło bez kompresji');
            await bgSrc.copy(destPath);
          }
        } else {
          onLog('  ⚠️ Plik tła nie istnieje: ${config.backgroundPath}');
        }
      }

      // 6. Generate and inject logo icon
      onLog('  🎨 Generowanie ikony...');
      final imgDir = Directory(p.join(assetsPath, 'images'));
      await imgDir.create(recursive: true);
      await _generateIconToDir(mod, imgDir);

      // 7. Rename exe to output name
      final srcExe = File(p.join(outDir.path, '${mod.exeName}.exe'));
      final destExe = File(p.join(outDir.path, '${mod.outputAs}.exe'));
      if (await srcExe.exists()) {
        await srcExe.rename(destExe.path);
      }

      onLog('  📁 Output: v$releaseVersion/${mod.outputAs}/');
      return ModuleBuildResult(
        moduleName: mod.name,
        success: true,
        exePath: destExe.path,
      );
    } catch (e) {
      return ModuleBuildResult(
        moduleName: mod.name,
        success: false,
        error: '$e',
      );
    }
  }

  /// Generates icon directly to a target directory (for template mode).
  Future<void> _generateIconToDir(_ModuleSpec mod, Directory imgDir) async {
    try {
      final nameParts = config.serverName.split(RegExp(r'\s+'));
      String acronym = '';
      for (var p_ in nameParts) {
        if (p_.isNotEmpty) acronym += p_[0].toUpperCase();
      }
      if (mod.name.toLowerCase().contains('launcher')) acronym += 'L';
      else if (mod.name.toLowerCase().contains('patcher')) acronym += 'P';
      else if (mod.name.toLowerCase().contains('updater')) acronym += 'U';

      final outputPath = p.join(imgDir.path, 'logo.png');
      final fontPath = p.join(_generatorRoot, 'assets', 'fonts', 'Norsebold.otf');
      final scriptPath = p.join(_generatorRoot, 'scripts', 'generate_icon.ps1');

      final result = await Process.run(
        'powershell',
        [
          '-ExecutionPolicy', 'Bypass',
          '-File', scriptPath,
          '-Text', acronym,
          '-OutputPath', outputPath,
          '-FontPath', fontPath,
          '-Size', '256',
        ],
        workingDirectory: _generatorRoot,
        runInShell: true,
      );

      if (result.exitCode != 0) {
        onLog('  ⚠️ PowerShell icon error: ${result.stderr}');
        return;
      }

      // Launcher needs valheim.png for backward compat
      if (mod.name == 'launcher') {
        final logoBytes = await File(outputPath).readAsBytes();
        await File(p.join(imgDir.path, 'valheim.png')).writeAsBytes(logoBytes);
      }

      onLog('  🎨 Ikona wygenerowana: $acronym (Norse Bold)');
    } catch (e) {
      onLog('  ⚠️ Błąd generowania ikony: $e');
    }
  }

  Future<void> _saveProfile(String encryptedPayload) async {
    try {
      await ProfileService.save(ServerProfile(
        serverName: config.serverName,
        serverAddr: config.serverAddr,
        serverPassword: config.serverPassword,
        ftpHost: config.ftpHost,
        ftpPort: config.ftpPort,
        ftpUser: config.ftpUser,
        ftpPassword: config.ftpPassword,
        backgroundPath: config.backgroundPath,
        salt: config.salt,
        savedAt: DateTime.now(),
        panelUrl: config.panelUrl,
        engineRepo: config.engineRepo,
      ));
    } catch (e) {
      onLog('  ⚠️ Nie udało się zapisać profilu: $e');
    }
  }


  Future<ModuleBuildResult> _buildModule(
      _ModuleSpec mod, String encryptedPayload) async {
    // Create junction to short path to avoid Windows 260-char path limit
    final workDir = await _junctionWorkDir(mod.dir, mod.shortAlias);
    final junctionCreated = workDir != mod.dir;
    try {
      final modDir = Directory(mod.dir);
      if (!await modDir.exists()) {
        return ModuleBuildResult(
          moduleName: mod.name,
          success: false,
          error: 'Folder modułu nie istnieje: ${mod.dir}',
        );
      }

      // 1. Write config_encrypted.json to module assets (always to real path)
      onLog('  📝 Wstrzykuję config do ${mod.name}/assets/...');
      final assetsDir = Directory(p.join(mod.dir, 'assets'));
      await assetsDir.create(recursive: true);
      await File(p.join(assetsDir.path, 'config_encrypted.json'))
          .writeAsString(encryptedPayload);

      // 1b. Write manifest.sig — salt encrypted with APP_SECRET (not plaintext!)
      final encryptedSalt = CryptoService.encryptSalt(config.salt);
      await File(p.join(assetsDir.path, 'manifest.sig'))
          .writeAsString(encryptedSalt);
      onLog('  🔐 manifest.sig wstrzyknięty do ${mod.name}/assets/');

      // 2c. Dynamically replace buildServerName in module's main.dart
      await _injectServerName(mod.dir);

      // 2b. Inject background video/image — launcher module only.
      //     Copies user-selected backgroundPath → assets/video/background.mp4
      if (mod.name == 'launcher' && config.backgroundPath.isNotEmpty) {
        final bgSrc = File(config.backgroundPath);
        if (await bgSrc.exists()) {
          final videoDir = Directory(p.join(assetsDir.path, 'video'));
          await videoDir.create(recursive: true);
          final destPath = p.join(videoDir.path, 'background.mp4');

          // Compress video with ffmpeg for optimal launcher performance
          // (scales to 1280x720, H.264 CRF 28, max 5Mbps, no audio, faststart)
          onLog('  🎬 Kompresja tła ffmpeg: ${p.basename(config.backgroundPath)}...');
          final compressResult = await _compressVideo(config.backgroundPath, destPath);
          if (compressResult) {
            final srcSize = await bgSrc.length();
            final destSize = await File(destPath).length();
            onLog('  🎬 Tło skompresowane: ${_fmtSize(srcSize)} → ${_fmtSize(destSize)}');
          } else {
            // Fallback: copy as-is if ffmpeg fails
            onLog('  ⚠️ ffmpeg niedostępny — kopiuję tło bez kompresji');
            await bgSrc.copy(destPath);
            onLog('  🎬 Tło skopiowane: ${p.basename(config.backgroundPath)}');
          }
        } else {
          onLog('  ⚠️ Plik tła nie istnieje: ${config.backgroundPath}');
        }
      }
      // 3. Generate dynamic icon (Logo)
      await _generateIcon(mod, assetsDir);

      onLog('  🎨 Generowanie ikon systemowych (EXE/Taskbar)...');
      final iconResult = await Process.run(
        'dart', ['run', 'flutter_launcher_icons'],
        workingDirectory: mod.dir,
        runInShell: true,
      );
      if (iconResult.exitCode != 0) {
        onLog('  ⚠️ Ostrzeżenie (ikony): ${iconResult.stderr}'.trim());
      }

      // 4. Increment version (patch 0.0.1 and build number +1)
      await _incrementVersion(mod.dir);
      onLog('  📦 flutter pub get...');
      final pubResult = await Process.run(
        'flutter', ['pub', 'get'],
        workingDirectory: mod.dir,
        runInShell: true,
      );
      if (pubResult.exitCode != 0) {
        onLog('  ⚠️ pub get warning: ${pubResult.stderr}'.trim());
      }

      // 4. If CMakeCache has stale junction paths → flutter clean (one-time cost)
      final cmakeCache = File(p.join(mod.dir, 'build', 'windows', 'x64', 'CMakeCache.txt'));
      if (await cmakeCache.exists()) {
        final cacheContent = await cmakeCache.readAsString();
        if (cacheContent.contains(r'C:/vlg/') || cacheContent.contains(r'C:\vlg\')) {
          onLog('  🧹 Wykryto stale ścieżki junction — flutter clean...');
          await Process.run('flutter', ['clean'], workingDirectory: mod.dir, runInShell: true);
        }
      }

      // 5. Run flutter build windows from workDir (short path via junction)
      onLog('  🔨 flutter build windows...');
      final buildResult = await _runFlutterBuild(workDir, mod);
      if (!buildResult.success) {
        return ModuleBuildResult(
          moduleName: mod.name,
          success: false,
          error: buildResult.error,
        );
      }

      // 6. Copy exe to output
      final exePath = await _copyOutput(mod);
      return ModuleBuildResult(
        moduleName: mod.name,
        success: true,
        exePath: exePath,
      );
    } catch (e) {
      return ModuleBuildResult(
        moduleName: mod.name,
        success: false,
        error: '$e',
      );
    } finally {
      if (junctionCreated) await _removeJunction(workDir);
    }
  }

  Future<({bool success, String? error})> _runFlutterBuild(
      String buildDir, _ModuleSpec mod) async {
    // Log file always goes to real (non-junction) path
    final logFile = File(p.join(mod.dir, '..', 'build_${mod.name}.log'));
    final logSink = logFile.openWrite();
    final meaningfulLines = <String>[];
    final startTime = DateTime.now();

    // Lines that are noise — suppress from UI but keep in log
    bool _isNoise(String t) =>
        t.startsWith('CMake Warning') ||
        t.startsWith('Policy CMP') ||
        t.startsWith('Run "cmake') ||
        t.startsWith('This warning is for') ||
        t.startsWith('  Policy') ||
        t.startsWith('  Run ') ||
        t.startsWith('  Assuming') ||
        t.startsWith('  POST_BUILD') ||
        t.startsWith('  PRE_') ||
        t.startsWith('Use -Wno-dev') ||
        t.startsWith('Exactly one of') ||
        t.contains('backward compatibility') ||
        t.contains('suppress this warning') ||
        t.startsWith('command to set');

    try {
      final process = await Process.start(
        'flutter',
        ['build', 'windows', '--release'],
        workingDirectory: buildDir,
        runInShell: true,
      );

      void handleChunk(String chunk) {
        // Log EVERYTHING to file
        logSink.write(chunk);
        // Split on \n and \r, skip empty and spinner-only lines
        for (final raw in chunk.split(RegExp(r'[\r\n]+'))) {
          final t = raw.trim();
          if (t.isEmpty || t == r'\' || t == '|' || t == '-' || t == '/') continue;
          meaningfulLines.add(t);
          // Show non-noise lines in UI
          if (!_isNoise(t)) {
            onLog('    $t');
          }
        }
      }

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(handleChunk);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(handleChunk);

      final exitCode = await process.exitCode;
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      await logSink.flush();
      await logSink.close();

      onLog('    ⏱️ czas buildu: ${elapsed}s');

      if (exitCode != 0) {
        final tail = meaningfulLines.reversed.take(20).toList().reversed.join('\n').trim();
        onLog('  ⛔ Pełny log: ${logFile.path}');
        return (
          success: false,
          error: 'flutter build kod $exitCode (${elapsed}s)\n$tail',
        );
      }
      return (success: true, error: null);
    } catch (e) {
      await logSink.close();
      return (success: false, error: 'Błąd uruchamiania flutter: $e');
    }
  }

  Future<String> _copyOutput(_ModuleSpec mod) async {
    // Built exe is at <modDir>/build/windows/x64/runner/Release/<exeName>.exe
    final releaseDir = Directory(p.join(
      mod.dir,
      'build',
      'windows',
      'x64',
      'runner',
      'Release',
    ));

    final builtExe = File(p.join(releaseDir.path, '${mod.exeName}.exe'));
    if (!await builtExe.exists()) {
      throw 'Nie znaleziono zbudowanego exe: ${builtExe.path}';
    }

    // All 3 modules share ONE versioned release folder (named after launcher version):
    //   output/{serverName}/v{launcherVersion}/
    //     ├── {ServerName} Launcher/   ← launcher exe + DLLs + data/
    //     ├── {ServerName} Patcher/    ← patcher exe + DLLs + data/
    //     └── {ServerName} Updater/    ← updater exe + DLLs + data/
    final launcherPubspec = p.join(_modulesRoot, 'launcher_module');
    final releaseVersion = _readVersion(launcherPubspec);
    final outDir = Directory(p.join(_outputRoot, config.serverName, 'v$releaseVersion', mod.outputAs));
    await outDir.create(recursive: true);

    // Copy entire Release folder first (DLLs + data/)
    await _copyDirContents(releaseDir, outDir, skipFiles: ['${mod.exeName}.exe']);

    // Then copy renamed exe
    final destExe = File(p.join(outDir.path, '${mod.outputAs}.exe'));
    await builtExe.copy(destExe.path);

    onLog('  📁 Output: v$releaseVersion/${mod.outputAs}/');
    return destExe.path;
  }

  Future<void> _copyDirContents(
    Directory src,
    Directory dest, {
    List<String> skipFiles = const [],
  }) async {
    await for (final entity in src.list(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is File) {
        if (skipFiles.contains(name)) continue;
        final destFile = File(p.join(dest.path, name));
        await entity.copy(destFile.path);
      } else if (entity is Directory) {
        final subDest = Directory(p.join(dest.path, name));
        await subDest.create(recursive: true);
        await _copyDirContents(entity, subDest);
      }
    }
  }

  // ── Upload to server ─────────────────────────────────────────────────────

  /// Uploads [serverName] Launcher.exe + Updater.exe + version manifests
  /// to `launcher_files/` on the configured FTP/SFTP server.
  Future<({bool success, String? error})> uploadToServer() async {
    const remoteDir = 'launcher_files';
    final isSftp = config.ftpPort == 22 || config.ftpPort == 2022;

    // All modules are placed in a folder named after the launcher version:
    // output/{serverName}/v{launcherVersion}/{modLabel}/
    final launcherVersion = _readVersion(p.join(_modulesRoot, 'launcher_module'));

    // Build ZIP files from output folders
    final tmpDir = Directory.systemTemp.createTempSync('vlg_upload_');
    final uploads = <({File file, String remoteName})>[];
    try {
      for (final modAlias in [
        (name: 'launcher', label: 'launcher'),
        (name: 'updater',  label: 'updater'),
      ]) {
        final modLabel = '${config.serverName} ${modAlias.name[0].toUpperCase()}${modAlias.name.substring(1)}';
        final modVersion = _readVersion(p.join(_modulesRoot, '${modAlias.name}_module'));
        
        // Use launcherVersion for the version-folder name (consistent with _copyOutput)
        final sourceDir = Directory(p.join(_outputRoot, config.serverName, 'v$launcherVersion', modLabel));
        if (!sourceDir.existsSync()) {
          onLog('  ⚠️ Pominięto ${modAlias.label} (folder nie istnieje: ${sourceDir.path})');
          continue;
        }

        // 1. Create .zip (contents of sourceDir in root of zip)
        onLog('  📦 Pakowanie ${modAlias.label}.zip...');
        final zipPath = p.join(tmpDir.path, '${modAlias.label}.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipPath);
        // Add contents of the directory without a prefix folder
        await for (final file in sourceDir.list(recursive: true)) {
           if (file is File) {
             final relative = p.relative(file.path, from: sourceDir.path);
             encoder.addFile(file, relative);
           }
        }
        encoder.close();
        uploads.add((file: File(zipPath), remoteName: '${modAlias.label}.zip'));

        // 2. Create .txt version manifest
        final vFile = File(p.join(tmpDir.path, '${modAlias.label}.txt'));
        await vFile.writeAsString(modVersion, flush: true);
        uploads.add((file: vFile, remoteName: '${modAlias.label}.txt'));
        onLog('  📄 ${modAlias.label}.txt → $modVersion');
      }

      if (uploads.isEmpty) {
        return (success: false, error: 'Brak plików do wysłania. Czy build zakończył się sukcesem?');
      }

      onLog('');
      onLog('🚀 Łączę z ${config.ftpHost}:${config.ftpPort} (${isSftp ? "SFTP" : "FTP"})...');

      ({bool success, String? error}) result;
      if (isSftp) {
        result = await _uploadSftp(remoteDir, uploads);
      } else {
        result = await _uploadFtp(remoteDir, uploads);
      }
      return result;
    } finally {
      tmpDir.deleteSync(recursive: true); // Clean up
    }
  }

  String _readVersion(String modDir) {
    try {
      final content = File(p.join(modDir, 'pubspec.yaml')).readAsStringSync();
      final m = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(content);
      return m?.group(1)?.trim() ?? '1.0.0+0';
    } catch (_) {
      return '1.0.0+0';
    }
  }

  Future<({bool success, String? error})> _uploadSftp(
      String remoteDir, List<({File file, String remoteName})> uploads) async {
    final socket = await SSHSocket.connect(config.ftpHost, config.ftpPort,
        timeout: const Duration(seconds: 15));
    final client = SSHClient(socket,
        username: config.ftpUser, onPasswordRequest: () => config.ftpPassword);
    await client.authenticated;
    final sftp = await client.sftp();

    try {
      await sftp.mkdir(remoteDir).catchError((_) {});
      for (final u in uploads) {
        onLog('  ⬆️  ${u.remoteName}...');
        final remote = await sftp.open(
          '$remoteDir/${u.remoteName}',
          mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
        );
        await remote.write(u.file.openRead().cast());
        await remote.close();
        onLog('     ✅ ${u.remoteName} (${_fmtSize(await u.file.length())})');
      }
    } finally {
      sftp.close();
      client.close();
    }
    return (success: true, error: null);
  }

  Future<({bool success, String? error})> _uploadFtp(
      String remoteDir, List<({File file, String remoteName})> uploads) async {
    final ftp = FTPConnect(
      config.ftpHost,
      user: config.ftpUser,
      pass: config.ftpPassword,
      port: config.ftpPort,
      timeout: 20,
    );
    await ftp.connect();
    try {
      await ftp.makeDirectory(remoteDir).catchError((_) => false);
      await ftp.changeDirectory(remoteDir);
      for (final u in uploads) {
        onLog('  ⬆️  ${u.remoteName}...');
        final ok = await ftp.uploadFile(u.file, sRemoteName: u.remoteName);
        if (ok) {
          onLog('     ✅ ${u.remoteName} (${_fmtSize(await u.file.length())})');
        } else {
          onLog('     ❌ Błąd wysyłania ${u.remoteName}');
        }
      }
    } finally {
      await ftp.disconnect();
    }
    return (success: true, error: null);
  }

  /// Replaces the hardcoded buildServerName constant in the module's main.dart
  /// with the actual server name configured by the user in the wizard.
  Future<void> _injectServerName(String modDir) async {
    try {
      final mainDart = File(p.join(modDir, 'lib', 'main.dart'));
      if (!await mainDart.exists()) return;
      var content = await mainDart.readAsString();
      // Replace the buildServerName constant value
      final pattern = RegExp(r"static const String buildServerName = '.*?';");
      if (pattern.hasMatch(content)) {
        content = content.replaceFirst(
          pattern,
          "static const String buildServerName = '${config.serverName}';",
        );
        await mainDart.writeAsString(content);
        onLog('  📛 Nazwa serwera wstrzyknięta: ${config.serverName}');
      }
    } catch (e) {
      onLog('  ⚠️ Nie udało się wstrzyknąć nazwy serwera: $e');
    }
  }

  /// Generuje dynamiczny obrazek logo (256x256) z akronimem nazwy przy użyciu
  /// PowerShell + System.Drawing dla natywnego renderowania fontu Norse.
  Future<void> _generateIcon(_ModuleSpec mod, Directory assetsDir) async {
    try {
      final imgDir = Directory(p.join(assetsDir.path, 'images'));
      await imgDir.create(recursive: true);

      // 1. Wygeneruj akronim (np. "Aurora Borealis" + "Launcher" -> "ABL")
      final nameParts = config.serverName.split(RegExp(r'\s+'));
      String acronym = '';
      for (var p_ in nameParts) {
        if (p_.isNotEmpty) acronym += p_[0].toUpperCase();
      }
      
      // Dodaj sufix modułu (L dla Launcher, P dla Patcher, U dla Updater)
      if (mod.name.toLowerCase().contains('launcher')) acronym += 'L';
      else if (mod.name.toLowerCase().contains('patcher')) acronym += 'P';
      else if (mod.name.toLowerCase().contains('updater')) acronym += 'U';

      // 2. Użyj PowerShell + System.Drawing do renderowania
      final outputPath = p.join(imgDir.path, 'logo.png');
      final fontPath = p.join(_generatorRoot, 'assets', 'fonts', 'Norsebold.otf');
      final scriptPath = p.join(_generatorRoot, 'scripts', 'generate_icon.ps1');
      
      // Kolor: biały dla modułów (na ciemnym tle dobrze widoczny)
      final result = await Process.run(
        'powershell',
        [
          '-ExecutionPolicy', 'Bypass',
          '-File', scriptPath,
          '-Text', acronym,
          '-OutputPath', outputPath,
          '-FontPath', fontPath,
          '-Size', '256',
        ],
        workingDirectory: _generatorRoot,
        runInShell: true,
      );

      if (result.exitCode != 0) {
        onLog('  ⚠️ PowerShell icon error: ${result.stderr}');
        return;
      }
      
      // Launcher potrzebuje też valheim.png dla kompatybilności wstecznej kodu
      if (mod.name == 'launcher') {
        final logoBytes = await File(outputPath).readAsBytes();
        await File(p.join(imgDir.path, 'valheim.png')).writeAsBytes(logoBytes);
      }

      onLog('  🎨 Ikona wygenerowana: $acronym (Norse Bold)');
    } catch (e) {
      onLog('  ⚠️ Błąd generowania ikony: $e');
    }
  }

  /// Resolves the path to ffmpeg executable.
  /// Priority: bundled tools/ffmpeg.exe → system PATH → null.
  String? _resolveFfmpeg() {
    // 1. Bundled: {generatorRoot}/tools/ffmpeg.exe (dev mode)
    final bundledDev = File(p.join(_generatorRoot, 'tools', 'ffmpeg.exe'));
    if (bundledDev.existsSync()) return bundledDev.path;

    // 2. Bundled: {exeDir}/tools/ffmpeg.exe (distributed ZIP)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundledDist = File(p.join(exeDir, 'tools', 'ffmpeg.exe'));
    if (bundledDist.existsSync()) return bundledDist.path;

    // 3. Bundled: {exeDir}/../tools/ffmpeg.exe (one level up)
    final bundledUp = File(p.join(exeDir, '..', 'tools', 'ffmpeg.exe'));
    if (bundledUp.existsSync()) return bundledUp.path;

    // 4. System PATH fallback
    try {
      final check = Process.runSync('where', ['ffmpeg'], runInShell: true);
      if (check.exitCode == 0) return 'ffmpeg'; // found in PATH
    } catch (_) {}

    return null; // not found anywhere
  }

  /// Kompresuje wideo ffmpeg do optymalnego formatu dla launchera.
  /// Zwraca true jeśli kompresja się powiodła, false jeśli ffmpeg niedostępny.
  Future<bool> _compressVideo(String srcPath, String destPath) async {
    final ffmpeg = _resolveFfmpeg();
    if (ffmpeg == null) {
      onLog('  ⚠️ ffmpeg nie znaleziony (tools/ffmpeg.exe ani w PATH)');
      return false;
    }

    // Log which ffmpeg we're using
    if (ffmpeg != 'ffmpeg') {
      onLog('  🔧 Używam bundled ffmpeg: ${p.basename(p.dirname(ffmpeg))}/${p.basename(ffmpeg)}');
    }

    try {
      final result = await Process.run(
        ffmpeg,
        [
          '-y',                          // overwrite output
          '-i', srcPath,                 // input
          '-vf', 'scale=1280:720',       // match launcher window size
          '-c:v', 'libx264',             // H.264 codec (best hw decode support)
          '-preset', 'slow',             // better compression
          '-crf', '28',                  // quality (lower = better, 28 is good for BG)
          '-b:v', '4M',                  // target bitrate
          '-maxrate', '5M',              // max bitrate cap
          '-bufsize', '8M',              // buffer size
          '-an',                         // strip audio (muted in launcher)
          '-movflags', '+faststart',     // streaming-friendly
          '-pix_fmt', 'yuv420p',         // max compatibility
          destPath,
        ],
        runInShell: true,
      );
      return result.exitCode == 0;
    } catch (e) {
      onLog('  ⚠️ ffmpeg error: $e');
      return false;
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

class _ModuleSpec {
  final String name;
  final String dir;
  final String shortAlias; // used for C:\vlg\{alias} junction
  final String exeName;
  final String outputAs;
  final double weight;
  const _ModuleSpec({
    required this.name,
    required this.dir,
    required this.shortAlias,
    required this.exeName,
    required this.outputAs,
    required this.weight,
  });
}
