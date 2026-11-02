import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asmrshelf/utils/log_util.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('asmrshelf_log');
  });

  tearDown(() async {
    LogUtil.detachFileSink();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  List<File> logFiles() => dir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).endsWith('.log'))
      .toList();

  String readLog() {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList();
    return files.map((f) => f.readAsStringSync()).join();
  }

  test('第三个参数 data 会进日志：异常对象与堆栈不再被丢掉', () {
    LogUtil.attachFileSink(dir.path);

    logError('Database', '建表失败', 'SqliteException: no such table\n#0 main');

    final text = readLog();
    expect(text, contains('[ERR]'));
    expect(text, contains('建表失败'));
    expect(text, contains('SqliteException: no such table'));
    expect(text, contains('#0 main'));
  });

  test('按天落到一个文件：多条日志追加，每行带时间戳', () {
    LogUtil.attachFileSink(dir.path);

    logInfo('App', 'first');
    logWarn('App', 'second', 'extra');

    final files = logFiles();
    expect(files, hasLength(1));
    expect(p.basename(files.single.path),
        matches(RegExp(r'^app-\d{4}-\d{2}-\d{2}\.log$')));
    final text = files.single.readAsStringSync();
    expect(text.split('\n').where((l) => l.isNotEmpty), hasLength(2));
    expect(text, contains('first'));
    expect(text, contains('[WRN] App                | second | extra'));
    expect(
        RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[INF\]',
                multiLine: true)
            .hasMatch(text),
        isTrue);
  });

  test('没挂 sink 时只写控制台，不在磁盘上造文件', () {
    logInfo('App', 'no sink');
    logError('App', 'still no sink', 'detail');
    expect(logFiles(), isEmpty);
  });

  test('单文件超过上限时轮转成 .1，主文件重新开始', () {
    LogUtil.attachFileSink(dir.path, maxBytes: 1);

    logInfo('App', 'first');
    logInfo('App', 'second');

    final main = logFiles().single;
    final rotated = File('${main.path}.1');
    expect(rotated.existsSync(), isTrue);
    expect(rotated.readAsStringSync(), contains('first'));
    expect(main.readAsStringSync(), contains('second'));
    expect(main.readAsStringSync(), isNot(contains('first')));
  });

  test('目录建不出来时静默退回只写控制台，不抛给调用方', () {
    final blocker = File(p.join(dir.path, 'blocker'))..writeAsStringSync('x');
    // blocker 是文件，它下面建不出目录。
    expect(() => LogUtil.attachFileSink(p.join(blocker.path, 'logs')),
        returnsNormally);
    expect(() => logInfo('App', 'quiet'), returnsNormally);
  });

  test('detachFileSink 之后不再落盘', () {
    LogUtil.attachFileSink(dir.path);
    logInfo('App', 'before');
    LogUtil.detachFileSink();
    logInfo('App', 'after');

    final text = readLog();
    expect(text, contains('before'));
    expect(text, isNot(contains('after')));
  });
}
