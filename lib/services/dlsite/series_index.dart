import 'dart:convert';

import '../../db/work_metadata_dao.dart';
import 'manual_series.dart';

/// 一个已导入至少两部的系列（界面上的「大作品」）。
class DlsiteSeries {
  DlsiteSeries({
    required this.key,
    required this.name,
    required this.workIds,
    this.id,
    this.total,
    this.manual = false,
  });

  /// 分组键：优先 `id:<series_id>`，没有编号时退回 `name:<circle>:<系列名>`。
  final String key;

  /// DLsite 的系列编号；按名称回退分组时为 null。
  final String? id;

  /// 系列名。接口没给名称时用 `系列 <id>`。
  final String name;

  /// 接口给的系列总数（`title_work_count`），可能为 null。
  final int? total;

  /// 是否是用户手动建的系列；手动系列优先于元数据派生。
  final bool manual;

  /// 已导入的作品 id，按元数据行顺序；展示排序由调用方决定。
  final List<int> workIds;

  int get importedCount => workIds.length;

  /// 徽标文案：有总数时显示「已导入/总数」，否则只显示已导入数。
  String get badge => total == null ? '$importedCount 部' : '$importedCount/$total 部';
}

/// 从 `work_metadata` 派生出的系列索引。
///
/// 不改 schema：系列身份从 `raw_json` 里取，按 `work_id + updated_at` 重建。
/// 只有已导入 ≥2 部的系列才进入 [groups]；单部作品仍按普通作品卡展示。
class DlsiteSeriesIndex {
  DlsiteSeriesIndex._(this.byWorkId, this.groups);

  static final DlsiteSeriesIndex empty = DlsiteSeriesIndex._(
    const {},
    const [],
  );

  /// 作品 id → 所属系列；单部或没有系列信息的作品不在表里。
  final Map<int, DlsiteSeries> byWorkId;

  /// 已导入 ≥2 部的系列。
  final List<DlsiteSeries> groups;

  DlsiteSeries? seriesFor(int workId) => byWorkId[workId];

  factory DlsiteSeriesIndex.fromMetadata(
    List<WorkMetadata> rows, {
    List<ManualSeries> manual = const [],
    Map<int, String>? workNames,
    Set<int>? validWorkIds,
  }) {
    final groups = <DlsiteSeries>[];
    final byWorkId = <int, DlsiteSeries>{};
    final claimed = <int>{};

    // 手动系列优先：同一部作品只能属于一个手动系列；先占住 id，派生系列
    // 就跳过这些作品，避免一个作品同时出现在两个书套里。
    for (final item in manual) {
      final ids = <int>[];
      for (final id in item.workIds) {
        if (validWorkIds != null && !validWorkIds.contains(id)) continue;
        if (claimed.contains(id) || ids.contains(id)) continue;
        ids.add(id);
      }
      if (ids.length < 2) continue;
      final series = DlsiteSeries(
        key: 'manual:${item.id}',
        name: item.name,
        manual: true,
        workIds: List<int>.unmodifiable(ids),
      );
      groups.add(series);
      claimed.addAll(ids);
      for (final id in ids) {
        byWorkId[id] = series;
      }
    }

    final members = <String, List<_SeriesMember>>{};
    for (final row in rows) {
      if (claimed.contains(row.workId)) continue;
      final member = _SeriesMember.fromMetadata(
        row,
        workTitle: workNames?[row.workId],
      );
      if (member == null) continue;
      members.putIfAbsent(member.key, () => []).add(member);
    }

    for (final entry in members.entries) {
      final list = entry.value;
      if (list.length < 2) continue;
      final first = list.first;
      final name = first.name;
      final total = list
          .map((m) => m.total)
          .whereType<int>()
          .fold<int?>(null, (max, value) => max == null || value > max ? value : max);
      final series = DlsiteSeries(
        key: entry.key,
        id: first.id,
        name: name,
        total: total,
        workIds: List<int>.unmodifiable(list.map((m) => m.workId)),
      );
      groups.add(series);
      for (final member in list) {
        byWorkId[member.workId] = series;
      }
    }
    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return DlsiteSeriesIndex._(byWorkId, List<DlsiteSeries>.unmodifiable(groups));
  }
}

class _SeriesMember {
  _SeriesMember({
    required this.workId,
    required this.key,
    required this.name,
    required this.id,
    required this.total,
  });

  final int workId;
  final String key;
  final String name;
  final String? id;
  final int? total;

  static _SeriesMember? fromMetadata(WorkMetadata row, {String? workTitle}) {
    final data = _firstJsonObject(row.rawJson);
    final id = _text(data?['series_id']);
    final rawName = _text(data?['series_name']);
    final fallbackName = row.series?.trim();
    final name = rawName ?? (fallbackName == null || fallbackName.isEmpty ? null : fallbackName);
    final circle = _text(data?['maker_name']) ?? row.circle?.trim();

    String? key;
    if (id != null) {
      key = 'id:$id';
    } else if (name != null && circle != null && circle.isNotEmpty) {
      // 没有系列编号时才按「社团 + 系列名」回退；缺社团不猜，避免跨社团误并。
      key = 'name:$circle:$name';
    } else if (name == null) {
      // 最后才从标题里找系列：同人社团经常跨社团出同一系列，且 DLsite
      // 的商品 JSON 不一定给 series_id。只接受高置信度的标题形态。
      // 有系列名但缺社团时仍不猜，保持原来的保守口径。
      final titleName = _seriesNameFromTitle(workTitle ?? row.title);
      if (titleName != null) {
        key = 'title:${titleName.toLowerCase()}';
      }
    }
    if (key == null) return null;

    return _SeriesMember(
      workId: row.workId,
      key: key,
      name: name ?? _seriesNameFromTitle(workTitle ?? row.title) ?? '系列 $id',
      id: id,
      total: _asInt(data?['title_work_count']),
    );
  }
}

Map<String, Object?>? _firstJsonObject(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  final first = switch (decoded) {
    List list => list.isEmpty ? null : list.first,
    Map<String, Object?> single => single,
    _ => null,
  };
  return first is Map ? Map<String, Object?>.from(first) : null;
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _asInt(Object? value) => switch (value) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

/// 商品标题里常见的版本标签，不属于系列名。
const _editionTags = {
  '简体中文版',
  '繁体中文版',
  '簡体中文版',
  '繁體中文版',
  '中文版',
  '中文字幕',
  '中字',
  '日配中字',
  '日配中文字幕',
};

/// 从标题里推断系列名。
///
/// 只认三种形态，宁可少合并也不跨作品误并：
/// 1. `【简体中文版】【巫女NTR】...`：剥掉版本标签后，取开头带
///    「系列 / シリーズ / NTR」的方括号标签；
/// 2. `【简体中文版】母亲失格～...`：取 `～` / `~` 前长度至少 4 的前缀；
/// 3. 没有可识别标签时返回 null。
String? _seriesNameFromTitle(String? raw) {
  if (raw == null) return null;
  var title = raw.trim();
  if (title.isEmpty) return null;

  while (true) {
    final match = RegExp(r'^【([^】]+)】').firstMatch(title);
    if (match == null) break;
    final label = match.group(1)!.trim();
    if (!_editionTags.contains(label)) break;
    title = title.substring(match.end).trimLeft();
  }

  final bracket = RegExp(r'^【([^】]{2,30})】').firstMatch(title);
  if (bracket != null) {
    final label = bracket.group(1)!.trim();
    final lower = label.toLowerCase();
    if (lower.contains('系列') ||
        lower.contains('シリーズ') ||
        lower.contains('ntr')) {
      return label;
    }
  }

  for (final separator in const ['～', '~']) {
    final index = title.indexOf(separator);
    if (index <= 0) continue;
    final prefix = title.substring(0, index).trim();
    if (prefix.length < 4 || prefix.length > 40) continue;
    if (prefix.startsWith('【') || _editionTags.contains(prefix)) continue;
    return prefix;
  }
  return null;
}
