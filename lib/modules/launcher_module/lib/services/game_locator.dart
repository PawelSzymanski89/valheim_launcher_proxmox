import 'dart:io';

import 'package:flutter/foundation.dart';

/// Finds the installed game, on whichever system the player is running.
///
/// The upstream launcher guessed drive letters, which only ever worked on
/// Windows and only for the default library. Steam already writes down every
/// library it owns in `libraryfolders.vdf`, so that file is read first and the
/// hardcoded spots are the fallback for an install Steam has forgotten.
class GameLocator {
  /// What "the executable" means per platform. All three sit directly in the
  /// game folder, so the parent directory is the game root everywhere - which is
  /// what the rest of the launcher works with.
  static String get executableName {
    if (Platform.isWindows) return 'valheim.exe';
    if (Platform.isMacOS) return 'valheim.app';
    return 'valheim.x86_64';
  }

  static String get _home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  /// Steam's own root, where `steamapps` lives.
  static List<String> _steamRoots() {
    final sep = Platform.pathSeparator;
    if (Platform.isMacOS) {
      return ['$_home/Library/Application Support/Steam'];
    }
    if (Platform.isLinux) {
      return [
        '$_home/.steam/steam',
        '$_home/.steam/root',
        '$_home/.local/share/Steam',
        // Flatpak keeps its own home; a player who installed Steam that way has
        // no Steam directory anywhere else.
        '$_home/.var/app/com.valvesoftware.Steam/data/Steam',
        '$_home/.var/app/com.valvesoftware.Steam/.local/share/Steam',
      ];
    }
    final roots = <String>[
      r'C:\Program Files (x86)\Steam',
      r'C:\Program Files\Steam',
      r'C:\Steam',
    ];
    for (var c = 'D'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final d = String.fromCharCode(c);
      if (Directory('$d:$sep').existsSync()) {
        roots.addAll(['$d:${sep}Steam', '$d:${sep}SteamLibrary', '$d:${sep}Games${sep}Steam']);
      }
    }
    return roots;
  }

  /// Every library Steam knows about, taken from `libraryfolders.vdf`. This is
  /// the only way to find a game the player moved to a second disk.
  static List<String> _librariesFromSteam() {
    final out = <String>[];
    final sep = Platform.pathSeparator;
    for (final root in _steamRoots()) {
      for (final name in ['libraryfolders.vdf', 'config${sep}libraryfolders.vdf']) {
        final f = File('$root${sep}steamapps$sep$name');
        final alt = File('$root$sep$name');
        for (final candidate in [f, alt]) {
          try {
            if (!candidate.existsSync()) continue;
            for (final m in RegExp(r'"path"\s*"([^"]+)"')
                .allMatches(candidate.readAsStringSync())) {
              final p = m[1]!.replaceAll(r'\\', sep);
              if (p.isNotEmpty) out.add(p);
            }
          } catch (_) {}
        }
      }
    }
    return out;
  }

  /// Absolute paths worth checking, most likely first, without duplicates.
  static List<String> candidates() {
    final sep = Platform.pathSeparator;
    final seen = <String>{};
    final out = <String>[];
    void add(String base) {
      final p = '$base${sep}steamapps${sep}common${sep}Valheim$sep$executableName';
      if (seen.add(p)) out.add(p);
    }

    for (final lib in _librariesFromSteam()) {
      add(lib);
    }
    for (final root in _steamRoots()) {
      add(root);
    }
    // A Windows library folder is sometimes the library itself, not a Steam root.
    if (Platform.isWindows) {
      for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        final d = String.fromCharCode(c);
        if (!Directory('$d:$sep').existsSync()) continue;
        for (final name in ['SteamLibrary', 'Games\\SteamLibrary']) {
          add('$d:$sep$name');
        }
      }
    }
    return out;
  }

  /// The game's path, or null when it is nowhere obvious. `valheim.app` is a
  /// directory on macOS, so existence is checked both ways.
  static Future<String?> find() async {
    for (final path in candidates()) {
      if (await _exists(path)) {
        if (kDebugMode) debugPrint('[GameLocator] found: $path');
        return path;
      }
    }
    if (kDebugMode) debugPrint('[GameLocator] nothing found in ${candidates().length} places');
    return null;
  }

  static Future<List<String>> findAll() async {
    final out = <String>[];
    for (final path in candidates()) {
      if (await _exists(path)) out.add(path);
    }
    return out;
  }

  static Future<bool> _exists(String path) async =>
      await File(path).exists() || await Directory(path).exists();

  /// True when the given path looks like the game, so a player pointing the
  /// launcher at their install by hand gets the same checks.
  static Future<bool> looksLikeGame(String path) => _exists(path);
}
