import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'config_manager.dart';
import 'steps/step1_branding.dart';
import 'steps/step2_server.dart';
import 'steps/step3_ftp.dart';
import 'steps/step4_salt.dart';
import '../utils/lang_provider.dart';
import '../utils/profile_service.dart';
import '../build_service.dart';

class WizardPage extends StatelessWidget {
  const WizardPage({super.key});

  static const _stepIcons = [
    Icons.palette_outlined,
    Icons.dns_outlined,
    Icons.storage_outlined,
    Icons.lock_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<GeneratorProvider>();
    final lang = context.watch<LangProvider>();
    final step = prov.currentStep;

    final stepTitles = [
      lang.t('step1_title'),
      lang.t('step2_title'),
      lang.t('step3_title'),
      lang.t('step4_title'),
    ];
    final stepSubs = [
      lang.t('step1_sub'),
      lang.t('step2_sub'),
      lang.t('step3_sub'),
      lang.t('step4_sub'),
    ];

    return Scaffold(
      body: Stack(children: [
        // ── Background gradient ──────────────────────────────────────
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0A0A0F), Color(0xFF12100A), Color(0xFF0D0A00)],
            ),
          ),
        ),
        CustomPaint(painter: _GridPainter(), size: Size.infinite),

        // ── Main layout ──────────────────────────────────────────────
        Row(children: [
          _Sidebar(step: step, stepTitles: stepTitles, stepIcons: _stepIcons, lang: lang),
          Expanded(
            child: Column(children: [
              _TopBar(step: step, subtitle: stepSubs[step], lang: lang),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(40),
                  child: _buildStepContent(step, prov.profileVersion),
                ),
              ),
              _BottomBar(step: step, prov: prov, lang: lang),
            ]),
          ),
        ]),
      ]),
    );
  }

  Widget _buildStepContent(int step, int version) {
    return switch (step) {
      0 => Step1Branding(key: ValueKey('s1-$version')),
      1 => Step2Server(key: ValueKey('s2-$version')),
      2 => Step3Ftp(key: ValueKey('s3-$version')),
      3 => Step4Salt(key: ValueKey('s4-$version')),
      _ => const SizedBox.shrink(),
    };
  }
}

// ── Sidebar ──────────────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.step, required this.stepTitles, required this.stepIcons, required this.lang});
  final int step;
  final List<String> stepTitles;
  final List<IconData> stepIcons;
  final LangProvider lang;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xFF2A2010), width: 1)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0B05), Color(0xFF100E08)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 36),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('VALHEIM',
                  style: TextStyle(
                    fontFamily: 'Norse', fontSize: 26, fontWeight: FontWeight.w700,
                    color: Color(0xFFD4A017), letterSpacing: 3,
                  )),
              const Text('LAUNCHER GENERATOR',
                  style: TextStyle(
                    fontFamily: 'Norse', fontSize: 11,
                    color: Color(0xFF8B6914), letterSpacing: 2,
                  )),
              const SizedBox(height: 6),
              Container(height: 1, width: 60, color: const Color(0xFF8B6914)),
            ]),
          ),

          // Steps
          ...List.generate(4, (i) => _StepItem(
            index: i, label: stepTitles[i], icon: stepIcons[i], current: step,
          )),

          const Spacer(),

          // Profiles
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: _ProfileButton(),
          ),

          // Contact
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: _ContactButton(),
          ),

          // Lang toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: _LangToggle(lang: lang),
          ),

          // Version
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Text('v1.0.0',
                style: TextStyle(color: Colors.white24, fontSize: 11, fontFamily: 'Norse')),
          ),
        ],
      ),
    );
  }
}

// ── Language Toggle ──────────────────────────────────────────────
class _LangToggle extends StatelessWidget {
  const _LangToggle({required this.lang});
  final LangProvider lang;

  @override
  Widget build(BuildContext context) {
    final isPl = lang.lang == 'pl';
    return GestureDetector(
      onTap: lang.toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF2A2010)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _LangChip(label: 'PL', active: isPl),
          const SizedBox(width: 6),
          Container(width: 1, height: 14, color: Colors.white12),
          const SizedBox(width: 6),
          _LangChip(label: 'EN', active: !isPl),
        ]),
      ),
    );
  }
}

class _LangChip extends StatelessWidget {
  const _LangChip({required this.label, required this.active});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: TextStyle(
          fontFamily: 'Norse',
          fontSize: 13,
          letterSpacing: 1.5,
          color: active ? const Color(0xFFD4A017) : Colors.white30,
          fontWeight: active ? FontWeight.w700 : FontWeight.normal,
        ));
  }
}

// ── Step Item ────────────────────────────────────────────────────
class _StepItem extends StatelessWidget {
  const _StepItem({required this.index, required this.label, required this.icon, required this.current});
  final int index, current;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDone = index < current;
    final isActive = index == current;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFD4A017).withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isActive ? const Color(0xFFD4A017).withValues(alpha: 0.4) : Colors.transparent,
        ),
      ),
      child: Row(children: [
        Container(
          width: 24, height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone ? const Color(0xFFD4A017) : Colors.transparent,
            border: Border.all(
              color: isDone || isActive ? const Color(0xFFD4A017) : Colors.white24,
              width: 1.5,
            ),
          ),
          child: Center(
            child: isDone
                ? const Icon(Icons.check, size: 13, color: Colors.black)
                : Text('${index + 1}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isActive ? const Color(0xFFD4A017) : Colors.white38,
                      fontFamily: 'Norse',
                    )),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Norse', fontSize: 13, letterSpacing: 1,
                color: isActive ? const Color(0xFFD4A017) : isDone ? Colors.white60 : Colors.white30,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
              )),
        ),
      ]),
    );
  }
}

// ── Top Bar ─────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.subtitle, required this.lang});
  final int step;
  final String subtitle;
  final LangProvider lang;

  @override
  Widget build(BuildContext context) {
    final stepLabel = lang.t('step_of').replaceAll('{n}', '${step + 1}');
    return Container(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF2A2010))),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(stepLabel,
              style: const TextStyle(
                fontFamily: 'Norse', fontSize: 11,
                color: Color(0xFF8B6914), letterSpacing: 3,
              )),
          const SizedBox(height: 4),
          Text(subtitle,
              style: const TextStyle(
                fontFamily: 'Norse', fontSize: 22,
                color: Colors.white, letterSpacing: 1,
              )),
        ]),
        const Spacer(),
        SizedBox(
          width: 160,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${((step + 1) / 4 * 100).round()}%',
                style: const TextStyle(
                    color: Color(0xFFD4A017), fontSize: 12, fontFamily: 'Norse')),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (step + 1) / 4,
                backgroundColor: const Color(0xFF2A2010),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFD4A017)),
                minHeight: 3,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── Bottom Navigation Bar ────────────────────────────────────────
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.step, required this.prov, required this.lang});
  final int step;
  final GeneratorProvider prov;
  final LangProvider lang;

  bool _canProceed() {
    final cfg = prov.config;
    return switch (step) {
      0 => cfg.isStep1Valid,
      1 => cfg.isStep2Valid,
      2 => cfg.isStep3Valid,
      3 => cfg.isStep4Valid,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isLast = step == 3;
    final canProceed = _canProceed();

    return Container(
      padding: const EdgeInsets.fromLTRB(40, 16, 40, 24),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF2A2010))),
      ),
      child: Row(children: [
        if (step > 0)
          OutlinedButton.icon(
            onPressed: prov.isGenerating ? null : prov.prevStep,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: Text(lang.t('back')),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Color(0xFF3A2E1A)),
              textStyle: const TextStyle(fontFamily: 'Norse', fontSize: 13, letterSpacing: 1),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
        const Spacer(),
        if (prov.lastError != null)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('${lang.t('error_prefix')}${prov.lastError}',
                style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontFamily: 'Norse')),
          ),
        if (prov.outputPath != null)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
              const SizedBox(width: 6),
              Text('${lang.t('done_prefix')}${prov.outputPath!.split(r'\').last}',
                  style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 13, fontFamily: 'Norse')),
            ]),
          ),
        ElevatedButton.icon(
          onPressed: (canProceed && !prov.isGenerating)
              ? () => isLast ? _generate(context, prov) : prov.nextStep()
              : null,
          icon: prov.isGenerating
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(isLast ? Icons.build_outlined : Icons.arrow_forward, size: 16),
          label: Text(isLast ? lang.t('generate') : lang.t('next')),
          style: ElevatedButton.styleFrom(
            backgroundColor: canProceed ? const Color(0xFF8B6914) : Colors.white12,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontFamily: 'Norse', fontSize: 14, letterSpacing: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ]),
    );
  }

  Future<void> _generate(BuildContext context, GeneratorProvider prov) async {
    prov.setGenerating(true);
    prov.setError(null);
    prov.setOutput(null);

    // Show live build log dialog
    final logs = <String>[];
    String currentLog = '🚀 Inicjalizacja...';
    double buildProgress = 0.0;
    StateSetter? dialogSetState;

    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setState) {
            dialogSetState = setState;
            return AlertDialog(
              backgroundColor: const Color(0xFF0D0B05),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF2A2010)),
              ),
              title: const Row(children: [
                Icon(Icons.build, color: Color(0xFFD4A017), size: 20),
                SizedBox(width: 8),
                Text('Budowanie...', style: TextStyle(color: Color(0xFFD4A017), fontFamily: 'Norse', fontSize: 18)),
              ]),
              content: SizedBox(
                width: 520,
                height: 320,
                child: Column(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: buildProgress,
                      backgroundColor: const Color(0xFF2A2010),
                      valueColor: const AlwaysStoppedAnimation(Color(0xFFD4A017)),
                      minHeight: 3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF2A2010)),
                      ),
                      child: ListView.builder(
                        reverse: true,
                        itemCount: logs.length,
                        itemBuilder: (_, i) => Text(
                          logs[logs.length - 1 - i],
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(currentLog,
                      style: const TextStyle(
                          color: Color(0xFFD4A017), fontSize: 13, fontFamily: 'Norse')),
                ]),
              ),
            );
          },
        ),
      );
    }

    void updateLog(String msg) {
      logs.add(msg);
      currentLog = msg;
      dialogSetState?.call(() {});
    }

    void updateProgress(double p) {
      buildProgress = p;
      dialogSetState?.call(() {});
    }

    try {
      final cfg = prov.config;

      final svc = BuildService(
        config: cfg,
        onLog: updateLog,
        onProgress: updateProgress,
      );

      final results = await svc.run();
      final allOk = results.isNotEmpty && results.every((r) => r.success);

      // Close build dialog first
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      if (allOk) {
        final outDir = results.first.exePath != null
            ? p.dirname(p.dirname(results.first.exePath!)) // output/{serverName}/
            : null;
        prov.setOutput(results.first.exePath ?? cfg.serverName);
        if (context.mounted) _showSuccessDialog(context, cfg.serverName, outDir);
      } else {
        final errors = results.where((r) => !r.success).map((r) => '${r.moduleName}: ${r.error}').join('\n');
        prov.setError(errors);
        if (context.mounted) _showErrorDialog(context, errors);
      }
    } catch (e) {
      prov.setError('$e');
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) _showErrorDialog(context, '$e');
    } finally {
      prov.setGenerating(false);
    }
  }

  void _showSuccessDialog(BuildContext context, String serverName, String? outDir) {
    showDialog(
      context: context,
      builder: (_) => _SuccessDialog(
        serverName: serverName,
        outDir: outDir,
        buildConfig: context.read<GeneratorProvider>().config,
      ),
    );
  }

  void _showErrorDialog(BuildContext context, String error) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D0B05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFB71C1C), width: 1.5),
        ),
        title: const Row(children: [
          Icon(Icons.error_outline, color: Color(0xFFEF5350), size: 24),
          SizedBox(width: 10),
          Text('Błąd budowania', style: TextStyle(color: Color(0xFFEF5350), fontFamily: 'Norse', fontSize: 20)),
        ]),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: SelectableText(
              error,
              style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace', height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }
}

// ── Success Dialog ────────────────────────────────────────────────
class _SuccessDialog extends StatefulWidget {
  const _SuccessDialog({
    required this.serverName,
    required this.outDir,
    required this.buildConfig,
  });
  final String serverName;
  final String? outDir;
  final GeneratorConfig buildConfig;

  @override
  State<_SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<_SuccessDialog> {
  bool _uploading = false;
  bool _uploadDone = false;
  bool _uploadOk = false;
  final List<String> _uploadLog = [];

  Future<void> _upload() async {
    setState(() {
      _uploading = true;
      _uploadLog.clear();
    });

    final svc = BuildService(
      config: widget.buildConfig,
      onLog: (msg) => setState(() => _uploadLog.add(msg)),
      onProgress: (_) {},
    );

    final result = await svc.uploadToServer();

    setState(() {
      _uploading = false;
      _uploadDone = true;
      _uploadOk = result.success;
      if (!result.success && result.error != null) {
        _uploadLog.add('❌ ${result.error}');
      } else {
        _uploadLog.add('');
        _uploadLog.add('✅ Upload zakończony!');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0B05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFD4A017), width: 1.5),
      ),
      title: const Row(children: [
        Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 24),
        SizedBox(width: 10),
        Text('Sukces!',
            style: TextStyle(
                color: Color(0xFFD4A017), fontFamily: 'Norse', fontSize: 22)),
      ]),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wygenerowano ${widget.serverName} Launcher, Patcher i Updater.',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            if (widget.outDir != null) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF2A2010)),
                ),
                child: Row(children: [
                  const Icon(Icons.folder_open,
                      color: Color(0xFFD4A017), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.outDir!,
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),
            ],
            // Upload log
            if (_uploadLog.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0800),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF2A2010)),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _uploadLog.length,
                  padding: const EdgeInsets.all(10),
                  itemBuilder: (_, i) => Text(
                    _uploadLog[i],
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.5),
                  ),
                ),
              ),
            ],
            if (_uploading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(
                  backgroundColor: Color(0xFF1A1408),
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFFD4A017))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zamknij',
              style: TextStyle(color: Colors.white54)),
        ),
        if (widget.outDir != null && !_uploading)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1408),
              foregroundColor: const Color(0xFFD4A017),
              side: const BorderSide(color: Color(0xFFD4A017)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Otwórz folder',
                style: TextStyle(fontFamily: 'Norse', fontSize: 14)),
            onPressed: () {
              Process.run('explorer', [widget.outDir!], runInShell: true);
            },
          ),
        if (!_uploading && !_uploadDone)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD4A017),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            icon: const Icon(Icons.cloud_upload, size: 18),
            label: const Text('Wgraj na serwer',
                style: TextStyle(fontFamily: 'Norse', fontSize: 14)),
            onPressed: _upload,
          ),
        if (_uploading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('Wysyłanie...',
                style: TextStyle(
                    color: Color(0xFFD4A017),
                    fontFamily: 'Norse',
                    fontSize: 14)),
          ),
        if (_uploadDone)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _uploadOk ? const Color(0xFF2E7D32) : const Color(0xFFB71C1C),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            icon: Icon(_uploadOk ? Icons.check : Icons.refresh, size: 18),
            label: Text(_uploadOk ? 'Wysłano!' : 'Spróbuj ponownie',
                style:
                    const TextStyle(fontFamily: 'Norse', fontSize: 14)),
            onPressed: _uploadOk ? null : _upload,
          ),
      ],
    );
  }
}

// ── Grid background painter ─────────────────────────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD4A017).withValues(alpha: 0.025)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── Profile Button ────────────────────────────────────────────────
class _ProfileButton extends StatelessWidget {
  const _ProfileButton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        child: const Text(
          'Profile',
          style: TextStyle(
            fontFamily: 'Norse', fontSize: 13,
            color: Color(0xFF8B6914), letterSpacing: 1,
          ),
        ),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          overlayColor: const Color(0xFF2A2010),
        ),
        onPressed: () => showDialog(
          context: context,
          builder: (_) => _ProfileDialog(
            onLoad: (profile) {
              context.read<GeneratorProvider>().loadFromProfile(profile);
            },
          ),
        ),
      ),
    );
  }
}

// ── Profile Dialog ────────────────────────────────────────────────
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.onLoad});
  final void Function(ServerProfile) onLoad;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late Future<List<ServerProfile>> _profilesFuture;

  @override
  void initState() {
    super.initState();
    _profilesFuture = ProfileService.loadAll();
  }

  void _reload() => setState(() => _profilesFuture = ProfileService.loadAll());

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF12100A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF3A2E1A)),
      ),
      child: SizedBox(
        width: 480,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.folder_open_outlined, color: Color(0xFFD4A017), size: 22),
                const SizedBox(width: 12),
                const Text('Profile', style: TextStyle(
                  fontFamily: 'Norse', fontSize: 22, fontWeight: FontWeight.w700,
                  color: Color(0xFFD4A017), letterSpacing: 2,
                )),
              ]),
              const SizedBox(height: 8),
              Container(height: 1, color: const Color(0xFF2A2010)),
              const SizedBox(height: 20),
              FutureBuilder<List<ServerProfile>>(
                future: _profilesFuture,
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final profiles = snap.data ?? [];
                  if (profiles.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'Brak zapisanych profili.\nProfile są zapisywane automatycznie po generowaniu.',
                        style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.6),
                      ),
                    );
                  }
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: profiles.length,
                      separatorBuilder: (_, _) => const Divider(color: Color(0xFF2A2010), height: 1),
                      itemBuilder: (ctx, i) {
                        final p = profiles[i];
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                          title: Text(p.serverName, style: const TextStyle(
                            fontFamily: 'Norse', color: Color(0xFFD4A017), fontSize: 15,
                          )),
                          subtitle: Text(
                            '${p.panelUrl.isNotEmpty ? p.panelUrl : '${p.ftpHost}:${p.ftpPort}'}  ·  ${p.serverAddr}',
                            style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'Norse'),
                          ),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            TextButton(
                              onPressed: () {
                                widget.onLoad(p);
                                Navigator.of(context).pop();
                              },
                              child: const Text('Wczytaj', style: TextStyle(
                                fontFamily: 'Norse', color: Color(0xFFD4A017), fontSize: 12,
                              )),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white24),
                              tooltip: 'Usuń',
                              onPressed: () async {
                                await ProfileService.delete(p.serverName);
                                _reload();
                              },
                            ),
                          ]),
                        );
                      },
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Zamknij', style: TextStyle(
                    fontFamily: 'Norse', color: Color(0xFF8B6914), letterSpacing: 1,
                  )),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Contact Button ────────────────────────────────────────────────
class _ContactButton extends StatelessWidget {
  const _ContactButton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        child: const Text(
          'Kontakt',
          style: TextStyle(
            fontFamily: 'Norse',
            fontSize: 13,
            color: Color(0xFF8B6914),
            letterSpacing: 1,
          ),
        ),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          overlayColor: const Color(0xFF2A2010),
        ),
        onPressed: () => showDialog(
          context: context,
          builder: (_) => const _ContactDialog(),
        ),
      ),
    );
  }
}

// ── Contact Dialog ────────────────────────────────────────────────
class _ContactDialog extends StatelessWidget {
  const _ContactDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF12100A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF3A2E1A)),
      ),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(children: [
                const Text(
                  'Kontakt',
                  style: TextStyle(
                    fontFamily: 'Norse',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFD4A017),
                    letterSpacing: 2,
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Container(height: 1, color: const Color(0xFF2A2010)),
              const SizedBox(height: 24),

              // Description
              const Text(
                'Zainteresowany wersją komercyjną lub\nwłasnym launcherem na zamówienie?',
                style: TextStyle(
                  fontFamily: 'Norse',
                  fontSize: 15,
                  color: Colors.white70,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 24),

              // Email row
              _ContactRow(
                icon: Icons.alternate_email,
                label: 'E-mail',
                value: 'pawel@howtodev.it',
              ),
              const SizedBox(height: 12),
              _ContactRow(
                icon: Icons.code,
                label: 'GitHub',
                value: 'github.com/PawelSzymanski89',
              ),
              const SizedBox(height: 32),

              // Close button
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Zamknij',
                    style: TextStyle(
                      fontFamily: 'Norse',
                      color: Color(0xFF8B6914),
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(
        '$label: ',
        style: const TextStyle(fontFamily: 'Norse', fontSize: 13, color: Colors.white38),
      ),
      SelectableText(
        value,
        style: const TextStyle(
          fontFamily: 'Norse',
          fontSize: 13,
          color: Color(0xFFD4A017),
          letterSpacing: 0.5,
        ),
      ),
    ]);
  }
}
