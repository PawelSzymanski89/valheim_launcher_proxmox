import 'dart:io';

/// Removes folders under [root] that are empty, deepest first; [root] itself stays. Moving a
/// dropped mod's files aside used to leave its folder behind - seventeen empty folders in
/// BepInEx/plugins after one sync on a real machine. Never follows links out of [root].
void removeEmptyDirs(String root) {
  final top = Directory(root);
  if (!top.existsSync()) return;
  final dirs = top
      .listSync(recursive: true, followLinks: false)
      .whereType<Directory>()
      .toList()
    ..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in dirs) {
    try {
      if (d.listSync(followLinks: false).isEmpty) d.deleteSync();
    } catch (_) {}
  }
}
