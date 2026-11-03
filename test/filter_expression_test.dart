import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/utils/filter_expression.dart';

void main() {
  group('FilterExpressionParser', () {
    test('解析单个标签', () {
      final ast = FilterExpressionParser.parse('风景');
      expect(ast, isA<TagRef>());
    });

    test('解析与/或/非', () {
      final ast = FilterExpressionParser.parse('A&&B||!C');
      expect(ast, isA<OrExpr>());
    });

    test('括号优先级', () {
      final ast = FilterExpressionParser.parse('(A||B)&&!C');
      expect(ast, isA<AndExpr>());
    });

    test('空表达式抛异常', () {
      expect(() => FilterExpressionParser.parse(''),
          throwsA(isA<FilterExpressionException>()));
    });

    test('未闭合括号抛异常', () {
      expect(() => FilterExpressionParser.parse('(A'),
          throwsA(isA<FilterExpressionException>()));
    });

    test('SQL 编译使用 media_tags', () {
      final ast = FilterExpressionParser.parse('A&&B');
      final sql = buildTrackIdSubquery(ast, (ref) => tagIdsSubquery([1, 2]));
      expect(sql, contains('media_id'));
      expect(sql, contains('media_tags'));
      expect(sql, contains("media_type = 'audio'"));
      expect(sql, contains('AND id IN'));
    });

    test('图片筛选使用图片作用域，不把规则标签拉回音频', () {
      final ast = FilterExpressionParser.parse('风景&&!kind:audio');
      final sql = buildTrackIdSubquery(
        ast,
        (ref) => tagIdsSubquery([1, 2]),
        scope: "SELECT id FROM media WHERE media_type = 'image'",
      );
      expect(sql, contains("media_type = 'image'"));
      expect(sql, isNot(contains("media_type = 'audio'")));
    });
  });
}
