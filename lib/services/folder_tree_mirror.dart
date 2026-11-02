/// 把一批媒体路径映射成作品下的虚拟文件夹树。
///
/// 一次性导入只建了作品根文件夹，普通导入与旧版媒体又都按目录分层展示；
/// 两边必须用同一套建树规则，否则曲目会「在库里、却不在任何可见文件夹里」。
library;

import 'package:path/path.dart' as p;

import '../db/folder_dao.dart';

class FolderTreeMirror {
  FolderTreeMirror(this._folderDao);

  final FolderDao _folderDao;

  /// 确保 [rootPath] 及其下所有媒体目录都有文件夹行与 `folder_paths`。
  ///
  /// 根目录已存在时复用；子目录按深度从浅到深创建，父级始终先落库。
  /// 只处理 [mediaPaths] 实际用到的目录，不猜测空目录。
  Future<VirtualFolder> ensureForPaths({
    required String rootPath,
    required String rootName,
    required int workId,
    required Iterable<String> mediaPaths,
    String library = 'audio',
  }) async {
    final root = _norm(rootPath);
    final rootKey = _key(root);
    final rootFolder = await _folderDao.ensureByPath(
      root,
      name: rootName,
      workId: workId,
      library: library,
    );

    // key 用小写做大小写不敏感匹配；值保留磁盘上的原始大小写。
    final dirs = <String, String>{};
    for (final raw in mediaPaths) {
      if (raw.trim().isEmpty) continue;
      var dir = _norm(_dirname(_norm(raw)));
      while (true) {
        final key = _key(dir);
        if (key == rootKey || !_isUnder(dir, root)) break;
        dirs[key] = dir;
        final parent = _norm(_dirname(dir));
        if (parent == dir) break;
        dir = parent;
      }
    }

    final ordered = dirs.values.toList()
      ..sort((a, b) {
        final byDepth = _depth(a).compareTo(_depth(b));
        return byDepth != 0 ? byDepth : a.compareTo(b);
      });

    final byKey = <String, VirtualFolder>{rootKey: rootFolder};
    for (final dir in ordered) {
      final parent = _norm(_dirname(dir));
      final parentFolder = byKey[_key(parent)] ?? rootFolder;
      final folder = await _folderDao.ensureByPath(
        dir,
        name: _basename(dir),
        parentId: parentFolder.id,
        workId: workId,
        library: library,
      );
      byKey[_key(dir)] = folder;
    }
    return rootFolder;
  }

  static String _norm(String s) {
    var x = s;
    while (x.endsWith('\\') || x.endsWith('/')) {
      x = x.substring(0, x.length - 1);
    }
    return x;
  }

  static String _key(String s) => s.toLowerCase();

  static p.Context _contextFor(String path) =>
      (path.contains('\\') || path.endsWith(':')) ? p.windows : p.posix;

  static String _dirname(String path) => _contextFor(path).dirname(path);

  static String _basename(String path) => _contextFor(path).basename(path);

  static bool _isUnder(String path, String root) {
    final a = _key(path);
    final b = _key(root);
    return a.startsWith('$b\\') || a.startsWith('$b/');
  }

  static int _depth(String dir) => dir.split(RegExp(r'[\\/]')).length;
}
