import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../utils/file_io.dart';
import '../utils/log_util.dart';
import 'data_dir_service.dart';

/// 封面服务：内嵌图提取、自定义封面导入、封面文件定位
class CoverService {
  CoverService._();

  static Future<String> _coversDir() async {
    final dir = p.join(await DataDirService.instance.dataDir, 'covers');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// 将内嵌封面字节写入缓存，返回路径
  static Future<String?> writeEmbedded(
      int trackId, Uint8List bytes, String mime) async {
    try {
      final ext = _extFromMime(mime);
      final dir = await _coversDir();
      final file = File(p.join(dir, 'track_$trackId.$ext'));
      await writeFileAtomic(file, (tmp) => tmp.writeAsBytes(bytes, flush: true));
      return file.path;
    } catch (e) {
      logWarn('Cover', '写入内嵌封面失败: $e');
      return null;
    }
  }

  /// 导入自定义封面（拷贝到数据目录），返回新路径
  static Future<String?> importCover(String srcPath, int workId) async {
    try {
      final src = File(srcPath);
      if (!src.existsSync()) return null;
      final ext = p.extension(srcPath).toLowerCase();
      final safeExt = const {'.jpg', '.jpeg', '.png', '.webp', '.bmp'}
              .contains(ext)
          ? ext
          : '.jpg';
      final dir = await _coversDir();
      final dest = File(p.join(dir, 'work_$workId$safeExt'));
      await writeFileAtomic(dest, (tmp) async {
        await src.copy(tmp.path);
      });
      logInfo('Cover', '导入封面: $srcPath → ${dest.path}');
      return dest.path;
    } catch (e) {
      logWarn('Cover', '导入封面失败: $e');
      return null;
    }
  }

  /// 封面缓存目录（公开）
  static Future<String> coversDir() => _coversDir();

  /// 计算内嵌封面缓存（track_*.jpg）总字节数
  static Future<int> embeddedCacheSizeBytes() async {
    try {
      final dir = await _coversDir();
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      int total = 0;
      await for (final e in d.list()) {
        if (e is File && p.basename(e.path).startsWith('track_')) {
          total += await e.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清理内嵌封面缓存（track_*.jpg，可重新从音频提取），返回释放字节数
  static Future<int> clearEmbeddedCache() async {
    try {
      final dir = await _coversDir();
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      int freed = 0;
      await for (final e in d.list()) {
        if (e is File && p.basename(e.path).startsWith('track_')) {
          freed += await e.length();
          await e.delete();
        }
      }
      logInfo('Cover', '清理内嵌封面缓存，释放 $freed 字节');
      return freed;
    } catch (e) {
      logWarn('Cover', '清理内嵌封面缓存失败: $e');
      return 0;
    }
  }

  /// 超出上限时按最旧优先删除内嵌封面（track_*.jpg）
  ///
  /// [keep] 里的文件不删：正在播放或正在展示的封面被删掉，界面会突然
  /// 丢掉封面，重新提取要再读一次音频文件。
  static Future<void> enforceLimit(int maxBytes,
      {Set<String> keep = const <String>{}}) async {
    if (maxBytes <= 0) return;
    try {
      final dir = await _coversDir();
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final keepNorm = keep.map(_normPath).toSet();
      final files = <File>[];
      await for (final e in d.list()) {
        if (e is File && p.basename(e.path).startsWith('track_')) {
          files.add(e);
        }
      }
      files.sort(
          (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      int total = files.fold(0, (s, f) => s + f.lengthSync());
      for (final f in files) {
        if (total <= maxBytes) break;
        if (keepNorm.contains(_normPath(f.path))) continue;
        total -= f.lengthSync();
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (e) {
      logWarn('Cover', 'enforceLimit 失败: $e');
    }
  }

  /// 统一成绝对路径再比较，调用方传相对路径或不同分隔符也能对上
  static String _normPath(String path) => p.normalize(File(path).absolute.path);

  static String _extFromMime(String mime) {
    final m = mime.toLowerCase();
    if (m.contains('png')) return 'png';
    if (m.contains('webp')) return 'webp';
    if (m.contains('bmp')) return 'bmp';
    return 'jpg';
  }
}
