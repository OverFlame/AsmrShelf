import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/tag_dao.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'controller_owner.dart';
import 'dialogs.dart';
import 'scan_access_snack.dart';

/// 左侧面板：导入 + 作品集 + 标签（对标 PictureViewer 的标签面板）
class TagPanel extends StatefulWidget {
  /// 导航后回调（窄屏抽屉里用于关闭抽屉）
  final VoidCallback? onNavigate;

  /// 只给标签区。图片与视频库的「标签筛选」对话框用这个模式，避免露出
  /// 音频专用的导入与作品集两段。
  final bool filterOnly;
  const TagPanel({super.key, this.onNavigate, this.filterOnly = false});

  @override
  State<TagPanel> createState() => _TagPanelState();
}

class _TagPanelState extends State<TagPanel> {
  final _pathController = TextEditingController();
  final _tagSearchCtrl = TextEditingController();
  String _tagSearch = '';

  @override
  void dispose() {
    _pathController.dispose();
    _tagSearchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (widget.filterOnly) return _tagSection(appState);
    return Column(
      children: [
        _importSection(appState),
        const Divider(height: 1),
        _librarySection(appState),
        const Divider(height: 1),
        Expanded(child: _tagSection(appState)),
      ],
    );
  }

  // ── 导入 ──
  Widget _importSection(AppState appState) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _pathController,
                    enabled: !appState.importing,
                    onSubmitted: (_) => _addFromPath(appState),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: '输入文件夹路径，回车添加',
                      hintStyle: TextStyle(
                          fontSize: 11,
                          color: AppColors.mutedLightOf(context)),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
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
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: OutlinedButton.icon(
              onPressed:
                  appState.importing ? null : () => _pickFolder(appState),
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
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
          if (appState.importing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: appState.importProgress,
                backgroundColor: AppColors.surfaceOf(context),
                color: AppColors.accent,
                minHeight: 2,
              ),
            ),
        ],
      ),
    );
  }

  /// 导入失败时把原因弹出来。调用方是按钮回调，没有别的错误出口。
  void _showImportError(AppState appState) {
    final err = appState.importError;
    if (err == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('导入失败：$err')));
  }

  Future<void> _addFromPath(AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final text = _pathController.text.trim();
    if (text.isEmpty) return;
    _pathController.clear();
    await appState.importDirectory(text);
    _showImportError(appState);
  }

  Future<void> _pickFolder(AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择包含音频的文件夹');
    if (result != null) {
      await appState.importDirectory(result);
      _showImportError(appState);
    }
  }

  // ── 作品集 ──
  Widget _librarySection(AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 2),
          child: Row(
            children: [
              Text('作品集',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mutedLightOf(context))),
              const Spacer(),
              IconButton(
                padding: EdgeInsets.zero,
                onPressed: () => _createWork(appState),
                icon: Icon(Icons.add_circle_outline,
                    size: 15, color: AppColors.mutedOf(context)),
                tooltip: '新建空作品',
              ),
            ],
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 4),
            children: [
              _navEntry(
                selected: appState.currentWork == null,
                icon: Icons.home_outlined,
                label: '全部作品',
                onTap: () {
                  appState.goHome();
                  widget.onNavigate?.call();
                },
              ),
              for (final w in appState.works)
                _navEntry(
                  selected: appState.currentWork?.id == w.id,
                  icon: Icons.album_outlined,
                  label: w.name,
                  onTap: () {
                    appState.enterWork(w.id!);
                    widget.onNavigate?.call();
                  },
                ),
              for (final f in appState.unassignedFolders)
                _navEntry(
                  selected: appState.currentFolderId == f.id,
                  icon: Icons.folder_outlined,
                  label: '未归类 · ${f.name}',
                  onTap: () {
                    appState.enterFolder(f.id!);
                    widget.onNavigate?.call();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createWork(AppState appState) async {
    final name = await promptText(context, title: '新建空作品');
    if (name != null && name.isNotEmpty) {
      await appState.createWork(name);
    }
  }

  Widget _navEntry({
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.surfaceOf(context) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(icon,
                size: 15, color: selected ? AppColors.accent : AppColors.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected
                      ? AppColors.textPrimaryOf(context)
                      : AppColors.textSecondaryOf(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 标签 ──
  Widget _tagSection(AppState appState) {
    final allTags = appState.allTags;
    final filter = appState.tagFilter;
    final activeIds = <int>{
      ...filter.andTagIds,
      ...filter.orTagIds,
      ...filter.notTagIds,
    };

    var filtered = _tagSearch.isEmpty
        ? allTags
        : allTags
            .where((t) =>
                t.name.toLowerCase().contains(_tagSearch.toLowerCase()) ||
                t.namespace.toLowerCase().contains(_tagSearch.toLowerCase()))
            .toList();

    final namespaces = <String, List<Tag>>{};
    for (final t in filtered) {
      final ns = t.namespace.isEmpty ? '(无命名空间)' : t.namespace;
      namespaces.putIfAbsent(ns, () => []).add(t);
    }
    final sortedNs = namespaces.keys.toList()
      ..sort((a, b) {
        if (a == '(无命名空间)') return 1;
        if (b == '(无命名空间)') return -1;
        return a.compareTo(b);
      });

    // 表头、搜索框与「已选筛选」条固定在顶上，只有标签列表滚动：
    // 往下翻几十个标签时，筛选与添加入口不会跟着跑掉。
    Widget pinnedBody() => Column(
          children: [
            _tagHeader(appState),
            const Divider(height: 1),
            _tagSearchBar(),
            if (activeIds.isNotEmpty) _activeFilterBar(appState),
            Expanded(
              child: ListView.builder(
                itemCount: sortedNs.length,
                itemBuilder: (ctx, i) => _namespaceGroup(
                    sortedNs[i], namespaces[sortedNs[i]]!, appState, filter),
              ),
            ),
          ],
        );

    // 面板被矮窗口压到只剩几十像素（固定行 81 高）时退回整体滚动，
    // 免得固定表头把面板顶出溢出条。
    Widget scrollingBody() => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _tagHeader(appState)),
            const SliverToBoxAdapter(child: Divider(height: 1)),
            SliverToBoxAdapter(child: _tagSearchBar()),
            if (activeIds.isNotEmpty)
              SliverToBoxAdapter(child: _activeFilterBar(appState)),
            SliverList.builder(
              itemCount: sortedNs.length,
              itemBuilder: (ctx, i) => _namespaceGroup(
                  sortedNs[i], namespaces[sortedNs[i]]!, appState, filter),
            ),
          ],
        );

    return LayoutBuilder(
      builder: (ctx, constraints) => constraints.maxHeight >= 170
          ? pinnedBody()
          : scrollingBody(),
    );
  }

  Widget _tagHeader(AppState appState) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text('标签',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOf(context))),
          ),
          // 左栏固定 260 宽：按钮组整体按需缩小，绝不横向溢出。
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('tag-expand-all'),
                      tooltip: '展开全部命名空间',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => appState.setAllNamespacesCollapsed(false),
                      icon: Icon(Icons.unfold_more,
                          size: 14, color: AppColors.mutedOf(context)),
                    ),
                    IconButton(
                      key: const ValueKey('tag-collapse-all'),
                      tooltip: '折叠全部命名空间',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => appState.setAllNamespacesCollapsed(true),
                      icon: Icon(Icons.unfold_less,
                          size: 14, color: AppColors.mutedOf(context)),
                    ),
                    IconButton(
                      tooltip: '高级筛选表达式',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => _advancedFilter(appState),
                      icon: Icon(Icons.functions,
                          size: 15,
                          color: appState.hasAdvancedFilter
                              ? AppColors.accent
                              : AppColors.mutedOf(context)),
                    ),
                    IconButton(
                      tooltip: '新建标签',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () => _showCreateTagDialog(appState),
                      icon: Icon(Icons.add,
                          size: 16, color: AppColors.mutedOf(context)),
                    ),
                    if (appState.tagFilter.active || appState.hasAdvancedFilter)
                      IconButton(
                        tooltip: '清除筛选',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                        onPressed: () {
                          appState.clearTagFilters();
                          appState.clearAdvancedFilter();
                        },
                        icon: Icon(Icons.clear,
                            size: 14, color: AppColors.mutedOf(context)),
                      ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: _tagSearchCtrl,
          onChanged: (v) => setState(() => _tagSearch = v),
          style: TextStyle(fontSize: 12, color: AppColors.textPrimaryOf(context)),
          decoration: InputDecoration(
            hintText: '搜索标签...',
            hintStyle: TextStyle(
                fontSize: 12, color: AppColors.mutedLightOf(context)),
            prefixIcon: Icon(Icons.search,
                size: 14, color: AppColors.mutedLightOf(context)),
            suffixIcon: _tagSearch.isNotEmpty
                ? IconButton(
                    tooltip: '清空搜索',
                    icon: Icon(Icons.clear,
                        size: 14, color: AppColors.mutedLightOf(context)),
                    onPressed: () {
                      _tagSearchCtrl.clear();
                      setState(() => _tagSearch = '');
                    },
                  )
                : null,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
        ),
      ),
    );
  }

  Widget _activeFilterBar(AppState appState) {
    final filter = appState.tagFilter;
    final tagMap = {for (final t in appState.allTags) t.id!: t};

    final chips = <Widget>[];
    for (final id in filter.andTagIds) {
      final tag = tagMap[id];
      if (tag == null) continue;
      chips.add(_filterChip('AND ${tag.name}', AppColors.success,
          () => appState.toggleAndFilter(id)));
    }
    for (final id in filter.orTagIds) {
      final tag = tagMap[id];
      if (tag == null) continue;
      chips.add(_filterChip('OR ${tag.name}', AppColors.warning,
          () => appState.toggleOrFilter(id)));
    }
    for (final id in filter.notTagIds) {
      final tag = tagMap[id];
      if (tag == null) continue;
      chips.add(_filterChip('NOT ${tag.name}', AppColors.danger,
          () => appState.toggleNotFilter(id)));
    }

    if (chips.isEmpty) return const SizedBox.shrink();
    return Container(
      color: AppColors.surfaceOf(context),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Wrap(spacing: 4, runSpacing: 2, children: chips),
    );
  }

  Widget _filterChip(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, color: color)),
      ),
    );
  }

  /// 命名空间在界面上显示的中文名。规则命名空间由软件自动生成，直接写
  /// kind/ext 没人看得懂。
  String _nsLabel(String ns) {
    switch (ns) {
      case TagDao.kindNamespace:
        return '类型';
      case TagDao.extNamespace:
        return '扩展名';
      case '(无命名空间)':
        return '(无命名空间)';
      default:
        return ns;
    }
  }

  /// 分组标题用的键：空命名空间统一按 '' 存
  String _nsKey(String ns) => ns == '(无命名空间)' ? '' : ns;

  Widget _namespaceGroup(
      String ns, List<Tag> tags, AppState appState, TagFilter filter) {
    tags.sort((a, b) => a.name.compareTo(b.name));
    final nsKey = _nsKey(ns);
    final collapsed = appState.isNamespaceCollapsed(nsKey);
    final activeCount = tags
        .where((t) =>
            t.id != null &&
            (filter.andTagIds.contains(t.id) ||
                filter.orTagIds.contains(t.id) ||
                filter.notTagIds.contains(t.id)))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('ns-header-$nsKey'),
          onTap: () => appState.toggleNamespaceCollapsed(nsKey),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 12, 4),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 14,
                  color: AppColors.mutedLighterOf(context),
                ),
                Text(
                  _nsLabel(ns),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mutedLighterOf(context),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${tags.length}',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.mutedLighterOf(context),
                  ),
                ),
                if (collapsed && activeCount > 0) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.filter_alt,
                      size: 11, color: AppColors.accent),
                ],
              ],
            ),
          ),
        ),
        if (!collapsed) ...tags.map((tag) => _tagItem(tag, appState, filter)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _tagItem(Tag tag, AppState appState, TagFilter filter) {
    final andActive = filter.andTagIds.contains(tag.id);
    final orActive = filter.orTagIds.contains(tag.id);
    final notActive = filter.notTagIds.contains(tag.id);
    final anyActive = andActive || orActive || notActive;
    final dotColor = AppColors.parseColor(tag.color);

    return Material(
      key: ValueKey('tag-item-${tag.id}'),
      color: anyActive ? AppColors.surfaceAltOf(context) : Colors.transparent,
      child: InkWell(
        onTap: () => appState.toggleAndFilter(tag.id!),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: anyActive
                      ? Border.all(color: dotColor, width: 2)
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tag.name,
                  style: TextStyle(
                    fontSize: 12,
                    color: anyActive
                        ? AppColors.textPrimaryOf(context)
                        : AppColors.textSecondaryOf(context),
                    fontWeight:
                        anyActive ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _filterPopup(tag, appState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterPopup(Tag tag, AppState appState) {
    final filter = appState.tagFilter;
    final andActive = filter.andTagIds.contains(tag.id);
    final orActive = filter.orTagIds.contains(tag.id);
    final notActive = filter.notTagIds.contains(tag.id);
    final isRule = AppState.isRuleTag(tag);

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      iconSize: 12,
      icon: Icon(
        Icons.more_horiz,
        size: 12,
        color: (andActive || orActive || notActive)
            ? AppColors.textPrimaryOf(context)
            : AppColors.mutedOf(context),
      ),
      tooltip: '筛选选项',
      onSelected: (action) {
        switch (action) {
          case 'and':
            appState.toggleAndFilter(tag.id!);
            break;
          case 'or':
            appState.toggleOrFilter(tag.id!);
            break;
          case 'not':
            appState.toggleNotFilter(tag.id!);
            break;
          case 'clear':
            appState.toggleAndFilter(tag.id!);
            appState.toggleOrFilter(tag.id!);
            appState.toggleNotFilter(tag.id!);
            break;
          case 'edit':
            _showEditTagDialog(tag, appState);
            break;
          case 'delete':
            _showDeleteTagDialog(tag, appState);
            break;
          case 'collapse':
            appState.toggleNamespaceCollapsed(tag.namespace);
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'and',
          child: _popupItem('AND 交集', '必须拥有此标签', Icons.search, andActive),
        ),
        PopupMenuItem(
          value: 'or',
          child: _popupItem('OR 并集', '可以拥有此标签', Icons.filter_list, orActive),
        ),
        PopupMenuItem(
          value: 'not',
          child: _popupItem('NOT 排除', '不能拥有此标签', Icons.block, notActive),
        ),
        if (andActive || orActive || notActive) const PopupMenuDivider(),
        if (andActive || orActive || notActive)
          const PopupMenuItem(
              value: 'clear', child: Text('清除此标签筛选', style: TextStyle(fontSize: 12))),
        const PopupMenuDivider(),
        if (isRule) ...[
          PopupMenuItem(
            value: 'collapse',
            child: const Text('折叠此命名空间', style: TextStyle(fontSize: 12)),
          ),
          PopupMenuItem(
            enabled: false,
            child: Text('规则标签由软件自动生成，不能改名或删除',
                style: TextStyle(
                    fontSize: 10, color: AppColors.mutedOf(context))),
          ),
        ] else ...[
          const PopupMenuItem(
              value: 'edit',
              child: Text('重命名/改色', style: TextStyle(fontSize: 12))),
          PopupMenuItem(
            value: 'delete',
            child: Text('删除标签',
                style: TextStyle(fontSize: 12, color: AppColors.danger)),
          ),
        ],
      ],
    );
  }

  Widget _popupItem(String title, String sub, IconData icon, bool active) {
    return Row(
      children: [
        Icon(icon,
            size: 14,
            color: active ? AppColors.accent : AppColors.mutedOf(context)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 12)),
            Text(sub,
                style: TextStyle(
                    fontSize: 10, color: AppColors.mutedOf(context))),
          ],
        ),
        if (active)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(Icons.check, size: 12, color: AppColors.accent),
          ),
      ],
    );
  }

  // ── 新建标签对话框 ──
  void _showCreateTagDialog(AppState appState) {
    final nameCtrl = TextEditingController();
    final nsCtrl = TextEditingController();
    String color = '#a98cf5';
    const presetColors = [
      '#a98cf5', '#f06e7f', '#f0a868', '#e2c275',
      '#9ccb86', '#63bfc8', '#6fb6ec', '#9fa6ef',
    ];
    // 联想用：库里已有的普通命名空间（general 是留空时的默认值，规则
    // 命名空间由软件维护，都不必提示）。
    final suggestions = appState.knownNamespaces
        .where((n) =>
            n != 'general' &&
            n != TagDao.kindNamespace &&
            n != TagDao.extNamespace)
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => ControllerOwner(
        controllers: [nameCtrl, nsCtrl],
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            final name = nameCtrl.text.trim();
            final ns = nsCtrl.text.trim().isEmpty
                ? 'general'
                : nsCtrl.text.trim();
            final exact =
                name.isEmpty ? null : appState.findTagByName(name, namespace: ns);
            final other = name.isEmpty ? null : appState.findTagByName(name);
            final warning = exact != null
                ? '「${exact.toString()}」已经存在，换个名字或改命名空间'
                : (other != null
                    ? '「${other.toString()}」在别的命名空间，继续创建会得到两个同名标签'
                    : null);
            return AlertDialog(
              title: const Text('新建标签'),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey('create-tag-name'),
                      controller: nameCtrl,
                      autofocus: true,
                      onChanged: (_) => setLocal(() {}),
                      decoration: const InputDecoration(
                          labelText: '标签名', hintText: '例如：纯音乐'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('create-tag-ns'),
                      controller: nsCtrl,
                      onChanged: (_) => setLocal(() {}),
                      decoration: const InputDecoration(
                          labelText: '命名空间 (可选)', hintText: '例如：风格'),
                    ),
                    if (suggestions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: suggestions.map((ns) {
                            return ActionChip(
                              key: ValueKey('ns-suggestion-$ns'),
                              label: Text(ns,
                                  style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setLocal(() => nsCtrl.text = ns),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: presetColors.map((c) {
                        final selected = color == c;
                        return GestureDetector(
                          onTap: () => setLocal(() => color = c),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: AppColors.parseColor(c),
                              shape: BoxShape.circle,
                              border: selected
                                  ? Border.all(
                                      color: AppColors.textPrimaryOf(ctx),
                                      width: 2)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    if (warning != null) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          warning,
                          key: const ValueKey('create-tag-warning'),
                          style: TextStyle(
                              fontSize: 11,
                              color: exact != null
                                  ? AppColors.danger
                                  : AppColors.mutedOf(ctx)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
                TextButton(
                  key: const ValueKey('create-tag-submit'),
                  onPressed: (name.isEmpty || exact != null)
                      ? null
                      : () {
                          appState.createTag(name,
                              namespace: nsCtrl.text.trim(), color: color);
                          Navigator.pop(ctx);
                        },
                  child: const Text('创建'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 编辑标签对话框（重命名 / 改命名空间 / 改色）──
  void _showEditTagDialog(Tag tag, AppState appState) {
    final nameCtrl = TextEditingController(text: tag.name);
    final nsCtrl = TextEditingController(
        text: tag.namespace == 'general' ? '' : tag.namespace);
    String color = tag.color;
    const presetColors = [
      '#a98cf5', '#f06e7f', '#f0a868', '#e2c275',
      '#9ccb86', '#63bfc8', '#6fb6ec', '#9fa6ef',
    ];

    showDialog(
      context: context,
      builder: (ctx) => ControllerOwner(
        controllers: [nameCtrl, nsCtrl],
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('编辑标签'),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '标签名'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nsCtrl,
                    decoration: const InputDecoration(
                        labelText: '命名空间 (可选)', hintText: '留空为 general'),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: presetColors.map((c) {
                      final selected = color == c;
                      return GestureDetector(
                        onTap: () => setLocal(() => color = c),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: AppColors.parseColor(c),
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(
                                    color: AppColors.textPrimaryOf(ctx), width: 2)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消')),
              TextButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isNotEmpty) {
                    final ns = nsCtrl.text.trim();
                    appState.updateTag(tag.id!, name,
                        namespace: ns.isEmpty ? 'general' : ns, color: color);
                    Navigator.pop(ctx);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDeleteTagDialog(Tag tag, AppState appState) async {
    final counts = await appState.tagUsageCounts(tag.id!);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签'),
        content: Text(
            '确定删除「${tag.name}」？\n将解除 ${counts.media} 个媒体、'
            '${counts.folders} 个文件夹的关联。\n磁盘上的文件不会被删除。',
            style: TextStyle(
                color: AppColors.textSecondaryOf(ctx), fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              appState.deleteTag(tag.id!);
              Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _advancedFilter(AppState appState) async {
    final expr = await promptText(context,
        title: '高级筛选表达式',
        initial: appState.advancedFilter,
        hint: '例如 (A||B)&&!C');
    if (expr == null) return;
    try {
      await appState.setAdvancedFilter(expr);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('表达式错误：$e')));
      }
    }
  }
}
