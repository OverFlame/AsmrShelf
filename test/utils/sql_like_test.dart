import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/db/sql_like.dart';

/// 回归用例：LIKE 模式通配符转义。
///
/// 旧实现把用户输入直接拼进 `LIKE '%$q%'`，`_` 变成「任意单字符」、
/// `%` 变成「任意串」，`2024_06` 会连 `2024-06` 一起搜出来。
void main() {
  group('escapeLike', () {
    test('下划线按字面量转义', () {
      expect(escapeLike('2024_06'), r'2024\_06');
    });

    test('百分号按字面量转义', () {
      expect(escapeLike('a%b'), r'a\%b');
    });

    test('反斜杠最先处理，不被二次转义', () {
      expect(escapeLike(r'D:\Photos'), r'D:\\Photos');
    });

    test('混合输入每个字符只转义一次', () {
      expect(escapeLike(r'D:\Photos\_2024%'), r'D:\\Photos\\\_2024\%');
    });

    test('普通字符原样返回', () {
      expect(escapeLike('IMG_0001'.replaceAll('_', 'x')), 'IMGx0001');
      expect(escapeLike('照片.jpg'), '照片.jpg');
      expect(escapeLike(''), '');
    });
  });

  test('ESCAPE 子句用的是单引号包裹的反斜杠', () {
    expect(sqlLikeEscape, r"ESCAPE '\'");
  });
}
