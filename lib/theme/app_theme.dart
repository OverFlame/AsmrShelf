import 'package:flutter/material.dart';

import '../utils/color_util.dart';

/// 应用配色与主题 — 原创深色配色，语义化命名。
///
/// 提供统一色板与 Material 3 主题，浅色/深色双主题。
class AppColors {
  AppColors._();

  // ── 背景 / 表面 ──
  static const Color background = Color(0xFF1C1F27);
  static const Color panel = Color(0xFF15171D);
  static const Color deep = Color(0xFF0D0E13);
  static const Color surface = Color(0xFF262A33);
  static const Color surfaceAlt = Color(0xFF323641);
  static const Color surfaceHigh = Color(0xFF3E434F);

  // ── 弱化层级 ──
  static const Color muted = Color(0xFF5B6271);
  static const Color mutedLight = Color(0xFF727A8C);
  static const Color mutedLighter = Color(0xFF8B94A8);

  // ── 文字 ──
  static const Color textPrimary = Color(0xFFE4E8F0);
  static const Color textSecondary = Color(0xFFA9B2C4);
  static const Color textTertiary = Color(0xFFC6CEDA);

  // ── 强调色 ──
  static const Color accent = Color(0xFFA98CF5);
  static const Color danger = Color(0xFFF06E7F);
  static const Color warning = Color(0xFFE2C275);
  static const Color success = Color(0xFF9CCB86);
  static const Color teal = Color(0xFF63BFC8);
  static const Color blue = Color(0xFF7AA0F6);
  static const Color lavender = Color(0xFF9FA6EF);
  static const Color sky = Color(0xFF6FB6EC);
  static const Color pink = Color(0xFFE98AC6);

  /// 标签命名空间对应颜色（用于视觉区分）
  static const Map<String, Color> namespaceColors = {
    'general': lavender,
    'character': success,
    'copyright': warning,
    'artist': sky,
    'meta': teal,
    'rating': danger,
  };

  static Color namespaceColor(String namespace) =>
      namespaceColors[namespace] ?? accent;

  /// 解析十六进制颜色字符串（标签色点用），支持 `#RGB` / `#RRGGBB` /
  /// `#RRGGBBAA`，解析失败回落到 [accent]。
  ///
  /// 旧实现是 `int.parse(h, radix: 16) | 0xFF000000`，遇到 8 位
  /// `#RRGGBBAA` 会把红通道当 alpha 用：`#7A3E5FAA` 读出 `0xAA7A3E5F`，
  /// 红蓝对调还带上了旧的 alpha。写入口（`colorToHex`）已经是 RRGGBBAA，
  /// 这里跟 [parseHexColor] 共用一套语义，免得读写两头不一致。
  static Color parseColor(String hex) => parseHexColor(hex, fallback: accent);

  // ── 浅色常量（与深色一一对应）──
  static const Color backgroundLight = Color(0xFFF1F2F7);
  static const Color panelLight = Color(0xFFE9EBF2);
  static const Color surfaceLight = Color(0xFFD8DBE4);
  static const Color surfaceAltLight = Color(0xFFC4C8D4);
  static const Color mutedLightC = Color(0xFF8C91A4);
  static const Color mutedC = Color(0xFF7A7F93);
  static const Color textPrimaryLight = Color(0xFF3C4050);
  static const Color textSecondaryLight = Color(0xFF6C7184);
  static const Color textTertiaryLight = Color(0xFF5A6070);
  static const Color mutedLighterC = Color(0xFF9AA0B2);
  static const Color deepLight = Color(0xFFE2E4EC);
  static const Color surfaceHighLight = Color(0xFFB8BDCB);

  /// 是否深色主题
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  // ── 按当前主题亮度取色（浅色/深色自动切换）──
  static Color backgroundOf(BuildContext c) =>
      isDark(c) ? background : backgroundLight;
  static Color panelOf(BuildContext c) => isDark(c) ? panel : panelLight;
  static Color surfaceOf(BuildContext c) => isDark(c) ? surface : surfaceLight;
  static Color surfaceAltOf(BuildContext c) =>
      isDark(c) ? surfaceAlt : surfaceAltLight;
  static Color mutedOf(BuildContext c) => isDark(c) ? muted : mutedC;
  static Color mutedLightOf(BuildContext c) => isDark(c) ? mutedLight : mutedC;
  static Color textPrimaryOf(BuildContext c) =>
      isDark(c) ? textPrimary : textPrimaryLight;
  static Color textSecondaryOf(BuildContext c) =>
      isDark(c) ? textSecondary : textSecondaryLight;
  static Color textTertiaryOf(BuildContext c) =>
      isDark(c) ? textTertiary : textTertiaryLight;
  static Color mutedLighterOf(BuildContext c) =>
      isDark(c) ? mutedLighter : mutedLighterC;
  static Color deepOf(BuildContext c) => isDark(c) ? deep : deepLight;
  static Color surfaceHighOf(BuildContext c) =>
      isDark(c) ? surfaceHigh : surfaceHighLight;

  static ThemeData get lightThemeData => _buildTheme(Brightness.light);
  static ThemeData get darkThemeData => _buildTheme(Brightness.dark);
  static ThemeData get themeData => darkThemeData;

  static ThemeData _buildTheme(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: isDark ? accent : const Color(0xFF6D28D9),
      scaffoldBackgroundColor: isDark ? background : const Color(0xFFF1F2F7),

      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? panel : const Color(0xFFE9EBF2),
        foregroundColor: isDark ? textPrimary : const Color(0xFF3C4050),
        elevation: 0,
        centerTitle: false,
      ),

      cardTheme: CardThemeData(
        color: isDark ? surface : const Color(0xFFD8DBE4),
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: isDark ? surfaceAlt : const Color(0xFFC4C8D4),
        thickness: 0.5,
        space: 0,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? surface : const Color(0xFFD8DBE4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: isDark ? surfaceAlt : const Color(0xFFC4C8D4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: isDark ? surfaceAlt : const Color(0xFFC4C8D4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: isDark ? accent : const Color(0xFF6D28D9), width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: TextStyle(
          color: isDark ? muted : const Color(0xFF8C91A4)),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: isDark ? accent : const Color(0xFF6D28D9),
        foregroundColor: isDark ? background : const Color(0xFFF1F2F7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      textTheme: TextTheme(
        headlineLarge: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050),
          fontSize: 28, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050),
          fontSize: 22, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050),
          fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050),
          fontSize: 14, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050), fontSize: 14),
        bodyMedium: TextStyle(
          color: isDark ? textSecondary : const Color(0xFF6C7184), fontSize: 13),
        bodySmall: TextStyle(
          color: isDark ? textTertiary : const Color(0xFF54586B), fontSize: 12),
        labelLarge: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050),
          fontSize: 14, fontWeight: FontWeight.w500),
        labelMedium: TextStyle(
          color: isDark ? mutedLight : const Color(0xFF7A7F93), fontSize: 12),
        labelSmall: TextStyle(
          color: isDark ? muted : const Color(0xFF8C91A4), fontSize: 10),
      ),

      iconTheme: IconThemeData(
        color: isDark ? mutedLight : const Color(0xFF7A7F93), size: 20),

      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? surface : const Color(0xFFD8DBE4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            isDark ? surface : const Color(0xFFD8DBE4)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? surfaceAlt : const Color(0xFFC4C8D4),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(
          color: isDark ? textPrimary : const Color(0xFF3C4050), fontSize: 12),
      ),
    );
  }
}
