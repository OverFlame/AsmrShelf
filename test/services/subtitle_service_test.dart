import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/subtitle_service.dart';
import '../support/test_env.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late SubtitleService service;

  Future<int> insertMedia({
    required String path,
    required String type,
    String? filename,
    int? subtitleOf,
    bool isDefault = false,
  }) {
    return db.insert('media', <String, Object?>{
      'path': path,
      'media_type': type,
      'filename': filename ?? p.basename(path),
      'added_at': 1,
      'subtitle_of': subtitleOf,
      'is_default_subtitle': isDefault ? 1 : 0,
    });
  }

  Future<int> insertAudio(String name) =>
      insertMedia(path: p.join(tmp.path, name), type: 'audio');

  Future<int> insertSubtitle(
    String name, {
    int? subtitleOf,
    bool isDefault = false,
  }) =>
      insertMedia(
        path: p.join(tmp.path, name),
        type: 'subtitle',
        subtitleOf: subtitleOf,
        isDefault: isDefault,
      );

  Future<int?> defaultOf(int audioId) async {
    final rows = await db.query(
      'media',
      columns: <String>['id'],
      where: "subtitle_of = ? AND is_default_subtitle <> 0",
      whereArgs: <Object?>[audioId],
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  Future<int> defaultCount(int audioId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM media WHERE subtitle_of = ? '
      'AND is_default_subtitle <> 0',
      <Object?>[audioId],
    );
    return (rows.first['c'] as num).toInt();
  }

  Future<int?> subtitleOf(int id) async {
    final rows = await db.query(
      'media',
      columns: <String>['subtitle_of'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    return rows.isEmpty ? null : rows.first['subtitle_of'] as int?;
  }

  Future<int> rowCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM media');
    return (rows.first['c'] as num).toInt();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_subtitle');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    service = SubtitleService(db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('纯函数', () {
    test('languageOfPath 认常见语言词', () {
      expect(SubtitleService.languageOfPath('/m/a.zh.srt'), 'zh-Hans');
      expect(SubtitleService.languageOfPath('/m/a.chs.srt'), 'zh-Hans');
      expect(SubtitleService.languageOfPath('/m/a.sc.srt'), 'zh-Hans');
      expect(SubtitleService.languageOfPath('/m/a.cht.srt'), 'zh-Hant');
      expect(SubtitleService.languageOfPath('/m/a.tc.srt'), 'zh-Hant');
      expect(SubtitleService.languageOfPath('/m/a.jpn.srt'), 'ja');
      expect(SubtitleService.languageOfPath('/m/a.eng.srt'), 'en');
      expect(SubtitleService.languageOfPath('/m/a.kor.srt'), 'ko');
      expect(SubtitleService.languageOfPath('/m/a.简.srt'), 'zh-Hans');
    });

    test('languageOfPath 认连写 CJK 语言字并取优先级最高者', () {
      expect(SubtitleService.languageOfPath('/m/第01话.简日.srt'), 'zh-Hans');
      expect(SubtitleService.languageOfPath('/m/第01话.日简.srt'), 'zh-Hans');
      expect(SubtitleService.languageOfPath('/m/第01话.繁日.srt'), 'zh-Hant');
    });

    test('languageOfPath 多语言词取优先级最高者', () {
      expect(SubtitleService.languageOfPath('/m/a.kor-eng.srt'), 'en');
      expect(SubtitleService.languageOfPath('/m/a.eng-jpn.srt'), 'ja');
      // 认不出或没有语言词 → null
      expect(SubtitleService.languageOfPath('/m/a.srt'), isNull);
      expect(SubtitleService.languageOfPath('/m/a.xyz.srt'), isNull);
    });

    test('languageOfPath 只看主干，不吃目录名', () {
      expect(SubtitleService.languageOfPath('/m/zh/a.srt'), isNull);
      expect(SubtitleService.languageOfPath('/m/zh/a.eng.srt'), 'en');
    });

    test('languageOfPath 认另一种分隔符的路径', () {
      // 库可以在 Windows 与 Linux 之间搬，路径字符串里留的是当初那台机器的
      // 分隔符。用 p.basenameWithoutExtension 时反斜杠不算目录分隔符，
      // 整条路径会被当成主干，目录名里的语言字会被当成文件的语言。
      expect(SubtitleService.languageOfPath(r'D:\日语\a.srt'), isNull);
      expect(SubtitleService.languageOfPath(r'D:\Music\a.eng.srt'), 'en');
      expect(SubtitleService.languageOfPath(r'D:\Music\第01话.简日.srt'),
          'zh-Hans');
    });

    test('languageRank 未知与 null 排最后', () {
      expect(SubtitleService.languageRank('zh-Hans'), 0);
      expect(SubtitleService.languageRank('ko'), 4);
      expect(SubtitleService.languageRank('fr'),
          SubtitleService.languageOrder.length);
      expect(SubtitleService.languageRank(null),
          SubtitleService.languageOrder.length + 1);
    });

    test('matchRank 三档且大小写不敏感', () {
      expect(SubtitleService.matchRank('/m/a.mp3.srt', 'a.mp3'), 0);
      expect(SubtitleService.matchRank('/m/A.MP3.SRT', 'a.mp3'), 0);
      expect(SubtitleService.matchRank('/m/a.srt', 'a.mp3'), 1);
      expect(SubtitleService.matchRank('/m/a.zh.srt', 'a.mp3'), 2);
      expect(SubtitleService.matchRank('/m/b.zh.srt', 'a.mp3'), 2);
    });

    test('matchRank 认另一种分隔符的路径', () {
      // 反斜杠路径在 Linux 上会被 p.basenameWithoutExtension 整条留下，
      // 完全同名的字幕反而被判定成最低档（2），默认字幕就选错了。
      expect(SubtitleService.matchRank(r'D:\Music\a.mp3.srt', 'a.mp3'), 0);
      expect(SubtitleService.matchRank(r'D:\Music\a.srt', 'a.mp3'), 1);
      expect(SubtitleService.matchRank(r'D:\Music\a.zh.srt', 'a.mp3'), 2);
    });
  });

  group('默认字幕三级顺序', () {
    test('第一级：已有唯一默认项就保留，不按档位改选', () async {
      final audio = await insertAudio('a.mp3');
      final loose = await insertSubtitle('a.zh.srt',
          subtitleOf: audio, isDefault: true);
      await insertSubtitle('a.mp3.srt', subtitleOf: audio); // 档位更好

      final chosen = await service.selectDefault(audio);

      expect(chosen!.id, loose, reason: '用户上次选定优先于文件名匹配');
      expect(await defaultOf(audio), loose);
      expect(await defaultCount(audio), 1);
    });

    test('第二级：没有默认项时选档位最好的一条', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.zh.srt', subtitleOf: audio); // 档 2
      await insertSubtitle('a.srt', subtitleOf: audio); // 档 1
      final best = await insertSubtitle('a.mp3.srt', subtitleOf: audio); // 档 0

      final chosen = await service.selectDefault(audio);

      expect(chosen!.id, best);
      expect(await defaultOf(audio), best);
      expect(await defaultCount(audio), 1);
    });

    test('第三级：档位并列时按语言优先级', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.kor.srt', subtitleOf: audio);
      await insertSubtitle('a.eng.srt', subtitleOf: audio);
      final jpn = await insertSubtitle('a.jpn.srt', subtitleOf: audio);
      await insertSubtitle('a.cht.srt', subtitleOf: audio);
      final zh = await insertSubtitle('a.zh.srt', subtitleOf: audio);

      expect((await service.selectDefault(audio))!.id, zh);
      // 打掉中文两条后应该轮到日文
      await db.delete('media', where: 'id = ?', whereArgs: <Object?>[zh]);
      await db.delete('media',
          where: 'path = ?', whereArgs: <Object?>[p.join(tmp.path, 'a.cht.srt')]);

      expect((await service.selectDefault(audio))!.id, jpn);
    });

    test('档位与语言都并列时按路径字典序，且顺序稳定', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.bbb.srt', subtitleOf: audio);
      final a2 = await insertSubtitle('a.aaa.srt', subtitleOf: audio);
      await insertSubtitle('a.ccc.srt', subtitleOf: audio);

      expect((await service.selectDefault(audio))!.id, a2);
      // 反复调用不漂移
      final again = await service.selectDefault(audio);
      expect(again!.id, a2);
      expect(again.filename, 'a.aaa.srt');
      expect(await defaultOf(audio), a2);
      expect(await defaultCount(audio), 1);
    });

    test('多条默认项会被收敛成一条', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.mp3.srt', subtitleOf: audio, isDefault: true);
      final second = await insertSubtitle('a.srt',
          subtitleOf: audio, isDefault: true);

      expect(await defaultCount(audio), 2);
      final chosen = await service.selectDefault(audio);

      expect(chosen!.id, isNot(second));
      expect(await defaultCount(audio), 1);
    });

    test('没有字幕时返回 null 且不写库', () async {
      final audio = await insertAudio('a.mp3');
      expect(await service.selectDefault(audio), isNull);
      expect(await service.defaultFor(audio), isNull);
    });
  });

  group('列出与切换', () {
    test('listForAudio 默认最前，其余按档位与语言', () async {
      final audio = await insertAudio('a.mp3');
      final rank2 = await insertSubtitle('a.eng.srt', subtitleOf: audio);
      final rank1 = await insertSubtitle('a.srt', subtitleOf: audio);
      final rank0 = await insertSubtitle('a.mp3.srt', subtitleOf: audio);
      await service.setDefault(rank1);

      final list = await service.listForAudio(audio);

      expect(list.map((e) => e.id).toList(), <int>[rank1, rank0, rank2]);
      expect(list.first.isDefault, isTrue);
      expect(list.first.filename, 'a.srt');
    });

    test('listForAudio 反斜杠路径的库也能排出正确档位', () async {
      // 音频名与字幕名都取不到 filename 列时，会退回从 path 现算。
      // 路径带的是建库那台机器的分隔符，现算必须两种都认，否则同名
      // 字幕（档位 0）会被判成最低档，排到别的字幕后面。
      final audio = await insertMedia(
          path: r'D:\Music\a.mp3', type: 'audio', filename: '');
      final exact = await insertMedia(
          path: r'D:\Music\z\a.mp3.srt',
          type: 'subtitle',
          filename: '',
          subtitleOf: audio);
      final other = await insertMedia(
          path: r'D:\Music\a\a.zh.srt',
          type: 'subtitle',
          filename: '',
          subtitleOf: audio);

      final list = await service.listForAudio(audio);

      expect(list.map((e) => e.id).toList(), <int>[exact, other]);
      expect(list.first.filename, 'a.mp3.srt');
    });

    test('listForAudio 只回本音频的字幕', () async {
      final audio1 = await insertAudio('a.mp3');
      final audio2 = await insertAudio('b.mp3');
      final mine = await insertSubtitle('a.srt', subtitleOf: audio1);
      await insertSubtitle('b.srt', subtitleOf: audio2);
      await insertSubtitle('c.srt');

      final list = await service.listForAudio(audio1);
      expect(list.map((e) => e.id).toList(), <int>[mine]);
      expect(list.single.language, isNull);
    });

    test('listUnassigned 只回未归属的字幕', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.srt', subtitleOf: audio);
      final free1 = await insertSubtitle('free1.zh.srt');
      final free2 = await insertSubtitle('free2.srt');

      final list = await service.listUnassigned();
      expect(list.map((e) => e.id).toSet(), <int>{free1, free2});
      expect(list.first.id, free1, reason: '有语言的排在没语言的前面');
    });

    test('setDefault 清掉同组旧默认', () async {
      final audio = await insertAudio('a.mp3');
      final first = await insertSubtitle('a.zh.srt',
          subtitleOf: audio, isDefault: true);
      final second = await insertSubtitle('a.eng.srt', subtitleOf: audio);

      await service.setDefault(second);

      expect(await defaultOf(audio), second);
      expect(await defaultCount(audio), 1);
      final rows = await db.query('media',
          columns: <String>['is_default_subtitle'],
          where: 'id = ?',
          whereArgs: <Object?>[first]);
      expect(rows.first['is_default_subtitle'], 0);

      final entry = await service.defaultFor(audio);
      expect(entry!.id, second);
      expect(entry.isDefault, isTrue);
    });

    test('setDefault 的错误路径', () async {
      final audio = await insertAudio('a.mp3');
      final free = await insertSubtitle('free.srt');
      final image = await insertMedia(
          path: p.join(tmp.path, 'x.jpg'), type: 'image');

      expect(service.setDefault(99999), throwsStateError);
      expect(service.setDefault(image), throwsArgumentError);
      expect(service.setDefault(free), throwsStateError);
      expect(await defaultOf(audio), isNull);
    });
  });

  group('归属', () {
    test('attach 挂上后补一个默认，旧归属的默认标记被清', () async {
      final audio1 = await insertAudio('a.mp3');
      final audio2 = await insertAudio('b.mp3');
      final sub = await insertSubtitle('a.zh.srt',
          subtitleOf: audio1, isDefault: true);

      await service.setDefault(sub);
      expect(await defaultOf(audio1), sub);

      await service.attach(sub, audio2);

      expect(await subtitleOf(sub), audio2);
      expect(await defaultOf(audio2), sub, reason: '新组原本没有默认项');
      expect(await defaultCount(audio2), 1);

      // 回挂到 audio1，audio1 重新按三级顺序选
      await service.attach(sub, audio1);
      expect(await defaultOf(audio1), sub);

      // 已归属别的音频的默认项再被挂走，原组补新默认
      final other = await insertSubtitle('a.eng.srt', subtitleOf: audio1);
      await service.setDefault(sub);
      await service.attach(sub, audio2);
      expect(await defaultOf(audio1), other, reason: '原组没默认项了要补一个');
      expect(await defaultCount(audio1), 1);
    });

    test('attachAll 跳过重复 id 并返回挂载条数', () async {
      final audio = await insertAudio('a.mp3');
      final s1 = await insertSubtitle('a.zh.srt');
      final s2 = await insertSubtitle('a.jpn.srt');

      final count = await service.attachAll(<int>[s1, s2, s1], audio);

      expect(count, 2);
      expect(await subtitleOf(s1), audio);
      expect(await subtitleOf(s2), audio);
      expect(await defaultCount(audio), 1);
    });

    test('attach 的错误路径', () async {
      final audio = await insertAudio('a.mp3');
      final free = await insertSubtitle('free.srt');
      final image = await insertMedia(
          path: p.join(tmp.path, 'x.jpg'), type: 'image');

      expect(service.attach(99999, audio), throwsStateError);
      expect(service.attach(image, audio), throwsArgumentError);
      expect(service.attach(free, 99999), throwsArgumentError);
      expect(service.attach(free, image), throwsArgumentError);
    });

    test('detach 摘掉归属并给原组补默认', () async {
      final audio = await insertAudio('a.mp3');
      final s1 = await insertSubtitle('a.mp3.srt', subtitleOf: audio);
      final s2 = await insertSubtitle('a.srt', subtitleOf: audio);
      await service.setDefault(s1);

      await service.detach(s1);

      expect(await subtitleOf(s1), isNull);
      expect(await defaultOf(audio), s2);
      expect(await defaultCount(audio), 1);

      // 摘掉最后一条 → 组里没有字幕，也不该炸
      await service.detach(s2);
      expect(await defaultOf(audio), isNull);
      expect(await service.defaultFor(audio), isNull);
    });

    test('detach 不存在的行是空操作', () async {
      await service.detach(99999);
      expect(await rowCount(), 0);
    });
  });

  group('删除与清理', () {
    test('删音频会连它名下的字幕一起删', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.srt', subtitleOf: audio);
      await insertSubtitle('a.zh.srt', subtitleOf: audio, isDefault: true);
      final other = await insertSubtitle('free.srt');

      await service.deleteEntry(audio);

      expect(await rowCount(), 1);
      expect(await subtitleOf(other), isNull);
    });

    test('删默认字幕会给同组补一个新默认', () async {
      final audio = await insertAudio('a.mp3');
      final best = await insertSubtitle('a.mp3.srt', subtitleOf: audio);
      final second = await insertSubtitle('a.srt', subtitleOf: audio);
      await service.setDefault(best);

      await service.deleteEntry(best);

      expect(await defaultOf(audio), second);
      expect(await defaultCount(audio), 1);
    });

    test('删非默认字幕不动默认项', () async {
      final audio = await insertAudio('a.mp3');
      final best = await insertSubtitle('a.mp3.srt', subtitleOf: audio);
      final second = await insertSubtitle('a.srt', subtitleOf: audio);
      await service.setDefault(best);

      await service.deleteEntry(second);

      expect(await defaultOf(audio), best);
      expect(await rowCount(), 2);
    });

    test('删不存在的行是空操作', () async {
      await service.deleteEntry(99999);
      expect(await rowCount(), 0);
    });

    test('cleanOrphans 把指向非音频行的归属摘掉', () async {
      final image = await insertMedia(
          path: p.join(tmp.path, 'x.jpg'), type: 'image');
      final sub = await insertSubtitle('x.zh.srt',
          subtitleOf: image, isDefault: true);

      final fixed = await service.cleanOrphans();

      expect(fixed, greaterThanOrEqualTo(1));
      expect(await subtitleOf(sub), isNull);
      final rows = await db.query('media',
          columns: <String>['is_default_subtitle'],
          where: 'id = ?',
          whereArgs: <Object?>[sub]);
      expect(rows.first['is_default_subtitle'], 0);
    });

    test('cleanOrphans 修正悬空 subtitle_of', () async {
      final audio = await insertAudio('a.mp3');
      await db.execute('PRAGMA foreign_keys = OFF');
      final dangling = await db.insert('media', <String, Object?>{
        'path': p.join(tmp.path, 'gone.srt'),
        'media_type': 'subtitle',
        'filename': 'gone.srt',
        'added_at': 1,
        'subtitle_of': 987654,
        'is_default_subtitle': 1,
      });
      await db.execute('PRAGMA foreign_keys = ON');

      await service.cleanOrphans();

      expect(await subtitleOf(dangling), isNull);
      expect(await defaultOf(audio), isNull);
    });

    test('cleanOrphans 把没有默认项的分组补上默认', () async {
      final audio = await insertAudio('a.mp3');
      final s1 = await insertSubtitle('a.mp3.srt', subtitleOf: audio);
      final s2 = await insertSubtitle('a.srt', subtitleOf: audio);

      final fixed = await service.cleanOrphans();

      expect(fixed, greaterThanOrEqualTo(1));
      expect(await defaultOf(audio), s1);
      expect(await defaultCount(audio), 1);
      expect(await subtitleOf(s2), audio);
    });

    test('cleanOrphans 把多条默认项收敛成一条', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.srt', subtitleOf: audio, isDefault: true);
      await insertSubtitle('a.zh.srt', subtitleOf: audio, isDefault: true);

      await service.cleanOrphans();

      expect(await defaultCount(audio), 1);
      expect((await service.defaultFor(audio))!.filename, 'a.srt');
    });

    test('cleanOrphans 对干净的库不改动', () async {
      final audio = await insertAudio('a.mp3');
      await insertSubtitle('a.srt', subtitleOf: audio, isDefault: true);

      expect(await service.cleanOrphans(), 0);
      expect(await defaultCount(audio), 1);
    });
  });

  group('读出字段', () {
    test('language / ext / audioId 填充正确', () async {
      final audio = await insertAudio('a.mp3');
      final id = await insertSubtitle('a.zh-Hans.srt', subtitleOf: audio);

      final beforeSelect = (await service.listForAudio(audio)).single;
      expect(beforeSelect.isDefault, isFalse, reason: '没人选过默认项');

      await service.selectDefault(audio);
      final entry = (await service.listForAudio(audio)).single;

      expect(entry.id, id);
      expect(entry.audioId, audio);
      expect(entry.ext, '.srt');
      expect(entry.language, 'zh-Hans');
      expect(entry.isDefault, isTrue, reason: '唯一一条字幕会被收敛选为默认');
    });
  });
}
