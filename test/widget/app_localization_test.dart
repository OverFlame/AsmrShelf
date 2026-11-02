import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/main.dart';

/// main.dart 里那套本地化配置：系统自带文案（返回、复制、取消等）要跟着
/// 界面语言走，不给的话中文界面里全是英文。
void main() {
  Future<BuildContext> pumpWith(WidgetTester tester, Locale locale) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      locale: locale,
      home: Builder(builder: (context) {
        captured = context;
        return const Scaffold(body: SizedBox());
      }),
    ));
    return captured;
  }

  testWidgets('中文环境下系统自带文案是中文', (tester) async {
    final ctx = await pumpWith(tester, const Locale('zh'));
    expect(MaterialLocalizations.of(ctx).backButtonTooltip, '返回');
  });

  testWidgets('英文环境下跟着变英文', (tester) async {
    final ctx = await pumpWith(tester, const Locale('en'));
    expect(MaterialLocalizations.of(ctx).backButtonTooltip, 'Back');
  });

  test('中文排第一，英文兜底', () {
    expect(appSupportedLocales.first, const Locale('zh'));
    expect(appSupportedLocales, contains(const Locale('en')));
    expect(appLocalizationsDelegates.length, 3);
  });
}
