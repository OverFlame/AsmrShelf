/// 文件写入与复制的安全封装。
///
/// 这里的两件事都围绕同一个风险：写坏或清空已有数据。
/// `AtomicFileWriter` 保证目标文件要么是完整的旧内容，要么是完整的新内容；
/// [safeCopyFile] 保证源与目标相同时不会把源文件截断。
library;

import 'dart:io';

import 'package:asmrshelf/utils/path_util.dart';

/// 串行化并原子替换的文本写入器。
///
/// 并发调用 [write] 时按调用顺序排队，每次写入先落 `<path>.tmp`，
/// 再把旧文件改名为 `<path>.bak`，最后 rename 覆盖目标。
/// 同目录内的 rename 是原子操作，进程中途被杀不会留下半截 JSON。
class AtomicFileWriter {
  AtomicFileWriter(this.path);

  /// 目标文件路径。
  final String path;

  Future<void> _pending = Future<void>.value();

  /// 写入 [content]。
  ///
  /// 返回的 Future 会把本次失败抛给调用方；排队链条本身吞掉错误，
  /// 避免一次写入失败让后续写入全部失效。
  Future<void> write(String content) {
    final next = _pending.then((_) => _writeNow(content));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _writeNow(String content) async {
    final target = File(path);
    await target.parent.create(recursive: true);

    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);

    if (await target.exists()) {
      final bak = File('$path.bak');
      if (await bak.exists()) await bak.delete();
      await target.rename(bak.path);
    }
    await tmp.rename(path);
  }
}

/// 写 `<target>.tmp` 再改名覆盖 [target]：目标要么是完整旧内容，要么是完整新内容。
///
/// 别写成「先删目标、再改名」：删成功、改名之前进程被杀或断电，目标就没了
/// （`.datadir` 指针消失会让应用回落默认数据目录，用户看到「库空了」，其实数据
/// 还在自定义目录里）。同目录 rename 覆盖本身是原子的，Windows 上 Dart 走
/// MoveFileEx 带 REPLACE_EXISTING，不需要那一删。
///
/// [write] 里请用 `flush: true`，否则改名成功而内容还在页缓存里。
/// 与 [AtomicFileWriter] 的分工：那个负责排队与保留 `.bak`，这里是单次替换。
Future<void> writeFileAtomic(
    File target, Future<void> Function(File tmp) write) async {
  final tmp = File('${target.path}.tmp');
  await target.parent.create(recursive: true);
  try {
    await write(tmp);
    await tmp.rename(target.path);
  } catch (e) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// 复制文件并校验结果。
///
/// 源与目标同一个位置时直接返回，不触碰文件：`File.copy` 在这种情况下
/// 会先删掉目标（也就是源），再把空内容写回去，文件变成 0 字节且不报错。
/// 复制过程先落 `<dst>.migrating`，确认非空后再改名到 [dst]。
Future<void> safeCopyFile(String src, String dst) async {
  final s = File(src);
  if (!s.existsSync()) return;
  if (isSamePath(src, dst)) return;

  final target = File(dst);
  await target.parent.create(recursive: true);

  final tmp = File('$dst.migrating');
  if (await tmp.exists()) await tmp.delete();
  await s.copy(tmp.path);

  final srcLen = await s.length();
  final tmpLen = await tmp.length();
  if (srcLen > 0 && tmpLen == 0) {
    await tmp.delete();
    throw FileSystemException('复制结果为空，已中止', src);
  }

  // rename 覆盖目标本身是原子的；先 delete 再 rename 的话，
  // 两步之间进程被杀会留下「目标已删」的窗口（报告 P2）。
  await tmp.rename(dst);
}
