import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../utils/log_util.dart';
import 'metadata_service.dart';
import 'thumbnail_cache.dart';

/// 视频封面服务：三级取图，外加一层落盘缓存（方案文档第三节）。
///
/// 顺序与理由：
/// 1. 系统已生成的封面。桌面文件管理器给这个视频生过缩略图，说明系统已经
///    解过一次码，直接复用最省。Linux 的键是文件 URI 的 md5，见
///    [thumbnailKeyFor]。Windows 的 Shell 缩略图要写 C++ 插件，本轮返回 null。
/// 2. 容器内嵌封面。MP4 系容器常带封面图，读它不用起进程。识别依据是文件头
///    的 ftyp 标记，MKV、AVI、WEBM、FLV 没有解析器，这一级会落空。
/// 3. 首帧。系统里有 ffmpeg 才起进程抽第一帧，命令照 video_launcher 的风格。
///    这一级最慢也最容易失败（没有 ffmpeg、超时、编解码报错），所以排在最后。
///
/// 任何一级成功都把结果写进 [ThumbnailService] 的缓存目录，文件名固定为
/// `video-<md5>.png`，同一个路径下次直接命中缓存。三级全落空就返回 null。
/// 这个类不抛异常：磁贴画在列表里，抛一次会毁掉一层列表。
class VideoCoverService {
  /// [systemCover] / [embeddedCover] / [start] 都是可注入的替身，测试里不会
  /// 碰真实系统，也不会真起 ffmpeg。
  ///
  /// [start] 是起进程的唯一入口：首帧用它跑 ffmpeg，探测系统有没有 ffmpeg
  /// 也用它跑 `which ffmpeg`。两条路共用一个替身，测试就不会漏掉一条。
  ///
  /// [outputDir] 为空时取 [ThumbnailService] 的缓存目录，跟随数据目录迁移。
  /// [timeout] 同时管首帧与 ffmpeg 探测，进程挂了也不会把调用方拖住。
  VideoCoverService({
    Future<String?> Function(String videoPath)? systemCover,
    Future<Uint8List?> Function(String videoPath)? embeddedCover,
    Future<Process> Function(String, List<String>)? start,
    String? os,
    this.outputDir,
    this.timeout = const Duration(seconds: 20),
  })  : _systemCover = systemCover ?? _systemThumbnail,
        _embeddedCover = embeddedCover ?? _readEmbeddedCover,
        _start = start ?? Process.start,
        _os = os ?? detectOs();

  final Future<String?> Function(String videoPath) _systemCover;
  final Future<Uint8List?> Function(String videoPath) _embeddedCover;
  final Future<Process> Function(String executable, List<String> arguments)
      _start;
  final String _os;

  /// 封面落盘的目录；null 表示用 [ThumbnailService] 的缓存目录
  final String? outputDir;

  /// 首帧与 ffmpeg 探测的超时上限
  final Duration timeout;

  /// 缓存文件名的前缀，配合路径的 md5 组成 `video-<md5>.png`
  static const String cacheNamePrefix = 'video-';

  /// 平台名。取值与 `VideoLauncher.detectOs` 一致，方便两边对着读。
  static String detectOs() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    return 'other';
  }

  /// 桌面缩略图规范用的键：文件 URI 的 md5 十六进制串。
  ///
  /// 三步顺序容易写反：先把路径转成绝对路径，再整体 URI 编码，最后才算 md5。
  /// 路径里的空格与中文按下分号编码（`%20`、UTF-8 的百分号形式），编出来的
  /// 字符串要和文件管理器算的一模一样，否则永远命中不了系统缓存。
  @visibleForTesting
  static String thumbnailKeyFor(String videoPath) {
    final abs = p.normalize(p.absolute(videoPath));
    return md5.convert(utf8.encode(Uri.file(abs).toString())).toString();
  }

  /// Linux 系统缩略图根目录；认不出 HOME 时返回 null。
  ///
  /// 先看 XDG_CACHE_HOME：用户把缓存挪到别处时，只认 `~/.cache` 会全部落空。
  static String? thumbnailRootDir() {
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'thumbnails');
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return p.join(home, '.cache', 'thumbnails');
  }

  /// 系统给这个视频生成的缩略图路径；认不出缓存根时返回 null
  static String? systemThumbnailPath(String videoPath) {
    final root = thumbnailRootDir();
    if (root == null) return null;
    return p.join(root, 'normal', '${thumbnailKeyFor(videoPath)}.png');
  }

  // ═══ 三级取图 ═══

  /// 取封面，返回缓存文件路径；三级全落空返回 null。
  Future<String?> coverFor(String videoPath) async {
    try {
      return await _coverFor(videoPath);
    } catch (e) {
      logDebug('VideoCover', '取封面失败 "$videoPath"：$e');
      return null;
    }
  }

  Future<String?> _coverFor(String videoPath) async {
    if (videoPath.isEmpty) return null;
    final source = File(videoPath);
    // 源文件已经不在（刚删、刚搬走）就没必要走三级链
    if (!source.existsSync()) {
      logDebug('VideoCover', '源文件不存在，不取封面：$videoPath');
      return null;
    }

    final dir = await _resolveCacheDir();
    final cachePath = dir == null ? null : _cachePathIn(dir, videoPath);

    // 缓存命中同时看存在性与 mtime：同一个路径换了内容，缓存必须让位
    if (cachePath != null && _cacheIsFresh(cachePath, source)) {
      logDebug('VideoCover', '命中缓存：${p.basename(cachePath)}');
      return cachePath;
    }

    final system = await _attempt('系统封面', () => _fromSystem(videoPath, cachePath));
    if (system != null) return system;
    final embedded =
        await _attempt('内嵌封面', () => _fromContainer(videoPath, cachePath));
    if (embedded != null) return embedded;
    final frame =
        await _attempt('首帧', () => _fromFirstFrame(videoPath, cachePath));
    if (frame != null) return frame;

    logDebug('VideoCover', '三级取图都没有结果：$videoPath');
    return null;
  }

  /// 跑一级取图。这一级抛异常只记日志，后面两级照跑，别让一级拖垮整条链。
  Future<String?> _attempt(String label, Future<String?> Function() run) async {
    try {
      return await run();
    } catch (e) {
      logDebug('VideoCover', '$label 取图异常：$e');
      return null;
    }
  }

  /// 一级：系统已生成的封面
  Future<String?> _fromSystem(String videoPath, String? cachePath) async {
    if (_os != 'linux') {
      if (_os == 'windows') {
        // Shell 缩略图接口要写 C++ 插件，本轮不做，直接落到下一级
        logDebug('VideoCover', 'Windows 系统缩略图未实现：$videoPath');
      }
      return null;
    }
    final systemPath = await _systemCover(videoPath);
    if (systemPath == null || !File(systemPath).existsSync()) {
      logDebug('VideoCover', '系统没给这个视频生成过封面：$videoPath');
      return null;
    }
    // 没有缓存目录时直接借系统图当封面：它本身就是一张可用的小图
    if (cachePath == null) return systemPath;
    final saved = await _persist(cachePath, (tmp) => File(systemPath).copy(tmp));
    if (saved != null) logInfo('VideoCover', '用系统封面：${p.basename(videoPath)}');
    return saved;
  }

  /// 二级：容器内嵌封面
  Future<String?> _fromContainer(String videoPath, String? cachePath) async {
    // 内嵌封面是内存里的字节，没有缓存目录就没有能交给界面的文件路径
    if (cachePath == null) return null;
    final bytes = await _embeddedCover(videoPath);
    if (bytes == null || bytes.isEmpty) return null;
    final saved = await _persist(
      cachePath,
      (tmp) => File(tmp).writeAsBytes(bytes, flush: true),
    );
    if (saved != null) logInfo('VideoCover', '用内嵌封面：${p.basename(videoPath)}');
    return saved;
  }

  /// 三级：首帧。只有 Linux 做这一级，Android 的首帧走
  /// MediaMetadataRetriever，本轮没有实现。
  Future<String?> _fromFirstFrame(String videoPath, String? cachePath) async {
    if (_os != 'linux' || cachePath == null) return null;
    if (!await _hasFfmpeg()) {
      logDebug('VideoCover', '系统里没有 ffmpeg，跳过首帧：$videoPath');
      return null;
    }

    // 输出先落在 `.tmp.png` 上：末段扩展名必须是 png，ffmpeg 靠扩展名挑
    // 封装器，改名成 `.tmp` 它会直接报「找不到输出格式」。
    final tmp = _tempPath(cachePath);
    final args = <String>[
      '-y',
      '-ss', '0',
      '-i', videoPath,
      '-frames:v', '1',
      '-vf', 'scale=300:-1',
      tmp,
    ];
    Process? proc;
    try {
      proc = await _start('ffmpeg', args);
      final drained = _drain(proc);
      final code = await proc.exitCode.timeout(timeout);
      await drained;
      if (code != 0) {
        logDebug('VideoCover', 'ffmpeg 退出码 $code：$videoPath');
        await _deleteQuietly(tmp);
        return null;
      }
      // 退出码为 0 还可能是空文件，两个条件都成立才算成功
      final out = File(tmp);
      if (!out.existsSync() || await out.length() == 0) {
        logDebug('VideoCover', 'ffmpeg 没有写出文件：$videoPath');
        await _deleteQuietly(tmp);
        return null;
      }
      return await _promote(tmp, cachePath);
    } on TimeoutException {
      proc?.kill();
      logDebug('VideoCover', 'ffmpeg 超过 ${timeout.inSeconds} 秒，已杀掉：$videoPath');
      await _deleteQuietly(tmp);
      return null;
    } catch (e) {
      logDebug('VideoCover', '首帧失败 "$videoPath"：$e');
      await _deleteQuietly(tmp);
      return null;
    }
  }

  /// 系统里有没有 ffmpeg：`which` 的退出码为 0 才算有。
  Future<bool> _hasFfmpeg() async {
    Process? proc;
    try {
      proc = await _start('which', <String>['ffmpeg']);
      // 先等退出码（带超时），再收流。反过来等会在进程卡死时永远等不到超时。
      final drained = _drain(proc);
      final code = await proc.exitCode.timeout(timeout);
      await drained;
      return code == 0;
    } catch (e) {
      logDebug('VideoCover', '探测 ffmpeg 失败：$e');
      return false;
    }
  }

  /// 收走进程的两条输出流。不读的话管道缓冲填满，进程会卡到超时。
  static Future<void> _drain(Process proc) async {
    try {
      await Future.wait<void>(<Future<void>>[
        proc.stdout.drain<void>(),
        proc.stderr.drain<void>(),
      ]);
    } catch (_) {
      // 进程被 kill 时流带着错误结束，这里不再关心
    }
  }

  // ═══ 缓存 ═══

  /// 缓存目录。注入了就用注入的；否则用 [ThumbnailService] 的目录。
  ///
  /// [ThumbnailService] 还没 init（或迁移过程中目录建不出来）时返回 null，
  /// 调用方据此降级，而不是抛 StateError 把磁贴打挂。
  Future<String?> _resolveCacheDir() async {
    final dir = outputDir ??
        (ThumbnailService.instance.isInitialized
            ? ThumbnailService.instance.cacheDir
            : null);
    if (dir == null) {
      logDebug('VideoCover', '缩略图目录未就绪，本次封面不落盘');
      return null;
    }
    try {
      final d = Directory(dir);
      if (!d.existsSync()) await d.create(recursive: true);
    } catch (e) {
      logDebug('VideoCover', '缩略图目录不可用 "$dir"：$e');
      return null;
    }
    return dir;
  }

  /// 缓存文件名固定为 `video-<md5>.png`，名字里不带 mtime。
  ///
  /// mtime 放到文件修改时间上比较，同一个路径只留一个文件。名字里带时间戳
  /// 的话每次源文件一变就多一份孤儿图，还得额外写清理。
  static String _cachePathIn(String dir, String videoPath) =>
      p.join(dir, '$cacheNamePrefix${thumbnailKeyFor(videoPath)}.png');

  /// 缓存是否还能用：文件要在，且不能比源文件旧
  static bool _cacheIsFresh(String cachePath, File source) {
    final cached = File(cachePath);
    if (!cached.existsSync()) return false;
    try {
      return !source.statSync().modified.isAfter(cached.statSync().modified);
    } catch (e) {
      return false;
    }
  }

  /// 先写 `.tmp.png`，写完改名成 [target]。
  ///
  /// 改名在同一目录内是原子的：写到一半失败也不会留下半张 PNG，被后续调用
  /// 当成缓存命中。
  Future<String?> _persist(
    String target,
    Future<void> Function(String tmp) write,
  ) async {
    final tmp = _tempPath(target);
    try {
      await write(tmp);
    } catch (e) {
      logDebug('VideoCover', '写封面缓存失败 "$target"：$e');
      await _deleteQuietly(tmp);
      return null;
    }
    return _promote(tmp, target);
  }

  /// 把已经写好的临时文件改名成最终缓存文件
  Future<String?> _promote(String tmp, String target) async {
    try {
      await File(tmp).rename(target);
      return target;
    } catch (e) {
      logDebug('VideoCover', '封面落盘失败 "$target"：$e');
      await _deleteQuietly(tmp);
      return null;
    }
  }

  /// 临时文件名。末段保留 `.png`，ffmpeg 靠它挑封装器。
  static String _tempPath(String target) => p.setExtension(target, '.tmp.png');

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // 临时文件删不掉不影响结果，留给磁盘清理
    }
  }

  // ═══ 默认替身 ═══

  /// 一级的默认实现：Linux 上看系统缩略图在不在
  static Future<String?> _systemThumbnail(String videoPath) async {
    if (!Platform.isLinux) return null;
    final path = systemThumbnailPath(videoPath);
    if (path == null) return null;
    return await File(path).exists() ? path : null;
  }

  /// 二级的默认实现：MP4 系容器的内嵌封面，读不到给 null
  static Future<Uint8List?> _readEmbeddedCover(String videoPath) async {
    final bytes = MetadataService.read(videoPath).pictureBytes;
    return (bytes == null || bytes.isEmpty) ? null : bytes;
  }
}
