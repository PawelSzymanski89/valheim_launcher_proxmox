import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server_launcher/services/github_engine.dart';
import 'dart:io';

// Signed with scripts/sign-release.py and the real release key.
final data = utf8.encode('launcher zip bytes');
const sig = 'qo4VtUi+Ahc1czoQsDbrvanarG0xsvdm/lN/CopwKNojLk3lDmhEe2JciDf1zb/a8+T67B65cW9s5C/1YgNBDA==';

void main() {
  test('a release file signed with the project key verifies', () async {
    expect(await verifyRelease(data, sig), isTrue);
    expect(await verifyRelease(data, '$sig\n'), isTrue);
  });
  test('a changed file, a foreign signature or garbage does not', () async {
    expect(await verifyRelease(utf8.encode('launcher zip byteS'), sig), isFalse);
    expect(await verifyRelease(data, base64.encode(List.filled(64, 1))), isFalse);
    expect(await verifyRelease(data, 'not base64 at all'), isFalse);
  });
  test('download keeps a verified file and throws away an unverified one', () async {
    final dir = Directory.systemTemp.createTempSync('eng');
    EngineRelease rel(String name) => EngineRelease(
        tag: 'v1', notes: '', assetName: name, assetUrl: 'https://x/$name', size: data.length);
    http.Client serve(String s) => MockClient((r) async => r.url.path.endsWith('.sig')
        ? http.Response(s, 200)
        : http.Response.bytes(data, 200));
    final good = GithubEngine(client: serve(sig));
    expect(await good.download(rel('a.zip'), '${dir.path}/a.zip'), isTrue);
    expect(File('${dir.path}/a.zip').existsSync(), isTrue);
    final bad = GithubEngine(client: serve(base64.encode(List.filled(64, 7))));
    expect(await bad.download(rel('b.zip'), '${dir.path}/b.zip'), isFalse);
    expect(File('${dir.path}/b.zip').existsSync(), isFalse);
    final missing = GithubEngine(client: MockClient((r) async => r.url.path.endsWith('.sig')
        ? http.Response('', 404) : http.Response.bytes(data, 200)));
    expect(await missing.download(rel('c.zip'), '${dir.path}/c.zip'), isFalse);
  });
}
