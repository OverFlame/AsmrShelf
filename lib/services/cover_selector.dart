/// 本地封面候选的打分与挑选。
///
/// 规则来自 `docs/需求研究与设计备忘.md` 第 12 节：先认白名单形态，再按
/// 强词、弱词、目录信号与深浅度加权，尺寸只作加减分。这里不读磁盘、
/// 不做 IO，调用方把候选路径与可选的宽高传进来。
library;

import 'package:path/path.dart' as p;

/// 认可的图片扩展名。
const Set<String> coverImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'bmp'};

/// 通用白名单：整段基名等于这些词。
const Set<String> _genericStems = {
  'cover',
  'folder',
  'front',
  'album',
  'albumart',
  'artwork',
  'jacket',
};

/// 强词，前缀命中即可。
const List<String> _strongWords = [
  '封面',
  '表紙',
  'jacket',
  'package',
  'パッケージ',
  'ジャケット',
];

/// 弱词，前缀命中即可。
const List<String> _weakWords = [
  '缩略图',
  'サムネイル',
  'thumbnail',
  'thumb',
  'main',
  'artwork',
];

/// 特典目录名，与 `lib/services/file_scanner.dart:68` 的 `bonusDirNames` 一致。
const Set<String> _bonusDirNames = {'特典', 'sp', 'bonus'};

/// `<编号>_cover` 这种形态的识别。编号允许 RJ 或 VJ 加 6 到 8 位数字，
/// 中间的分隔符允许下划线、连字符、空格或无。
final RegExp _codeCoverStem = RegExp(
  r'^(rj|vj)(\d{6,8})[\s_\-]?cover$',
  caseSensitive: false,
);

/// 一张候选图的路径信息。
class CoverCandidate {
  const CoverCandidate(String path) : _path = path;

  final String _path;

  /// 原样保留的路径，用于排序相同时的稳定输出。
  String get path => _path;

  String get fileName => p.basename(_path);

  /// 从作品根目录往下的目录段，根目录下的文件为空列表。
  List<String> get directories {
    final dir = p.dirname(_path);
    if (dir == '.' || dir.isEmpty) return const [];
    return p.split(dir).where((s) => s.isNotEmpty && s != '.').toList();
  }

  String get _stem {
    final name = fileName;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  String get extension {
    final name = fileName;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  bool get isImage => coverImageExtensions.contains(extension);
}

/// 文件名的分值，不含目录与尺寸信号。
int scoreCoverName(String fileName, {String? code}) {
  final candidate = CoverCandidate(fileName);
  if (!candidate.isImage) return 0;
  final stem = candidate._stem;
  final lower = stem.toLowerCase();

  final byCode = _codeCoverStem.firstMatch(stem);
  if (byCode != null) {
    // 编号形态本身就是最强信号；编号与作品一致再加 5。
    final hitCode = '${byCode.group(1)!.toUpperCase()}${byCode.group(2)!}';
    final same = code != null && hitCode == code.toUpperCase();
    return same ? 45 : 40;
  }

  if (_genericStems.contains(lower)) return 40;

  for (final word in _strongWords) {
    if (lower.startsWith(word) || stem.startsWith(word)) return 35;
  }

  if (code != null && lower == code.toLowerCase()) return 30;

  for (final word in _weakWords) {
    if (lower.startsWith(word) || stem.startsWith(word)) return 25;
  }

  return 0;
}

/// 整条路径的分值：文件名 + 目录信号 + 深浅度。尺寸分另算，见 [scoreSize]。
///
/// [rootPath] 是作品根目录。给了它，深浅度按「离作品根几层」算；不给就只能按
/// 整条路径的目录数算，跨目录比较时会不公平。
int scoreCoverPath(String path, {String? code, String? rootPath}) {
  final candidate = CoverCandidate(path);
  if (!candidate.isImage) return 0;

  var score = scoreCoverName(candidate.fileName, code: code);
  final dirs = candidate.directories;

  // 目录里带强词时，说明这张图多半就是封面，即便文件名很随意。
  final dirStrong = dirs.any(
    (d) => _strongWords.any((w) => d.toLowerCase().contains(w)),
  );
  if (dirStrong) score += 20;

  if (dirs.any((d) => _bonusDirNames.contains(d.toLowerCase()))) score += 10;

  // 越靠近作品根目录越可能是封面，每深一层扣 5 分。
  score -= _relativeDepth(path, rootPath).clamp(0, 6) * 5;
  return score;
}

/// 尺寸分：接近正方形或竖版加分，长边太短扣分。
///
/// 判定竖版而不是横版，是因为 DLsite 的样图多为横版截图，正文封面优先。
int scoreSize(int width, int height) {
  if (width <= 0 || height <= 0) return 0;
  var score = 0;
  final ratio = width / height;
  if (ratio >= 0.6 && ratio <= 1.1) score += 15;
  if (width > height ? width < 300 : height < 300) score -= 20;
  return score;
}

/// 从候选里挑一张最合适的封面。
///
/// 排序键依次是：分值高的优先、目录浅的优先、文件名自然序小的优先。
/// `sizeOf` 可选，用来把尺寸分算进总分；拿不到尺寸时传 null。
CoverCandidate? pickBestCover(
  Iterable<String> paths, {
  String? code,
  ({int width, int height})? Function(String path)? sizeOf,
  bool Function(String path)? exists,
  String? rootPath,
}) {
  CoverCandidate? best;
  var bestScore = -1 << 30;
  String? bestName;

  for (final path in paths) {
    if (exists != null && !exists(path)) continue;
    final candidate = CoverCandidate(path);
    if (!candidate.isImage) continue;

    // 分值只用来排序，不用来淘汰：第四级回退就是「一张都不像封面时也得挑一张」，
    // 淘汰放在调用方（白名单门槛、信号目录）判。
    var score = scoreCoverPath(path, code: code, rootPath: rootPath);
    final size = sizeOf?.call(path);
    if (size != null) score += scoreSize(size.width, size.height);

    final name = candidate.fileName;
    final better = best == null ||
        score > bestScore ||
        (score == bestScore &&
            _relativeDepth(candidate.path, rootPath) <
                _relativeDepth(best.path, rootPath)) ||
        (score == bestScore &&
            _relativeDepth(candidate.path, rootPath) ==
                _relativeDepth(best.path, rootPath) &&
            _naturalLess(name, bestName ?? ''));
    if (better) {
      best = candidate;
      bestScore = score;
      bestName = name;
    }
  }

  return best;
}

/// 图片所在目录离 [rootPath] 有几层；没给根目录时退回整条路径的目录数。
int _relativeDepth(String path, String? rootPath) {
  final dir = p.dirname(path);
  if (rootPath == null) {
    return p.split(dir).where((s) => s.isNotEmpty && s != '/').length;
  }
  final rel = p.isWithin(rootPath, dir) ? p.relative(dir, from: rootPath) : dir;
  if (rel == '.' || rel.isEmpty) return 0;
  return p.split(rel).where((s) => s.isNotEmpty && s != '/').length;
}

/// 自然序比较：把连续数字当成整数比，比纯字典序更接近资源管理器的顺序。
bool _naturalLess(String a, String b) {
  final ca = _splitRuns(a.toLowerCase());
  final cb = _splitRuns(b.toLowerCase());
  final n = ca.length < cb.length ? ca.length : cb.length;
  for (var i = 0; i < n; i++) {
    final x = ca[i];
    final y = cb[i];
    final xi = int.tryParse(x);
    final yi = int.tryParse(y);
    if (xi != null && yi != null) {
      if (xi != yi) return xi < yi;
      continue;
    }
    final cmp = x.compareTo(y);
    if (cmp != 0) return cmp < 0;
  }
  return ca.length < cb.length;
}

List<String> _splitRuns(String s) =>
    RegExp(r'\d+|\D+').allMatches(s).map((m) => m[0]!).toList();
