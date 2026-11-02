import 'package:sqflite/sqflite.dart';

import '../utils/log_util.dart';
import 'media_rules.dart';

/// 一条字幕行（`media` 表里 `media_type = 'subtitle'` 的行）。
class SubtitleEntry {
  const SubtitleEntry({
    required this.id,
    required this.path,
    required this.filename,
    this.ext = '',
    this.audioId,
    this.isDefault = false,
    this.language,
  });

  /// `media.id`
  final int id;

  /// 绝对路径
  final String path;

  /// 文件名（含扩展名）
  final String filename;

  final String ext;

  /// 归属的音频行 = `media.subtitle_of`；null 表示未归属
  final int? audioId;

  /// `media.is_default_subtitle`
  final bool isDefault;

  /// 从文件名解析出的规范语言标签，如 `zh-Hans` / `ja`；解析不出为 null
  final String? language;

  SubtitleEntry copyWith({int? audioId, bool clearAudioId = false, bool? isDefault}) {
    return SubtitleEntry(
      id: id,
      path: path,
      filename: filename,
      ext: ext,
      audioId: clearAudioId ? null : (audioId ?? this.audioId),
      isDefault: isDefault ?? this.isDefault,
      language: language,
    );
  }

  @override
  String toString() =>
      'SubtitleEntry(id=$id, path=$path, audio=$audioId, default=$isDefault, '
      'lang=$language)';
}

/// 字幕归属模型（BUILD_GUIDE 第 23.6 节）。
///
/// 归属关系只存在 `media.subtitle_of`（指向音频行），`media.subtitle_path`
/// 在新模型下废弃、本服务不读不写。
///
/// 默认字幕的三级顺序（第 23.6 节原文「用户上次选定 → 文件名完全匹配 →
/// 语言优先级」）：
/// 1. 该音频已经有一条 `is_default_subtitle = 1` 的行 → 直接保留；
/// 2. 否则按文件名的匹配档位取最好的一条：
///    - 档 0：字幕主干 == 音频文件名（`a.mp3.srt`）
///    - 档 1：字幕主干 == 音频去扩展名（`a.srt`）
///    - 档 2：其余（带语言后缀的 `a.zh.srt` 等）
/// 3. 档位并列时按语言优先级；语言并列时按路径字典序，路径也相同按 id。
///
/// 语言优先级：`zh-Hans` > `zh-Hant` > `ja` > `en` > `ko` > 其它 > 无语言。
class SubtitleService {
  SubtitleService(this._db);

  static const String _table = 'media';

  final Database _db;

  /// 文件名里能认出的语言词 → 规范标签
  static const Map<String, String> languageByToken = <String, String>{
    'zh': 'zh-Hans',
    'chs': 'zh-Hans',
    'chi': 'zh-Hans',
    'sc': 'zh-Hans',
    '简': 'zh-Hans',
    'cht': 'zh-Hant',
    'tc': 'zh-Hant',
    '繁': 'zh-Hant',
    'jpn': 'ja',
    'jp': 'ja',
    '日': 'ja',
    'eng': 'en',
    '英': 'en',
    'kor': 'ko',
  };

  /// 语言优先级，越靠前越优先
  static const List<String> languageOrder = <String>[
    'zh-Hans',
    'zh-Hant',
    'ja',
    'en',
    'ko',
  ];

  /// 语言优先级的名次；认不出或无语言排在最后
  static int languageRank(String? language) {
    if (language == null) return languageOrder.length + 1;
    final index = languageOrder.indexOf(language);
    return index < 0 ? languageOrder.length : index;
  }

  /// 从字幕路径解析规范语言标签。
  ///
  /// 只看主干的词元（按 `.` `-` `_` 空白 `&` `+` 切分），也认连写的 CJK
  /// 语言字（`第01话.简日.srt` → `zh-Hans`）。同一文件里认出多个语言时取
  /// 优先级最高的那个。
  static String? languageOfPath(String path) {
    final stem = stemOfPath(path);
    String? best;
    var bestRank = 1 << 30;
    for (final token in stem.split(RegExp(r'[.\-_\s&+]+'))) {
      for (final candidate in _languageTokensOf(token)) {
        final language = languageByToken[candidate];
        if (language == null) continue;
        final rank = languageRank(language);
        if (rank < bestRank) {
          bestRank = rank;
          best = language;
        }
      }
    }
    return best;
  }

  /// 文件名的匹配档位：0 最好，数值越小越优先
  static int matchRank(String subtitlePath, String audioFilename) {
    final stem = stemOfPath(subtitlePath).toLowerCase();
    final audio = audioFilename.toLowerCase();
    if (stem == audio) return 0;
    if (stem == stemOfPath(audio)) return 1;
    return 2;
  }

  // ═══ 查 ═══

  /// 某音频条目下的全部字幕。
  ///
  /// 排序：默认项在最前 → 匹配档位 → 语言优先级 → 路径字典序 → id。
  Future<List<SubtitleEntry>> listForAudio(int audioId) async {
    final rows = await _queryRows(
      _db,
      where: "media_type = 'subtitle' AND subtitle_of = ?",
      whereArgs: <Object?>[audioId],
    );
    final audio = await _filenameOf(audioId);
    final entries = rows.map(_entryFromRow).toList();
    entries.sort((a, b) => _compareEntries(a, b, audio));
    return entries;
  }

  /// 未归属任何音频的字幕行（界面上的「未归属」分组）
  Future<List<SubtitleEntry>> listUnassigned() async {
    final rows = await _queryRows(
      _db,
      where: "media_type = 'subtitle' AND subtitle_of IS NULL",
    );
    final entries = rows.map(_entryFromRow).toList();
    entries.sort((a, b) => _compareEntries(a, b, null));
    return entries;
  }

  /// 该音频当前的默认字幕；没有默认项返回 null（不写库）
  Future<SubtitleEntry?> defaultFor(int audioId) async {
    final rows = await _queryRows(
      _db,
      where:
          "media_type = 'subtitle' AND subtitle_of = ? AND is_default_subtitle <> 0",
      whereArgs: <Object?>[audioId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _entryFromRow(rows.first);
  }

  /// 按三级顺序选出默认字幕并写 `is_default_subtitle`。
  ///
  /// 没有字幕返回 null；已有唯一默认项时原样保留（用户上次选定优先）。
  Future<SubtitleEntry?> selectDefault(int audioId) =>
      _db.transaction((txn) => _resolveDefaultIn(txn, audioId));

  // ═══ 改 ═══

  /// 把 [subtitleId] 设为所在音频的默认字幕，同组其它行清零。
  Future<void> setDefault(int subtitleId) async {
    final row = await _row(subtitleId);
    if (row == null) {
      throw StateError('字幕行不存在: id=$subtitleId');
    }
    if (row['media_type'] != 'subtitle') {
      throw ArgumentError.value(
          subtitleId, 'subtitleId', '不是字幕行（media_type != subtitle）');
    }
    final audioId = _asInt(row['subtitle_of']);
    if (audioId == null) {
      throw StateError('字幕 id=$subtitleId 未归属任何音频，先 attach 再设默认');
    }
    await _db.rawUpdate(
      "UPDATE media SET is_default_subtitle = CASE WHEN id = ? THEN 1 ELSE 0 END "
      "WHERE media_type = 'subtitle' AND subtitle_of = ?",
      <Object?>[subtitleId, audioId],
    );
  }

  /// 把一条字幕挂到音频条目上。
  ///
  /// 挂上去先清掉它从旧归属带来的默认标记；如果新组原来没有默认项，
  /// 按三级顺序补一个。它若是旧组的默认项，旧组也会重新选一个。
  Future<void> attach(int subtitleId, int audioId) async {
    final row = await _row(subtitleId);
    if (row == null) {
      throw StateError('字幕行不存在: id=$subtitleId');
    }
    if (row['media_type'] != 'subtitle') {
      throw ArgumentError.value(
          subtitleId, 'subtitleId', '不是字幕行（media_type != subtitle）');
    }
    final audio = await _row(audioId);
    if (audio == null) {
      throw ArgumentError.value(audioId, 'audioId', '音频行不存在');
    }
    if (audio['media_type'] != 'audio') {
      throw ArgumentError.value(
          audioId, 'audioId', '不是音频行（media_type != audio）');
    }
    final oldAudioId = _asInt(row['subtitle_of']);

    await _db.transaction((txn) async {
      await txn.update(
        _table,
        <String, Object?>{'subtitle_of': audioId, 'is_default_subtitle': 0},
        where: 'id = ?',
        whereArgs: <Object?>[subtitleId],
      );
      await _resolveDefaultIn(txn, audioId);
      // 从旧组搬走可能把旧组的默认项带走了，旧组要重新选一个
      if (oldAudioId != null && oldAudioId != audioId) {
        await _resolveDefaultIn(txn, oldAudioId);
      }
    });
  }

  /// 批量挂载，返回成功挂上的条数
  Future<int> attachAll(Iterable<int> subtitleIds, int audioId) async {
    var count = 0;
    for (final id in subtitleIds.toSet()) {
      await attach(id, audioId);
      count++;
    }
    return count;
  }

  /// 解除归属。原组若因此没了默认项，自动补一个。
  Future<void> detach(int subtitleId) async {
    final row = await _row(subtitleId);
    if (row == null) return;
    final audioId = _asInt(row['subtitle_of']);
    await _db.transaction((txn) async {
      await txn.update(
        _table,
        <String, Object?>{'subtitle_of': null, 'is_default_subtitle': 0},
        where: 'id = ?',
        whereArgs: <Object?>[subtitleId],
      );
      if (audioId != null) await _resolveDefaultIn(txn, audioId);
    });
  }

  /// 删除一条条目并清理字幕关联。
  ///
  /// - 音频：连同它名下所有字幕行一起删（否则字幕会变成孤儿行）；
  /// - 字幕：只删自己；它若是默认项，同组按三级顺序补一个；
  /// - 其它类型：只删自己，指向它的字幕由 `ON DELETE SET NULL` 收尾。
  Future<void> deleteEntry(int mediaId) async {
    final row = await _row(mediaId);
    if (row == null) return;
    final type = row['media_type'] as String?;
    final audioId = _asInt(row['subtitle_of']);

    await _db.transaction((txn) async {
      if (type == 'audio') {
        final removed = await txn.delete(
          _table,
          where: "media_type = 'subtitle' AND subtitle_of = ?",
          whereArgs: <Object?>[mediaId],
        );
        if (removed > 0) {
          logDebug('SubtitleService', '随音频 $mediaId 删除 $removed 条字幕');
        }
      }
      await txn.delete(_table, where: 'id = ?', whereArgs: <Object?>[mediaId]);
      if (type == 'subtitle' && audioId != null) {
        await _resolveDefaultIn(txn, audioId);
      }
    });
  }

  /// 全库体检，返回修正的行数/组数。
  ///
  /// 1. `subtitle_of` 指向不存在的行（历史库没开外键时留下的悬空引用）；
  /// 2. `subtitle_of` 指向的不是音频行；
  /// 3. 同一音频有多条默认项，或一条都没有 → 按三级顺序收敛成一条。
  Future<int> cleanOrphans() async {
    var fixed = 0;
    await _db.transaction((txn) async {
      fixed += await txn.rawUpdate(
        'UPDATE media SET subtitle_of = NULL, is_default_subtitle = 0 '
        "WHERE media_type = 'subtitle' AND subtitle_of IS NOT NULL "
        'AND subtitle_of NOT IN (SELECT id FROM media)',
      );
      fixed += await txn.rawUpdate(
        'UPDATE media SET subtitle_of = NULL, is_default_subtitle = 0 '
        "WHERE media_type = 'subtitle' AND subtitle_of IN "
        "(SELECT id FROM media WHERE media_type <> 'audio')",
      );

      final groups = await txn.rawQuery(
        "SELECT subtitle_of AS audio_id, COUNT(*) AS total, "
        'SUM(CASE WHEN is_default_subtitle <> 0 THEN 1 ELSE 0 END) AS defaults '
        "FROM media WHERE media_type = 'subtitle' AND subtitle_of IS NOT NULL "
        'GROUP BY subtitle_of',
      );
      for (final group in groups) {
        final audioId = _asInt(group['audio_id']);
        if (audioId == null) continue;
        final defaults = (group['defaults'] as num?)?.toInt() ?? 0;
        if (defaults == 1) continue;
        final chosen = await _resolveDefaultIn(txn, audioId);
        if (chosen != null) fixed++;
      }
    });
    if (fixed > 0) {
      logInfo('SubtitleService', '字幕归属体检修正 $fixed 处');
    }
    return fixed;
  }

  // ═══ 内部 ═══

  static const List<String> _columns = <String>[
    'id',
    'path',
    'media_type',
    'filename',
    'ext',
    'subtitle_of',
    'is_default_subtitle',
  ];

  Future<Map<String, Object?>?> _row(int id) async {
    final rows = await _queryRows(_db, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> _filenameOf(int mediaId) async {
    final rows = await _db.query(
      _table,
      columns: <String>['filename', 'path'],
      where: 'id = ?',
      whereArgs: <Object?>[mediaId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    final filename = rows.first['filename'] as String?;
    if (filename != null && filename.isNotEmpty) return filename;
    return baseNameOfPath(rows.first['path'] as String? ?? '');
  }

  /// 按三级顺序定下 [audioId] 的默认字幕，返回被选中的行。
  ///
  /// 已经是唯一默认项时不再改选（第 1 级：用户上次选定）。
  Future<SubtitleEntry?> _resolveDefaultIn(
    DatabaseExecutor txn,
    int audioId,
  ) async {
    final rows = await txn.query(
      _table,
      columns: _columns,
      where: "media_type = 'subtitle' AND subtitle_of = ?",
      whereArgs: <Object?>[audioId],
    );
    if (rows.isEmpty) return null;

    final entries = rows.map(_entryFromRow).toList();
    final defaults = entries.where((e) => e.isDefault).toList();
    SubtitleEntry chosen;
    if (defaults.length == 1) {
      chosen = defaults.first;
    } else {
      final audio = await _filenameOfIn(txn, audioId);
      entries.sort((a, b) => _compareEntries(a, b, audio));
      chosen = entries.first;
    }

    await txn.rawUpdate(
      "UPDATE media SET is_default_subtitle = CASE WHEN id = ? THEN 1 ELSE 0 END "
      "WHERE media_type = 'subtitle' AND subtitle_of = ?",
      <Object?>[chosen.id, audioId],
    );
    return chosen;
  }

  Future<String> _filenameOfIn(DatabaseExecutor txn, int mediaId) async {
    final rows = await txn.query(
      _table,
      columns: <String>['filename', 'path'],
      where: 'id = ?',
      whereArgs: <Object?>[mediaId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    final filename = rows.first['filename'] as String?;
    if (filename != null && filename.isNotEmpty) return filename;
    return baseNameOfPath(rows.first['path'] as String? ?? '');
  }

  static Future<List<Map<String, Object?>>> _queryRows(
    DatabaseExecutor db, {
    String? where,
    List<Object?>? whereArgs,
    int? limit,
  }) =>
      db.query(
        _table,
        columns: _columns,
        where: where,
        whereArgs: whereArgs,
        limit: limit,
      );

  static SubtitleEntry _entryFromRow(Map<String, Object?> row) {
    final path = row['path'] as String? ?? '';
    var filename = row['filename'] as String? ?? '';
    if (filename.isEmpty) filename = baseNameOfPath(path);
    // ext 列可能是空串（早期导入只写了 path / filename），按文件名补出来
    var ext = row['ext'] as String? ?? '';
    if (ext.isEmpty) ext = extOfPath(filename);
    return SubtitleEntry(
      id: row['id']! as int,
      path: path,
      filename: filename,
      ext: ext,
      audioId: _asInt(row['subtitle_of']),
      isDefault: _isTruthy(row['is_default_subtitle']),
      language: languageOfPath(path.isEmpty ? filename : path),
    );
  }

  /// 排序用的比较：默认在最前 → 匹配档位 → 语言 → 路径 → id（稳定）
  static int _compareEntries(
    SubtitleEntry a,
    SubtitleEntry b,
    String? audioFilename,
  ) {
    if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
    if (audioFilename != null && audioFilename.isNotEmpty) {
      final ra = matchRank(a.path, audioFilename);
      final rb = matchRank(b.path, audioFilename);
      if (ra != rb) return ra.compareTo(rb);
    }
    final la = languageRank(a.language);
    final lb = languageRank(b.language);
    if (la != lb) return la.compareTo(lb);
    final byPath = a.path.toLowerCase().compareTo(b.path.toLowerCase());
    if (byPath != 0) return byPath;
    final byRawPath = a.path.compareTo(b.path);
    if (byRawPath != 0) return byRawPath;
    return a.id.compareTo(b.id);
  }

  static Iterable<String> _languageTokensOf(String token) sync* {
    final lower = token.toLowerCase();
    if (languageByToken.containsKey(lower)) {
      yield lower;
      return;
    }
    // 连写的 CJK 语言字：'简日' / '繁中'
    final chars = lower.split('');
    if (chars.isEmpty || chars.length > 4) return;
    var recognized = 0;
    for (final char in chars) {
      if (languageByToken.containsKey(char)) recognized++;
    }
    if (recognized == chars.length) yield* chars;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool _isTruthy(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return false;
  }
}
