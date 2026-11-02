import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/dlsite/dlsite_models.dart';
import 'package:asmrshelf/widgets/dlsite_preview_dialog.dart';

DlsiteWork _work({bool withCover = true}) => DlsiteWork.fromJson({
      'workno': 'RJ294126',
      'work_name': '远程标题',
      'work_name_kana': 'えんきょく',
      'maker_name': '社团A',
      'series_name': '系列B',
      'series_id': 'SRI1',
      'title_work_count': 3,
      'intro_s': '这是简介',
      'regist_date': '2024-05-01 00:00:00',
      'rate_average_star': 48,
      'rate_count': 12,
      'genres': [
        {'name': 'ASMR', 'id': 1},
      ],
      'creaters': {
        'voice_by': [
          {'id': 1, 'name': '逢坂成美'},
        ],
      },
      if (withCover)
        'image_main': {'url': 'https://img.dlsite.jp/main.jpg'},
    }, rawJson: '{}');

void main() {
  testWidgets('预览显示远程字段，取消返回 null', (tester) async {
    DlsitePreviewChoice? choice;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showDlsitePreviewDialog(context, work: _work());
          },
          child: const Text('打开'),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    for (final text in [
      '社团A',
      '系列B',
      'SRI1',
      '共 3 部',
      'ASMR',
      '逢坂成美',
      '4.8 / 5（12 人）',
    ]) {
      expect(find.textContaining(text, findRichText: true), findsOneWidget,
          reason: text);
    }
    expect(find.text('这是简介'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dlsite-cancel')));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });

  testWidgets('勾选封面后应用，选择带出 applyCover', (tester) async {
    DlsitePreviewChoice? choice;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showDlsitePreviewDialog(context, work: _work());
          },
          child: const Text('打开'),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dlsite-apply-cover')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dlsite-apply')));
    await tester.pumpAndSettle();

    expect(choice, isNotNull);
    expect(choice!.applyCover, isTrue);
  });

  testWidgets('没有封面时不显示勾选框', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showDlsitePreviewDialog(context, work: _work(withCover: false)),
          child: const Text('打开'),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dlsite-apply-cover')), findsNothing);
  });

  testWidgets('命中缓存时标题旁标出本地缓存', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showDlsitePreviewDialog(context, work: _work(), fromCache: true),
          child: const Text('打开'),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('本地缓存'), findsOneWidget);
  });
}
