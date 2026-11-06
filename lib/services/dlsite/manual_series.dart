import 'package:flutter/foundation.dart';

/// 用户手动建的系列。
///
/// 不写数据库：系列只是「作品 id 的集合」，保存在 settings.json 里，启动或
/// 修改后由 [DlsiteSeriesIndex] 合并进派生索引。这样不需要改 schema，也不会
/// 因为重新抓取 DLsite 元数据而丢掉手动分组。
@immutable
class ManualSeries {
  const ManualSeries({
    required this.id,
    required this.name,
    required this.workIds,
  });

  final String id;
  final String name;
  final List<int> workIds;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'workIds': workIds,
      };

  /// 解析 settings.json 里的对象；缺字段或类型不对时返回 null。
  static ManualSeries? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final rawIds = value['workIds'];
    if (id is! String || id.trim().isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    if (rawIds is! List) return null;

    final ids = <int>[];
    for (final raw in rawIds) {
      final parsed = raw is int ? raw : (raw is num ? raw.toInt() : null);
      if (parsed != null && parsed > 0 && !ids.contains(parsed)) ids.add(parsed);
    }
    if (ids.isEmpty) return null;

    return ManualSeries(
      id: id.trim(),
      name: name.trim(),
      workIds: List<int>.unmodifiable(ids),
    );
  }
}
