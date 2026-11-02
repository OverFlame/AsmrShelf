import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/dlsite/series_index.dart';

WorkMetadata _meta(
  int workId, {
  String? seriesId,
  String? seriesName,
  String? circle,
  int? total,
  String? fallbackSeries,
}) {
  final json = <String, Object?>{
    'series_id': ?seriesId,
    'series_name': ?seriesName,
    'maker_name': ?circle,
    'title_work_count': ?total,
  };
  return WorkMetadata(
    workId: workId,
    series: fallbackSeries,
    rawJson: json.isEmpty ? null : jsonEncode([json]),
  );
}

void main() {
  test('同系列编号的两部作品合成一个书套，并取总数', () {
    final index = DlsiteSeriesIndex.fromMetadata([
      _meta(1, seriesId: '100', seriesName: '雨の日', total: 3),
      _meta(2, seriesId: '100', seriesName: '雨の日', total: 4),
    ]);

    expect(index.groups, hasLength(1));
    final series = index.groups.single;
    expect(series.id, '100');
    expect(series.name, '雨の日');
    expect(series.total, 4);
    expect(series.workIds, [1, 2]);
    expect(series.badge, '2/4 部');
    expect(index.seriesFor(1), same(series));
    expect(index.seriesFor(2), same(series));
  });

  test('只有一部作品不立书套', () {
    final index = DlsiteSeriesIndex.fromMetadata([
      _meta(1, seriesId: '100', seriesName: '雨の日', total: 3),
    ]);
    expect(index.groups, isEmpty);
    expect(index.seriesFor(1), isNull);
  });

  test('没有系列编号时按社团 + 系列名回退，不同社团不合并', () {
    final index = DlsiteSeriesIndex.fromMetadata([
      _meta(1, seriesName: '雨の日', circle: 'A'),
      _meta(2, seriesName: '雨の日', circle: 'A'),
      _meta(3, seriesName: '雨の日', circle: 'B'),
      _meta(4, seriesName: '雨の日', circle: 'B'),
    ]);

    expect(index.groups, hasLength(2));
    expect(index.groups.map((s) => s.workIds), [
      [1, 2],
      [3, 4],
    ]);
  });

  test('没有社团的回退不猜，避免跨社团误并', () {
    final index = DlsiteSeriesIndex.fromMetadata([
      _meta(1, seriesName: '雨の日'),
      _meta(2, seriesName: '雨の日'),
    ]);
    expect(index.groups, isEmpty);
  });

  test('raw_json 坏掉时不崩，也不参与分组', () {
    final index = DlsiteSeriesIndex.fromMetadata([
      const WorkMetadata(workId: 1, rawJson: 'not json'),
      _meta(2, seriesId: '100', seriesName: '雨の日'),
    ]);
    expect(index.groups, isEmpty);
  });
}
