import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/theme/app_theme.dart';
import 'package:asmrshelf/utils/color_util.dart';

/// 回归用例：`parseHexColor` 与 `colorToHex` 必须互逆。
///
/// 此前的读侧按 AARRGGBB 解析 8 位值，而写侧输出 RRGGBBAA，等于把 alpha
/// 与红通道对调：库里存的值是对的，界面显示与 hex 输入框回填却是错的。
void main() {
  group('parseHexColor 解析顺序', () {
    test('8 位按 RRGGBBAA 读，alpha 在最后', () {
      expect(parseHexColor('#FF000080').toARGB32(), 0x80FF0000);
      expect(parseHexColor('00FF0080').toARGB32(), 0x8000FF00);
    });

    test('短格式 #RGBA 同样按 RGBA 展开', () {
      expect(parseHexColor('#F008').toARGB32(), 0x88FF0000);
      expect(parseHexColor('#0f08').toARGB32(), 0x8800FF00);
    });

    test('6 位与 3 位是不透明色', () {
      expect(parseHexColor('#FF0000').toARGB32(), 0xFFFF0000);
      expect(parseHexColor('#f00').toARGB32(), 0xFFFF0000);
    });
  });

  group('往返一致', () {
    const colors = [
      Color(0x80FF0000),
      Color(0x00112233),
      Color(0xFF00FF00),
      Color(0xFFCBA6F7),
      Color(0x12345678),
      Color(0x00000000),
    ];

    test('parseHexColor(colorToHex(c)) 还原出同一个颜色', () {
      for (final c in colors) {
        final hex = colorToHex(c);
        expect(parseHexColor(hex).toARGB32(), c.toARGB32(),
            reason: 'hex=$hex');
      }
    });

    test('颜色选择器回填的 hex 能原样解析回去', () {
      const picked = Color(0x80FF0000);
      final shown = colorToHex(picked);
      expect(shown, '#FF000080');
      expect(parseHexColor(shown).toARGB32(), picked.toARGB32());
    });

    test('不透明色写出 6 位，读回仍不透明', () {
      expect(colorToHex(const Color(0xFFFF0000)), '#FF0000');
    });
  });

  group('异常输入', () {
    test('无法解析时返回 fallback', () {
      const fallback = Color(0xFFCBA6F7);
      expect(parseHexColor('xyz').toARGB32(), fallback.toARGB32());
      expect(parseHexColor('#12').toARGB32(), fallback.toARGB32());
      expect(parseHexColor('').toARGB32(), fallback.toARGB32());
      expect(parseHexColor(null).toARGB32(), fallback.toARGB32());
      expect(parseHexColor('#GGGGGG').toARGB32(), fallback.toARGB32());
    });

    test('可以指定自己的 fallback', () {
      expect(parseHexColor('zzz', fallback: const Color(0xFF000000)).toARGB32(),
          0xFF000000);
    });
  });

  group('AppColors.parseColor 与 parseHexColor 共用一套语义', () {
    test('8 位十六进制保留 alpha', () {
      // 旧实现是 int.parse(h, radix: 16) | 0xFF000000，把 'FF000080' 的 alpha
      // 直接抹成不透明，而写侧的 colorToHex 输出的是 RRGGBBAA
      expect(AppColors.parseColor('#FF000080').toARGB32(), 0x80FF0000);
    });

    test('短格式按位展开', () {
      expect(AppColors.parseColor('#f00').toARGB32(), 0xFFFF0000);
    });

    test('解析不了时回落到主题强调色', () {
      expect(AppColors.parseColor('nope').toARGB32(),
          AppColors.accent.toARGB32());
      expect(AppColors.parseColor('').toARGB32(), AppColors.accent.toARGB32());
    });
  });
}
