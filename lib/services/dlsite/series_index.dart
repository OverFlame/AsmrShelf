import 'dart:convert';

import '../../db/work_metadata_dao.dart';

/// 一个已导入至少两部的系列（界面上的「大作品」）。
class DlsiteSeries {
  DlsiteSeries({
    required this.key,
    required this.name,
    required this.workIds,
    this.id,
    this.total,
  });

  /// 分组键：优先 `id:<series_id>`，没有编号时退回 `name:<circle>:<系列名>`。
  final String key;

  /// DLsite 的系列编号；按名称回退分组时为 null。
  final String? id;

  /// 系列名。接口没给名称时用 `系列 <id>`。
  final String name;

  /// 接口给的系列总数（`title_work_count`），可能为 null。
  final int? total;

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

  factory DlsiteSeriesIndex.fromMetadata(List<WorkMetadata> rows) {
    final members = <String, List<_SeriesMember>>{};
    for (final row in rows) {
      final member = _SeriesMember.fromMetadata(row);
      if (member == null) continue;
      members.putIfAbsent(member.key, () => []).add(member);
    }

    final groups = <DlsiteSeries>[];
    final byWorkId = <int, DlsiteSeries>{};
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

  static _SeriesMember? fromMetadata(WorkMetadata row) {
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
    }
    if (key == null) return null;

    return _SeriesMember(
      workId: row.workId,
      key: key,
      name: name ?? '系列 $id',
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
