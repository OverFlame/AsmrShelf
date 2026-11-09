import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/dlsite/manual_series.dart';
import 'package:asmrshelf/services/dlsite/series_index.dart';

WorkMetadata _meta(
  int workId, {
  String? seriesId,
  String? seriesName,
  String? circle,
  int? total,
  String? fallbackSeries,
  String? title,
}) {
  final json = <String, Object?>{
    'series_id': ?seriesId,
    'series_name': ?seriesName,
    'maker_name': ?circle,
    'title_work_count': ?total,
  };
  return WorkMetadata(
    workId: workId,
    title: title,
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

  test('没有 series 字段时，从【巫女NTR】标题跨社团合并', () {
    final index = DlsiteSeriesIndex.fromMetadata(
      [
        _meta(8, circle: '无糖可乐', title: '【简体中文版】【巫女NTR】怀孕巫女 上'),
        _meta(31, circle: '五月的花緑青', title: '【简体中文版】【巫女NTR】怀孕巫女 下'),
      ],
      workNames: {
        8: '【简体中文版】【巫女NTR】怀孕巫女 上',
        31: '【简体中文版】【巫女NTR】怀孕巫女 下',
      },
    );
    expect(index.groups, hasLength(1));
    expect(index.groups.single.name, '巫女NTR');
    expect(index.groups.single.workIds, [8, 31]);
  });

  test('没有 series 字段时，从「母亲失格～」标题跨社团合并', () {
    final index = DlsiteSeriesIndex.fromMetadata(
      [
        _meta(2, circle: '五月的花緑青', title: '【简体中文版】母亲失格～在学校'),
        _meta(6, circle: 'J○大好き', title: '【简体中文版】母亲失格～在电车'),
      ],
      workNames: {
        2: '【简体中文版】母亲失格～在学校',
        6: '【简体中文版】母亲失格～在电车',
      },
    );
    expect(index.groups, hasLength(1));
    expect(index.groups.single.name, '母亲失格');
    expect(index.groups.single.workIds, [2, 6]);
  });

  test('引用语后的「冷淡妈妈」标题也能跨社团合并', () {
    final index = DlsiteSeriesIndex.fromMetadata(
      [
        _meta(68, circle: 'J○大好き',
            title: '【简体中文版】【耳边紧贴】能做除无套内射外任何事的「只有表面清纯」的冷淡妈妈和你的尽情乱伦性活'),
        _meta(70, circle: 'J○大好き',
            title: '【简体中文版】【耳旁紧贴】理解儿子的宠溺M性癖的「只有表面清纯」的冷淡妈妈和你的疯狂近亲相奸性活'),
        _meta(74, circle: '虚無の刃',
            title: '【简体中文版】【紧贴耳边】与除了无套插入以外什么都愿意做、「只有外表看似清纯」的冷淡妈妈疯狂近亲相〇的性生活2'),
      ],
      workNames: {
        68: '【简体中文版】【耳边紧贴】能做除无套内射外任何事的「只有表面清纯」的冷淡妈妈和你的尽情乱伦性活',
        70: '【简体中文版】【耳旁紧贴】理解儿子的宠溺M性癖的「只有表面清纯」的冷淡妈妈和你的疯狂近亲相奸性活',
        74: '【简体中文版】【紧贴耳边】与除了无套插入以外什么都愿意做、「只有外表看似清纯」的冷淡妈妈疯狂近亲相〇的性生活2',
      },
    );
    expect(index.groups, hasLength(1));
    expect(index.groups.single.name, '冷淡妈妈');
    expect(index.groups.single.workIds, [68, 70, 74]);
  });

  test('手动系列优先于自动系列，并且只保留有效作品', () {
    final index = DlsiteSeriesIndex.fromMetadata(
      [
        _meta(1, seriesId: '100', seriesName: '雨の日'),
        _meta(2, seriesId: '100', seriesName: '雨の日'),
      ],
      manual: const [
        ManualSeries(id: 'm1', name: '我的系列', workIds: [1, 2, 999]),
      ],
      validWorkIds: {1, 2},
    );
    expect(index.groups, hasLength(1));
    final series = index.groups.single;
    expect(series.manual, isTrue);
    expect(series.key, 'manual:m1');
    expect(series.name, '我的系列');
    expect(series.workIds, [1, 2]);
    expect(series.badge, '2 部');
  });

  test('手动系列只剩一部有效作品时不立书套', () {
    final index = DlsiteSeriesIndex.fromMetadata(
      [_meta(1, seriesId: '100', seriesName: '雨の日')],
      manual: const [
        ManualSeries(id: 'm1', name: '我的系列', workIds: [1, 999]),
      ],
      validWorkIds: {1},
    );
    expect(index.groups, isEmpty);
  });
}
