/// 一次性导入：扫一棵目录树，整理成「作品 → 曲目」的计划。
///
/// 目录约定（用户已整理好的音频内容）：根目录下每个子目录是一部作品，作品
/// 目录名里可能带 RJ 号，也可能只有标题。这里只做文件系统层面的整理，不碰
/// 数据库：接入导入流程时再把 [ImportPlan] 落库。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'cover_finder.dart';
import 'dlsite/work_code.dart';

/// 一首曲目：文件路径加上从文件名里剥出来的名字。
class ImportTrack {
  const ImportTrack({
    required this.path,
    required this.fileName,
    required this.title,
    required this.sizeBytes,
  });

  final String path;
  final String fileName;

  /// 去掉扩展名与开头序号的标题，例如 `01. 名前` 里的 `名前`。
  final String title;
  final int sizeBytes;

  @override
  String toString() => 'ImportTrack($title)';
}

/// 一部作品。
class ImportWork {
  const ImportWork({
    required this.dirPath,
    required this.title,
    this.code,
    this.coverPath,
    this.coverLevel = 6,
    required this.tracks,
  });

  final String dirPath;

  /// 作品名：目录名里剥掉编号之后剩下的部分；剥完为空时退回目录名。
  final String title;

  /// 目录名里的 RJ 或 VJ 编号，没有则为 null。
  final String? code;

  /// 落盘后的封面文件路径；没找到封面时为 null。
  final String? coverPath;

  /// 封面来自回退链的第几级，6 表示没有。
  final int coverLevel;

  final List<ImportTrack> tracks;

  int get trackCount => tracks.length;

  int get totalBytes => tracks.fold(0, (sum, t) => sum + t.sizeBytes);

  @override
  String toString() =>
      'ImportWork($title, code=$code, tracks=$trackCount, cover=L$coverLevel)';
}

/// 一次导入的完整计划。
class ImportPlan {
  const ImportPlan({required this.rootPath, required this.works, this.skipped});

  final String rootPath;
  final List<ImportWork> works;

  /// 看着像作品但没有可导入音频的目录，留给界面提示用户。
  final List<String>? skipped;

  int get trackCount => works.fold(0, (sum, w) => sum + w.trackCount);

  @override
  String toString() => 'ImportPlan(${works.length} 部作品, $trackCount 首曲目)';
}

/// 认作音频的扩展名。
const Set<String> importAudioExtensions = {
  'mp3',
  'm4a',
  'flac',
  'wav',
  'ogg',
  'aac',
  'opus',
  'wma',
};

/// 扫描 [rootPath] 下的作品目录。
///
/// [nested] 为 true 时，作品目录可以再套一层（例如 `根/社团/作品/`）；默认
/// 只认根目录的直接子目录，避免把作品里自带的 `特典/` 误当作品。
Future<ImportPlan> scanImportTree(
  String rootPath, {
  bool nested = false,
  int maxDepth = 3,
  bool writeCover = true,
  CoverFinder? finder,
}) async {
  final root = Directory(rootPath);
  if (!await root.exists()) {
    return ImportPlan(rootPath: rootPath, works: const [], skipped: const []);
  }

  final works = <ImportWork>[];
  final skipped = <String>[];

  Future<bool> looksLikeWork(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            importAudioExtensions
                .contains(p.extension(entity.path).toLowerCase().substring(1))) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<List<Directory>> subdirsOf(Directory dir, int depth) async {
    final out = <Directory>[];
    if (depth > maxDepth) return out;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
          out.add(entity);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> scanWork(Directory dir) async {
    final plan = await _planWork(dir, finder: finder, writeCover: writeCover);
    if (plan.tracks.isEmpty) {
      skipped.add(dir.path);
      return;
    }
    works.add(plan);
  }

  final top = await subdirsOf(root, 1);
  for (final dir in top) {
    if (await looksLikeWork(dir)) {
      await scanWork(dir);
      continue;
    }
    if (!nested) {
      skipped.add(dir.path);
      continue;
    }
    // 可能是作品外层目录（社团、系列）：往里看一层。
    final inner = await subdirsOf(dir, 2);
    for (final child in inner) {
      if (await looksLikeWork(child)) await scanWork(child);
    }
    final found = works.where((w) => p.isWithin(dir.path, w.dirPath)).length;
    if (found == 0) skipped.add(dir.path);
  }

  works.sort((a, b) => _naturalLess(a.title, b.title) ? -1 : 1);
  return ImportPlan(rootPath: rootPath, works: works, skipped: skipped);
}

Future<ImportWork> _planWork(
  Directory dir, {
  CoverFinder? finder,
  bool writeCover = true,
}) async {
  final parsed = parseWorkCode(p.basename(dir.path));
  final code = parsed?.code;
  final title = (parsed?.title.trim().isNotEmpty ?? false)
      ? parsed!.title.trim()
      : p.basename(dir.path);

  final tracks = <ImportTrack>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final ext = p.extension(entity.path).toLowerCase();
    if (!importAudioExtensions.contains(ext.substring(1))) continue;
    if (p.split(entity.path).any((s) => s == '特典')) continue;
    final fileName = p.basename(entity.path);
    final size = await entity.length();
    tracks.add(ImportTrack(
      path: entity.path,
      fileName: fileName,
      title: trackTitle(fileName),
      sizeBytes: size,
    ));
  }
  tracks.sort((a, b) => _naturalLess(a.fileName, b.fileName) ? -1 : 1);

  String? coverPath;
  var level = 6;
  if (tracks.isNotEmpty) {
    final f = finder ?? CoverFinder();
    final lookup = await f.find(dir.path, code: code);
    level = lookup.level;
    if (lookup.found) {
      coverPath = writeCover
          ? await f.writeCoverFile(
              rootPath: dir.path,
              sourcePath: lookup.path!,
              code: code,
            )
          : lookup.path;
    }
  }

  return ImportWork(
    dirPath: dir.path,
    title: title,
    code: code,
    coverPath: coverPath,
    coverLevel: level,
    tracks: tracks,
  );
}

/// 从文件名推曲目标题：去掉扩展名、开头序号与紧跟着的顿号或点。
///
/// `01. 名前` → `名前`；`03 - 夜` → `夜`；`トラック` → `トラック`。
String trackTitle(String fileName) {
  var name = p.basenameWithoutExtension(fileName).trim();
  final numbered = RegExp(r'^(\d{1,3})\s*[.\-_、．]\s*(.+)$').firstMatch(name);
  if (numbered != null) name = numbered.group(2)!.trim();
  return name.isEmpty ? p.basenameWithoutExtension(fileName) : name;
}

/// 自然序比较，与 `cover_selector.dart` 的排序口径一致。
bool _naturalLess(String a, String b) {
  final run = RegExp(r'\d+|\D+');
  final ma = run.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final mb = run.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i];
    final y = mb[i];
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);
    if (nx != null && ny != null) {
      if (nx != ny) return nx < ny;
    } else {
      final cmp = x.compareTo(y);
      if (cmp != 0) return cmp < 0;
    }
  }
  return ma.length < mb.length;
}
