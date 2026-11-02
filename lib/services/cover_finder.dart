/// 在作品目录里找封面，并把选中的图写到作品根目录。
///
/// 回退链来自 `docs/需求研究与设计备忘.md` 第 12.2 节：
///
/// ```text
/// 1  根目录里的白名单形态（cover、<编号>_cover、folder、front…）
/// 2  信号目录（封面、表紙、特典…）里的图
/// 3  根目录里的任意图片
/// 4  整棵子树按（深度, 名称分, 自然序）挑一张
/// 5  音频内嵌封面（这里不做，留给调用方）
/// 6  没有封面
/// ```
///
/// 本模块只碰文件系统，不访问数据库，也不发网络请求。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'cover_selector.dart';
import 'image_size.dart';
import '../utils/file_io.dart';

/// 找封面的结果。[level] 是回退链的层级，[path] 为空表示没找到。
class CoverLookup {
  const CoverLookup(this.path, this.level);

  const CoverLookup.none() : path = null, level = 6;

  final String? path;
  final int level;

  bool get found => path != null;

  @override
  String toString() => found ? 'CoverLookup($path, L$level)' : 'CoverLookup(none)';
}

/// 找封面并写盘。
class CoverFinder {
  CoverFinder({
    this.maxDepth = 6,
    this.maxImages = 4000,
    Future<ImageSize?> Function(String path)? sizeOf,
  }) : _sizeOf = sizeOf ?? readImageSize;

  /// 往里翻几层目录。作品目录一般 2 至 4 层，留到 6 层够用。
  final int maxDepth;

  /// 最多看多少张图，防止误把巨大的素材库当作品目录。
  final int maxImages;

  final Future<ImageSize?> Function(String path) _sizeOf;

  /// 只找不写。
  Future<CoverLookup> find(String rootPath, {String? code}) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return const CoverLookup.none();

    final rootFiles = await _imagesIn(root);
    // 第 1 级：根目录白名单
    final whitelisted = [
      for (final f in rootFiles)
        if (scoreCoverName(p.basename(f), code: code) >= 40) f,
    ];
    if (whitelisted.isNotEmpty) {
      final best = await _pick(whitelisted, rootPath, code);
      if (best != null) return CoverLookup(best, 1);
    }

    // 第 2 级：信号目录
    final signalDirs = await _signalDirs(root);
    if (signalDirs.isNotEmpty) {
      final inSignal = <String>[];
      for (final dir in signalDirs) {
        inSignal.addAll(await _imagesIn(Directory(dir), maxDepth: maxDepth));
      }
      if (inSignal.isNotEmpty) {
        final best = await _pick(inSignal, rootPath, code);
        if (best != null) return CoverLookup(best, 2);
      }
    }

    // 第 3 级：根目录任意图片
    if (rootFiles.isNotEmpty) {
      final best = await _pick(rootFiles, rootPath, code);
      if (best != null) return CoverLookup(best, 3);
    }

    // 第 4 级：整棵子树
    final all = await _imagesIn(root, maxDepth: maxDepth);
    if (all.isNotEmpty) {
      final best = await _pick(all, rootPath, code);
      if (best != null) return CoverLookup(best, 4);
    }

    return const CoverLookup.none();
  }

  /// 找到封面后复制到作品根目录，返回落盘路径。
  ///
  /// 有编号写 `<编号>_cover.<ext>`，没有编号写 `cover.<ext>`。目标已存在时
  /// 不覆盖，直接返回已有文件；用户手放的文件优先。
  Future<String?> fetchAndWrite(
    String rootPath, {
    String? code,
    CoverLookup? found,
  }) async {
    final hit = found ?? await find(rootPath, code: code);
    if (!hit.found) return null;
    return writeCoverFile(
      rootPath: rootPath,
      sourcePath: hit.path!,
      code: code,
    );
  }

  /// 把 [sourcePath] 写到 [rootPath] 下，返回目标路径。
  Future<String?> writeCoverFile({
    required String rootPath,
    required String sourcePath,
    String? code,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    final ext = p.extension(sourcePath).toLowerCase();
    final name = code == null || code.isEmpty
        ? 'cover$ext'
        : '${code}_cover$ext';
    final target = File(p.join(rootPath, name));

    if (await target.exists()) return target.path;
    // 无编号时若 cover.<ext> 已被别的东西占用，退回编号名不会发生；
    // 这里只保证同名不覆盖。

    await writeFileAtomic(target, (tmp) async {
      await source.copy(tmp.path);
    });
    return target.path;
  }

  Future<String?> _pick(List<String> paths, String rootPath, String? code) async {
    final sizes = <String, ImageSize?>{};
    for (final path in paths) {
      sizes[path] = await _sizeOf(path);
    }
    final picked = pickBestCover(
      paths,
      code: code,
      sizeOf: (path) => sizes[path] == null
          ? null
          : (width: sizes[path]!.width, height: sizes[path]!.height),
      rootPath: rootPath,
    );
    return picked?.path;
  }

  /// 直接列一个目录里的图片，不递归。
  Future<List<String>> _imagesIn(Directory dir, {int maxDepth = 0}) async {
    final out = <String>[];
    if (!await dir.exists()) return out;
    Future<void> walk(Directory current, int depth) async {
      if (out.length >= maxImages) return;
      List<FileSystemEntity> entries;
      try {
        entries = await current.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      for (final entry in entries) {
        if (out.length >= maxImages) return;
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (entry is File) {
          if (coverImageExtensions.contains(p.extension(name).toLowerCase().substring(1))) {
            out.add(entry.path);
          }
        } else if (entry is Directory && depth < maxDepth) {
          await walk(entry, depth + 1);
        }
      }
    }

    await walk(dir, 0);
    // 不递归时也要能只取本层
    if (maxDepth == 0) {
      return [
        for (final e in await dir.list(followLinks: false).toList())
          if (e is File &&
              coverImageExtensions.contains(
                  p.extension(e.path).toLowerCase().substring(1)))
            e.path,
      ];
    }
    return out;
  }

  /// 名字像封面的目录：强词（封面、表紙、パッケージ…）与特典目录。
  Future<List<String>> _signalDirs(Directory root) async {
    final out = <String>[];
    final strong = ['封面', '表紙', 'jacket', 'package', 'パッケージ', 'ジャケット'];
    final bonus = {'特典', 'sp', 'bonus'};
    Future<void> walk(Directory current, int depth) async {
      if (depth > maxDepth) return;
      List<FileSystemEntity> entries;
      try {
        entries = await current.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path).toLowerCase();
        if (strong.any(name.contains) || bonus.contains(name)) {
          out.add(entry.path);
        }
        await walk(entry, depth + 1);
      }
    }

    await walk(root, 1);
    return out;
  }
}
