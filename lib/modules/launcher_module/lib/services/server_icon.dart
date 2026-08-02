import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// The launcher's icon is drawn from the server's name at runtime.
///
/// Upstream baked a pixel-art icon into every build, which worked because every
/// server had its own build. Here one neutral engine serves every server and the
/// name arrives from the panel at startup - so the icon is drawn when the name is
/// known, not when the exe is compiled.
class ServerIcon {
  /// Up to three letters standing in for the server name: initials of the words
  /// ("Moja Baza" -> MB), or the capitals inside one word ("VintageSrv" -> VS),
  /// falling back to the first letters when the name offers neither.
  static String acronym(String serverName) {
    final name = serverName.trim();
    if (name.isEmpty) return 'VH';
    final words = name.split(RegExp(r'[\s_\-]+')).where((w) => w.isNotEmpty).toList();
    if (words.length > 1) {
      return words.take(3).map((w) => w[0]).join().toUpperCase();
    }
    final caps = RegExp(r'[A-ZĄĆĘŁŃÓŚŹŻ]').allMatches(words.first);
    if (caps.length >= 2) {
      return caps.take(3).map((m) => m[0]!).join();
    }
    return words.first.substring(0, words.first.length >= 2 ? 2 : 1).toUpperCase();
  }

  /// Draws the badge and returns the PNG bytes. Norse on soot and gold, the same
  /// palette the launcher uses everywhere else.
  static Future<ui.Image> render(String serverName, {double size = 256}) async {
    final text = acronym(serverName);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, size, size);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size * 0.18)),
      Paint()..color = const Color(0xFF1A1410),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(size * 0.045), Radius.circular(size * 0.14)),
      Paint()
        ..color = const Color(0xFFD4A017)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.035,
    );

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Norse',
          fontWeight: FontWeight.w700,
          // Two letters want more room than three; scale so both fill the badge.
          fontSize: size * (text.length >= 3 ? 0.42 : 0.52),
          color: const Color(0xFFD4A017),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );

    return recorder.endRecording().toImage(size.toInt(), size.toInt());
  }

  /// Writes the badge next to the launcher's own data and hands it to Windows as
  /// the window and taskbar icon. Quietly does nothing when that fails - a wrong
  /// icon must never stop the game from starting.
  static Future<void> apply(String serverName) async {
    try {
      if (!Platform.isWindows) return;
      final image = await render(serverName);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final dir = Directory(
          '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
          '${Platform.pathSeparator}schron_twarda_launcher');
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}server_icon.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await windowManager.setIcon(file.path);
    } catch (_) {}
  }
}

/// The same badge as a widget, for the title bar.
class ServerIconBadge extends StatelessWidget {
  final String serverName;
  final double size;

  const ServerIconBadge({super.key, required this.serverName, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final text = ServerIcon.acronym(serverName);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1410),
        borderRadius: BorderRadius.circular(size * 0.18),
        border: Border.all(color: const Color(0xFFD4A017), width: 1.2),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Norse',
          fontWeight: FontWeight.w700,
          fontSize: size * (text.length >= 3 ? 0.44 : 0.54),
          color: const Color(0xFFD4A017),
          height: 1.1,
        ),
      ),
    );
  }
}
