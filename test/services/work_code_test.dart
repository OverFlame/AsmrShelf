import 'package:asmrshelf/services/dlsite/work_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseWorkCode：编号在开头', () {
    test('编号加空格加标题', () {
      expect(
        parseWorkCode('RJ294126 あまあま催眠'),
        const WorkCode('RJ294126', 'あまあま催眠'),
      );
    });

    test('只有编号', () {
      expect(parseWorkCode('RJ294126'), const WorkCode('RJ294126', ''));
    });

    test('小写输入归一成大写', () {
      expect(parseWorkCode('rj294126'), const WorkCode('RJ294126', ''));
    });

    test('VJ 编号', () {
      expect(
        parseWorkCode('VJ010010 タイトル'),
        const WorkCode('VJ010010', 'タイトル'),
      );
    });

    test('八位编号', () {
      expect(
        parseWorkCode('RJ01021542_澄ました顔'),
        const WorkCode('RJ01021542', '澄ました顔'),
      );
    });

    test('连字符与下划线都当分隔符', () {
      expect(
        parseWorkCode('RJ294126 - 作品名'),
        const WorkCode('RJ294126', '作品名'),
      );
      expect(
        parseWorkCode('RJ294126_作品名'),
        const WorkCode('RJ294126', '作品名'),
      );
    });

    test('标题里带空格时保留中间的单个空格', () {
      expect(
        parseWorkCode('RJ294126  ふたり  きり'),
        const WorkCode('RJ294126', 'ふたり  きり'),
      );
    });

    test('首尾空格被忽略', () {
      expect(
        parseWorkCode('  RJ294126 作品名  '),
        const WorkCode('RJ294126', '作品名'),
      );
    });
  });

  group('parseWorkCode：编号不在开头', () {
    test('前置社团名时退到全文搜索', () {
      expect(
        parseWorkCode('[サークル] RJ294126 作品名'),
        const WorkCode('RJ294126', '[サークル] 作品名'),
      );
    });

    test('编号在末尾', () {
      expect(
        parseWorkCode('作品名 RJ294126'),
        const WorkCode('RJ294126', '作品名'),
      );
    });
  });

  group('parseWorkCode：不该认的形态', () {
    test('位数不足', () {
      expect(parseWorkCode('RJ12345 作品名'), isNull);
    });

    test('七位编号仍然有效', () {
      expect(
        parseWorkCode('RJ2941267 作品名'),
        const WorkCode('RJ2941267', '作品名'),
      );
    });

    test('位数过多', () {
      expect(parseWorkCode('RJ294126789 作品名'), isNull);
    });

    test('前缀不对', () {
      expect(parseWorkCode('RX294126 作品名'), isNull);
    });

    test('纯文字', () {
      expect(parseWorkCode('あまあま催眠'), isNull);
    });

    test('空串', () {
      expect(parseWorkCode('   '), isNull);
    });

    test('编号后面接的孤立数字归到标题', () {
      expect(parseWorkCode('RJ294126 6'), const WorkCode('RJ294126', '6'));
    });
  });

  group('findWorkCode 与 isValidWorkCode', () {
    test('从路径里取编号', () {
      expect(
        findWorkCode('/music/asmr/RJ294126 あまあま/track01.mp3'),
        'RJ294126',
      );
    });

    test('路径里没有编号时返回 null', () {
      expect(findWorkCode('/music/asmr/あまあま/track01.mp3'), isNull);
    });

    test('整串校验', () {
      expect(isValidWorkCode('RJ294126'), isTrue);
      expect(isValidWorkCode('rj294126'), isTrue);
      expect(isValidWorkCode('RJ294126 作品名'), isFalse);
      expect(isValidWorkCode('RJ12345'), isFalse);
    });
  });
}
