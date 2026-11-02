import 'package:sqflite_common/sqlite_api.dart';

/// 数据库 DDL 建表语句
///
/// v5 起音频、图片、视频与字幕共用一张 media 表，见 BUILD_GUIDE 第 7.3 节。
/// v10 起栏目合并为「音频栏 + 多媒体栏」，库归属只剩 `audio` 与 `media`
/// 两个值，同一个文件两个栏目共用一行。
///
/// 结构不兼容时不做增量迁移：版本号对不上就删表重建，见 [applyMigrations]。
class Tables {
  Tables._();

  static const int version = 10;

  static const List<String> createStatements = [
    // 作品集：音频侧是系列，多媒体侧是剧集或漫画系列
    '''
    CREATE TABLE works (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT    NOT NULL,
      library     TEXT    NOT NULL CHECK (library IN ('audio', 'media')),
      cover_path  TEXT,
      sort_order  INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL
    )
    ''',

    // 媒体：音频、图片、视频、字幕共用
    '''
    CREATE TABLE media (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      path          TEXT    NOT NULL UNIQUE,
      media_type    TEXT    NOT NULL CHECK (media_type IN ('audio', 'image', 'video', 'subtitle')),
      ext           TEXT    NOT NULL DEFAULT '',
      name_lower    TEXT    NOT NULL DEFAULT '',
      filename      TEXT    NOT NULL,
      format        TEXT,
      file_size     INTEGER,
      file_mtime    INTEGER,
      added_at      INTEGER NOT NULL,
      title         TEXT,
      artist        TEXT,
      album         TEXT,
      duration_ms   INTEGER,
      -- 上一次播到的位置（毫秒）：磁贴右侧的已播时间与下次续播都用它，
      -- 取舍规则见 lib/services/play_position.dart
      play_position_ms INTEGER NOT NULL DEFAULT 0,
      width         INTEGER,
      height        INTEGER,
      alias         TEXT,
      subtitle_path TEXT,
      cover_path    TEXT,
      -- 自然排序键：文件名里的连续数字补零，见 BUILD_GUIDE 第 20.2 节
      sort_key      TEXT,
      -- 多字幕归属：字幕行指回它所属的音频行，见 BUILD_GUIDE 第 23.6 节
      subtitle_of         INTEGER REFERENCES media(id) ON DELETE SET NULL,
      is_default_subtitle INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_media_type ON media(media_type)',
    'CREATE INDEX IF NOT EXISTS idx_media_ext ON media(ext)',
    'CREATE INDEX IF NOT EXISTS idx_media_name_lower ON media(name_lower)',
    'CREATE INDEX IF NOT EXISTS idx_media_added_at ON media(added_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_media_title ON media(title)',
    'CREATE INDEX IF NOT EXISTS idx_media_sort_key ON media(sort_key)',
    'CREATE INDEX IF NOT EXISTS idx_media_path_nocase '
        'ON media(path COLLATE NOCASE)',
    // tracks 视图固定带 media_type 条件；复合索引让「类型 + 目录区间」
    // 一次走完，不用先按类型取全部音频再逐行过滤路径。
    'CREATE INDEX IF NOT EXISTS idx_media_type_path_nocase '
        'ON media(media_type, path COLLATE NOCASE)',
    'CREATE INDEX IF NOT EXISTS idx_media_subtitle_of ON media(subtitle_of)',

    // 虚拟文件夹（镜像磁盘目录树）。卷封面、裁剪与阅读方向都记在这一行。
    '''
    CREATE TABLE folders (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      name              TEXT    NOT NULL,
      parent            INTEGER REFERENCES folders(id),
      -- 库归属：音频与多媒体各一棵树，见 BUILD_GUIDE 第 18.2 节
      library           TEXT    NOT NULL CHECK (library IN ('audio', 'media')),
      -- 作品被删时自动摘掉归属，避免留下指向已删作品的悬空引用
      work_id           INTEGER REFERENCES works(id) ON DELETE SET NULL,
      -- 卷封面与裁剪，见 BUILD_GUIDE 第 19.2 与 21 节
      cover_path        TEXT,
      cover_crop        TEXT,
      -- 阅读模式，见 BUILD_GUIDE 第 22.2 与 22.3 节
      reading_direction TEXT    NOT NULL DEFAULT 'rtl'
                                CHECK (reading_direction IN ('rtl', 'ltr')),
      reading_fit       TEXT    NOT NULL DEFAULT 'page'
                                CHECK (reading_fit IN ('page', 'height', 'width')),
      UNIQUE(name, parent)
    )
    ''',

    // 文件夹路径映射
    '''
    CREATE TABLE folder_paths (
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      path      TEXT    NOT NULL,
      recursive INTEGER NOT NULL DEFAULT 1
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_folder_paths_path ON folder_paths(path)',
    // 同一文件夹不能重复挂同一条路径。addPath 用 INSERT OR IGNORE 去重，靠这条唯一索引生效。
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_folder_paths_unique ON folder_paths(folder_id, path)',

    // 标签
    '''
    CREATE TABLE tags (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      namespace  TEXT    NOT NULL DEFAULT 'general',
      name       TEXT    NOT NULL,
      color      TEXT    NOT NULL DEFAULT '#cba6f7',
      UNIQUE(namespace, name)
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_tags_namespace ON tags(namespace)',
    'CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name)',

    // 媒体↔标签 多对多
    '''
    CREATE TABLE media_tags (
      media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      tag_id   INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
      PRIMARY KEY (media_id, tag_id)
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_media_tags_tag ON media_tags(tag_id)',

    // 文件夹↔标签 多对多
    '''
    CREATE TABLE folder_tags (
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      tag_id    INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
      PRIMARY KEY (folder_id, tag_id)
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_folder_tags_tag ON folder_tags(tag_id)',

    // 播放历史
    '''
    CREATE TABLE play_history (
      id        INTEGER PRIMARY KEY AUTOINCREMENT,
      media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      played_at INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_play_history_media ON play_history(media_id)',
    'CREATE INDEX IF NOT EXISTS idx_play_history_time ON play_history(played_at)',

    // 收藏选段：一轨可存多段，见 BUILD_GUIDE 第 24.3 节
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
    'CREATE INDEX IF NOT EXISTS idx_media_segments_media ON media_segments(media_id)',

    // 阅读进度：一卷一条，见 BUILD_GUIDE 第 22.6 节
    '''
    CREATE TABLE reading_progress (
      volume_id  INTEGER PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
      media_id   INTEGER REFERENCES media(id) ON DELETE SET NULL,
      page_index INTEGER NOT NULL DEFAULT 0,
      finished   INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    )
    ''',

    // 过渡视图：只读，老查询按 tracks 读，写入一律走 MediaDao。
    'CREATE VIEW IF NOT EXISTS tracks AS '
        "SELECT * FROM media WHERE media_type = 'audio'",
  ];

  /// 建全表：开库时 onCreate 用。
  static Future<void> createAll(DatabaseExecutor db) async {
    for (final sql in createStatements) {
      await db.execute(sql);
    }
  }

  /// 清掉全部视图与表：删表重建之前、以及测试造空库时用。
  ///
  /// 为什么不按固定清单删：旧库会留着本轮已经删掉的表。v9 库里有
  /// `reading_spreads`，它的外键指向 `media` 与 `folders`。清单里没有它，
  /// 删掉 `media` 之后外键就指向了不存在的表。外键开着时，下一次 DDL 要重建
  /// 整份 schema，于是报 `no such table: main.media`，整个升级回滚。
  ///
  /// 现在直接扫 `sqlite_master`，一张不留；顺序按 `PRAGMA foreign_key_list`
  /// 拓扑排序，子表在前，父表在后。删父表时还有别的表引用它就同样会炸。
  static Future<void> dropAll(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT type, name FROM sqlite_master "
      "WHERE name NOT LIKE 'sqlite_%' AND name <> 'android_metadata'",
    );
    final views = <String>[];
    final tables = <String>[];
    for (final row in rows) {
      final name = row['name'] as String? ?? '';
      if (name.isEmpty) continue;
      if (row['type'] == 'view') {
        views.add(name);
      } else {
        tables.add(name);
      }
    }
    for (final name in views) {
      await db.execute('DROP VIEW IF EXISTS ${_quote(name)}');
    }
    for (final name in await _dropOrder(db, tables)) {
      await db.execute('DROP TABLE IF EXISTS ${_quote(name)}');
    }
  }

  /// 子表在前：只要还有别的表引用它，就排到后面再删。
  static Future<List<String>> _dropOrder(
      DatabaseExecutor db, List<String> tables) async {
    final present = tables.toSet();
    final parents = <String, Set<String>>{};
    for (final name in tables) {
      final fks = await db.rawQuery('PRAGMA foreign_key_list(${_quote(name)})');
      parents[name] = fks
          .map((fk) => fk['table'] as String? ?? '')
          // 自引用（media.subtitle_of、folders.parent）随本表一起消失，不算依赖
          .where((p) => p.isNotEmpty && p != name && present.contains(p))
          .toSet();
    }
    final remaining = <String>{...tables};
    final order = <String>[];
    while (remaining.isNotEmpty) {
      final droppable = remaining
          .where((t) => !remaining.any((o) => o != t && parents[o]!.contains(t)))
          .toList();
      if (droppable.isEmpty) {
        // 环状引用（SQLite 不拦建表）。剩下的按名字删，保证库是空的。
        order.addAll(remaining);
        break;
      }
      for (final t in droppable) {
        order.add(t);
        remaining.remove(t);
      }
    }
    return order;
  }

  /// 表名与列名进语句前包一层双引号。
  static String _quote(String name) => '"${name.replaceAll('"', '""')}"';

  /// 版本号对不上就删表重建：开库时 onUpgrade 用。
  ///
  /// v10 起不再维护增量迁移链。升级前 `MigrationGuard` 会先备份库文件，
  /// 启动时再由确认页等用户点头；没有确认就根本不会走到这里。
  /// 这样改 CHECK 约束、删列都不必再靠重建单表绕开，用户数据也还有退路。
  static Future<void> applyMigrations(
      DatabaseExecutor db, int oldVersion, int newVersion) async {
    if (oldVersion == newVersion) return;
    await dropAll(db);
    await createAll(db);
  }
}
