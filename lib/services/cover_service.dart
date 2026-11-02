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

  /// 把远程抓来的作品封面写进缓存目录，返回路径。
  ///
  /// 与 [importCover] 的区别是字节已经在内存里（DLsite 的图），不落临时文件。
  /// 写了新扩展名就删掉旧扩展名的同 id 文件，否则换格式后会留下两份，
  /// 界面按 `works.cover_path` 读新的，旧的只会白占空间。
  static Future<String?> writeWorkCover(int workId, Uint8List bytes,
      {String? extHint}) async {
    try {
      final ext = _sanitizeExt(extHint ?? _sniffExt(bytes));
      final dir = await _coversDir();
      final dest = File(p.join(dir, 'work_$workId.$ext'));
      await writeFileAtomic(dest, (tmp) => tmp.writeAsBytes(bytes, flush: true));
      await for (final e in Directory(dir).list()) {
        final name = p.basename(e.path);
        if (e is File &&
            name.startsWith('work_$workId.') &&
            name != 'work_$workId.$ext') {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      final size = bytes.length;
      logInfo('Cover', '写入作品封面: work_$workId.$ext ($size 字节)');
      return dest.path;
    } catch (e) {
      logWarn('Cover', '写入作品封面失败: $e');
      return null;
    }
  }

  /// 只认这五种扩展名，别的一律当 jpg，避免抓来一个 `.php` 当图片写。
  static String _sanitizeExt(String ext) {
    final e = ext.toLowerCase();
    return const {'jpg', 'jpeg', 'png', 'webp', 'bmp'}.contains(e) ? e : 'jpg';
  }

  /// 按文件头判断扩展名。抓来的图不一定带可信的 Content-Type。
  static String _sniffExt(Uint8List b) {
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'png';
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'webp';
    }
    if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
    return 'jpg';
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
