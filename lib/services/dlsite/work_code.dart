/// 作品编号（RJ / VJ）识别。
///
/// 规则来自 `docs/需求研究与设计备忘.md` 第 5.1 节：
///
/// ```text
/// 匹配  ^(RJ|VJ)\d{6,8}   大小写不敏感，取开头
/// 后备  整个文件夹名里搜一次 (RJ|VJ)\d{6,8}
/// ```
///
/// 长度取 6 到 8 位，因为 DLsite 同时存在 `RJ294126` 与 `RJ01021542`。
/// 这里只做字符串识别，不访问网络，也不碰数据库。
library;

/// 编号与标题的拆分结果。[code] 统一成大写，[title] 可能为空字符串。
class WorkCode {
  const WorkCode(this.code, this.title);

  /// 形如 `RJ294126` 或 `VJ010010`。
  final String code;

  /// 文件夹名里编号之外的剩余部分，去掉首尾的空格与分隔符。
  final String title;

  @override
  String toString() => 'WorkCode($code, ${title.isEmpty ? '-' : title})';

  @override
  bool operator ==(Object other) =>
      other is WorkCode && other.code == code && other.title == title;

  @override
  int get hashCode => Object.hash(code, title);
}

/// `RJ` 或 `VJ` 加 6 到 8 位数字。
final RegExp _atStart = RegExp(r'^(RJ|VJ)(\d{6,8})(?!\d)', caseSensitive: false);

/// 全文搜索用同一套形态，不限开头。
final RegExp _anywhere = RegExp(r'(RJ|VJ)(\d{6,8})(?!\d)', caseSensitive: false);

/// 编号后面常见的分隔符，拆标题时从两端去掉。
final RegExp _separators = RegExp(r'^[\s_\-\.・:：]+|[\s_\-\.・:：]+$');

/// 识别文件夹名里的作品编号。
///
/// 先试开头，失败再在整串里找一次。两处都失败时返回 null，
/// 调用方按「没有编号」处理，作品照常入库。
WorkCode? parseWorkCode(String folderName) {
  final text = folderName.trim();
  if (text.isEmpty) return null;

  final head = _atStart.firstMatch(text);
  if (head != null) {
    final code = _normalize(head);
    final rest = text.substring(head.end).replaceAll(_separators, '');
    return WorkCode(code, rest);
  }

  final found = _anywhere.firstMatch(text);
  if (found == null) return null;
  final code = _normalize(found);
  final rest = '${text.substring(0, found.start)} ${text.substring(found.end)}'
      .replaceAll(_separators, '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  return WorkCode(code, rest);
}

/// 从任意一段文本里取第一个编号，取不到返回 null。
String? findWorkCode(String text) {
  final found = _anywhere.firstMatch(text);
  return found == null ? null : _normalize(found);
}

/// 整串必须是一个编号，不允许多余字符。
bool isValidWorkCode(String text) =>
    RegExp(r'^(RJ|VJ)\d{6,8}$', caseSensitive: false).hasMatch(text.trim());

String _normalize(RegExpMatch m) =>
    '${m.group(1)!.toUpperCase()}${m.group(2)!}';
