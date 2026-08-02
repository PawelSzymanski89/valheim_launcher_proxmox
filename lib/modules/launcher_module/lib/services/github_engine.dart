import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Engine updates come straight from the fork's GitHub releases.
///
/// The launcher only *detects* a newer engine here; installing it is the
/// updater's job, because a running exe cannot replace itself on Windows. The
/// launcher hands over and exits, the updater swaps the files and starts it
/// again - which is why both modules carry this same client.
///
/// The upstream design keeps the launcher build on the admin's own FTP, so every
/// server owner has to re-upload a new engine by hand and anyone who forgets
/// leaves their players on an old one. A release on the engine repository
/// reaches every server at once, without the admin doing anything - which is the
/// whole point of splitting the engine from the per-server config.
class GithubEngine {
  /// owner/name of the engine repository.
  final String repo;
  final http.Client _http;

  GithubEngine({this.repo = 'PawelSzymanski89/valheim_launcher_proxmox',
      http.Client? client})
      : _http = client ?? http.Client();

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'valheim-launcher-updater',
  };

  /// The newest published release, or null when GitHub is unreachable or the
  /// repository has none yet. Never throws: no network must not stop the game
  /// from starting.
  Future<EngineRelease?> latest() async {
    try {
      final r = await _http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final assets = (j['assets'] as List?) ?? const [];
      final asset = assets.cast<Map<String, dynamic>>().firstWhere(
            (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.zip'),
            orElse: () => const {},
          );
      if (asset.isEmpty) return null;
      return EngineRelease(
        tag: (j['tag_name'] as String? ?? '').trim(),
        notes: j['body'] as String? ?? '',
        assetName: asset['name'] as String,
        assetUrl: asset['browser_download_url'] as String,
        size: (asset['size'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads the release archive to [target].
  Future<bool> download(EngineRelease release, String target,
      {void Function(int received, int total)? onProgress}) async {
    try {
      final resp = await _http
          .send(http.Request('GET', Uri.parse(release.assetUrl))..followRedirects = true);
      if (resp.statusCode != 200) return false;
      final out = File(target);
      await out.parent.create(recursive: true);
      final sink = out.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, release.size);
        }
      } finally {
        await sink.close();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close();
}

class EngineRelease {
  final String tag;
  final String notes;
  final String assetName;
  final String assetUrl;
  final int size;

  const EngineRelease({
    required this.tag,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.size,
  });

  /// True when this release is newer than [current] ("v1.4.2" style, and a plain
  /// "1.4.2" compares the same). An unparseable version is treated as older, so
  /// a broken local version.txt results in an update rather than a stuck client.
  bool isNewerThan(String current) {
    final a = _parts(tag), b = _parts(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int> _parts(String v) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
    if (m == null) return [0, 0, 0];
    return [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
  }
}
