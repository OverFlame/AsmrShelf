import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/utils/log_util.dart';
import 'package:asmrshelf/utils/stable_hash.dart';
import 'package:path/path.dart' as p;

/// 缩略图内存 LRU 缓存
class ThumbnailMemoryCache {
  static const _maxEntries = 200;

  /// 字面量 Map 就是按插入顺序遍历的 LinkedHashMap，LRU 依赖这个顺序。
  final _map = <String, ui.Image>{};

  ui.Image? get(String key) {
    final img = _map.remove(key);
    if (img != null) {
      _map[key] = img; // 移到末尾 → LRU
    }
    return img;
  }

  void put(String key, ui.Image img) {
    _map.remove(key);
    _map[key] = img;
    while (_map.length > _maxEntries) {
      final oldest = _map.keys.first;
      _map.remove(oldest)?.dispose(); // 释放 GPU 纹理
    }
  }

  void clear() {
    for (final img in _map.values) {
      img.dispose();
    }
    _map.clear();
  }

  /// 按条件移除（原图内容变化或删除时用），移除时释放 GPU 纹理
  void removeWhere(bool Function(String key) test) {
    for (final key in _map.keys.where(test).toList()) {
      _map.remove(key)?.dispose();
    }
  }
}

/// 缩略图服务 — 三层缓存（内存 LRU → 磁盘 → 原图生成）
class ThumbnailService {
  static ThumbnailService? _instance;
  final ThumbnailMemoryCache _memoryCache = ThumbnailMemoryCache();
  String? _cacheDir;
  bool _initialized = false;

  /// 缓存目录是否已经就绪。未就绪时 [thumbPath] 等同步接口无目录可用。
  bool get isInitialized => _initialized;

  /// 同时解码的原图数量上限。
  ///
  /// 每张卡片各自发起生成，不设闸门时快速滚动会让几十张原图同时解码
  /// （每张解码后是宽×高×4 字节），内存峰值与滚动速度成正比。
  static const int maxConcurrentGenerations = 3;

  int _activeGenerations = 0;
  final List<Completer<void>> _generationQueue = [];

  /// 观察到的并发峰值（诊断/测试用）
  int peakConcurrentGenerations = 0;

  ThumbnailService._();

  static ThumbnailService get instance {
    _instance ??= ThumbnailService._();
    return _instance!;
  }

  /// 缓存根目录路径
  String get cacheDir => _requireDir();

  /// 取缓存目录；未初始化时给一条能读懂的错误，而不是 late 字段的
  /// LateInitializationError（那个堆栈指不到「谁忘了 init」）。
  String _requireDir() {
    final dir = _cacheDir;
    if (dir == null) {
      throw StateError(
        'ThumbnailService 未初始化：先 await ThumbnailService.instance.init()',
      );
    }
    return dir;
  }

  /// [cacheDir] 只给测试用：跳过 DataDirService 直接指定缓存根目录。
  ///
  /// 幂等：应用启动路径（不给 cacheDir）重复调用直接返回；测试显式传目录时
  /// 按新目录重设，这样同一个测试进程里每个用例仍各用各的临时目录。
  Future<void> init({String? cacheDir}) async {
    if (cacheDir == null && _initialized) return;
    // 缩略图随数据目录走（可迁移）
    final dir =
        cacheDir ?? p.join(await DataDirService.instance.dataDir, 'thumbnails');
    await Directory(dir).create(recursive: true);
    _cacheDir = dir;
    _initialized = true;
    logInfo('Thumbnail', 'Cache dir: $dir');
  }

  /// 还原成「没初始化过」：测试要验证初始化路径本身时才需要。
  ///
  /// 只复位目录状态，不动内存缓存：里面的 `ui.Image` 是各用例自己
  /// `dispose()` 的，这里再清一遍会二次释放。
  void resetForTest() {
    _cacheDir = null;
    _initialized = false;
  }

  /// 获取缩略图路径（不生成，仅返回路径）。
  ///
  /// 文件名里带源文件的 mtime：源文件内容一变，缩略图就落到新的文件名上，
  /// 旧缩略图不会被命中。不带 mtime 的话，同一个路径换了内容仍会读到旧缩略图，
  /// 而 [Image.file] 的缓存键只有路径，界面也就跟着一直显示旧图。
  ///
  /// [mtimeMs] 只给「调用方已经 stat 过」的场景用，缺省时自己 stat。
  String thumbPath(String originalPath, {int size = 300, int? mtimeMs}) {
    final stamp = mtimeMs ?? _mtimeMs(originalPath);
    final hash = _hashKey(originalPath);
    final subDir = hash.substring(0, 2);
    return p.join(_requireDir(), subDir, '$hash.$stamp.t$size');
  }

  /// 原图路径的哈希（不含 mtime，用于按前缀清理）
  ///
  /// 用 utf8 编码而不是 `codeUnits`：`codeUnits` 是 UTF-16 码元，值可以超过
  /// 255，塞进 typed_data 时高位被截掉，只在码元高位上不同的两条路径会算出
  /// 同一个文件名，表现为缩略图串图。
  String _hashKey(String originalPath) => stableHashHex(originalPath);

  /// 源文件的 mtime（毫秒）；文件不存在返回 0
  int _mtimeMs(String originalPath) {
    final f = File(originalPath);
    if (!f.existsSync()) return 0;
    return f.statSync().modified.millisecondsSinceEpoch;
  }

  /// 缩略图缓存目录下，该原图所属的子目录
  Directory _subDirOf(String originalPath) =>
      Directory(p.join(_requireDir(), _hashKey(originalPath).substring(0, 2)));

  /// 占用一个解码名额（超过上限时排队等待）
  Future<void> _acquireSlot() async {
    if (_activeGenerations < maxConcurrentGenerations) {
      _activeGenerations++;
      if (_activeGenerations > peakConcurrentGenerations) {
        peakConcurrentGenerations = _activeGenerations;
      }
      return;
    }
    final waiter = Completer<void>();
    _generationQueue.add(waiter);
    await waiter.future;
  }

  /// 释放解码名额，唤醒下一个等待者
  void _releaseSlot() {
    if (_generationQueue.isNotEmpty) {
      _generationQueue.removeAt(0).complete();
      return;
    }
    if (_activeGenerations > 0) _activeGenerations--;
  }

  /// 确保磁盘缓存目录存在
  Future<void> _ensureSubDir(String subDir) async {
    await Directory(p.join(_requireDir(), subDir)).create(recursive: true);
  }

  /// 生成缩略图并写入磁盘缓存
  /// 只有磁盘缓存未命中时才真正解码原图
  /// [size] 是目标长边像素
  Future<String> ensureThumbnail(String originalPath, {int size = 300}) async {
    final targetPath = thumbPath(originalPath, size: size);

    // 磁盘缓存命中 → 直接返回路径
    if (File(targetPath).existsSync()) {
      return targetPath;
    }

    // 检查原图是否存在
    final originalFile = File(originalPath);
    if (!originalFile.existsSync()) {
      throw FileSystemException('Original image not found', originalPath);
    }

    // 原图解码 → 缩放 → 编码 → 写入磁盘
    logDebug('Thumbnail', 'Generating: ${p.basename(originalPath)} (${size}px)');
    // 先抢名额再读文件：并发上限本来是为了压住内存峰值，
    // 旧实现先整块 readAsBytes 再等名额，峰值等于「等待者数量 × 原图大小」。
    await _acquireSlot();
    try {
      final rawBytes = await originalFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        rawBytes,
        targetWidth: size,
        targetHeight: size,
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          // 写入 PNG 缩略图
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          if (byteData == null) {
            throw Exception('Failed to encode thumbnail for $originalPath');
          }

          final hash = _hashKey(originalPath);
          final subDir = hash.substring(0, 2);
          await _ensureSubDir(subDir);
          // 先写临时文件再改名：写到一半失败时不会留下半张 PNG
          // 被后续调用当成缓存命中。
          final tmp = File('$targetPath.tmp');
          await tmp.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
          await tmp.rename(targetPath);

          // 清掉同一原图同一尺寸的旧时间戳版本，否则每换一次内容就留一份孤儿
          await _removeOtherVariants(hash, size,
              keepName: p.basename(targetPath));
        } finally {
          // 之前 dispose 在函数最后一行，前面任何一步抛错都会漏解码结果
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      _releaseSlot();
    }
    logDebug('Thumbnail', 'Saved: ${p.basename(targetPath)}');
    return targetPath;
  }

  /// 删除 [_subDirOf] 里同一原图、同一尺寸、非 [keepName] 的历史缩略图
  Future<void> _removeOtherVariants(String hash, int size,
      {required String keepName}) async {
    final dir = Directory(p.join(_requireDir(), hash.substring(0, 2)));
    if (!dir.existsSync()) return;
    final suffix = '.t$size';
    // 先收名字再删，避免边遍历目录流边删文件
    final victims = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == keepName || !name.startsWith('$hash.')) continue;
      if (!name.endsWith(suffix)) continue;
      victims.add(entity);
    }
    for (final file in victims) {
      try {
        await file.delete();
      } catch (e) {
        logDebug('Thumbnail', 'Old thumbnail not removed: ${file.path} ($e)');
      }
    }
  }

  /// 解码缩略图为 ui.Image 并放入内存缓存
  Future<ui.Image> loadThumbnail(String originalPath, {int size = 300}) async {
    // 内存键也要带 mtime，不然原图换了内容还是拿到旧的 ui.Image
    final cacheKey = '$originalPath::$size::${_mtimeMs(originalPath)}';

    // L1: 内存
    final cached = _memoryCache.get(cacheKey);
    if (cached != null) return cached;

    // L2+L3: 磁盘 / 原图生成
    final diskPath = await ensureThumbnail(originalPath, size: size);
    final bytes = await File(diskPath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }

    _memoryCache.put(cacheKey, image);
    return image;
  }

  /// 删除原图对应的所有缩略图缓存
  ///
  /// 文件名带 mtime，删的时候算不出当时的时间戳，所以按哈希前缀扫子目录。
  /// 原图已经删掉的情况也走这条路（那种情况下 stat 不出 mtime）。
  Future<void> deleteThumbnails(String originalPath) async {
    final hash = _hashKey(originalPath);
    final dir = _subDirOf(originalPath);
    if (dir.existsSync()) {
      // 先收名字再删，避免边遍历目录流边删文件
      final victims = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File && p.basename(entity.path).startsWith('$hash.')) {
          victims.add(entity);
        }
      }
      for (final file in victims) {
        await file.delete();
      }
    }
    // 同时清理内存缓存（键里带 mtime，只能按前缀删）
    _memoryCache.removeWhere((key) => key.startsWith('$originalPath::'));
  }

  /// 磁盘缓存按 LRU 淘汰（超出上限时清理最旧的访问过的文件）
  ///
  /// 扫描与删除都放到后台 isolate：缓存目录里通常有几万个小文件，
  /// 在 UI isolate 上同步遍历会直接卡住启动。
  Future<int> evictDiskCache({int maxSizeMB = 2048}) async {
    final dir = _requireDir();
    if (!Directory(dir).existsSync()) return 0;
    final maxBytes = maxSizeMB * 1024 * 1024;
    try {
      final removed =
          await Isolate.run(() => _evictDiskCacheSync(dir, maxBytes));
      if (removed > 0) {
        logInfo('Thumbnail',
            'Disk cache evicted $removed files (limit ${maxSizeMB}MB)');
      }
      return removed;
    } catch (e) {
      logWarn('Thumbnail', 'Disk cache eviction failed: $e');
      return 0;
    }
  }

  /// 清空全部内存缓存（GPU 纹理）
  void clearMemoryCache() {
    _memoryCache.clear();
  }
}

/// 在后台 isolate 里扫描并清理缓存目录。
///
/// 必须是顶层函数：实例方法会把整个 service 一起捕获，跨 isolate 传不过去。
int _evictDiskCacheSync(String cacheDir, int maxBytes) {
  final dir = Directory(cacheDir);
  if (!dir.existsSync()) return 0;

  final files = <(File, int, DateTime)>[];
  var totalSize = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final stat = entity.statSync();
    files.add((entity, stat.size, stat.accessed));
    totalSize += stat.size;
  }

  // 按最后访问时间升序排列，优先删最旧的
  files.sort((a, b) => a.$3.compareTo(b.$3));

  var removed = 0;
  for (final (file, size, _) in files) {
    if (totalSize <= maxBytes) break;
    try {
      file.deleteSync();
      totalSize -= size;
      removed++;
    } catch (_) {
      // 单个文件删不掉（占用/权限）不影响其余清理
    }
  }
  return removed;
}
