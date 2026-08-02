import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config_manager.dart';
import '../../utils/lang_provider.dart';

/// Fork: krok 3 zbiera adres panelu zamiast konta FTP.
/// Launcher rozmawia z panelem po HTTPS, a aktualizacje silnika idą z GitHuba,
/// więc jedyne, co trzeba zapiec w binarkę, to te dwa adresy.
class Step3Ftp extends StatefulWidget {
  const Step3Ftp({super.key});
  @override
  State<Step3Ftp> createState() => _Step3FtpState();
}

class _Step3FtpState extends State<Step3Ftp> {
  late TextEditingController _panelCtrl;
  late TextEditingController _repoCtrl;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<GeneratorProvider>().config;
    _panelCtrl = TextEditingController(text: cfg.panelUrl);
    _repoCtrl = TextEditingController(text: cfg.engineRepo);
  }

  @override
  void dispose() {
    _panelCtrl.dispose();
    _repoCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final url = _panelCtrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    setState(() { _testing = true; _testResult = null; });
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse('$url/api/launcher/manifest'));
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final files = ((json.decode(body) as Map<String, dynamic>)['files'] as List?)?.length ?? 0;
          setState(() { _testOk = true; _testResult = '✓ OK ($files ${_plFiles(files)})'; });
        } else if (resp.statusCode == 404) {
          // Panel odpowiada, launcher tylko wyłączony w zakładce — to nie błąd.
          setState(() { _testOk = true; _testResult = '✓ 404 (launcher off)'; });
        } else {
          setState(() { _testOk = false; _testResult = '✗ HTTP ${resp.statusCode}'; });
        }
      } finally {
        client.close();
      }
    } catch (e) {
      setState(() { _testOk = false; _testResult = '✗ $e'; });
    } finally {
      setState(() => _testing = false);
    }
  }

  String _plFiles(int n) => n == 1 ? 'file' : 'files';

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<GeneratorProvider>();
    final lang = context.watch<LangProvider>();
    final cfg = prov.config;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(lang.t('panel_url')),
      const SizedBox(height: 8),
      _field(_panelCtrl, lang.t('panel_url_hint'), (v) { cfg.panelUrl = v; prov.notify(); }),
      const SizedBox(height: 16),
      _label(lang.t('engine_repo')),
      const SizedBox(height: 8),
      _field(_repoCtrl, lang.t('engine_repo_hint'), (v) { cfg.engineRepo = v; prov.notify(); }),
      const SizedBox(height: 8),
      Text(lang.t('engine_repo_note'),
          style: const TextStyle(color: Colors.white38, fontSize: 12)),
      const SizedBox(height: 20),
      Row(children: [
        ElevatedButton.icon(
          onPressed: _testing || !cfg.isStep3Valid ? null : _testConnection,
          icon: _testing
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.wifi_tethering, size: 18),
          label: Text(_testing ? lang.t('testing') : lang.t('test_conn')),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        if (_testResult != null) ...[
          const SizedBox(width: 14),
          Flexible(child: Text(_testResult!,
              style: TextStyle(
                color: _testOk ? Colors.greenAccent.shade400 : Colors.redAccent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ))),
        ],
      ]),
    ]);
  }

  Widget _label(String t) => Text(t,
      style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600));

  InputDecoration _deco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white12)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white12)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.blueAccent.shade400)),
  );

  Widget _field(TextEditingController ctrl, String hint, void Function(String) onChange) =>
    TextField(
      controller: ctrl,
      onChanged: onChange,
      style: const TextStyle(color: Colors.white),
      decoration: _deco(hint),
    );
}
