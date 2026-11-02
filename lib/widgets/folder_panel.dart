import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database.dart';
import '../db/folder_dao.dart';
import '../services/media_rules.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/log_util.dart';
import 'dialogs.dart';
import 'move_folder_dialog.dart';
import 'tag_picker_dialog.dart';
import 'volume_panel.dart';
import 'scan_access_snack.dart';

/// 多媒体库虚拟文件夹在 `folders.library` 里的库名。
///
/// 图片与视频合并成一个库之后就剩这一个值，与 `works.library` 同一套取值。
const String kMediaLibrary = 'media';

/// 左侧文件夹面板：导入 + 树形文件夹浏览（资源管理器式）
///
/// 文件夹树不经过 [AppState]（它没有全量文件夹表），而是直接用 [FolderDao]
/// 按图片库读取；[AppState.folderVersion] 只当「结构变了」的刷新信号。
class FolderPanel extends StatefulWidget {
  /// 本面板所属的库：目前只有 `media`。
  /// 决定读哪一支文件夹树（`folders.library`）与导入落到哪个库
  /// （`AppState.importDirectory(dir, library: ...)`）。
  final String library;

  const FolderPanel({super.key, this.library = kMediaLibrary});

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

class _FolderPanelState extends State<FolderPanel> {
  final _pathController = TextEditingController();
  final _pathFocus = FocusNode();

  /// 「浏览文件」用的扩展名白名单，直接取 `media_rules.dart` 的唯一来源
  /// （去掉前导点，`FileType.custom` 要的是不带点的形式）。
  /// 多媒体库同时收图片与视频。
  List<String> get _allowedExtensions =>
      <String>[...imageExtensions, ...videoExtensions]
          .map((e) => e.startsWith('.') ? e.substring(1) : e)
          .toList();

  List<VirtualFolder> _roots = const [];
  bool _loadingRoots = true;

  /// 上次见到的 AppState.folderVersion，用来发现外部发起的结构变化
  int? _seenVersion;

  @override
  void didUpdateWidget(FolderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切库后要换一整棵树，folderVersion 不一定变，这里主动重读
    if (oldWidget.library != widget.library) {
      _loadingRoots = true;
      _reloadRoots();
    }
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    // 版本号变了（新建/重命名/删除/移动）就重新读根文件夹。
    // build 里不能直接 setState，排到下一帧。
    if (_seenVersion != appState.folderVersion) {
      _seenVersion = appState.folderVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reloadRoots();
      });
    }

    final folders = _roots;

    return Column(
      children: [
        // 路径输入框
        _buildPathInput(appState),
        // 导入按钮行
        _buildImportButtons(appState),
        // 导入进度条
        if (appState.importing)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: LinearProgressIndicator(
              value: appState.importProgress,
              backgroundColor: AppColors.surfaceOf(context),
              color: AppColors.accent,
              minHeight: 2,
            ),
          ),
        const Divider(height: 1),
        // 树形文件夹列表。「全部图片」入口与表头跟文件夹节点放进同一个
        // 滚动视图：面板被矮窗口压到只剩几十像素时，固定表头不会再顶出溢出条。
        Expanded(
          child: folders.isEmpty && !appState.importing && !_loadingRoots
              ? _emptyGuide()
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    _allImagesEntry(appState),
                    _treeHeader(appState),
                    for (final f in folders)
                      _FolderTreeNode(
                        key: ValueKey('folder-${f.id}'),
                        folder: f,
                        depth: 0,
                        selectedId: appState.currentFolderId,
                        version: appState.folderVersion,
                        library: widget.library,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  // ── 直接读库 ──

  FolderDao get _folderDao => FolderDao(DatabaseManager.instance.db);

  Future<void> _reloadRoots() async {
    final library = widget.library;
    try {
      // 多媒体栏也列出音频作品，左栏的文件夹树就跟着一起给：音频根与多媒体根
      // 都是这一栏能点进去的目录。音频栏自己的 FolderBrowser 不受影响。
      final roots = library == kMediaLibrary
          ? <VirtualFolder>[
              ...await _folderDao.listRoot(library: 'audio'),
              ...await _folderDao.listRoot(library: library),
            ]
          : await _folderDao.listRoot(library: library);
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _loadingRoots = false;
      });
    } catch (e) {
      logDebug('FolderPanel', 'listRoot(library=$library) failed: $e');
      if (!mounted) return;
      setState(() => _loadingRoots = false);
    }
  }

  // ── 「全部图片」入口 ──
  Widget _allImagesEntry(AppState appState) {
    final selected = appState.currentFolderId == null;
    return InkWell(
      onTap: () => _goToRoot(appState),
      child: Container(
        color: selected ? AppColors.surfaceOf(context) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 16,
              color: selected ? AppColors.accent : AppColors.blue,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '全部媒体',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? AppColors.textPrimaryOf(context) : AppColors.textSecondaryOf(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 逐级上溯回到顶层（AppState 没有 goRoot，用 goUp 循环）
  Future<void> _goToRoot(AppState appState) async {
    var guard = 0;
    while (appState.currentFolderId != null && guard++ < 64) {
      await appState.goUp();
    }
  }

  // ── 树标题行（含新建根文件夹） ──
  Widget _treeHeader(AppState appState) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 2),
      child: Row(
        children: [
           Text(
            '文件夹',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedLightOf(context),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: () => _createRootFolder(appState),
              icon:  Icon(Icons.create_new_folder_outlined,
                  size: 15, color: AppColors.mutedOf(context)),
              tooltip: '新建根文件夹',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathInput(AppState appState) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _pathController,
                focusNode: _pathFocus,
                enabled: !appState.importing,
                onSubmitted: (_) => _addFromPath(appState),
                decoration: InputDecoration(
                  hintText: '输入文件夹或文件路径，回车添加',
                  hintStyle:  TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedLightOf(context),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:  BorderSide(color: AppColors.surfaceAltOf(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:  BorderSide(color: AppColors.surfaceAltOf(context)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceOf(context),
                ),
                style:  TextStyle(fontSize: 12, color: AppColors.textPrimaryOf(context)),
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            height: 32,
            child: IconButton(
              onPressed:
                  appState.importing ? null : () => _addFromPath(appState),
              icon: const Icon(Icons.add, size: 18),
              tooltip: '从路径添加',
              style: IconButton.styleFrom(
                foregroundColor: AppColors.accent,
                backgroundColor: AppColors.surfaceOf(context),
                side:  BorderSide(color: AppColors.surfaceAltOf(context)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportButtons(AppState appState) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: OutlinedButton.icon(
                    key: const ValueKey('folder-panel-add-folder'),
                    onPressed: appState.importing
                        ? null
                        : () => _pickFolder(appState),
                    icon: Icon(
                      appState.importing
                          ? Icons.hourglass_empty
                          : Icons.create_new_folder,
                      size: 14,
                    ),
                    label: Text(
                      appState.importing ? '导入中...' : '添加文件夹',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: BorderSide(color: AppColors.surfaceAltOf(context)),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: OutlinedButton.icon(
                    onPressed: appState.importing
                        ? null
                        : () => _pickFiles(appState),
                    icon: Icon(
                      Icons.image_outlined,
                      size: 14,
                      color: appState.importing
                          ? AppColors.mutedLightOf(context)
                          : AppColors.teal,
                    ),
                    label: Text(
                      '浏览文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: appState.importing
                            ? AppColors.mutedLightOf(context)
                            : AppColors.textPrimaryOf(context),
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.teal,
                      side: BorderSide(color: AppColors.surfaceAltOf(context)),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            height: 32,
            child: OutlinedButton.icon(
              key: const ValueKey('folder-panel-batch-import'),
              onPressed: appState.importing
                  ? null
                  : () => _pickBatchFolder(appState),
              icon: Icon(
                Icons.library_add_outlined,
                size: 14,
                color: appState.importing
                    ? AppColors.mutedLightOf(context)
                    : AppColors.accent,
              ),
              label: Text(
                '批量导入（每个子文件夹一个作品）',
                style: TextStyle(
                  fontSize: 10.5,
                  color: appState.importing
                      ? AppColors.mutedLightOf(context)
                      : AppColors.textPrimaryOf(context),
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(color: AppColors.surfaceAltOf(context)),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyGuide() {
    // 可滚动：面板被矮窗口压到只剩几十像素时，这块提示也不会顶出溢出条。
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
               Icon(Icons.folder_open, size: 48, color: AppColors.mutedOf(context)),
              const SizedBox(height: 12),
              Text(
                '点击按钮浏览 | 输入路径添加',
                textAlign: TextAlign.center,
                style:  TextStyle(
                  color: AppColors.textSecondaryOf(context),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 文件夹 CRUD 操作 ──

  Future<void> _createRootFolder(AppState appState) async {
    final name = await _promptFolderName('新建根文件夹');
    if (name == null || name.isEmpty) return;
    try {
      await _folderDao.create(name, library: widget.library);
    } catch (e) {
      logWarn('FolderPanel', '新建根文件夹失败: $name ($e)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建文件夹失败：$e')),
      );
      return;
    }
    await appState.refresh();
  }

  Future<void> _addFromPath(AppState appState) async {
    final text = _pathController.text.trim();
    if (text.isEmpty) return;
    if (!await ensureScanAccessOrPrompt(context)) return;
    _pathController.clear();
    _pathFocus.unfocus();
    // 输入的是文件时，导入它所在的目录（AppState 只按目录导入）
    final dir = Directory(text).existsSync() ? text : File(text).parent.path;
    appState.importDirectory(dir, library: widget.library);
  }

  Future<void> _pickFolder(AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择包含图片或视频的文件夹');
    if (result != null && mounted) {
      await appState.importDirectory(result, library: widget.library);
    }
  }

  /// 批量导入：选父目录，里面的每个子文件夹各建一个作品。
  ///
  /// 一个子文件夹 = 一个作品，比一个个目录点进去导入快得多。
  Future<void> _pickBatchFolder(AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择父文件夹（每个子文件夹一个作品）');
    if (result == null || !mounted) return;
    final created = await appState.importSubdirectoriesAsWorks(
      result,
      library: widget.library,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created > 0 ? '批量导入完成：新建 $created 个作品' : '没有发现可导入的子文件夹（或里面的媒体都已在库里）',
        ),
      ),
    );
  }

  Future<void> _pickFiles(AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final files = await pickFilePaths(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      title: '选择图片或视频文件',
    );
    if (files.isEmpty || !mounted) return;
    // AppState 没有「按文件导入」，只能把它们所在的目录各导入一次
    final dirs = <String>{};
    for (final p in files) {
      dirs.add(File(p).parent.path);
    }
    for (final d in dirs) {
      await appState.importDirectory(d, library: widget.library);
    }
  }

  Future<String?> _promptFolderName(String title, {String? initial}) {
    return promptText(context,
        title: title, initial: initial ?? '', hint: '文件夹名称');
  }
}

/// 递归树节点：懒加载子文件夹 + 展开/收起 + 右键菜单
class _FolderTreeNode extends StatefulWidget {
  final VirtualFolder folder;
  final int depth;
  final int? selectedId;
  final int version;

  /// 所属库：新建子文件夹与「移动到」列表都按这个库查
  final String library;

  const _FolderTreeNode({
    super.key,
    required this.folder,
    required this.depth,
    required this.selectedId,
    required this.version,
    required this.library,
  });

  @override
  State<_FolderTreeNode> createState() => _FolderTreeNodeState();
}

class _FolderTreeNodeState extends State<_FolderTreeNode> {
  List<VirtualFolder>? _children;
  bool _expanded = false;
  bool _loadingChildren = false;

  FolderDao get _folderDao => FolderDao(DatabaseManager.instance.db);

  @override
  void didUpdateWidget(_FolderTreeNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 结构变化（新建/重命名/删除/移动）后重新加载子节点
    if (oldWidget.version != widget.version) {
      _children = null;
      if (_expanded) {
        _loadChildren();
      }
    }
  }

  Future<void> _toggle() async {
    final willExpand = !_expanded;
    setState(() => _expanded = willExpand);
    if (willExpand && _children == null) {
      await _loadChildren();
    }
  }

  Future<void> _loadChildren() async {
    if (_loadingChildren) return;
    setState(() => _loadingChildren = true);
    List<VirtualFolder> children;
    try {
      children = await _folderDao.listChildren(widget.folder.id!);
    } catch (e) {
      logDebug('FolderPanel', 'listChildren(${widget.folder.id}) failed: $e');
      children = const [];
    }
    if (mounted) {
      setState(() {
        _children = children;
        _loadingChildren = false;
        if (children.isNotEmpty) _expanded = true;
      });
    }
  }

  Future<void> _createChildFolder(AppState appState) async {
    final name = await _promptName('新建子文件夹');
    if (name == null || name.isEmpty) return;
    try {
      await _folderDao.create(name,
          parentId: widget.folder.id, library: widget.library);
    } catch (e) {
      logWarn('FolderPanel', '新建子文件夹失败: $name ($e)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建子文件夹失败：$e')),
      );
      return;
    }
    await appState.refresh();
    if (!mounted) return;
    _children = null;
    _expanded = true;
    _loadChildren();
  }

  Future<void> _rename(AppState appState) async {
    final name =
        await _promptName('重命名文件夹', initial: widget.folder.name);
    if (name == null || name.isEmpty) return;
    try {
      await appState.renameFolder(widget.folder.id!, name);
    } catch (e) {
      logWarn('FolderPanel', '重命名文件夹失败: ${widget.folder.name} ($e)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重命名失败：$e')),
      );
    }
  }

  Future<void> _delete(AppState appState) async {
    final count = await appState.countMediaUnderFolder(widget.folder.id!);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除文件夹「${widget.folder.name}」？'),
        content: Text('将从软件里移除这个文件夹、它的子文件夹，以及其中的 '
            '$count 条媒体记录（音频、图片、视频、字幕都算）。\n\n'
            '磁盘上的文件不会被删除，之后可以重新导入。\n'
            '如果这条目录也登记在别的库（比如专辑目录里的图片），那边的记录会一起移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await appState.deleteFolderDeep(widget.folder.id!);
    }
  }

  Future<void> _moveTo(AppState appState) async {
    List<VirtualFolder> allFolders;
    try {
      allFolders = await _folderDao.listAll(library: widget.library);
    } catch (e) {
      logWarn('FolderPanel', 'listAll(library=${widget.library}) failed: $e');
      return;
    }
    if (!mounted) return;
    final target = await showMoveFolderDialog(
      context,
      source: widget.folder,
      allFolders: allFolders,
    );
    if (target == null || !mounted) return; // 取消
    final newParentId = target == kMoveToRoot ? null : target;
    try {
      await _folderDao.move(widget.folder.id!, newParentId);
    } catch (e) {
      logWarn('FolderPanel', '移动文件夹失败: ${widget.folder.name} ($e)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移动失败：$e')),
      );
      return;
    }
    await appState.refresh();
  }

  Future<String?> _promptName(String title, {String? initial}) {
    return promptText(context,
        title: title, initial: initial ?? '', hint: '文件夹名称');
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final selected = widget.selectedId == widget.folder.id;
    final hasChildren =
        _children == null ? null : (_children!.isNotEmpty);

    return Column(
      children: [
        InkWell(
          onTap: () => appState.enterFolder(widget.folder.id!),
          child: Container(
            color: selected ? AppColors.surfaceOf(context) : null,
            padding: EdgeInsets.only(
              left: 6 + widget.depth * 14.0,
              right: 4,
              top: 2,
              bottom: 2,
            ),
            child: Row(
              children: [
                // 展开箭头（懒加载后若无子文件夹则隐藏）
                SizedBox(
                  width: 20,
                  height: 20,
                  child: hasChildren == false
                      ? null
                      : InkWell(
                          onTap: _toggle,
                          borderRadius: BorderRadius.circular(4),
                          child: Icon(
                            _expanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 16,
                            color: AppColors.mutedOf(context),
                          ),
                        ),
                ),
                Icon(
                  _expanded
                      ? Icons.folder_open
                      : Icons.folder,
                  size: 15,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.folder.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? AppColors.textPrimaryOf(context) : AppColors.textSecondaryOf(context),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 更多菜单
                SizedBox(
                  width: 24,
                  height: 20,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 15,
                    icon:  Icon(Icons.more_vert,
                        size: 15, color: AppColors.mutedOf(context)),
                    tooltip: '文件夹操作',
                    onSelected: (v) => _onMenu(v, appState),
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'new',
                        child: Text('新建子文件夹', style: TextStyle(fontSize: 12)),
                      ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('重命名', style: TextStyle(fontSize: 12)),
                      ),
                      const PopupMenuItem(
                        value: 'move',
                        child: Text('移动到...', style: TextStyle(fontSize: 12)),
                      ),
                      if (widget.library == kMediaLibrary)
                        PopupMenuItem(
                          value: 'volume',
                          child:
                              Text('卷面板...', style: TextStyle(fontSize: 12)),
                        ),
                      const PopupMenuItem(
                        value: 'tags',
                        child: Text('添加标签...', style: TextStyle(fontSize: 12)),
                      ),
                      const PopupMenuItem(
                        value: 'untag',
                        child: Text('移除标签...', style: TextStyle(fontSize: 12)),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.danger)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 展开后的子节点
        if (_expanded && _children != null)
          for (final child in _children!)
            _FolderTreeNode(
              key: ValueKey('folder-${child.id}'),
              folder: child,
              depth: widget.depth + 1,
              selectedId: widget.selectedId,
              version: widget.version,
              library: widget.library,
            ),
      ],
    );
  }

  void _onMenu(String value, AppState appState) {
    switch (value) {
      case 'new':
        _createChildFolder(appState);
        break;
      case 'rename':
        _rename(appState);
        break;
      case 'move':
        _moveTo(appState);
        break;
      case 'volume':
        VolumePanel.show(context, folder: widget.folder);
        break;
      case 'tags':
        _addTags(appState);
        break;
      case 'untag':
        _removeTags(appState);
        break;
      case 'delete':
        _delete(appState);
        break;
    }
  }

  Future<void> _addTags(AppState appState) async {
    final tags = await showTagPickerDialog(context, title: '为文件夹添加标签');
    if (tags == null || tags.isEmpty || !mounted) return;
    final recursive = await _confirmSync(
      content: '是否把该标签同步到文件夹内所有图片及子文件夹（一直到底层图片）？',
      folderOnlyLabel: '仅标记文件夹',
      syncLabel: '同步到所有图片',
    );
    if (recursive == null || !mounted) return;
    await appState.addTagsToFolder(widget.folder.id!, tags, recursive: recursive);
  }

  Future<void> _removeTags(AppState appState) async {
    final folderTags = await appState.getFolderTags(widget.folder.id!);
    final ids = folderTags.map((t) => t.id).whereType<int>().toSet();
    if (!mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该文件夹没有标签')));
      return;
    }
    final tags = await showTagPickerDialog(context,
        title: '移除文件夹标签', filterTagIds: ids);
    if (tags == null || tags.isEmpty || !mounted) return;
    final recursive = await _confirmSync(
      content: '是否同步移除该标签（文件夹内所有图片及子文件夹）？',
      folderOnlyLabel: '仅移除文件夹标签',
      syncLabel: '同步移除所有图片',
    );
    if (recursive == null || !mounted) return;
    await appState.removeTagsFromFolder(widget.folder.id!, tags,
        recursive: recursive);
  }

  /// 询问是否递归同步；返回 null=取消, true=同步, false=仅当前文件夹
  Future<bool?> _confirmSync({
    required String content,
    required String folderOnlyLabel,
    required String syncLabel,
  }) async {
    return showDialog<bool?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panelOf(context),
        title:  Text('同步操作', style: TextStyle(color: AppColors.textPrimaryOf(context))),
        content: Text(content,
            style:  TextStyle(color: AppColors.textTertiaryOf(context), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:  Text('取消', style: TextStyle(color: AppColors.mutedLightOf(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(folderOnlyLabel, style: const TextStyle(fontSize: 12)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(syncLabel),
          ),
        ],
      ),
    );
  }
}
