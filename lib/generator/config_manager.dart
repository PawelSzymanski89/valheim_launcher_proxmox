import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../utils/crypto_service.dart';
import '../utils/profile_service.dart';

/// Model pełnej konfiguracji generatora.
class GeneratorConfig {
  // Step 1: Branding
  String serverName;        // "Moja Baza" → "Moja Baza Launcher.exe"
  String backgroundPath;   // Lokalna ścieżka do PNG/MP4

  // Step 2: Serwer
  String serverAddr;        // "192.168.1.100:2456"
  String serverPassword;

  // Step 3: Panel (fork: HTTPS zamiast FTP; pola ftp zostają dla zgodności profili)
  String panelUrl;         // "https://valheim.klans.eu"
  String engineRepo;       // "owner/repo"; puste = domyślne repo silnika
  String ftpHost;
  int ftpPort;
  String ftpUser;
  String ftpPassword;

  // Step 4: Salt
  String salt;
  bool saveSalt;

  GeneratorConfig({
    this.serverName = '',
    this.backgroundPath = '',
    this.serverAddr = '',
    this.serverPassword = '',
    this.panelUrl = '',
    this.engineRepo = '',
    this.ftpHost = '',
    this.ftpPort = 2022,
    this.ftpUser = '',
    this.ftpPassword = '',
    this.salt = '',
    this.saveSalt = true,
  });

  bool get isStep1Valid => serverName.isNotEmpty;
  bool get isStep2Valid => serverAddr.isNotEmpty;
  bool get isStep3Valid => panelUrl.trim().startsWith('http');
  bool get isStep4Valid => salt.length >= 30 && saveSalt;

  /// Zwraca zaszyfrowany JSON config do wbudowania w launcher/patcher/updater.
  String toEncryptedJson() {
    final plain = jsonEncode({
      'serverName': serverName,
      'serverAddr': serverAddr,
      'serverPassword': serverPassword,
      'ftpHost': ftpHost,
      'ftpPort': ftpPort,
      'ftpUser': ftpUser,
      'ftpPassword': ftpPassword,
      'panelUrl': panelUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      'engineRepo': engineRepo.trim(),
    });
    return CryptoService.encrypt(plain, salt);
  }
}

/// Provider stanu wizarda.
class GeneratorProvider extends ChangeNotifier {
  final config = GeneratorConfig();
  int currentStep = 0;
  bool isGenerating = false;
  int profileVersion = 0; // incremented on profile load → forces step widgets to re-init controllers
  String? lastError;
  String? outputPath;

  /// Publiczna metoda do powiadamiania listenerów z widget child.
  void notify() => notifyListeners();

  void nextStep() {
    if (currentStep < 3) {
      currentStep++;
      notifyListeners();
    }
  }

  void prevStep() {
    if (currentStep > 0) {
      currentStep--;
      notifyListeners();
    }
  }

  void setGenerating(bool v) {
    isGenerating = v;
    notifyListeners();
  }

  void setOutput(String? path) {
    outputPath = path;
    notifyListeners();
  }

  void setError(String? e) {
    lastError = e;
    notifyListeners();
  }

  /// Loads non-sensitive fields from a profile into the config.
  /// Passwords and salt are intentionally NOT stored in profiles.
  void loadFromProfile(ServerProfile profile) {
    config.serverName = profile.serverName;
    config.serverAddr = profile.serverAddr;
    config.serverPassword = profile.serverPassword;
    config.ftpHost = profile.ftpHost;
    config.ftpPort = profile.ftpPort;
    config.ftpUser = profile.ftpUser;
    config.ftpPassword = profile.ftpPassword;
    config.panelUrl = profile.panelUrl;
    config.engineRepo = profile.engineRepo;
    config.backgroundPath = profile.backgroundPath;
    if (profile.salt.isNotEmpty) config.salt = profile.salt;
    profileVersion++;
    currentStep = 0;
    notifyListeners();
  }
}
