/// 通用路径判断与生成。
///
/// 这里的两件事都必须在「动文件之前」完成：
/// 判断源与目标是不是同一个位置，以及为复制动作找一个不冲突的目标名。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 去掉尾分隔符并归一化的绝对路径。
String _canonical(String path) {
  var s = p.normalize(p.absolute(path));
  while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 两个路径是否指向同一个位置。
///
/// Windows 下忽略大小写，所有平台都忽略 `.` 段与尾分隔符。
/// 用于在任何复制动作之前拦截「源与目标是同一个位置」：
/// `File.copy` 遇到这种情况不报错，而是把源文件截成 0 字节。
bool isSamePath(String a, String b) {
  final na = _canonical(a);
  final nb = _canonical(b);
  if (Platform.isWindows) {
    return na.toLowerCase() == nb.toLowerCase();
  }
  return na == nb;
}

/// 在 [destDir] 下为 [name] 找一个不冲突的目标路径。
///
/// 目标已存在时依次尝试 `name_(1).ext`、`name_(2).ext`，最多试 [maxAttempts] 次。
/// 每轮判断都基于新生成的候选路径，不会退化成对同一个路径反复判断。
/// 候选全部被占用时抛 [FileSystemException]，由调用方决定如何提示。
Future<String> uniqueDestPath({
  required String destDir,
  required String name,
  int maxAttempts = 1000,
}) async {
  final sep = Platform.pathSeparator;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';

  var candidate = '$destDir$sep$name';
  var attempt = 1;
  while (await File(candidate).exists()) {
    if (attempt > maxAttempts) {
      throw FileSystemException('同名文件过多，无法生成新的目标文件名', candidate);
    }
    candidate = '$destDir$sep${base}_($attempt)$ext';
    attempt++;
  }
  return candidate;
}
