import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' as cg;
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
/// The project's release keys (ed25519): the working one and a backup kept offline. Every
/// release asset has a `.sig` made on the maintainer's machine - the private halves are not
/// on GitHub - and a download no trusted key signed is thrown away. The repository comes
/// from the server's config, so without this a server (or anyone who got hold of the GitHub
/// account) could hand every player any program it liked as an "update".
const releaseKeys = [
  'WwQ2bZrUDQpTQhWzJgT4ojDUo5DXnHi8DuXvTRBZgX0=',
  '649uL/TAv45znSgfclQMBTS3IhUV45Fh3ax2vsYaRDA=',
];

/// A release may carry release-keys.txt (+ .sig by a key trusted now); from then on that
/// list replaces the built-in pair - how a lost or leaked key is swapped out without every
/// player reinstalling. Kept per user, next to the launcher's other data.
String Function() releaseKeysFile = () {
  final env = Platform.environment;
  final base = Platform.isWindows
      ? (env['APPDATA'] ?? env['LOCALAPPDATA'] ?? Directory.systemTemp.path)
      : Platform.isMacOS
          ? '${env['HOME']}/Library/Application Support'
          : (env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share');
  return '$base${Platform.pathSeparator}schron_twarda_launcher${Platform.pathSeparator}release-keys.txt';
};

final _keyLine = RegExp(r'^[A-Za-z0-9+/]{43}=$');

List<String> trustedKeys() {
  try {
    final keys = File(releaseKeysFile())
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    if (keys.isNotEmpty && keys.every(_keyLine.hasMatch)) return keys;
  } catch (_) {}
  return releaseKeys;
}

Future<bool> verifyRelease(List<int> data, String sigB64, {List<String>? keys}) async {
  final List<int> sig;
  try {
    sig = base64.decode(sigB64.trim());
  } catch (_) {
    return false;
  }
  for (final k in keys ?? trustedKeys()) {
    try {
      final key = cg.SimplePublicKey(base64.decode(k), type: cg.KeyPairType.ed25519);
      if (await cg.Ed25519().verify(data, signature: cg.Signature(sig, publicKey: key))) return true;
    } catch (_) {}
  }
  return false;
}

class GithubEngine {
  /// owner/name of the engine repository.
  final String repo;
  final http.Client _http;

  GithubEngine({this.repo = 'PawelSzymanski89/valheim_launcher_proxmox',
      http.Client? client})
      : _http = client ?? http.Client();

  /// Release assets are named per platform (`launcher-windows.zip`,
  /// `launcher-macos.zip`, `launcher-linux.zip`), so a client only ever fetches
  /// the build it can actually run.
  static String platformAsset(String module) {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';
    return '$module-$os';
  }

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'valheim-launcher-updater',
  };

  /// The newest published release, or null when GitHub is unreachable or the
  /// repository has none yet. Never throws: no network must not stop the game
  /// from starting.
  ///
  /// A release carries one zip per module (launcher.zip, updater.zip) - pass
  /// [asset] to pick the right one; without it the first zip wins.
  Future<EngineRelease?> latest({String? asset}) async {
    try {
      final r = await _http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final zips = ((j['assets'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.zip'));
      final wanted = asset == null
          ? zips
          : zips.where((a) =>
              (a['name'] as String).toLowerCase().contains(asset.toLowerCase()));
      final found = (wanted.isNotEmpty ? wanted : zips).toList();
      final Map<String, dynamic> chosen = found.isNotEmpty ? found.first : const {};
      if (chosen.isEmpty) return null;
      return EngineRelease(
        tag: (j['tag_name'] as String? ?? '').trim(),
        notes: j['body'] as String? ?? '',
        assetName: chosen['name'] as String,
        assetUrl: chosen['browser_download_url'] as String,
        size: (chosen['size'] as num?)?.toInt() ?? 0,
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
      final sig = await _http.get(Uri.parse('${release.assetUrl}.sig'));
      if (sig.statusCode != 200 || !await verifyRelease(await out.readAsBytes(), sig.body)) {
        await out.delete();
        return false;
      }
      await _takeKeyList(release);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A new key list from the same release, if it has one signed by a key trusted now.
  Future<void> _takeKeyList(EngineRelease release) async {
    try {
      final dir = release.assetUrl.substring(0, release.assetUrl.lastIndexOf('/'));
      final list = await _http.get(Uri.parse('$dir/release-keys.txt'));
      if (list.statusCode != 200) return;
      final sig = await _http.get(Uri.parse('$dir/release-keys.txt.sig'));
      if (sig.statusCode != 200 || !await verifyRelease(list.bodyBytes, sig.body)) return;
      final keys = utf8.decode(list.bodyBytes).split('\n').map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
      if (keys.isEmpty || !keys.every(_keyLine.hasMatch)) return;
      final f = File(releaseKeysFile());
      await f.parent.create(recursive: true);
      await f.writeAsString('${keys.join('\n')}\n');
    } catch (_) {}
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
