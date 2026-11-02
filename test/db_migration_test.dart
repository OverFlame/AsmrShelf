import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/utils/filter_expression.dart';
import 'support/test_env.dart';

/// 建一个空的当前版本库，直接从 Tables.createStatements 建。
Future<Database> openFresh(String path) async {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: Tables.version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        await Tables.createAll(db);
      },
    ),
  );
}

/// 读一张表的列名集合。
Future<Set<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

/// v6 的老结构，只保留升级用例用到的部分。
///
/// works 的 library 只认 audio / video，media 连 sort_key 都没有。
/// 删表重建的升级路径跟老结构长什么样无关，拿它当更老的样本。
const List<String> _v6Statements = [
  '''
  CREATE TABLE works (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    library     TEXT    NOT NULL CHECK (library IN ('audio', 'video')),
    cover_path  TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE media (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    path        TEXT    NOT NULL UNIQUE,
    media_type  TEXT    NOT NULL CHECK (media_type IN ('audio', 'image', 'video', 'subtitle')),
    ext         TEXT    NOT NULL DEFAULT '',
    name_lower  TEXT    NOT NULL DEFAULT '',
    filename    TEXT    NOT NULL,
    added_at    INTEGER NOT NULL,
    cover_path  TEXT
  )
  ''',
  '''
  CREATE TABLE folders (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT    NOT NULL,
    parent    INTEGER REFERENCES folders(id),
    library   TEXT    NOT NULL CHECK (library IN ('audio', 'image', 'video')),
    work_id   INTEGER REFERENCES works(id) ON DELETE SET NULL,
    UNIQUE(name, parent)
  )
  ''',
];

/// v9 的真实老结构（本轮之前的形态），照 `426279b:lib/db/tables.dart` 抄。
///
/// works 与 folders 的 library 还认 image / video，media 还有 hash 与 note，
/// 库里还有 `reading_spreads` 表与 `images` 视图。删表重建的升级路径必须能把这一堆
/// 全清掉：`reading_spreads` 的外键指向 media 与 folders，漏删它会让下一次 DDL
/// 重建 schema 时报 `no such table: main.media`。
const List<String> _v9Statements = [
  '''
  CREATE TABLE works (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT    NOT NULL,
      library     TEXT    NOT NULL CHECK (library IN ('audio', 'image', 'video')),
      cover_path  TEXT,
      cover_crop  TEXT,
      sort_order  INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL
    )
  ''',
  '''
  CREATE TABLE media (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      path         TEXT    NOT NULL UNIQUE,
      media_type   TEXT    NOT NULL CHECK (media_type IN ('audio', 'image', 'video', 'subtitle')),
      ext          TEXT    NOT NULL DEFAULT '',
      name_lower   TEXT    NOT NULL DEFAULT '',
      filename     TEXT    NOT NULL,
      added_at     INTEGER NOT NULL,
      play_position_ms INTEGER NOT NULL DEFAULT 0,
      hash         TEXT,
      note         TEXT,
      cover_path   TEXT,
      sort_key     TEXT,
      subtitle_of  INTEGER REFERENCES media(id) ON DELETE SET NULL
    )
  ''',
  '''
  CREATE TABLE folders (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT    NOT NULL,
      parent     INTEGER REFERENCES folders(id),
      library    TEXT    NOT NULL CHECK (library IN ('audio', 'image', 'video')),
      work_id    INTEGER REFERENCES works(id) ON DELETE SET NULL,
      cover_path TEXT,
      cover_crop TEXT,
      UNIQUE(name, parent)
    )
  ''',
  '''
  CREATE TABLE folder_paths (
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      path      TEXT    NOT NULL,
      recursive INTEGER NOT NULL DEFAULT 1
    )
  ''',
  '''
  CREATE TABLE tags (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      namespace  TEXT    NOT NULL DEFAULT 'general',
      name       TEXT    NOT NULL,
      color      TEXT    NOT NULL DEFAULT '#cba6f7',
      UNIQUE(namespace, name)
    )
  ''',
  '''
  CREATE TABLE media_tags (
      media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      tag_id   INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
      PRIMARY KEY (media_id, tag_id)
    )
  ''',
  '''
  CREATE TABLE folder_tags (
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      tag_id    INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
      PRIMARY KEY (folder_id, tag_id)
    )
  ''',
  '''
  CREATE TABLE play_history (
      id        INTEGER PRIMARY KEY AUTOINCREMENT,
      media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      played_at INTEGER NOT NULL
    )
  ''',
  '''
  CREATE TABLE media_segments (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      media_id   INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      start_ms   INTEGER NOT NULL,
      end_ms     INTEGER NOT NULL,
      name       TEXT,
      created_at INTEGER NOT NULL
    )
  ''',
  '''
  CREATE TABLE reading_spreads (
      volume_id      INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      left_media_id  INTEGER NOT NULL REFERENCES media(id)   ON DELETE CASCADE,
      right_media_id INTEGER NOT NULL REFERENCES media(id)   ON DELETE CASCADE,
      PRIMARY KEY (volume_id, left_media_id)
    )
  ''',
  '''
  CREATE TABLE reading_progress (
      volume_id  INTEGER PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
      media_id   INTEGER REFERENCES media(id) ON DELETE SET NULL,
      page_index INTEGER NOT NULL DEFAULT 0,
      finished   INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    )
  ''',
  "CREATE VIEW images AS SELECT * FROM media WHERE media_type = 'image'",
  "CREATE VIEW tracks AS SELECT * FROM media WHERE media_type = 'audio'",
];

/// 造一个指定版本号与结构的老库。
Future<Database> openLegacy(
    String path, int version, List<String> statements) async {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, v) async {
        for (final sql in statements) {
          await db.execute(sql);
        }
      },
    ),
  );
}

/// 按真实开库路径重开：onUpgrade 走 Tables.applyMigrations。
Future<Database> reopenLatest(String path) async {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: Tables.version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        await Tables.createAll(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await Tables.applyMigrations(db, oldVersion, newVersion);
      },
    ),
  );
}

void main() {
  sqfliteFfiInit();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('asmrshelf_v5');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('v10 建库：media 四值、库归属只认 audio 与 media、路径唯一', () async {
    final db = await openFresh('${dir.path}/fresh.db');

    // ── 表与视图分离：tracks 是只读视图，不是表 ──
    final objs = await db.rawQuery(
        "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')");
    final tables = objs
        .where((r) => r['type'] == 'table')
        .map((r) => r['name'])
        .toSet();
    final views =
        objs.where((r) => r['type'] == 'view').map((r) => r['name']).toSet();
    expect(
        tables,
        containsAll([
          'works',
          'media',
          'folders',
          'folder_paths',
          'tags',
          'media_tags',
          'folder_tags',
          'play_history',
        ]));
    expect(tables, isNot(contains('tracks')));
    expect(tables, isNot(contains('images')));
    expect(views, {'tracks'});
    expect(tables, isNot(contains('reading_spreads')),
        reason: 'v10 删掉这张从没写过的表');

    // ── media_type 四个值都能落库，第五个被 CHECK 挡掉 ──
    for (final type in MediaType.allValues) {
      await db.insert('media', {
        'path': '/m/$type.bin',
        'media_type': type,
        'filename': '$type.bin',
        'added_at': 1,
      });
    }
    expect(await db.query('media'), hasLength(4));
    await expectLater(
      db.insert('media', {
        'path': '/m/other.bin',
        'media_type': 'document',
        'filename': 'other.bin',
        'added_at': 1,
      }),
      throwsA(anything),
    );

    // ── works.library 只认 audio 与 media（v10 起图片与视频合进多媒体栏） ──
    await db.insert('works',
        {'name': '专辑', 'library': 'audio', 'sort_order': 0, 'created_at': 1});
    await db.insert('works',
        {'name': '剧集', 'library': 'media', 'sort_order': 0, 'created_at': 1});
    for (final gone in ['image', 'video', 'document']) {
      await expectLater(
        db.insert('works', {
          'name': '该被挡掉的 $gone',
          'library': gone,
          'sort_order': 0,
          'created_at': 1,
        }),
        throwsA(anything),
        reason: '$gone 不再是合法的库归属',
      );
    }

    // ── media 与 works 的列：v10 删掉 hash、note 与 works.cover_crop ──
    final mediaColumns = await _columns(db, 'media');
    expect(mediaColumns, isNot(contains('hash')));
    expect(mediaColumns, isNot(contains('note')));
    expect(mediaColumns, contains('sort_key'));
    expect(mediaColumns, contains('play_position_ms'));
    expect(await _columns(db, 'works'), isNot(contains('cover_crop')));
    expect(await _columns(db, 'folders'), containsAll(
        ['cover_path', 'cover_crop', 'reading_direction', 'reading_fit']));
    final idxNames = (await db.rawQuery("SELECT name FROM sqlite_master "
            "WHERE type = 'index'"))
        .map((r) => r['name'])
        .toSet();
    expect(idxNames, contains('idx_media_sort_key'));
    expect(idxNames, isNot(contains('idx_media_hash')));

    // folders 的阅读模式列有默认值
    final folderId = await db.insert('folders',
        {'name': '阅读根', 'parent': null, 'library': 'media', 'work_id': null});
    final folderRow =
        (await db.query('folders', where: 'id = ?', whereArgs: [folderId])).first;
    expect(folderRow['reading_direction'], 'rtl');
    expect(folderRow['reading_fit'], 'page');
    expect(folderRow['cover_path'], isNull);
    expect(folderRow['cover_crop'], isNull);

    // ── folders.library 只认 audio 与 media ──
    await db.insert('folders',
        {'name': '根', 'parent': null, 'library': 'audio', 'work_id': null});
    for (final gone in ['image', 'video', 'subtitle']) {
      await expectLater(
        db.insert('folders', {
          'name': '该被挡掉的 $gone',
          'parent': null,
          'library': gone,
          'work_id': null,
        }),
        throwsA(anything),
        reason: '$gone 不再是合法的库归属',
      );
    }

    // ── media.path 唯一：同一个文件不会进两行 ──
    await expectLater(
      db.insert('media', {
        'path': '/m/audio.bin',
        'media_type': 'audio',
        'filename': 'audio.bin',
        'added_at': 2,
      }),
      throwsA(anything),
    );

    expect((await db.rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
    await db.close();
  });

  test('folder_paths 默认 recursive=1，唯一索引挡住重复路径', () async {
    final db = await openFresh('${dir.path}/paths.db');
    await db.insert('folders', {'name': '根', 'library': 'audio'});
    await db
        .insert('folder_paths', {'folder_id': 1, 'path': '/m/x', 'recursive': 1});
    await db.insert('folder_paths', {'folder_id': 1, 'path': '/m/set'});
    final loose = (await db.query('folder_paths',
            where: 'path = ?', whereArgs: ['/m/set']))
        .single;
    expect(loose['recursive'], 1, reason: 'v5 起 folder_paths 默认递归');

    final dup = await db.insert(
        'folder_paths', {'folder_id': 1, 'path': '/m/x', 'recursive': 0},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    expect(dup, 0, reason: 'INSERT OR IGNORE 不该再插一行');
    expect(await db.query('folder_paths'), hasLength(2));

    await db.insert('folders', {'name': '另一个根', 'library': 'audio'});
    final other = await db.insert(
        'folder_paths', {'folder_id': 2, 'path': '/m/x'},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    expect(other, greaterThan(0), reason: '唯一约束只约束 (folder_id, path) 组合');
    await db.close();
  });

  test('MediaDao 补全 ext 与 name_lower，tracks 视图只读', () async {
    final db = await openFresh('${dir.path}/media.db');
    final media = MediaDao(db);

    await media.insertRow({
      'path': '/m/Album/A.MP3',
      'media_type': 'audio',
      'filename': 'A.MP3',
      'added_at': 1,
    });
    await media.insertRow({
      'path': '/m/Album/p.png',
      'media_type': 'image',
      'filename': 'p.png',
      'added_at': 1,
    });

    final item = await media.getByPath('/m/Album/A.MP3');
    expect(item, isNotNull);
    expect(item!.ext, '.mp3', reason: 'ext 统一小写且带点');
    expect(item.nameLower, '/m/album/a.mp3');
    expect(item.mediaType, MediaType.audio);

    expect(await db.query('tracks'), hasLength(1));
    expect(
        (await db.query('media',
                    where: 'media_type = ?', whereArgs: ['image']))
            .single['filename'],
        'p.png');
    await expectLater(
      db.insert('tracks', {'path': '/x', 'filename': 'x', 'added_at': 1}),
      throwsA(anything),
      reason: '视图只读，写入必须走 media 表',
    );

    expect(await media.count(type: MediaType.audio), 1);
    expect(await media.count(), 2);
    expect(await media.existingPaths(['/m/Album/A.MP3', '/nope'],
        type: MediaType.audio), {'/m/Album/A.MP3'});
    expect(await media.existingPaths(['/m/Album/p.png'],
        type: MediaType.audio), isEmpty, reason: '类型不匹配不算已入库');

    // 文件删除：外键级联清掉标签关联与播放历史
    final imageId = (await media.getByPath('/m/Album/p.png'))!.id!;
    final tagId = await db.insert('tags', {'namespace': 'general', 'name': '风景'});
    await db
        .insert('media_tags', {'media_id': imageId, 'tag_id': tagId});
    await db.insert(
        'play_history', {'media_id': imageId, 'played_at': 10});
    await media.deleteByPaths(['/m/Album/p.png'], type: MediaType.image);
    expect(await db.query('media_tags'), isEmpty);
    expect(await db.query('play_history'), isEmpty);
    await db.close();
  });

  test('规则标签翻成列条件，普通标签仍走 media_tags', () async {
    final db = await openFresh('${dir.path}/rules.db');
    final media = MediaDao(db);
    final tags = TagDao(db);
    final tracks = TrackDao(db);

    final a1 = await tracks.insert(
        TrackItem(path: '/m/a1.mp3', filename: 'a1.mp3', addedAt: 1));
    final a2 = await tracks.insert(
        TrackItem(path: '/m/a2.flac', filename: 'a2.flac', addedAt: 1));
    await media.insertRow({
      'path': '/m/p.png',
      'media_type': 'image',
      'filename': 'p.png',
      'added_at': 1,
    });

    // ── 翻译：kind 只看四个媒体类型，ext 只认字母数字且补点 ──
    expect(TagDao.ruleTagSql(TagRef('kind:audio')), "media_type = 'audio'");
    expect(TagDao.ruleTagSql(TagRef('kind:AUDIO')), "media_type = 'audio'");
    expect(TagDao.ruleTagSql(TagRef('ext:VTT')), "ext = '.vtt'");
    expect(TagDao.ruleTagSql(TagRef('ext:.flac')), "ext = '.flac'");
    expect(TagDao.ruleTagSql(TagRef('kind:document')), isNull);
    expect(TagDao.ruleTagSql(TagRef('ext:a b')), isNull);
    expect(TagDao.ruleTagSql(TagRef('general:纯音乐')), isNull);
    expect(TagDao.ruleTagSql(TagRef('kind:audio', quoted: true)), isNull,
        reason: '带引号的是普通标签名，不是规则');

    // ── 求值：音频筛选永远只看 audio，图片行不会混进来 ──
    expect(await tags.getTrackIdsByExpression('kind:audio', []), {a1, a2});
    expect(await tags.getTrackIdsByExpression('ext:mp3', []), {a1});
    expect(await tags.getTrackIdsByExpression('kind:audio&&ext:flac', []),
        {a2});
    expect(await tags.getTrackIdsByExpression('kind:audio&&!ext:mp3', []),
        {a2});
    expect(await tags.getTrackIdsByExpression('kind:image', []), isEmpty);

    // ── 普通标签仍然走 media_tags ──
    final fav = await tags.insert(const Tag(name: '收藏'));
    await tags.addTagToTrack(a2, fav.id!);
    expect(await tags.getTrackIdsByExpression('收藏', [fav]), {a2});
    expect(await tags.getTrackIdsByExpression('kind:audio&&收藏', [fav]),
        {a2});

    // ── 规则标签的定义行可以补齐，重复调用不产生重复行 ──
    await tags.ensureRuleTags(extNames: ['.mp3', 'vtt']);
    await tags.ensureRuleTags(extNames: ['.mp3', 'vtt']);
    final kinds = await tags.listByNamespace(TagDao.kindNamespace);
    final exts = await tags.listByNamespace(TagDao.extNamespace);
    expect(kinds.map((t) => t.name).toSet(), MediaType.allValues.toSet());
    expect(exts.map((t) => t.name).toSet(), {'mp3', 'vtt'});
    await db.close();
  });

  test('v9 老库带着 reading_spreads 升级：外键开着也能清库重建', () async {
    final path = '${dir.path}/v9_real.db';
    final old = await openLegacy(path, 9, _v9Statements);
    await old.insert('works', {
      'name': '图集',
      'library': 'image',
      'sort_order': 0,
      'created_at': 1,
    });
    await old.insert('folders', {
      'name': '第1卷',
      'parent': null,
      'library': 'image',
      'work_id': 1,
    });
    await old.insert('media', {
      'path': '/m/a.png',
      'media_type': 'image',
      'filename': 'a.png',
      'added_at': 1,
    });
    // 这张表 v10 已经删掉。旧库里有它，它的外键指向 media 与 folders：
    // 清库时漏删它，删掉 media 之后下一次 DDL 就会报 no such table: main.media。
    await old.insert('reading_spreads', {
      'volume_id': 1,
      'left_media_id': 1,
      'right_media_id': 1,
    });
    await old.close();

    final db = await reopenLatest(path);

    final names = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"))
        .map((r) => r['name'] as String)
        // sqlite_sequence 是 AUTOINCREMENT 自带的，不算残留
        .where((n) => !n.startsWith('sqlite_'))
        .toSet();
    // 一张不留：老库里的 reading_spreads 与 images 视图都不该剩下来
    expect(names, {
      'works',
      'media',
      'folders',
      'folder_paths',
      'tags',
      'media_tags',
      'folder_tags',
      'play_history',
      'media_segments',
      'reading_progress',
      'tracks',
    });
    expect(await db.getVersion(), Tables.version);
    // 重建之后照常能用
    await WorkDao(db).create('新作品', library: 'media');
    expect((await db.query('works')).length, 1);
    await db.close();
  });

  test('v9 升 v10：结构不兼容就删表重建，老行与旧结构一起清掉', () async {
    final path = '${dir.path}/v9.db';
    final old = await openLegacy(path, 9, _v9Statements);
    await old.insert('works', {
      'name': '图集',
      'library': 'image',
      'cover_path': '/m/c.png',
      'cover_crop': '0,0,1,1',
      'sort_order': 3,
      'created_at': 11,
    });
    await old.insert('folders', {
      'name': '第1卷',
      'parent': null,
      'library': 'image',
      'work_id': 1,
    });
    await old.insert('media', {
      'path': '/m/第10话.png',
      'media_type': 'image',
      'filename': '第10话.png',
      'added_at': 5,
      'hash': 'deadbeef',
      'note': '老备注',
    });
    expect(await old.getVersion(), 9);
    await old.close();

    final db = await reopenLatest(path);
    expect(await db.getVersion(), Tables.version);

    // 老行清空：非兼容式升级按删表重建处理
    expect(await db.query('works'), isEmpty);
    expect(await db.query('folders'), isEmpty);
    expect(await db.query('media'), isEmpty);

    // 结构是新版：旧列与旧视图都不在了
    final mediaColumns = await _columns(db, 'media');
    expect(mediaColumns, isNot(contains('hash')));
    expect(mediaColumns, isNot(contains('note')));
    expect(mediaColumns, contains('play_position_ms'));
    expect(await _columns(db, 'works'), isNot(contains('cover_crop')));
    final objs = await db.rawQuery(
        "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')");
    final views =
        objs.where((r) => r['type'] == 'view').map((r) => r['name']).toSet();
    expect(views, {'tracks'}, reason: '老的 images 视图要跟着删掉');
    final tables = objs
        .where((r) => r['type'] == 'table')
        .map((r) => r['name'])
        .toSet();
    expect(tables, isNot(contains('reading_spreads')));

    // 新库能直接收下多媒体作品与多媒体文件夹
    await db.insert('works',
        {'name': '混合集', 'library': 'media', 'sort_order': 0, 'created_at': 12});
    await db.insert('folders',
        {'name': '混合根', 'parent': null, 'library': 'media', 'work_id': 1});
    expect(
        (await db.rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
    await db.close();
  });

  test('更老的 v6 库走同一条删表重建，不依赖版本链', () async {
    final path = '${dir.path}/v6.db';
    final old = await openLegacy(path, 6, _v6Statements);
    await old.insert('works', {
      'name': '专辑A',
      'library': 'audio',
      'sort_order': 3,
      'created_at': 11,
    });
    await old.insert('folders', {
      'name': '卷1',
      'parent': null,
      'library': 'audio',
      'work_id': 1,
    });
    await old.insert('media', {
      'path': '/m/第10话.mp3',
      'media_type': 'audio',
      'filename': '第10话.mp3',
      'added_at': 5,
    });
    expect(await old.getVersion(), 6);
    await old.close();

    final db = await reopenLatest(path);
    expect(await db.getVersion(), Tables.version);
    expect(await db.query('works'), isEmpty);
    expect(await db.query('media'), isEmpty);
    expect(await _columns(db, 'media'), contains('sort_key'));
    expect(await _columns(db, 'media'), isNot(contains('hash')));
    expect(
        (await db.rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
    await db.close();
  });

  test('版本号没变就不动库：重开同版本不清数据', () async {
    final path = '${dir.path}/same.db';
    final db = await openFresh(path);
    await db.insert('media', {
      'path': '/m/留着的.mp3',
      'media_type': 'audio',
      'filename': '留着的.mp3',
      'added_at': 1,
    });
    await db.close();

    final again = await reopenLatest(path);
    expect(await again.query('media'), hasLength(1), reason: '同版本不该被清库');
    await again.close();
  });

  test('setPlayPosition 只写音频行，tracks 视图跟着读出新列', () async {
    final db = await openFresh('${dir.path}/playpos_write.db');
    final media = MediaDao(db);
    final tracks = TrackDao(db);

    final audioId = await tracks.insert(const TrackItem(
      path: '/m/听过一半.mp3',
      filename: '听过一半.mp3',
      addedAt: 7,
      durationMs: 200000,
    ));
    final imageId = await media.insertRow({
      'path': '/m/封面.png',
      'media_type': 'image',
      'filename': '封面.png',
      'added_at': 8,
    });

    await media.setPlayPosition(audioId, 83000);
    expect(
        (await db.query('media', where: 'id = ?', whereArgs: [audioId]))
            .single['play_position_ms'],
        83000);
    await media.setPlayPosition(imageId, 5000);
    expect(
        (await db.query('media', where: 'id = ?', whereArgs: [imageId]))
            .single['play_position_ms'],
        0,
        reason: '播放位置是音频的事，不该写到图片行上');
    expect((await tracks.getById(audioId))!.playPositionMs, 83000,
        reason: 'tracks 视图是 SELECT *，新列要能跟着读出来');
    await db.close();
  });

  test('TrackItem 的播放位置能往返，copyWith 能改也能清零', () async {
    final db = await openFresh('${dir.path}/playpos.db');
    final tracks = TrackDao(db);

    final id = await tracks.insert(const TrackItem(
      path: '/m/a.mp3',
      filename: 'a.mp3',
      addedAt: 1,
      durationMs: 200000,
      playPositionMs: 83000,
    ));
    expect((await tracks.getById(id))!.playPositionMs, 83000);
    expect((await tracks.getById(id))!.toMap()['play_position_ms'], 83000);

    // 清零也要能写回去（一首听完就该从头播）
    await tracks.update(TrackItem(
      id: id,
      path: '/m/a.mp3',
      filename: 'a.mp3',
      addedAt: 1,
      durationMs: 200000,
      playPositionMs: 0,
    ));
    expect((await tracks.getById(id))!.playPositionMs, 0);

    // 不给位置就是 0：老调用点不用改
    final other = await tracks.insert(
        const TrackItem(path: '/m/b.mp3', filename: 'b.mp3', addedAt: 2));
    expect((await tracks.getById(other))!.playPositionMs, 0);
    final otherTrack = (await tracks.getById(other))!;
    expect(otherTrack.copyWith(playPositionMs: 9000).playPositionMs, 9000);

    await db.close();
  });

  test('MediaDao 落 sort_key，查询按自然序返回', () async {
    final db = await openFresh('${dir.path}/sort.db');
    final media = MediaDao(db);
    for (final name in ['第10话.mp3', '第2话.mp3', '第1话.mp3', '封面.png']) {
      await media.insertRow({
        'path': '/m/第1卷/$name',
        'media_type': name.endsWith('.png') ? 'image' : 'audio',
        'filename': name,
        'added_at': 1,
      });
    }

    final item = await media.getByPath('/m/第1卷/第10话.mp3');
    expect(item!.sortKey, '第0010话.mp3', reason: 'insertRow 应自动补 sort_key');

    final audio = await media.queryAll(type: MediaType.audio);
    expect(audio.map((m) => m.filename).toList(),
        ['第1话.mp3', '第2话.mp3', '第10话.mp3'],
        reason: '第 10 话必须排在第 2 话之后');

    // 同一目录给两遍，跨批次合并去重后仍要走自然序
    final merged = await media
        .queryByDirs(['/m/第1卷/', '/m/第1卷/'], type: MediaType.audio);
    expect(merged.map((m) => m.filename).toList(),
        ['第1话.mp3', '第2话.mp3', '第10话.mp3']);
    expect(merged, hasLength(3), reason: '同一行不该出现两次');

    // 老行 sort_key 为空时回落到文件名排序，不报错
    await db.update('media', {'sort_key': null},
        where: 'filename = ?', whereArgs: ['第2话.mp3']);
    final fallback = await media.queryAll(type: MediaType.audio);
    expect(fallback.map((m) => m.filename), contains('第2话.mp3'));

    await db.close();
  });

  test('WorkDao.delete 在一个事务里摘归属并删作品', () async {
    final db = await openFresh('${dir.path}/delete.db');

    final dao = WorkDao(db);
    final work = await dao.create('待删专辑');
    await db.insert('folders',
        {'name': '根', 'parent': null, 'work_id': work.id, 'library': 'audio'});
    await db.insert('folders',
        {'name': '子', 'parent': 1, 'work_id': work.id, 'library': 'audio'});

    await dao.delete(work.id!);

    expect(await dao.getById(work.id!), isNull, reason: '作品应已删除');
    final folders = await db.query('folders');
    expect(folders.length, 2, reason: '文件夹不该被删，只该摘归属');
    for (final f in folders) {
      expect(f['work_id'], isNull);
    }

    await db.close();
  });

  test('DatabaseManager.init 给老行回填 sort_key（补零，修自然序）', () async {
    PathProviderPlatform.instance = FakePathProvider(
      p.join(dir.path, 'support'),
    );
    DataDirService.instance.resetCache();

    // 先建库并塞一批「老行」：sort_key 为 NULL（v7 的 ALTER TABLE 只加列不回填）
    await DatabaseManager.instance.init();
    final names = ['第1话.jpg', '第10话.jpg', '第2话.jpg'];
    for (var i = 0; i < names.length; i++) {
      await DatabaseManager.instance.db.insert('media', {
        'path': p.join(dir.path, 'pics', names[i]),
        'media_type': MediaType.image.value,
        'filename': names[i],
        'added_at': i,
        'sort_key': null,
      });
    }
    expect(
      (await DatabaseManager.instance.db.query(
        'media',
      )).every((r) => r['sort_key'] == null),
      isTrue,
      reason: '前提：老行没有 sort_key',
    );
    await DatabaseManager.instance.close();

    // 重开：init 里那一步回填应该把补零后的键写回去
    await DatabaseManager.instance.init();
    final rows = await DatabaseManager.instance.db.query(
      'media',
      columns: ['filename', 'sort_key'],
    );
    String keyOf(String filename) =>
        rows.firstWhere((r) => r['filename'] == filename)['sort_key'] as String;
    expect(keyOf('第1话.jpg'), '第0001话.jpg');
    expect(keyOf('第2话.jpg'), '第0002话.jpg');
    expect(keyOf('第10话.jpg'), '第0010话.jpg');

    // 自然序因此恢复：字符串序会把 10 排到 2 前面
    final items = await MediaDao(
      DatabaseManager.instance.db,
    ).queryAll(type: MediaType.image);
    expect(items.map((m) => m.filename).toList(), [
      '第1话.jpg',
      '第2话.jpg',
      '第10话.jpg',
    ]);

    // 幂等：都补完了，再开一次不再改动
    final before = {for (final r in rows) r['filename']: r['sort_key']};
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    final after = {
      for (final r in await DatabaseManager.instance.db.query(
        'media',
        columns: ['filename', 'sort_key'],
      ))
        r['filename']: r['sort_key'],
    };
    expect(after, before);
    await DatabaseManager.instance.close();
  });
}

