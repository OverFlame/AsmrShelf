import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/color_util.dart';

/// 颜色选择对话框：色轮（色相/饱和度）+ 明度/透明度滑块 + 色号输入
/// （支持 hex / rgb / hsl 主流格式）+ 预设色。
///
/// 返回选中颜色的十六进制字符串（`#RRGGBB` 或 `#RRGGBBAA`）。
class ColorPickerDialog extends StatefulWidget {
  final String initialHex;
  const ColorPickerDialog({super.key, required this.initialHex});

  static Future<String?> show(BuildContext context,
      {required String initialHex}) {
    return showDialog<String>(
      context: context,
      builder: (_) => ColorPickerDialog(initialHex: initialHex),
    );
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

enum _ColorFormat { hex, rgb, hsl }

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late Color _color;
  late final TextEditingController _codeCtrl = TextEditingController();
  _ColorFormat _format = _ColorFormat.hex;
  bool _codeError = false;

  static const _presets = [
    '#cba6f7', '#f38ba8', '#fab387', '#f9e2af',
    '#a6e3a1', '#94e2d5', '#89dceb', '#b4befe',
    '#f5c2e7', '#e78284', '#ef9f76', '#e5c890',
    '#a6d189', '#85c1dc', '#ea999c', '#ffffff',
  ];

  @override
  void initState() {
    super.initState();
    _color = parseHexColor(widget.initialHex);
    _syncCodeField();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  HSVColor get _hsv => HSVColor.fromColor(_color);
  double get _alpha => ((_color.toARGB32() >> 24) & 0xFF) / 255;

  void _setColor(Color c, {bool fromCode = false}) {
    setState(() {
      _color = c;
      if (!fromCode) _syncCodeField();
    });
  }

  // ── 色号输入 ──
  String _formatColor(Color c) {
    switch (_format) {
      case _ColorFormat.hex:
        return colorToHex(c);
      case _ColorFormat.rgb:
        return _toRgb(c);
      case _ColorFormat.hsl:
        return _toHsl(c);
    }
  }

  String _toRgb(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final a = ((argb >> 24) & 0xFF) / 255;
    if (a >= 1) return 'rgb($r, $g, $b)';
    return 'rgba($r, $g, $b, ${a.toStringAsFixed(2)})';
  }

  String _toHsl(Color c) {
    final hsl = HSLColor.fromColor(c);
    final a = ((c.toARGB32() >> 24) & 0xFF) / 255;
    final h = hsl.hue.round();
    final s = (hsl.saturation * 100).round();
    final l = (hsl.lightness * 100).round();
    if (a >= 1) return 'hsl($h, $s%, $l%)';
    return 'hsla($h, $s%, $l%, ${a.toStringAsFixed(2)})';
  }

  Color? _parseColor(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#') || RegExp(r'^[0-9a-fA-F]{3,8}$').hasMatch(t)) {
      final c = parseHexColor(t, fallback: const Color(0x00000000));
      // 解析失败时 parseHexColor 返回 fallback；用正则严格判断是否合法 hex
      return _looksLikeHex(t) ? c : null;
    }
    if (t.toLowerCase().startsWith('rgb')) return _parseRgb(t);
    if (t.toLowerCase().startsWith('hsl')) return _parseHsl(t);
    return null;
  }

  bool _looksLikeHex(String s) {
    var t = s.trim();
    if (t.startsWith('#')) t = t.substring(1);
    return RegExp(r'^[0-9a-fA-F]{3}([0-9a-fA-F]{3})?([0-9a-fA-F]{2})?$')
        .hasMatch(t);
  }

  Color? _parseRgb(String s) {
    final m =
        RegExp(r'^rgba?\((.*)\)$', caseSensitive: false).firstMatch(s.trim());
    if (m == null) return null;
    final parts =
        m.group(1)!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length < 3 || parts.length > 4) return null;
    final r = double.tryParse(parts[0]);
    final g = double.tryParse(parts[1]);
    final b = double.tryParse(parts[2]);
    if (r == null || g == null || b == null) return null;
    double a = 1;
    if (parts.length == 4) {
      a = double.tryParse(parts[3]) ?? -1;
      if (a < 0) return null;
      if (a > 1) a = a / 255;
    }
    return Color.fromARGB(
      (a.clamp(0, 1) * 255).round(),
      r.clamp(0, 255).round(),
      g.clamp(0, 255).round(),
      b.clamp(0, 255).round(),
    );
  }

  Color? _parseHsl(String s) {
    final m =
        RegExp(r'^hsla?\((.*)\)$', caseSensitive: false).firstMatch(s.trim());
    if (m == null) return null;
    final parts = m
        .group(1)!
        .split(',')
        .map((e) => e.trim().replaceAll('%', ''))
        .toList();
    if (parts.length < 3 || parts.length > 4) return null;
    final h = double.tryParse(parts[0]);
    final sp = double.tryParse(parts[1]);
    final lp = double.tryParse(parts[2]);
    if (h == null || sp == null || lp == null) return null;
    double a = 1;
    if (parts.length == 4) {
      a = double.tryParse(parts[3]) ?? -1;
      if (a < 0) return null;
      if (a > 1) a = a / 255;
    }
    return HSLColor.fromAHSL(
            a.clamp(0, 1), h % 360, (sp / 100).clamp(0, 1), (lp / 100).clamp(0, 1))
        .toColor();
  }

  void _syncCodeField() {
    _codeCtrl.text = _formatColor(_color);
    _codeError = false;
  }

  // ── 色轮交互 ──
  void _onWheel(Offset local, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final dx = local.dx - center.dx;
    final dy = local.dy - center.dy;
    final radius = size.shortestSide / 2 - 1;
    final dist = math.sqrt(dx * dx + dy * dy);
    final sat = (dist / radius).clamp(0.0, 1.0);
    var hue = math.atan2(dy, dx) / (2 * math.pi);
    if (hue < 0) hue += 1;
    final hsv = HSVColor.fromAHSV(_alpha, hue * 360, sat, _hsv.value);
    _setColor(hsv.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final hsv = _hsv;

    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: const Text('选择颜色',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 预览 + 色号输入
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.surfaceAlt),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      DropdownButton<_ColorFormat>(
                        value: _format,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: _ColorFormat.hex, child: Text('HEX')),
                          DropdownMenuItem(value: _ColorFormat.rgb, child: Text('RGB')),
                          DropdownMenuItem(value: _ColorFormat.hsl, child: Text('HSL')),
                        ],
                        onChanged: (f) {
                          if (f == null) return;
                          setState(() {
                            _format = f;
                            _syncCodeField();
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _codeCtrl,
                          onChanged: (v) {
                            final c = _parseColor(v);
                            if (c == null) {
                              setState(() => _codeError = true);
                            } else {
                              setState(() {
                                _color = c;
                                _codeError = false;
                              });
                            }
                          },
                          style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            isDense: true,
                            errorText: _codeError ? '无效色号' : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 色轮
            Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: GestureDetector(
                  onPanDown: (d) => _onWheel(d.localPosition, const Size(200, 200)),
                  onPanUpdate: (d) =>
                      _onWheel(d.localPosition, const Size(200, 200)),
                  child: CustomPaint(
                    painter: _ColorWheelPainter(
                      hue: hsv.hue / 360,
                      saturation: hsv.saturation,
                      value: hsv.value,
                      color: _color,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 明度
            Row(
              children: [
                const Text('明度',
                    style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
                Expanded(
                  child: Slider(
                    value: hsv.value.clamp(0.0, 1.0),
                    onChanged: (v) {
                      final h = HSVColor.fromAHSV(
                          _alpha, hsv.hue, hsv.saturation, v);
                      _setColor(h.toColor());
                    },
                  ),
                ),
              ],
            ),
            // 透明度
            Row(
              children: [
                const Text('透明度',
                    style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
                Expanded(
                  child: Slider(
                    value: _alpha.clamp(0.0, 1.0),
                    onChanged: (v) {
                      _setColor(_color.withValues(alpha: v));
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 预设色
            const Text('预设',
                style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _presets.map((hex) {
                final c = parseHexColor(hex);
                final selected = colorToHex(_color) == hex.toUpperCase();
                return GestureDetector(
                  key: ValueKey<String>('color-preset-$hex'),
                  onTap: () => _setColor(c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(color: AppColors.textPrimary, width: 2)
                          : Border.all(color: AppColors.surfaceAlt),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: AppColors.mutedLight)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, colorToHex(_color)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 色轮绘制：色相（角度）+ 饱和度（半径），叠加明度暗化与指示点。
class _ColorWheelPainter extends CustomPainter {
  final double hue; // 0-1
  final double saturation; // 0-1
  final double value; // 0-1
  final Color color;

  _ColorWheelPainter({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final hueColors = <Color>[
      for (int deg = 0; deg <= 360; deg += 60)
        HSVColor.fromAHSV(1, deg.toDouble(), 1, 1).toColor(),
    ];
    final hueStops = <double>[for (int deg = 0; deg <= 360; deg += 60) deg / 360];

    // 色相轮
    final hueShader = SweepGradient(colors: hueColors, stops: hueStops)
        .createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = hueShader);

    // 饱和度（中心白 → 边缘透明）
    final satShader = RadialGradient(colors: [
      Colors.white,
      Colors.white.withValues(alpha: 0),
    ]).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = satShader);

    // 明度暗化
    if (value < 1) {
      canvas.drawCircle(
          center, radius, Paint()..color = Colors.black.withValues(alpha: 1 - value));
    }

    // 指示点
    final angle = hue * 2 * math.pi;
    final r = saturation * radius;
    final pos = Offset(center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle));
    canvas.drawCircle(pos, 8, Paint()..color = Colors.white);
    canvas.drawCircle(
        pos,
        8,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    canvas.drawCircle(pos, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ColorWheelPainter old) =>
      old.hue != hue ||
      old.saturation != saturation ||
      old.value != value ||
      old.color != color;
}
