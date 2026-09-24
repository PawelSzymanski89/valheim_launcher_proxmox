import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server_launcher/services/github_engine.dart';
import 'dart:io';
import 'package:cryptography/cryptography.dart' as cg;

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

  group('key rotation', () {
    late Directory dir;
    Future<(cg.SimpleKeyPair, String)> kp() async {
      final k = await cg.Ed25519().newKeyPair();
      return (k, base64.encode((await k.extractPublicKey()).bytes));
    }
    Future<String> sign(cg.SimpleKeyPair k, List<int> d) async =>
        base64.encode((await cg.Ed25519().sign(d, keyPair: k)).bytes);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('keys');
      releaseKeysFile = () => '${dir.path}/release-keys.txt';
    });

    test('any key in the list verifies; the stored list replaces the built-in pair', () async {
      final (a, aPub) = await kp();
      final (b, bPub) = await kp();
      expect(await verifyRelease(data, await sign(b, data), keys: [aPub, bPub]), isTrue);
      expect(await verifyRelease(data, await sign(a, data), keys: [bPub]), isFalse);
      expect(trustedKeys(), releaseKeys, reason: 'no stored list: the built-in pair');
      File(releaseKeysFile()).writeAsStringSync('# rotated\n$aPub\n');
      expect(trustedKeys(), [aPub]);
      expect(await verifyRelease(data, sig), isFalse, reason: 'a removed built-in key still verified');
      File(releaseKeysFile()).writeAsStringSync('not a key\n');
      expect(trustedKeys(), releaseKeys, reason: 'a damaged list must not lock the launcher out');
    });

    test('a key list from a release is taken only when a trusted key signed it', () async {
      final (trusted, trustedPub) = await kp();
      final (stranger, _) = await kp();
      final (_, nextPub) = await kp();
      File(releaseKeysFile()).writeAsStringSync('$trustedPub\n');
      final zip = utf8.encode('zip');
      final list = utf8.encode('$nextPub\n$trustedPub\n');
      Future<bool> offer(cg.SimpleKeyPair listSigner) async {
        final zipSig = await sign(trusted, zip), listSig = await sign(listSigner, list);
        final e = GithubEngine(client: MockClient((r) async {
          final p = r.url.path;
          if (p.endsWith('release-keys.txt')) return http.Response.bytes(list, 200);
          if (p.endsWith('release-keys.txt.sig')) return http.Response(listSig, 200);
          if (p.endsWith('.zip.sig')) return http.Response(zipSig, 200);
          return http.Response.bytes(zip, 200);
        }));
        return e.download(EngineRelease(tag: 'v1', notes: '', assetName: 'l.zip',
            assetUrl: 'https://x/download/v1/l.zip', size: zip.length), '${dir.path}/l.zip');
      }
      expect(await offer(stranger), isTrue, reason: 'the zip itself was fine');
      expect(trustedKeys(), [trustedPub], reason: 'took a key list signed by a stranger');
      expect(await offer(trusted), isTrue);
      expect(trustedKeys(), [nextPub, trustedPub], reason: 'did not take a properly signed key list');
    });
  });
}
