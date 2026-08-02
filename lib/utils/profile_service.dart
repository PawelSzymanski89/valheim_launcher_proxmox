import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ServerProfile {
  final String serverName;
  final String serverAddr;
  final String serverPassword;
  final String ftpHost;
  final int ftpPort;
  final String ftpUser;
  final String ftpPassword;
  final String backgroundPath;
  final String salt;
  final DateTime savedAt;
  final String panelUrl;
  final String engineRepo;

  const ServerProfile({
    required this.serverName,
    required this.serverAddr,
    required this.serverPassword,
    required this.ftpHost,
    required this.ftpPort,
    required this.ftpUser,
    required this.ftpPassword,
    required this.backgroundPath,
    required this.salt,
    required this.savedAt,
    this.panelUrl = '',
    this.engineRepo = '',
  });

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        serverName: j['serverName'] as String? ?? '',
        serverAddr: j['serverAddr'] as String? ?? '',
        serverPassword: j['serverPassword'] as String? ?? '',
        ftpHost: j['ftpHost'] as String? ?? '',
        ftpPort: (j['ftpPort'] as num?)?.toInt() ?? 2022,
        ftpUser: j['ftpUser'] as String? ?? '',
        ftpPassword: j['ftpPassword'] as String? ?? '',
        backgroundPath: j['backgroundPath'] as String? ?? '',
        salt: j['salt'] as String? ?? '',
        savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
        panelUrl: j['panelUrl'] as String? ?? '',
        engineRepo: j['engineRepo'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'serverName': serverName,
        'serverAddr': serverAddr,
        'serverPassword': serverPassword,
        'ftpHost': ftpHost,
        'ftpPort': ftpPort,
        'ftpUser': ftpUser,
        'ftpPassword': ftpPassword,
        'backgroundPath': backgroundPath,
        'salt': salt,
        'savedAt': savedAt.toIso8601String(),
        'panelUrl': panelUrl,
        'engineRepo': engineRepo,
      };
}

class ProfileService {
  static String get _profilesDir {
    // Same heuristic as BuildService._generatorRoot
    final exe = Platform.resolvedExecutable;
    Directory dir = File(exe).parent;
    for (int i = 0; i < 6; i++) {
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync() &&
          pubspec.readAsStringSync().contains('valheim_launcher_generator')) {
        return p.join(dir.path, 'profiles');
      }
      dir = dir.parent;
    }
    return p.join(Directory.current.path, 'profiles');
  }

  /// Returns all saved profiles sorted by savedAt descending.
  static Future<List<ServerProfile>> loadAll() async {
    final dir = Directory(_profilesDir);
    if (!await dir.exists()) return [];
    final profiles = <ServerProfile>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final raw = await entity.readAsString();
          final j = jsonDecode(raw) as Map<String, dynamic>;
          profiles.add(ServerProfile.fromJson(j));
        } catch (_) {}
      }
    }
    profiles.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return profiles;
  }

  /// Saves or overwrites a profile for the given server name.
  static Future<void> save(ServerProfile profile) async {
    final dir = Directory(_profilesDir);
    await dir.create(recursive: true);
    final safeName = profile.serverName.replaceAll(RegExp(r'[^\w\s-]'), '_');
    final file = File(p.join(dir.path, '$safeName.json'));
    await file.writeAsString(jsonEncode(profile.toJson()));
  }

  /// Deletes a profile by server name.
  static Future<void> delete(String serverName) async {
    final safeName = serverName.replaceAll(RegExp(r'[^\w\s-]'), '_');
    final file = File(p.join(_profilesDir, '$safeName.json'));
    if (await file.exists()) await file.delete();
  }
}
