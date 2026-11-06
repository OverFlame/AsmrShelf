import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/dlsite/manual_series.dart';

void main() {
  test('ManualSeries JSON 往返保留 id、名称与去重后的作品', () {
    const series = ManualSeries(
      id: 'm1',
      name: '我的系列',
      workIds: [1, 2],
    );
    final restored = ManualSeries.tryFromJson(series.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, 'm1');
    expect(restored.name, '我的系列');
    expect(restored.workIds, [1, 2]);
  });

  test('坏条目返回 null，缺作品也返回 null', () {
    expect(ManualSeries.tryFromJson(null), isNull);
    expect(ManualSeries.tryFromJson({'id': '', 'name': 'x', 'workIds': [1]}), isNull);
    expect(ManualSeries.tryFromJson({'id': 'm1', 'name': 'x', 'workIds': []}), isNull);
    expect(ManualSeries.tryFromJson({'id': 'm1', 'name': 'x', 'workIds': '1'}), isNull);
  });

  test('重复、非法与非正数作品 id 会被丢掉', () {
    final restored = ManualSeries.tryFromJson({
      'id': ' m1 ',
      'name': ' 系列 ',
      'workIds': [1, 1, 0, -3, '2', 2.0],
    });
    expect(restored, isNotNull);
    expect(restored!.id, 'm1');
    expect(restored.name, '系列');
    expect(restored.workIds, [1, 2]);
  });
}
