import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server_launcher/services/panel_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Signed by the panel's own Python code (app._manifest_key), so this checks that the two
// implementations agree, not just that Dart agrees with itself.
const key = 'GLudaW5WazZzpDMPkT6s6GbbIyZepns21QzBzl+Jn1Y=';
final body = base64.decode('eyJmaWxlcyI6W3sicGF0aCI6InBsdWdpbnMvYS5kbGwiLCJzaXplIjoxLCJzaGEyNTYiOiJ4In1dfQ==');
const sig = 'Q0C0laV1qa4eORpPThmo/eGWVNjCc8nF5e9m7leGojjxxMIrtb+8SnN3TkJMIaiGuSX3e0wKLmXBxrV5Rz+vCQ==';

http.Client panel(List<int> bytes, {String? signature, String? offered}) =>
    MockClient((_) async => http.Response.bytes(bytes, 200, headers: {
          if (signature != null) 'x-manifest-signature': signature,
          if (offered != null) 'x-manifest-key': offered,
        }));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('paths stay inside BepInEx', () {
    for (final ok in ['plugins/a.dll', 'config/x.cfg', 'plugins/Sub Dir/b.dll', 'core/BepInEx.dll']) {
      expect(PanelFile.isSafePath(ok), isTrue, reason: ok);
    }
    for (final bad in [
      '../../../../.bashrc', 'plugins/../../x', '..\\..\\Startup\\x.exe', '/etc/passwd',
      '\\\\server\\share\\x', 'C:/Windows/x', 'C:\\x', '', '.', 'plugins/./x', 'a\u0000b',
    ]) {
      expect(PanelFile.isSafePath(bad), isFalse, reason: bad);
    }
    expect(() => PanelFile.fromJson({'path': '../../x'}), throwsA(isA<UnsafePathException>()));
  });

  test('a manifest signed by the panel verifies, a changed one does not', () async {
    expect(await PanelClient.verifyManifest(body, sig, key), isTrue);
    final changed = [...body]..[5] ^= 1;
    expect(await PanelClient.verifyManifest(changed, sig, key), isFalse);
    expect(await PanelClient.verifyManifest(body, 'garbage', key), isFalse);
  });

  test('with a key in the config, an unsigned or re-signed manifest is refused', () async {
    final good = PanelClient('http://p', client: panel(body, signature: sig), manifestKey: key);
    expect((await good.manifest()).files.single.path, 'plugins/a.dll');
    final unsigned = PanelClient('http://p', client: panel(body), manifestKey: key);
    expect(unsigned.manifest(), throwsA(isA<ManifestSignatureException>()));
    final tampered = PanelClient('http://p',
        client: panel(utf8.encode('{"files":[]}'), signature: sig), manifestKey: key);
    expect(tampered.manifest(), throwsA(isA<ManifestSignatureException>()));
  });

  test('without a key: the first key seen is pinned and held to', () async {
    final first = PanelClient('http://p', client: panel(body, signature: sig, offered: key));
    await first.manifest();
    // later, someone on the path answers unsigned - refused, the key was pinned
    final later = PanelClient('http://p', client: panel(body));
    expect(later.manifest(), throwsA(isA<ManifestSignatureException>()));
  });

  test('the background is fetched only from the panel itself', () async {
    final hits = <Uri>[];
    final c = PanelClient('http://panel.lan:2460',
        client: MockClient((r) async { hits.add(r.url); return http.Response.bytes([1, 2, 3], 200); }));
    final d = Directory.systemTemp.createTempSync('bg').path;
    expect(await c.syncBackground('https://evil.example/x.png', '$d/bg', '$d/bg.stamp', 's1'), isFalse);
    expect(hits, isEmpty);
    expect(await c.syncBackground('/api/launcher/background?v=1', '$d/bg', '$d/bg.stamp', 's2'), isTrue);
    expect(hits.single.host, 'panel.lan');
  });

  test('an old panel that signs nothing still works for an old launcher', () async {
    final old = PanelClient('http://p', client: panel(body));
    expect((await old.manifest()).files.length, 1);
  });
}
