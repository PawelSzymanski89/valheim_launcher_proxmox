import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_launcher/services/fs_util.dart';

void main() {
  test('empty folders go, folders with files and the root stay, links are not followed', () {
    final d = Directory.systemTemp.createTempSync('fs').path;
    Directory('$d/plugins/Gone-Mod/sub/deeper').createSync(recursive: true);
    Directory('$d/plugins/Kept-Mod/lang').createSync(recursive: true);
    File('$d/plugins/Kept-Mod/kept.dll').writeAsStringSync('x');
    Directory('$d/outside').createSync();
    File('$d/outside/precious.txt').writeAsStringSync('x');
    Link('$d/plugins/link-out').createSync('$d/outside');
    removeEmptyDirs('$d/plugins');
    expect(Directory('$d/plugins').existsSync(), isTrue);
    expect(Directory('$d/plugins/Gone-Mod').existsSync(), isFalse);
    expect(File('$d/plugins/Kept-Mod/kept.dll').existsSync(), isTrue);
    expect(Directory('$d/plugins/Kept-Mod/lang').existsSync(), isFalse);
    expect(File('$d/outside/precious.txt').existsSync(), isTrue);
    removeEmptyDirs('$d/does-not-exist');
  });
}
