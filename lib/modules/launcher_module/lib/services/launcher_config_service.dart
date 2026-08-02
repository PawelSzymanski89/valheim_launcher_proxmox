import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'crypto_config.dart' as cc;
import 'panel_client.dart';

/// Configuration model for launcher settings
class LauncherConfig {
  final String serverName;
  final String serverAddress;
  final int serverPort;
  final String serverPassword;

  /// Set in panel mode - widgets use it to ask the panel instead of A2S.
  final String? panelUrl;

  const LauncherConfig({
    required this.serverName,
    required this.serverAddress,
    required this.serverPort,
    required this.serverPassword,
    this.panelUrl,
  });

  factory LauncherConfig.fromJson(Map<String, dynamic> json) {
    return LauncherConfig(
      serverName: json['server_name'] as String? ?? '',
      serverAddress: json['server_address'] as String? ?? '',
      serverPort: json['server_port'] as int? ?? 2456,
      serverPassword: json['server_password'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'server_name': serverName,
      'server_address': serverAddress,
      'server_port': serverPort,
      'server_password': serverPassword,
    };
  }

  factory LauncherConfig.defaults() {
    return const LauncherConfig(
      serverName: '',
      serverAddress: '',
      serverPort: 2456,
      serverPassword: '',
    );
  }
}

class LauncherConfigService {
  // loadConfig is called from several widgets on startup - one manifest fetch
  // serves them all for a while.
  static PanelManifest? _manifestCache;
  static DateTime? _manifestAt;

  Future<PanelManifest?> _panelManifest(String panelUrl) async {
    final now = DateTime.now();
    if (_manifestCache != null &&
        _manifestAt != null &&
        now.difference(_manifestAt!) < const Duration(seconds: 30)) {
      return _manifestCache;
    }
    final client = PanelClient(panelUrl);
    try {
      _manifestCache = await client.manifest()
          .timeout(const Duration(seconds: 6));
      _manifestAt = now;
      return _manifestCache;
    } catch (_) {
      return _manifestCache; // stale beats nothing; null on first failure
    } finally {
      client.close();
    }
  }

  // Encryption key derived from app-specific data
  static const String _encryptionSalt = 'ValheimLauncher2024';
  
  /// Simple XOR encryption/decryption
  Uint8List _xorCipher(Uint8List data, String key) {
    final keyBytes = utf8.encode(key);
    final result = Uint8List(data.length);
    
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ keyBytes[i % keyBytes.length];
    }
    
    return result;
  }
  
  /// Encrypt config data
  String _encryptConfig(String jsonString) {
    try {
      // Generate encryption key from salt
      final keyHash = sha256.convert(utf8.encode(_encryptionSalt));
      final key = base64.encode(keyHash.bytes);
      
      // Encrypt using XOR
      final dataBytes = utf8.encode(jsonString);
      final encrypted = _xorCipher(Uint8List.fromList(dataBytes), key);
      
      // Encode to base64 for storage
      return base64.encode(encrypted);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherConfigService] Encryption error: $e');
      }
      rethrow;
    }
  }
  
  /// Decrypt config data
  String _decryptConfig(String encryptedData) {
    try {
      // Generate encryption key from salt
      final keyHash = sha256.convert(utf8.encode(_encryptionSalt));
      final key = base64.encode(keyHash.bytes);
      
      // Decode from base64
      final encrypted = base64.decode(encryptedData);
      
      // Decrypt using XOR
      final decrypted = _xorCipher(encrypted, key);
      
      // Convert back to string
      return utf8.decode(decrypted);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherConfigService] Decryption error: $e');
      }
      rethrow;
    }
  }

  /// Loads launcher configuration.
  /// Priority:
  ///   1. Encrypted config (manifest.sig + config_encrypted.json) — always used if manifest.sig present.
  ///   2. Legacy launcher_config.json — only when manifest.sig is absent (old installs).
  ///   3. Defaults (empty)
  Future<LauncherConfig> loadConfig() async {
    // Detect if this is a generator-built launcher (has manifest.sig)
    final hasManifest = await _hasManifestSig();

    // 0) Panel mode: the manifest is the truth. The name is set in the panel's
    //    Settings, the address follows DDNS - both change without rebuilding
    //    anything, so the baked values only break the tie when the panel is
    //    unreachable.
    try {
      final decrypted = await cc.loadDecryptedConfig();
      if (decrypted != null && decrypted.usesPanel) {
        final manifest = await _panelManifest(decrypted.panelUrl);
        if (manifest != null) {
          return LauncherConfig(
            serverName: manifest.serverName.isNotEmpty
                ? manifest.serverName
                : decrypted.serverName,
            serverAddress:
                manifest.serverAddress ?? Uri.parse(decrypted.panelUrl).host,
            serverPort: manifest.serverPort,
            serverPassword: decrypted.serverPassword,
            panelUrl: decrypted.panelUrl,
          );
        }
        return LauncherConfig(
          serverName: decrypted.serverName,
          serverAddress: Uri.parse(decrypted.panelUrl).host,
          serverPort: decrypted.serverPort,
          serverPassword: decrypted.serverPassword,
          panelUrl: decrypted.panelUrl,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LauncherConfigService] panel config failed: $e');
    }

    // 1) Try generated encrypted config
    try {
      final decrypted = await cc.loadDecryptedConfig();
      if (decrypted != null && decrypted.serverName.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('[LauncherConfigService] Loaded encrypted config: ${decrypted.serverName} addr=${decrypted.serverAddr}');
        }
        // serverAddr may be "hostname:port" — split into host and port
        final addr = decrypted.serverAddr.trim();
        final colonIdx = addr.lastIndexOf(':');
        String host;
        int port;
        if (colonIdx > 0) {
          host = addr.substring(0, colonIdx);
          port = int.tryParse(addr.substring(colonIdx + 1)) ?? decrypted.serverPort;
        } else {
          host = addr;
          port = decrypted.serverPort;
        }
        return LauncherConfig(
          serverName: decrypted.serverName,
          serverAddress: host,
          serverPort: port,
          serverPassword: decrypted.serverPassword,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LauncherConfigService] loadDecryptedConfig failed: $e');
    }

    // If manifest.sig is present but decryption failed → don't fall back to stale cache.
    // Return empty defaults so the user sees a blank config, not someone else's server name.
    if (hasManifest) {
      if (kDebugMode) debugPrint('[LauncherConfigService] manifest.sig present but decryption failed — returning defaults');
      return LauncherConfig.defaults();
    }

    // 2) Fallback: legacy launcher_config.json next to exe
    try {
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      final configPath = p.join(exeDir, 'launcher_config.json');
      final configFile = File(configPath);

      if (kDebugMode) {
        debugPrint('[LauncherConfigService] Loading fallback from: $configPath');
      }

      if (await configFile.exists()) {
        final encryptedContent = await configFile.readAsString();
        try {
          final decryptedContent = _decryptConfig(encryptedContent);
          final json = jsonDecode(decryptedContent) as Map<String, dynamic>;
          final config = LauncherConfig.fromJson(json);
          if (kDebugMode) debugPrint('[LauncherConfigService] Loaded legacy encrypted config');
          return config;
        } catch (_) {
          // Try plain JSON migration
          try {
            final json = jsonDecode(encryptedContent) as Map<String, dynamic>;
            final config = LauncherConfig.fromJson(json);
            await _saveConfig(configFile, config);
            return config;
          } catch (_) {}
        }
      } else {
        // Create empty defaults file
        final defaultConfig = LauncherConfig.defaults();
        await _saveConfig(configFile, defaultConfig);
        return defaultConfig;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LauncherConfigService] Fallback config error: $e');
    }

    return LauncherConfig.defaults();
  }

  /// Saves configuration to file (encrypted)
  Future<void> _saveConfig(File configFile, LauncherConfig config) async {
    try {
      final json = config.toJson();
      final jsonString = const JsonEncoder.withIndent('  ').convert(json);
      
      // Encrypt the JSON
      final encrypted = _encryptConfig(jsonString);
      
      // Save encrypted data
      await configFile.writeAsString(encrypted);
      
      if (kDebugMode) {
        debugPrint('[LauncherConfigService] Encrypted config saved to: ${configFile.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LauncherConfigService] Error saving config: $e');
      }
    }
  }

  /// Validates server address (basic domain/IP check)
  bool isValidAddress(String address) {
    if (address.isEmpty) return false;
    // Allow domain names (letters, numbers, dots, hyphens) or IP addresses
    final domainRegex = RegExp(r'^[a-zA-Z0-9.-]+$');
    return domainRegex.hasMatch(address);
  }

  /// Validates server port (1-65535)
  bool isValidPort(int port) {
    return port >= 1 && port <= 65535;
  }

  /// Returns true if assets/manifest.sig is present and contains real data
  /// (i.e. this launcher was built by the generator, not an old manual install).
  Future<bool> _hasManifestSig() async {
    try {
      final raw = await rootBundle.loadString('assets/manifest.sig');
      final trimmed = raw.trim();
      return trimmed.isNotEmpty && trimmed != 'PLACEHOLDER';
    } catch (_) {
      return false;
    }
  }
}

