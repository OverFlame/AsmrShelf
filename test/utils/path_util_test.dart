import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asmrshelf/utils/path_util.dart';

void main() {
  group('isSamePath', () {
    test('忽略尾部分隔符', () {
      expect(isSamePath('/a/b/', '/a/b'), isTrue);
      expect(isSamePath('/a/b', '/a/b/'), isTrue);
    });

    test('忽略重复分隔符与 . 段', () {
      expect(isSamePath('/a//b/./c', '/a/b/c'), isTrue);
    });

    test('解析 ..', () {
      expect(isSamePath('/a/b/../c', '/a/c'), isTrue);
    });

    test('互为前缀的不同路径不相等', () {
      expect(isSamePath('/a/b', '/a/bc'), isFalse);
    });

    test('同一层级的兄弟目录不相等', () {
      expect(isSamePath('/a/b', '/a/c'), isFalse);
    });
  });

  group('uniqueDestPath', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pv2_path_util');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('无冲突时直接用原名', () async {
      final path = await uniqueDestPath(destDir: tmp.path, name: 'a.jpg');
      expect(p.basename(path), 'a.jpg');
      expect(p.dirname(path), tmp.path);
    });

    test('已被占用时依次加序号', () async {
      await File(p.join(tmp.path, 'a.jpg')).writeAsString('x');
      await File(p.join(tmp.path, 'a_(1).jpg')).writeAsString('x');

      final path = await uniqueDestPath(destDir: tmp.path, name: 'a.jpg');
      expect(p.basename(path), 'a_(2).jpg');
    });

    test('无扩展名时也能加序号', () async {
      await File(p.join(tmp.path, 'README')).writeAsString('x');

      final path = await uniqueDestPath(destDir: tmp.path, name: 'README');
      expect(p.basename(path), 'README_(1)');
    });

    test('候选全部被占用时抛 FileSystemException', () async {
      await File(p.join(tmp.path, 'a.jpg')).writeAsString('x');
      await File(p.join(tmp.path, 'a_(1).jpg')).writeAsString('x');

      expect(
        () => uniqueDestPath(destDir: tmp.path, name: 'a.jpg', maxAttempts: 1),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
