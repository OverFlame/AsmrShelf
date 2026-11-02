/// 原图内容变化时的图片缓存失效工具。
///
/// Flutter 的 [FileImage] 缓存键只含 `path` 与 `scale`，不含修改时间。同一个
/// 路径的文件被外部改过（重新导出、别的程序编辑、覆盖粘贴）之后，解码结果
/// 照样命中旧键，界面会一直显示旧图，直到进程重启。
///
/// 这里用 mtime 记账：同一个路径的 mtime 变了就驱逐一次。
library;

import 'dart:io';

import 'package:flutter/painting.dart';

class ImageCacheGuard {
  ImageCacheGuard._();

  /// path → 上次见到的 mtime（毫秒）
  static final Map<String, int> _stamps = {};

  /// [path] 的 mtime 与上次记录不同时，驱逐它的解码缓存。
  ///
  /// 返回是否真的驱逐了。第一次见到某个路径不算变化，返回 false。
  static bool evictIfChanged(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;

    final stamp = file.statSync().modified.millisecondsSinceEpoch;
    final known = _stamps[path];
    _stamps[path] = stamp;
    if (known == null || known == stamp) return false;

    imageCache.evict(FileImage(file));
    return true;
  }

  /// 立即驱逐 [path] 的解码缓存，并记下当前 mtime。
  ///
  /// 与 [evictIfChanged] 的区别：这里不看「是不是第一次见到」。封面被原子写
  /// 覆盖后路径不变，界面可能已经显示过旧图，必须无条件驱逐一次。
  static void invalidate(String path) {
    final file = File(path);
    if (file.existsSync()) {
      _stamps[path] = file.statSync().modified.millisecondsSinceEpoch;
    }
    imageCache.evict(FileImage(file));
  }

  /// 忘掉某个路径的记账（图片被删除时调用，免得 Map 越积越大）
  static void forget(String path) {
    _stamps.remove(path);
  }

  /// 清空记账（测试用）
  static void reset() {
    _stamps.clear();
  }
}
