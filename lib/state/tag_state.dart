import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../db/folder_dao.dart';
import '../db/media_dao.dart' show MediaType;
import '../db/tag_dao.dart';
import '../db/track_dao.dart';
import '../services/settings_service.dart';
import '../utils/filter_expression.dart';
import 'tag_filter.dart';

/// 标签相关的全部状态：标签清单、每个媒体已绑定的标签缓存、筛选表达式、
/// 面板折叠的命名空间。
///
/// 拆分自 [AppState]。这里只管标签自己的读写；需要让作品列表重新查询时
/// 调 [onRefresh]（由 AppState 注入），需要让界面重画时由 [notifyListeners]
/// 经 AppState 的监听转发出去。状态对象不 import 别的状态对象。
class TagState extends ChangeNotifier {
  TagState({
    required this.tagDao,
    required this.folderDao,
    required this.trackDao,
  });

  /// DAO 用工厂传入：库在 [AppState.init] 里才打开，构造时不能碰连接。
  final TagDao Function() tagDao;
  final FolderDao Function() folderDao;
  final TrackDao Function() trackDao;

  /// 筛选变了要让作品列表重查；不注入时只通知界面重画。
  Future<void> Function()? onRefresh;

  // ── 标签清单与缓存 ──

  List<Tag> _allTags = [];

  /// 库里的全部标签，按名字排序（DAO 负责）。
  List<Tag> get allTags => _allTags;

  final Map<int, List<Tag>> _trackTags = {};
  final Map<int, List<Tag>> _imageTags = {};

  /// 每个媒体的标签切换排队串行执行，见 [toggleTagOnTrack]。
  final Map<int, Future<void>> _tagToggleChains = {};

  // ── 筛选 ──

  TagFilter _tagFilter = const TagFilter();
  TagFilter get tagFilter => _tagFilter;

  String _advancedFilter = '';
  String get advancedFilter => _advancedFilter;
  bool get hasAdvancedFilter => _advancedFilter.trim().isNotEmpty;

  /// 当前筛选里出现的全部标签 id（界面高亮用）。
  Set<int> get activeTagIds => {
        ..._tagFilter.andTagIds,
        ..._tagFilter.orTagIds,
        ..._tagFilter.notTagIds,
      };

  // ── 面板折叠 ──

  final Set<String> _collapsedNamespaces = {};

  Set<String> get collapsedNamespaces =>
      UnmodifiableSetView(_collapsedNamespaces);

  bool isNamespaceCollapsed(String namespace) =>
      _collapsedNamespaces.contains(namespace);

  /// 首次启动折叠扩展名那一组：那是按文件后缀自动生成的规则标签，几十个，
  /// 不折叠会盖住用户自己打的标签。用户改过就按用户存的来。
  Future<void> initCollapsedNamespaces() async {
    final stored = SettingsService.instance.collapsedTagNamespaces;
    if (stored != null) {
      _collapsedNamespaces
        ..clear()
        ..addAll(stored);
      notifyListeners();
      return;
    }
    _collapsedNamespaces.add(TagDao.extNamespace);
    await SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList());
  }

  void toggleNamespaceCollapsed(String namespace) {
    if (!_collapsedNamespaces.remove(namespace)) {
      _collapsedNamespaces.add(namespace);
    }
    unawaited(SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList()));
    notifyListeners();
  }

  /// 展开或折叠当前已有的全部命名空间（标签面板的「全部折叠/展开」）。
  void setAllNamespacesCollapsed(bool collapsed) {
    final all = _allTags.map((t) => t.namespace).toSet();
    if (collapsed) {
      _collapsedNamespaces.addAll(all);
    } else {
      _collapsedNamespaces.removeAll(all);
    }
    unawaited(SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList()));
    notifyListeners();
  }

  // ── 读 ──

  Future<void> load() async {
    _allTags = await tagDao().getAll();
    notifyListeners();
  }

  Future<List<Tag>> getTrackTags(int trackId) async {
    final cached = _trackTags[trackId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await tagDao().getTagsForTrack(trackId);
    _trackTags[trackId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_trackTags[trackId]!);
  }

  Future<List<Tag>> getImageTags(int imageId) async {
    final cached = _imageTags[imageId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await tagDao().getTagsForImage(imageId);
    _imageTags[imageId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_imageTags[imageId]!);
  }

  /// 媒体行不分类型，曲目与图片都读 `media_tags`。
  Future<List<Tag>> getTagsForMedia(int mediaId) async {
    final cached = _imageTags[mediaId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await tagDao().getTagsForTrack(mediaId);
    _imageTags[mediaId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_imageTags[mediaId]!);
  }

  Future<List<Tag>> getFolderTags(int folderId) =>
      tagDao().getTagsForFolder(folderId);

  /// 标签被多少条媒体、多少个文件夹引用（删除前提示用）。
  Future<({int media, int folders})> tagUsageCounts(int tagId) =>
      tagDao().countUsage(tagId);

  /// 标签库里出现过的命名空间（新建标签时给输入框做联想）。
  List<String> get knownNamespaces {
    final names = _allTags.map((t) => t.namespace).toSet().toList()..sort();
    return names;
  }

  /// 按名字找标签。给了命名空间就精确匹配，没给就跨命名空间找第一个。
  Tag? findTagByName(String name, {String? namespace}) {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) return null;
    for (final t in _allTags) {
      if (t.name.toLowerCase() != target) continue;
      if (namespace == null || t.namespace == namespace) return t;
    }
    return null;
  }

  // ── 单个媒体的标签切换 ──

  /// 切换曲目标签。同一曲目的多次调用按顺序串行执行。
  ///
  /// 连点两次同一个标签时，第二次必须在第一次写库并更新缓存之后才读当前状态；
  /// 否则两次都读到「未打标签」，双击「关标签」会变成打开。
  Future<void> toggleTagOnTrack(int trackId, Tag tag) =>
      _queueTagToggle(trackId, image: false, tag: tag);

  /// 切换图片标签。串行语义与 [toggleTagOnTrack] 相同。
  Future<void> toggleTagOnImage(int imageId, Tag tag) =>
      _queueTagToggle(imageId, image: true, tag: tag);

  Future<void> _queueTagToggle(int mediaId,
      {required bool image, required Tag tag}) {
    final previous = _tagToggleChains[mediaId] ?? Future<void>.value();
    final chain =
        previous.then((_) => _applyTagToggle(mediaId, tag, image: image));
    // 链尾只保留不会失败的 future：前一次出错不能卡住后面的点击。
    final tail = chain.catchError((Object _) {});
    _tagToggleChains[mediaId] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_tagToggleChains[mediaId], tail)) {
        _tagToggleChains.remove(mediaId);
      }
    }));
    return chain;
  }

  /// media_tags 以 media.id 为键，曲目与图片共用；只有内存缓存分两份。
  Future<void> _applyTagToggle(int mediaId, Tag tag,
      {required bool image}) async {
    final cache = image ? _imageTags : _trackTags;
    // 改副本，缓存里的 List 不被就地修改；调用方拿到的也是不可变视图。
    final current = List<Tag>.of(cache[mediaId] ??
        (image
            ? await tagDao().getTagsForImage(mediaId)
            : await tagDao().getTagsForTrack(mediaId)));
    final has = current.any((t) => t.id == tag.id);
    if (has) {
      if (image) {
        await tagDao().removeTagFromImage(mediaId, tag.id!);
      } else {
        await tagDao().removeTagFromTrack(mediaId, tag.id!);
      }
      current.removeWhere((t) => t.id == tag.id);
    } else {
      if (image) {
        await tagDao().addTagToImage(mediaId, tag.id!);
      } else {
        await tagDao().addTagToTrack(mediaId, tag.id!);
      }
      current.add(tag);
    }
    cache[mediaId] = current;
    notifyListeners();
  }

  // ── 批量 ──

  Future<void> addTagToFolder(int folderId, Tag tag) =>
      addTagsToFolder(folderId, [tag]);

  /// 为文件夹批量添加标签；[recursive] 为真时递归同步到其所有子文件夹曲目。
  Future<void> addTagsToFolder(int folderId, List<Tag> tags,
      {bool recursive = false}) async {
    for (final tag in tags) {
      await tagDao().addTagToFolder(folderId, tag.id!);
    }
    if (recursive) {
      final trackIds = await collectFolderTrackIds(folderId);
      await tagDao().addTagsToTracks(trackIds, tags.map((t) => t.id!));
    }
    await _refreshIfPossible();
  }

  Future<void> removeTagsFromFolder(int folderId, List<Tag> tags,
      {bool recursive = false}) async {
    if (recursive) {
      final trackIds = await collectFolderTrackIds(folderId);
      await tagDao().removeTagsFromTracks(trackIds, tags.map((t) => t.id!));
    }
    for (final tag in tags) {
      await tagDao().removeTagFromFolder(folderId, tag.id!);
    }
    await _refreshIfPossible();
  }

  /// 收集文件夹及其所有子文件夹下的曲目 id（按路径前缀）。
  Future<Set<int>> collectFolderTrackIds(int folderId) async {
    final paths = <String>[];
    final queue = <int>[folderId];
    while (queue.isNotEmpty) {
      final fid = queue.removeAt(0);
      for (final fp in await folderDao().getPaths(fid)) {
        paths.add(fp.path);
      }
      for (final c in await folderDao().listChildren(fid)) {
        if (c.id != null) queue.add(c.id!);
      }
    }
    if (paths.isEmpty) return {};
    final tracks = await trackDao().queryByDirs(paths);
    return tracks.map((t) => t.id).whereType<int>().toSet();
  }

  Future<void> addTagsToTracks(Iterable<int> trackIds, List<Tag> tags) async {
    await tagDao().addTagsToTracks(trackIds, tags.map((t) => t.id!));
    _trackTags.clear();
    notifyListeners();
  }

  Future<void> removeTagsFromTracks(
      Iterable<int> trackIds, List<Tag> tags) async {
    await tagDao().removeTagsFromTracks(trackIds, tags.map((t) => t.id!));
    _trackTags.clear();
    notifyListeners();
  }

  /// 返回这批曲目上已绑定的标签 id 集合（用于「移除标签」时过滤可选项）。
  Future<Set<int>> getTagIdsOnTracks(Iterable<int> trackIds) async {
    final ids = trackIds.toList();
    if (ids.isEmpty) return {};
    final map = await tagDao().getTagsForTracks(ids);
    final result = <int>{};
    for (final tags in map.values) {
      for (final t in tags) {
        if (t.id != null) result.add(t.id!);
      }
    }
    return result;
  }

  Future<void> addTagsToImages(Iterable<int> imageIds, List<Tag> tags) async {
    for (final t in tags) {
      await tagDao().addTagsToTracks(imageIds, [t.id!]);
    }
    _imageTags.clear();
    notifyListeners();
  }

  Future<void> removeTagsFromImages(
      Iterable<int> imageIds, List<Tag> tags) async {
    for (final t in tags) {
      await tagDao().removeTagsFromTracks(imageIds, [t.id!]);
    }
    _imageTags.clear();
    notifyListeners();
  }

  /// 返回这批图片上已绑定的标签 id 集合（用于「移除标签」时过滤可选项）。
  Future<Set<int>> getTagIdsOnImages(Iterable<int> imageIds) async {
    final ids = imageIds.toList();
    if (ids.isEmpty) return {};
    final map = await tagDao().getTagsForImages(ids);
    final result = <int>{};
    for (final tags in map.values) {
      for (final t in tags) {
        if (t.id != null) result.add(t.id!);
      }
    }
    return result;
  }

  /// 覆盖设置单个媒体的标签集（视频卡片菜单用）。
  Future<void> setMediaTags(int mediaId, List<Tag> tags) async {
    await tagDao().setTrackTags(mediaId, [
      for (final t in tags)
        if (t.id != null) t.id!,
    ]);
    _imageTags.clear();
    if (_tagFilter.active || hasAdvancedFilter) {
      await _refreshIfPossible();
    } else {
      notifyListeners();
    }
  }

  // ── 写 ──

  Future<Tag> createTag(String name,
      {String namespace = '', String color = '#cba6f7'}) async {
    final ns = namespace.isEmpty ? 'general' : namespace;
    final match = _allTags.where((t) =>
        t.name.toLowerCase() == name.toLowerCase() && t.namespace == ns);
    if (match.isNotEmpty) return match.first;
    final tag =
        await tagDao().insert(Tag(name: name, namespace: ns, color: color));
    await load();
    return tag;
  }

  Future<void> deleteTag(int tagId) async {
    await tagDao().delete(tagId);
    _trackTags.clear();
    _imageTags.clear();
    removeFromFilter(tagId);
    await load();
    await _refreshIfPossible();
  }

  /// 更新标签（重命名 / 改命名空间 / 改色）
  Future<void> updateTag(int tagId, String name,
      {String? namespace, String? color}) async {
    final existing = await tagDao().getById(tagId);
    if (existing == null) return;
    await tagDao().update(Tag(
      id: tagId,
      namespace: namespace ?? existing.namespace,
      name: name,
      color: color ?? existing.color,
    ));
    _trackTags.clear();
    _imageTags.clear();
    await load();
    await _refreshIfPossible();
  }

  // ── 首次启动的默认排除集 ──

  /// 默认排除「字幕」这类规则标签，并把排除集持久化（BUILD_GUIDE 第 18.5 节）。
  ///
  /// 字幕照常入库，只是默认不进列表；用户改过排除集就不再套用默认值。
  Future<void> initNotTagIds() async {
    final settings = SettingsService.instance;
    final stored = settings.excludedTagIds;
    if (stored != null) {
      if (stored.isNotEmpty) {
        _tagFilter = TagFilter(notTagIds: stored);
        notifyListeners();
      }
      return;
    }
    final kindIds = _allTags
        .where((t) =>
            t.namespace == TagDao.kindNamespace &&
            t.name == MediaType.subtitle.value)
        .map((t) => t.id)
        .whereType<int>()
        .toList();
    await settings.setExcludedTagIds(kindIds);
    if (kindIds.isNotEmpty) {
      _tagFilter = TagFilter(notTagIds: kindIds);
      notifyListeners();
    }
  }

  /// 排除集每次变动都落盘，重启后保持。
  void _persistNotTagIds() {
    unawaited(
        SettingsService.instance.setExcludedTagIds(_tagFilter.notTagIds));
  }

  void removeFromFilter(int tagId) {
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    _persistNotTagIds();
  }

  // ── 筛选开关 ──

  void toggleAndFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.andTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: list,
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    _requestRefresh();
  }

  void toggleOrFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.orTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: list,
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    _persistNotTagIds();
    _requestRefresh();
  }

  void toggleNotFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.notTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: list,
    );
    _persistNotTagIds();
    _requestRefresh();
  }

  void clearTagFilters() {
    _tagFilter = const TagFilter();
    _persistNotTagIds();
    _requestRefresh();
  }

  Future<void> setAdvancedFilter(String expression) async {
    final expr = expression.trim();
    if (expr.isEmpty) {
      await clearAdvancedFilter();
      return;
    }
    FilterExpressionParser.parse(expr);
    _advancedFilter = expr;
    _tagFilter = const TagFilter();
    await SettingsService.instance.addExpression(expr);
    await _refreshIfPossible();
  }

  Future<void> clearAdvancedFilter() async {
    if (!hasAdvancedFilter) return;
    _advancedFilter = '';
    await _refreshIfPossible();
  }

  /// 让作品列表重查一次；没有接线时退化成只通知界面。
  void _requestRefresh() {
    final f = onRefresh;
    if (f == null) {
      notifyListeners();
      return;
    }
    unawaited(f());
  }

  Future<void> _refreshIfPossible() async {
    final f = onRefresh;
    if (f == null) {
      notifyListeners();
      return;
    }
    await f();
  }

  /// 标签被删或改名后，界面上的缓存都该失效。
  void clearCaches() {
    _trackTags.clear();
    _imageTags.clear();
  }

  @override
  void dispose() {
    onRefresh = null;
    super.dispose();
  }

}
