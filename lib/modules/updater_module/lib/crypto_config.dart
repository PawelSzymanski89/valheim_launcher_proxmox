import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;

// APP_SECRET injected at compile time via --dart-define=APP_SECRET=...
const _kAppSecret = String.fromEnvironment('APP_SECRET');

Uint8List _keyStream(String salt, int length) {
  final saltBytes = utf8.encode(salt);
  final result = <int>[];
  int block = 1;
  while (result.length < length) {
    final blockBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, block, Endian.big);
    var u = Uint8List.fromList(
        Hmac(sha256, saltBytes).convert([...saltBytes, ...blockBytes]).bytes);
    final xored = Uint8List.fromList(u);
    for (int i = 1; i < 1; i++) {
      u = Uint8List.fromList(Hmac(sha256, saltBytes).convert(u).bytes);
      for (int j = 0; j < xored.length; j++) {
        xored[j] ^= u[j];
      }
    }
    result.addAll(xored);
    block++;
  }
  return Uint8List.fromList(result.sublist(0, length));
}

String _xorDecrypt(String ciphertext, String salt) {
  final combined = base64.decode(ciphertext);
  final iv = combined.sublist(0, 16);
  final encrypted = combined.sublist(16);
  final saltWithIv = '$salt-${base64.encode(iv)}';
  final keyStream = _keyStream(saltWithIv, encrypted.length);
  final decrypted = Uint8List(encrypted.length);
  for (int i = 0; i < encrypted.length; i++) {
    decrypted[i] = encrypted[i] ^ keyStream[i];
  }
  return utf8.decode(decrypted);
}

/// Reads manifest.sig (encrypted), decrypts with APP_SECRET → real salt.
Future<String?> loadSalt() async {
  try {
    final encryptedSalt = await rootBundle.loadString('assets/manifest.sig');
    final trimmed = encryptedSalt.trim();
    if (trimmed.isEmpty || trimmed == 'PLACEHOLDER') return null;
    return _xorDecrypt(trimmed, _kAppSecret);
  } catch (_) {
    return null;
  }
}

String cryptoDecrypt(String ciphertext, String salt) =>
    _xorDecrypt(ciphertext, salt);

class DecryptedConfig {
  final String serverName;
  final String serverAddr;
  final String serverPassword;
  final String ftpHost;
  final int ftpPort;
  final String ftpUser;
  final String ftpPassword;

  /// Panel address, e.g. https://valheim.klans.eu. When set the launcher build
  /// comes from the engine repo's GitHub releases and the ftp fields are
  /// ignored - they stay so a config from the upstream generator still loads.
  final String panelUrl;

  /// Engine repository for updates, owner/name. Empty falls back to the
  /// fork's own default.
  final String engineRepo;

  const DecryptedConfig({
    required this.serverName,
    required this.serverAddr,
    required this.serverPassword,
    required this.ftpHost,
    required this.ftpPort,
    required this.ftpUser,
    required this.ftpPassword,
    this.panelUrl = '',
    this.engineRepo = '',
  });

  /// True when this server is served by a panel rather than an FTP account.
  bool get usesPanel => panelUrl.trim().isNotEmpty;

  factory DecryptedConfig.fromJson(Map<String, dynamic> j) => DecryptedConfig(
        serverName: j['serverName'] as String? ?? '',
        serverAddr: j['serverAddr'] as String? ?? '',
        serverPassword: j['serverPassword'] as String? ?? '',
        ftpHost: j['ftpHost'] as String? ?? '',
        ftpPort: (j['ftpPort'] as num?)?.toInt() ?? 21,
        ftpUser: j['ftpUser'] as String? ?? '',
        ftpPassword: j['ftpPassword'] as String? ?? '',
        panelUrl: j['panelUrl'] as String? ?? '',
        engineRepo: j['engineRepo'] as String? ?? '',
      );
}

Future<DecryptedConfig?> loadDecryptedConfig() async {
  try {
    final salt = await loadSalt();
    if (salt == null || salt.isEmpty) return null;
    final raw = await rootBundle.loadString('assets/config_encrypted.json');
    final map = json.decode(raw) as Map<String, dynamic>;
    final ciphertext = map['data'] as String;
    if (ciphertext == 'PLACEHOLDER_REPLACE_BY_GENERATOR') return null;
    final plainJson = cryptoDecrypt(ciphertext, salt);
    final decoded = json.decode(plainJson) as Map<String, dynamic>;
    return DecryptedConfig.fromJson(decoded);
  } catch (_) {
    return null;
  }
}
