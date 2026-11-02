/// 目录路径的查询区间，闭开区间 `[lower, upper)`。
///
/// [lower] 末尾补一个分隔符，因此 `/m/vol` 不会命中 `/m/vol2`。
/// 比较走 SQLite 的 NOCASE 排序，与 `LIKE` 的默认大小写行为一致；
/// media 表上的 `idx_media_path_nocase` 可以直接服务这种区间查询。
(String lower, String upper) dirPathRange(String dirPath) {
  final sep = (dirPath.contains('\\') || dirPath.endsWith(':')) ? '\\' : '/';
  var base = dirPath;
  while (base.endsWith('\\') || base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final lower = '$base$sep';
  // 分隔符加一就是紧邻的下一个字符：'/' -> '0'，'\' -> ']'。
  // 任何以 lower 开头的路径都落在 lower 与 upper 之间。
  final upper =
      lower.substring(0, lower.length - 1) + String.fromCharCode(sep.codeUnitAt(0) + 1);
  return (lower, upper);
}
