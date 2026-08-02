import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Talks to the valheim-proxmox panel over HTTPS instead of FTP.
///
/// The upstream design ships an FTP account inside every player's exe: the
/// credentials are obfuscated but the key travels in the same binary, and FTP
/// is plaintext on the wire. Nothing here needs an account at all - the panel
/// publishes the manifest and the mod files on open routes, and answers 404
/// when the admin has the launcher switched off.
class PanelClient {
  /// Base address of the panel, e.g. https://valheim.klans.eu
  final String baseUrl;
  final http.Client _http;

  PanelClient(String baseUrl, {http.Client? client})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// Everything the launcher needs in one call: server details, the mod list and
  /// every file with its hash. Throws [PanelOffException] when the admin has the
  /// launcher turned off, which is a normal answer rather than a failure.
  Future<PanelManifest> manifest() async {
    final r = await _http.get(_u('/api/launcher/manifest'));
    if (r.statusCode == 404) throw PanelOffException();
    if (r.statusCode != 200) {
      throw Exception('Panel answered ${r.statusCode}');
    }
    return PanelManifest.fromJson(
        json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
  }

  /// Downloads one file from the manifest to [target], creating parent folders.
  /// The hash is verified after writing - a truncated download is worse than no
  /// download, because it looks installed.
  Future<void> downloadFile(PanelFile file, String target,
      {void Function(int received, int total)? onProgress}) async {
    final req = http.Request('GET', _u('/api/launcher/files/${Uri.encodeFull(file.path)}'));
    final resp = await _http.send(req);
    if (resp.statusCode != 200) {
      throw Exception('${file.path}: panel answered ${resp.statusCode}');
    }
    final out = File(target);
    await out.parent.create(recursive: true);
    final sink = out.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, file.size);
      }
    } finally {
      await sink.close();
    }
    final got = sha256.convert(await out.readAsBytes()).toString();
    if (got != file.sha256) {
      await out.delete();
      throw Exception('${file.path}: hash mismatch, download discarded');
    }
  }

  /// Fetches the background only when the stamp differs from the cached one.
  /// Returns true when a new file was written.
  Future<bool> syncBackground(String url, String target, String stampFile,
      String stamp) async {
    final stampOnDisk = File(stampFile);
    final current = File(target);
    if (await current.exists() && await stampOnDisk.exists()) {
      if ((await stampOnDisk.readAsString()).trim() == stamp) return false;
    }
    final r = await _http.get(url.startsWith('http') ? Uri.parse(url) : _u(url));
    if (r.statusCode != 200) return false;
    final out = File(target);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(r.bodyBytes);
    await stampOnDisk.writeAsString(stamp);
    return true;
  }

  /// The address to join, with the panel's own host as the fallback: if the
  /// admin has not named the game server, the panel is reachable at some name
  /// already and the game almost always answers on the same one.
  String joinHost(PanelManifest m) => m.serverAddress ?? Uri.parse(baseUrl).host;

  void close() => _http.close();
}

/// The panel is reachable but the admin has the launcher switched off.
class PanelOffException implements Exception {
  @override
  String toString() => 'The launcher is switched off on this server';
}

class PanelFile {
  final String path;
  final int size;
  final String sha256;

  const PanelFile({required this.path, required this.size, required this.sha256});

  factory PanelFile.fromJson(Map<String, dynamic> j) => PanelFile(
        path: j['path'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        sha256: j['sha256'] as String? ?? '',
      );
}

class PanelManifest {
  final String serverName;

  /// Where players connect. Comes from the panel at every start rather than
  /// being baked in, because a home connection changes address and DDNS follows
  /// it - a number compiled into an exe is wrong by morning. Null means the
  /// admin has not set one, and the launcher falls back to the panel's own host.
  final String? serverAddress;
  final int serverPort;
  final bool passwordRequired;
  final bool crossplay;
  final List<PanelFile> files;
  final List<String> mods;
  final String? profileCode;
  final String? backgroundUrl;
  final String? engineRepo;
  final String? note;

  const PanelManifest({
    required this.serverName,
    required this.serverPort,
    this.serverAddress,
    required this.passwordRequired,
    required this.crossplay,
    required this.files,
    required this.mods,
    this.profileCode,
    this.backgroundUrl,
    this.engineRepo,
    this.note,
  });

  factory PanelManifest.fromJson(Map<String, dynamic> j) {
    final server = (j['server'] as Map<String, dynamic>?) ?? const {};
    final engine = (j['engine'] as Map<String, dynamic>?) ?? const {};
    return PanelManifest(
      serverName: server['name'] as String? ?? '',
      serverAddress: (server['address'] as String?)?.trim().isEmpty == true
          ? null
          : server['address'] as String?,
      serverPort: (server['port'] as num?)?.toInt() ?? 2456,
      passwordRequired: server['password_required'] == true,
      crossplay: server['crossplay'] == true,
      files: ((j['files'] as List?) ?? const [])
          .map((e) => PanelFile.fromJson(e as Map<String, dynamic>))
          .toList(),
      mods: ((j['mods'] as List?) ?? const [])
          .map((e) => (e as Map<String, dynamic>)['full_name'] as String)
          .toList(),
      profileCode: j['profile_code'] as String?,
      backgroundUrl: j['background'] as String?,
      engineRepo: engine['repo'] as String?,
      note: j['note'] as String?,
    );
  }

  /// Files the client is missing or has in a different version, plus the ones it
  /// has and the server no longer ships - the launcher deletes those, otherwise
  /// a removed mod keeps loading on the player's machine and bounces them at the
  /// door with a version mismatch.
  ({List<PanelFile> fetch, List<String> remove}) diff(
      Map<String, String> localHashes) {
    final wanted = {for (final f in files) f.path: f};
    final fetch = <PanelFile>[];
    for (final f in files) {
      if (localHashes[f.path] != f.sha256) fetch.add(f);
    }
    final remove = localHashes.keys.where((p) => !wanted.containsKey(p)).toList();
    return (fetch: fetch, remove: remove);
  }
}
