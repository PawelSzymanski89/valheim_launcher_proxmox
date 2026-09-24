import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// The panel's manifest key from panel_config.json, or empty for a launcher built
  /// before panels signed their manifests - that one pins the key it sees first.
  final String manifestKey;

  PanelClient(String baseUrl, {http.Client? client, this.manifestKey = ''})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// Everything the launcher needs in one call: server details, the mod list and
  /// every file with its hash. Throws [PanelOffException] when the admin has the
  /// launcher turned off, which is a normal answer rather than a failure.
  ///
  /// The manifest decides which DLLs end up in the player's game, and the panel is
  /// reached over plain http more often than not - so it is signed, and checked here
  /// against the key this launcher was built with. A launcher from before that has no
  /// key in its config: it trusts the first key it sees for this panel and holds every
  /// later manifest to it (trust on first use, like ssh).
  Future<PanelManifest> manifest() async {
    final r = await _http.get(_u('/api/launcher/manifest'));
    if (r.statusCode == 404) throw PanelOffException();
    if (r.statusCode != 200) {
      throw Exception('Panel answered ${r.statusCode}');
    }
    final sig = r.headers['x-manifest-signature'];
    final offered = r.headers['x-manifest-key'];
    final expected = manifestKey.isNotEmpty ? manifestKey : await _pinnedKey();
    if (expected != null) {
      if (sig == null || !await verifyManifest(r.bodyBytes, sig, expected)) {
        throw ManifestSignatureException();
      }
    } else if (sig != null && offered != null &&
        await verifyManifest(r.bodyBytes, sig, offered)) {
      await _pinKey(offered);
    }
    return PanelManifest.fromJson(
        json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
  }

  String get _pinName => 'manifest_key|$baseUrl';

  Future<String?> _pinnedKey() async =>
      (await SharedPreferences.getInstance()).getString(_pinName);

  Future<void> _pinKey(String key) async =>
      (await SharedPreferences.getInstance()).setString(_pinName, key);

  /// ed25519 over the exact bytes the panel sent.
  static Future<bool> verifyManifest(List<int> body, String sigB64, String keyB64) async {
    try {
      final key = cg.SimplePublicKey(base64.decode(keyB64), type: cg.KeyPairType.ed25519);
      return await cg.Ed25519().verify(body,
          signature: cg.Signature(base64.decode(sigB64), publicKey: key));
    } catch (_) {
      return false;
    }
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
    if (file.sha256.isNotEmpty) {
      final got = sha256.convert(await out.readAsBytes()).toString();
      if (got != file.sha256) {
        await out.delete();
        throw Exception('${file.path}: hash mismatch, download discarded');
      }
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

/// The manifest did not carry a valid signature for the key this launcher trusts.
class ManifestSignatureException implements Exception {
  @override
  String toString() =>
      'The mod list from the panel is not signed by the panel this launcher belongs to - '
      'refusing to install anything (someone may be tampering with the connection)';
}

/// A manifest entry pointing outside the BepInEx folder.
class UnsafePathException implements Exception {
  final String path;
  UnsafePathException(this.path);
  @override
  String toString() => 'The panel listed a file outside BepInEx: $path - refusing to sync';
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

  factory PanelFile.fromJson(Map<String, dynamic> j) {
    final path = j['path'] as String;
    if (!isSafePath(path)) throw UnsafePathException(path);
    return PanelFile(
      path: path,
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: j['sha256'] as String? ?? '',
    );
  }

  /// A manifest path is relative to BepInEx/ and stays inside it. Nothing absolute, no
  /// drive letter or UNC share, no ".." - a path like "../../../../.bashrc" used to land
  /// exactly where it pointed, outside the game, and run at the player's next login.
  static bool isSafePath(String path) {
    if (path.isEmpty || path.contains('\u0000') || path.contains(':')) return false;
    final unified = path.replaceAll('\\', '/');
    if (unified.startsWith('/')) return false;
    final parts = unified.split('/');
    if (parts.any((s) => s == '..' || s == '.')) return false;
    return p.posix.isWithin('BepInEx', p.posix.normalize(p.posix.join('BepInEx', unified)));
  }
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
