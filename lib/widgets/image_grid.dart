import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../db/database.dart';
import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../services/thumbnail_cache.dart';
import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../utils/latest_only_runner.dart';
import '../utils/log_util.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'folder_panel.dart';
import 'launch_result_snack.dart';
import 'scan_access_snack.dart';
import 'tag_picker_dialog.dart';

/// 中间栏：资源管理器式浏览（子文件夹 + 直接媒体），支持网格/列表视图与多选。
///
/// [library] 是这一栏所属的库，多媒体栏传 [kMediaLibrary]。图片栏与视频栏已经合并成
/// 多媒体栏，所以同一层目录里的图片、视频、音频混在 `AppState.images` 里，这一栏按
/// 每条行自己的 `mediaType` 分派：
/// - 图片：[_ThumbnailCard]，双击进漫画查看器（查看器只收图片，见
///   [_openImageInViewer]，否则左右翻页会翻到视频/音频这些「打不开的图」）；
/// - 视频：[_VideoTile]，封面走 `AppState.videoCoverFor` 的三级取图，取不到退回
///   `Icons.movie`；双击或菜单走 `AppState.playFolderExternal` /
///   `playWorkExternal`，不做应用内解码；
/// - 音频：[_AudioTile]，网格里画封面/标题/时长，列表里用与音频栏一致的曲目行；
///   双击把本目录的音频排成专辑队列播放（`AppState.playAudioInDir`）。
///
/// 三种行的选择语义完全一致：单击/Ctrl/Shift/长按都走 [_handleImageTap] 与
/// `AppState.enterVisualSelectionMode`，`ValueKey('image-tile-$id')` 之类的 key 也
/// 保持不变（既有用例与首页接线都依赖这些 key）。
class ImageGrid extends StatefulWidget {
  final String library;

  const ImageGrid({super.key, this.library = kMediaLibrary});

  @override
  State<ImageGrid> createState() => _ImageGridState();
}

class _ImageGridState extends State<ImageGrid> {
  /// 作品层自己查出来的媒体行：null = 还没查，空列表 = 查过确实没有
  List<MediaItem>? _workItems;

  /// 已加载数据的归属签名（`<库>:<作品id>`）；作品或库一变就重新查
  String? _loadedKey;
  int _loadedRevision = -1;

  /// 已经在哪个上下文触发过后台缩略图补齐（`<库>:<文件夹id>:<作品id>`）
  String? _warmedThumbKey;

  void _openViewer(AppState appState, List<MediaItem> images, int index) {
    if (images.isEmpty) return;
    logInfo('Grid', 'Opening viewer at index $index (${images.length} images)');
    appState.openViewer(images, index);
  }

  /// 点开一张图：把当前可见列表过滤成图片子集再交给查看器。
  ///
  /// 多媒体栏的同一层列表里混着视频与音频，而漫画查看器只会按图片加载与预取；
  /// 整份列表塞进去，翻页会停在一条音频/视频上（画不出图，也把预取拖慢）。索引
  /// 因此按过滤后的位置重算，不能沿用原列表下标。
  void _openImageInViewer(
      AppState appState, List<MediaItem> images, MediaItem image) {
    final photos = images.where((m) => m.mediaType == MediaType.image).toList();
    final index = photos.indexWhere((m) => m.id == image.id);
    if (index < 0) return;
    _openViewer(appState, photos, index);
  }

  /// 网格与列表里点一条音频：把这条音频所在目录的音频排成专辑队列，从它开始播。
  ///
  /// 队列的组装（排序、换成 TrackItem）都在 AppState 里，与音频栏同源；这里只把
  /// 目录与起始行传过去，免得两处各写一套排序、结果还对不上。
  Future<void> _playAudioInDir(AppState appState, MediaItem audio) async {
    if (audio.id == null) return;
    await appState.playAudioInDir(
      p.dirname(audio.path),
      startMediaId: audio.id,
    );
  }

  /// 给一条音频行选它自己的封面（写 `media.cover_path`）。
  ///
  /// 用户点「取消」时什么都不做：清空另有「清除缩略图」，取消若是顺手把已设好的
  /// 封面删掉，用户下次再想设还得重新挑一遍。
  Future<void> _setAudioCover(AppState appState, MediaItem audio) async {
    final id = audio.id;
    if (id == null) return;
    final path = await pickImagePath(title: '选择缩略图');
    if (path == null || path.isEmpty) return;
    await appState.setMediaCover(id, path);
  }

  Future<void> _clearAudioCover(AppState appState, MediaItem audio) async {
    final id = audio.id;
    if (id == null) return;
    await appState.setMediaCover(id, null);
  }

  /// 视频：把播放交给已有的外链通道（在文件夹里播这个文件夹，否则播整个作品）
  Future<void> _playExternal(AppState appState) async {
    final folderId = appState.currentFolderId;
    final workId = appState.currentWork?.id;
    if (folderId == null && workId == null) return;
    final result = folderId != null
        ? await appState.playFolderExternal(folderId)
        : await appState.playWorkExternal(workId!);
    if (mounted) showLaunchResult(context, result);
  }

  /// 视频/音频卡片的「标签...」：勾选状态为当前已绑定标签，确认后整集覆盖。
  ///
  /// 与图片的 [_editMediaTags] 不同：这两种行在网格里没有缩略图可点，菜单是唯一
  /// 入口，所以直接把已绑定的标签勾上，让用户一眼看到现状再增删。
  Future<void> _editItemTags(AppState appState, MediaItem item) async {
    final id = item.id;
    if (id == null) return;
    final existing = (await appState.getTagsForMedia(id))
        .map((t) => t.id)
        .whereType<int>()
        .toSet();
    if (!mounted) return;
    final tags = await showTagPickerDialog(
      context,
      title: item.mediaType == MediaType.audio ? '为曲目选择标签' : '为视频选择标签',
      selectedTagIds: existing,
    );
    if (tags == null) return;
    await appState.setMediaTags(id, tags);
  }

  /// 单条媒体的标签增删（图片/视频/音频磁贴 ⋮ 菜单）。
  ///
  /// [add] 为 false 时先取这条媒体已有的标签收窄候选，免得让用户从全库标签里
  /// 挑一个根本不在这张图上的来「移除」。
  Future<void> _editMediaTags(
    AppState appState,
    MediaItem item, {
    required bool add,
  }) async {
    final id = item.id;
    if (id == null || !mounted) return;
    final what = switch (item.mediaType) {
      MediaType.audio => '这首曲目',
      MediaType.video => '这个视频',
      _ => '这张图',
    };
    Set<int>? current;
    if (!add) {
      current = await appState.getTagIdsOnMedia([id]);
      if (!mounted) return;
      if (current.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$what还没有标签')));
        return;
      }
    }
    final tags = await showTagPickerDialog(
      context,
      title: add ? '添加标签' : '移除标签',
      filterTagIds: current,
    );
    if (tags == null || tags.isEmpty || !mounted) return;
    if (add) {
      await appState.addTagsToMedia([id], tags);
    } else {
      await appState.removeTagsFromMedia([id], tags);
    }
  }

  /// 作品层的媒体行自己查：`FolderDao.getPathsByWork` 拿作品的目录，
  /// 再取这些目录里的直接媒体（与 `playWorkExternal` 同一套取法）。
  ///
  /// 多媒体栏的作品层同样要三种媒体都给出来，所以 `type` 传 null（不带
  /// media_type 条件），由 [_buildItem] 按行类型分派，与文件夹层保持一致。
  ///
  /// [sort] 是 AppState 当前视觉库的排序比较器：默认的自然序让 `第2话` 排在
  /// `第10话` 前面（按文件名字符串比会把 10 排到 2 前面）。
  Future<void> _loadWorkItems(
      int workId, int Function(MediaItem, MediaItem) sort) async {
    final key = '${widget.library}:$workId';
    try {
      final dirs =
          await FolderDao(DatabaseManager.instance.db).getPathsByWork(workId);
      final rows = dirs.isEmpty
          ? <MediaItem>[]
          : await MediaDao(DatabaseManager.instance.db)
              .queryByDirs(dirs, type: null);
      final items = [...rows]..sort(sort);
      if (!mounted || _loadedKey != key) return;
      setState(() => _workItems = items);
    } catch (e) {
      logDebug('Grid', 'load work items failed (work=$workId): $e');
      if (!mounted || _loadedKey != key) return;
      setState(() => _workItems = const []);
    }
  }

  /// 根据修饰键决定选择行为：Shift=区间、Ctrl=切换、否则单选
  ///
  /// 多选模式下没有修饰键的单击也当作勾选，长按磁贴会先进多选模式。
  void _handleImageTap(AppState appState, int id) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    final ctrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    if (shift) {
      appState.rangeSelect(id);
    } else if (ctrl) {
      appState.toggleSelect(id);
    } else if (appState.visualSelectionMode) {
      appState.toggleSelect(id);
    } else {
      appState.selectImage(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final folders = appState.centerFolders;
    final work = appState.currentWork;
    final atFolderLevel = appState.currentFolderId != null;

    // 作品层：换作品或换库就丢掉缓存并排到下一帧重查（build 里不能 setState）。
    // 搜索生效时 AppState 已经把命中结果装进 images，这里不再自己查。
    final searching = appState.searchQuery.trim().isNotEmpty;
    final key = work == null || atFolderLevel || searching
        ? null
        : '${widget.library}:${work.id}';
    final revision = appState.mediaRevision;
    if (key != _loadedKey || revision != _loadedRevision) {
      _loadedKey = key;
      _loadedRevision = revision;
      _workItems = null;
      if (key != null) {
        final workId = work!.id!;
        final sort = appState.visualSortComparator;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadWorkItems(workId, sort);
        });
      }
    }

    final images = atFolderLevel || searching
        ? appState.images
        : (_workItems ?? const <MediaItem>[]);
    // 作品层这里自己查媒体行，AppState 那一层只有文件夹：把当前真正画出来的
    // 媒体行登记回去，「全选」「Shift 区间选」和图片详情才有据可依。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) appState.reportVisibleMedia(images);
    });
    // 老库（1.3.0 之前导入的图片）磁盘上没有缩略图：进到某个上下文时补一次，
    // 免得用户以为「必须重启才有图」。按上下文只触发一次，生成走 AppState 的
    // 后台队列，卡片自己也会按需生成，两边都命中磁盘则直接返回。
    // 只把图片行交出去：backfillThumbnails 解的就是图片缩略图，视频封面走
    // videoCoverFor 的三级取图、音频封面走 media.cover_path，都不吃这套缓存。
    final warmKey = '${widget.library}:${appState.currentFolderId}:${work?.id}';
    final photoPaths = images
        .where((i) => i.mediaType == MediaType.image)
        .map((i) => i.path)
        .toList();
    if (photoPaths.isNotEmpty && _warmedThumbKey != warmKey) {
      _warmedThumbKey = warmKey;
      unawaited(appState.backfillThumbnails(photoPaths));
    }

    final loading = appState.loading || (key != null && _workItems == null);
    if (!loading && folders.isEmpty && images.isEmpty) {
      return _buildEmptyState(context);
    }
    if (loading && folders.isEmpty && images.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
      );
    }

    if (appState.viewMode == 'list') {
      return _buildList(appState, folders, images);
    }
    return _buildGrid(appState, folders, images);
  }

  // ── 网格 ──
  Widget _buildGrid(AppState appState, List<VirtualFolder> folders,
      List<MediaItem> images) {
    final total = folders.length + images.length;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: appState.gridColumns,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: total,
      itemBuilder: (ctx, i) {
        if (i < folders.length) {
          return _FolderTile(
            key: ValueKey('folder-tile-${folders[i].id}'),
            folder: folders[i],
            compact: true,
          );
        }
        return _buildItem(appState, images, i - folders.length, compact: true);
      },
    );
  }

  // ── 列表 ──
  Widget _buildList(AppState appState, List<VirtualFolder> folders,
      List<MediaItem> images) {
    // 音频行显示的序号只数音频：列表里还夹着图片/视频行，直接用列表下标会数出
    // 「第 7 首」这种跟专辑对不上的号。
    final trackOrdinals = <int, int>{};
    var seenAudio = 0;
    for (final media in images) {
      if (media.mediaType != MediaType.audio) continue;
      final id = media.id;
      if (id != null) trackOrdinals[id] = ++seenAudio;
    }

    final total = folders.length + images.length;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: total,
      itemBuilder: (ctx, i) {
        if (i < folders.length) {
          return _FolderTile(
            key: ValueKey('folder-tile-${folders[i].id}'),
            folder: folders[i],
            compact: false,
          );
        }
        final index = i - folders.length;
        return _buildItem(
          appState,
          images,
          index,
          compact: false,
          trackOrdinal: trackOrdinals[images[index].id],
        );
      },
    );
  }

  /// 一条媒体行按自己的类型分派成磁贴/行。网格与列表共用这一处。
  ///
  /// 分派只写一份：早先网格与列表各有一个 `_isVideo` 分支，加第三种媒体就得改
  /// 两处、漏一处就是「网格能看、列表崩」这种只在某个视图下出现的毛病。
  Widget _buildItem(
    AppState appState,
    List<MediaItem> images,
    int index, {
    required bool compact,
    int? trackOrdinal,
  }) {
    final img = images[index];
    final id = img.id ?? -1;
    final selected = appState.isSelected(id);
    void onTap() => _handleImageTap(appState, id);
    void onLongPress() => appState.enterVisualSelectionMode(img.id);

    switch (img.mediaType) {
      case MediaType.video:
        return _VideoTile(
          key: ValueKey('video-tile-${img.id}'),
          video: img,
          selected: selected,
          compact: compact,
          onTap: onTap,
          onDoubleTap: () => _playExternal(appState),
          onLongPress: onLongPress,
          onPlayExternal: () => _playExternal(appState),
          onEditTags: () => _editItemTags(appState, img),
          onRemoveTags: () => _editMediaTags(appState, img, add: false),
        );
      case MediaType.audio:
        return _AudioTile(
          key: ValueKey('audio-tile-${img.id}'),
          audio: img,
          selected: selected,
          compact: compact,
          trackOrdinal: trackOrdinal,
          onTap: onTap,
          onDoubleTap: () => _playAudioInDir(appState, img),
          onLongPress: onLongPress,
          onEditTags: () => _editItemTags(appState, img),
          onRemoveTags: () => _editMediaTags(appState, img, add: false),
          onSetCover: () => _setAudioCover(appState, img),
          onClearCover: () => _clearAudioCover(appState, img),
        );
      case MediaType.image:
      case MediaType.subtitle:
        // 字幕行也走图片卡片兜底：查询用 `type: null`，同目录的 .srt 会被一起带
        // 出来，落到没有分支的 switch 上会直接崩。它自己画不出缩略图，双击也进
        // 不了查看器（_openImageInViewer 只收图片行，找不到就什么都不做）。
        return _ThumbnailCard(
          key: ValueKey('image-tile-${img.id}'),
          image: img,
          selected: selected,
          onTap: onTap,
          onDoubleTap: () => _openImageInViewer(appState, images, img),
          onLongPress: onLongPress,
          compact: compact,
          cacheEpoch: appState.thumbEpoch,
          onEditTags: () => _editMediaTags(appState, img, add: true),
          onRemoveTags: () => _editMediaTags(appState, img, add: false),
        );
    }
  }

  Widget _buildEmptyState(BuildContext context) {
    final appState = context.read<AppState>();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
           Icon(Icons.folder_open, size: 64, color: AppColors.mutedOf(context)),
          const SizedBox(height: 16),
          Text('这里还没有内容',
              style:  TextStyle(color: AppColors.textSecondaryOf(context), fontSize: 15, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          // 多媒体栏一个文件夹里三种媒体都可能出现，文案不再分「图片/视频」两套
          Text('点下面的按钮添加文件夹（图片、视频或音频）',
              style:  TextStyle(color: AppColors.mutedOf(context), fontSize: 12)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('grid-empty-add-folder'),
            onPressed: () => _pickFolder(context, appState),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('添加文件夹'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side:  BorderSide(color: AppColors.surfaceAltOf(context)),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('grid-empty-batch-import'),
            onPressed: () => _pickBatchFolder(context, appState),
            icon: const Icon(Icons.library_add_outlined, size: 16),
            label: const Text(
              '批量导入：每个子文件夹一个作品',
              style: TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(foregroundColor: AppColors.teal),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFolder(BuildContext context, AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择包含图片、视频或音频的文件夹');
    if (result != null && result.isNotEmpty && context.mounted) {
      await appState.importDirectory(result, library: widget.library);
    }
  }

  /// 批量导入：选父目录，里面的每个子文件夹各建一个作品。
  Future<void> _pickBatchFolder(BuildContext context, AppState appState) async {
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择父文件夹（每个子文件夹一个作品）');
    if (result == null || result.isEmpty || !context.mounted) return;
    final created = await appState.importSubdirectoriesAsWorks(
      result,
      library: widget.library,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created > 0 ? '批量导入完成：新建 $created 个作品' : '没有发现可导入的子文件夹（或里面的媒体都已在库里）',
        ),
      ),
    );
  }
}

/// 文件夹瓦片（网格/列表）
class _FolderTile extends StatelessWidget {
  final VirtualFolder folder;
  final bool compact;

  const _FolderTile({super.key, required this.folder, required this.compact});

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    if (compact) {
      return GestureDetector(
        onTap: () => appState.enterFolder(folder.id!),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceOf(context),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 格子小（列数多或中间区窄）时图标跟着缩，避免溢出
                const Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Icon(Icons.folder, size: 44, color: AppColors.warning),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(fontSize: 11, color: AppColors.textPrimaryOf(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ListTile(
      dense: true,
      leading: const Icon(Icons.folder, size: 22, color: AppColors.warning),
      title: Text(folder.name,
          style:  TextStyle(fontSize: 13, color: AppColors.textPrimaryOf(context))),
      onTap: () => appState.enterFolder(folder.id!),
    );
  }
}

/// 图片卡片（网格/列表），懒加载缩略图，支持多选高亮
class _ThumbnailCard extends StatefulWidget {
  final MediaItem image;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;
  final bool compact;

  /// 缩略图缓存被清空时会自增；卡片靠它重新生成缩略图
  final int cacheEpoch;

  /// 右上角 ⋮ 菜单：添加/移除这条媒体的标签
  final VoidCallback onEditTags;
  final VoidCallback onRemoveTags;

  const _ThumbnailCard({
    super.key,
    required this.image,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    this.onLongPress,
    required this.compact,
    required this.cacheEpoch,
    required this.onEditTags,
    required this.onRemoveTags,
  });

  @override
  State<_ThumbnailCard> createState() => _ThumbnailCardState();
}

class _ThumbnailCardState extends State<_ThumbnailCard> {
  bool _thumbReady = false;

  /// 缩略图文件是否还没生成。由 [_checkAndGenerate] 异步确认，
  /// build 里不再做任何文件系统调用。
  bool _thumbMissing = true;

  /// 生成串行器：同一时刻只解码一张，跑的过程中换了图就在收尾时补跑一次。
  /// 早先用一个布尔量直接 return，换图时新请求被丢掉，磁贴会一直空着。
  final LatestOnlyRunner _runner = LatestOnlyRunner();

  /// 计算好的缩略图文件（路径要 stat 源文件拿 mtime，
  /// 所以只在异步路径上算，build 里不碰文件系统）
  File? _thumbFile;

  @override
  void initState() {
    super.initState();
    _checkAndGenerate();
  }

  @override
  void didUpdateWidget(_ThumbnailCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.path != widget.image.path ||
        oldWidget.cacheEpoch != widget.cacheEpoch) {
      _thumbReady = false;
      _thumbMissing = true;
      _checkAndGenerate();
    }
  }

  Future<void> _checkAndGenerate() => _runner.run(_generateOnce);

  Future<void> _generateOnce() async {
    final path = widget.image.path;
    // thumbPath 内部要 stat 源文件拿 mtime，所以只在异步路径上算。
    // 放在 try 里：缓存目录没准备好时也要落成「没有缩略图」，
    // 不能让异常从 initState 发起的 Future 里逃出去。
    File? thumbFile;
    try {
      thumbFile = File(ThumbnailService.instance.thumbPath(path, size: 300));
      if (!await thumbFile.exists()) {
        await ThumbnailService.instance.ensureThumbnail(path, size: 300);
      }
      // 等的这段时间里卡片可能已经被复用给另一张图（`didUpdateWidget` 已经把
      // 状态退回「没缩略图」并登记了重跑），旧图的结果不能盖上去。
      if (!mounted || widget.image.path != path) return;
      setState(() {
        _thumbFile = thumbFile;
        _thumbMissing = false;
        _thumbReady = true;
      });
    } catch (e) {
      logDebug('Grid', 'Thumbnail generate failed: $path ($e)');
      if (!mounted || widget.image.path != path) return;
      setState(() {
        _thumbFile = thumbFile;
        _thumbReady = false;
      });
    }
  }

  String get _displayName => widget.image.alias ?? widget.image.filename;

  @override
  Widget build(BuildContext context) {
    // build 里不做 IO：路径、存在性都由 _checkAndGenerate 异步落进 State
    final thumbFile = _thumbFile;
    final canShowThumb = thumbFile != null && _thumbReady && !_thumbMissing;

    if (!widget.compact) {
      // 列表行
      return InkWell(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: Container(
          color: widget.selected ? AppColors.surfaceOf(context) : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: canShowThumb
                    ? Image.file(thumbFile, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _placeholder())
                    : _placeholder(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:  TextStyle(fontSize: 13, color: AppColors.textPrimaryOf(context))),
                    if (widget.image.alias != null)
                      Text(widget.image.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:  TextStyle(fontSize: 10, color: AppColors.mutedOf(context))),
                  ],
                ),
              ),
              _tagsMenu(onDark: false),
            ],
          ),
        ),
      );
    }

    // 网格卡片
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: widget.selected ? AppColors.accent : Colors.transparent,
            width: widget.selected ? 2 : 0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (canShowThumb)
              Image.file(thumbFile, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _placeholder())
            else
              _placeholder(),
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(4),
                child: _tagsMenu(onDark: true),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.black54,
                child: Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return  Center(
      child: Icon(Icons.image_outlined, color: AppColors.mutedOf(context), size: 32),
    );
  }

  /// 图片磁贴的 ⋮ 菜单：以前图片只有双击看图，标签只能在多选栏里整批改，
  /// 单张图想补一个标签没有入口。
  Widget _tagsMenu({required bool onDark}) {
    return PopupMenuButton<String>(
      key: ValueKey('image-menu-${widget.image.id}'),
      icon: Icon(
        Icons.more_vert,
        size: 14,
        color: onDark ? Colors.white : AppColors.mutedOf(context),
      ),
      tooltip: '图片操作',
      padding: EdgeInsets.zero,
      // 小磁贴（手机上是 80~90 像素见方）容不下 M3 默认的 48 见方触摸区，
      // 否则 ⋮ 会盖住大半个磁贴、把单击和长按都吃掉。
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(26),
        maximumSize: const Size.square(26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onSelected: (v) =>
          v == 'tags' ? widget.onEditTags() : widget.onRemoveTags(),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'tags',
          child: Text('标签...', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: 'untag',
          child: Text('移除标签...', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

/// 视频卡片（网格/列表）：网格画封面，列表画图标与文件名，都不做应用内解码。
/// 封面走 `AppState.videoCoverFor` 的三级取图（系统缩略图 → 容器内嵌 → 首帧），
/// 取不到就退回首帧之外的图标；双击或菜单调用 [onPlayExternal]（外链播放通道）。
class _VideoTile extends StatefulWidget {
  final MediaItem video;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;
  final VoidCallback onPlayExternal;
  final VoidCallback onEditTags;
  final VoidCallback onRemoveTags;

  const _VideoTile({
    super.key,
    required this.video,
    required this.selected,
    required this.compact,
    required this.onTap,
    required this.onDoubleTap,
    this.onLongPress,
    required this.onPlayExternal,
    required this.onEditTags,
    required this.onRemoveTags,
  });

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  /// 取到的封面路径；null = 还没取到或确实没有，两种情况都画图标
  String? _cover;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(_VideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.path != widget.video.path) {
      // 网格会复用 State 换视频：先清掉上一条的封面，免得新视频先闪一帧旧图
      _cover = null;
      _loadCover();
    }
  }

  /// 视频封面要解容器、必要时还等 ffmpeg 抽首帧，是真实 I/O，所以异步取。
  /// 失败不能从 initState 发起的 Future 里逃出去，取不到就退回图标。
  Future<void> _loadCover() async {
    final path = widget.video.path;
    try {
      final cover = await context.read<AppState>().videoCoverFor(widget.video);
      if (!mounted || widget.video.path != path) return;
      setState(() => _cover = cover);
    } catch (e) {
      logDebug('Grid', 'Video cover failed: $path ($e)');
      if (!mounted || widget.video.path != path) return;
      setState(() => _cover = null);
    }
  }

  String get _displayName => widget.video.alias ?? widget.video.filename;

  Widget _movieIcon() => const Center(
        child: Icon(Icons.movie, color: AppColors.blue, size: 40),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) {
      return InkWell(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: Container(
          color: widget.selected ? AppColors.surfaceOf(context) : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.movie, size: 22, color: AppColors.blue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                        fontSize: 13, color: AppColors.textPrimaryOf(context))),
              ),
              IconButton(
                key: ValueKey('video-tags-${widget.video.id}'),
                icon: const Icon(Icons.label_outline, size: 18),
                tooltip: '标签...',
                onPressed: widget.onEditTags,
              ),
              IconButton(
                icon: const Icon(Icons.play_circle_outline, size: 18),
                tooltip: '用外部播放器播放',
                onPressed: widget.onPlayExternal,
              ),
            ],
          ),
        ),
      );
    }

    final cover = _cover;
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: widget.selected ? AppColors.accent : Colors.transparent,
            width: widget.selected ? 2 : 0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null)
              Image.file(File(cover), fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _movieIcon())
            else
              _movieIcon(),
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(4),
                child: PopupMenuButton<String>(
                  key: ValueKey('video-menu-${widget.video.id}'),
                  icon: const Icon(Icons.more_vert, size: 14, color: Colors.white),
                  tooltip: '视频操作',
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    switch (v) {
                      case 'tags':
                        widget.onEditTags();
                      case 'untag':
                        widget.onRemoveTags();
                      default:
                        widget.onPlayExternal();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'playExternal',
                      child: Text('用外部播放器播放',
                          style: TextStyle(fontSize: 13)),
                    ),
                    PopupMenuItem(
                      key: ValueKey('video-tags-menu-${widget.video.id}'),
                      value: 'tags',
                      child: const Text('标签...',
                          style: TextStyle(fontSize: 13)),
                    ),
                    PopupMenuItem(
                      key: ValueKey('video-untag-menu-${widget.video.id}'),
                      value: 'untag',
                      child: const Text(
                        '移除标签...',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.black54,
                child: Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 音频磁贴/音频行（多媒体栏里的第三种媒体）。
///
/// 网格态与音频栏的专辑页保持一致：封面 + 标题 + 时长，正在播的那一首加高亮与
/// [Icons.graphic_eq]；列表态直接照音频栏的曲目行画（序号/播放指示 + 标题 +
/// 艺人·专辑 + 时长），从多媒体栏点进来的列表才不会像另一个 App。
///
/// 封面走 `AppState.coverForMedia`（行自己的 `cover_path` → 当前作品封面 → 图标），
/// 与音频栏同源；这里不自己读文件、也不自己排回退顺序，免得两处结果不一致。
/// 封面路径是同步取的（和 CoverImage 一样是几次 existsSync），所以磁贴不必等
/// 异步取图；「设置缩略图」写库时一并换掉内存里那一行，磁贴立刻跟着变。
class _AudioTile extends StatelessWidget {
  final MediaItem audio;
  final bool selected;
  final bool compact;

  /// 列表态显示的曲目序号（1 起，只数音频行）；网格态不用
  final int? trackOrdinal;

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;
  final VoidCallback onEditTags;
  final VoidCallback onRemoveTags;
  final VoidCallback onSetCover;
  final VoidCallback onClearCover;

  const _AudioTile({
    super.key,
    required this.audio,
    required this.selected,
    required this.compact,
    this.trackOrdinal,
    required this.onTap,
    required this.onDoubleTap,
    this.onLongPress,
    required this.onEditTags,
    required this.onRemoveTags,
    required this.onSetCover,
    required this.onClearCover,
  });

  String get _title => audio.title ?? audio.filename;

  /// 「艺人 · 专辑 · 格式」：与音频栏曲目行的副标题同一套拼法
  String get _subtitle =>
      [audio.artist, audio.album, audio.format?.toUpperCase()]
          .where((s) => s != null && s.isNotEmpty)
          .join(' · ');

  @override
  Widget build(BuildContext context) {
    // 只订阅两个布尔量：整份 PlayerController 每 250ms notifyListeners 一次，
    // watch 整个对象会让每个音频磁贴都跟着刷一遍。
    final (isCurrent, isPlaying) = context
        .select<PlayerController, (bool, bool)>(
            (p) => (p.currentTrack?.path == audio.path, p.playing));
    final cover = context.select<AppState, String?>(
      (s) => s.coverForMedia(audio),
    );

    if (!compact) {
      return _listRow(context, isCurrent: isCurrent, isPlaying: isPlaying);
    }
    return _gridTile(context,
        isCurrent: isCurrent,
        isPlaying: isPlaying,
        cover: cover);
  }

  Widget _gridTile(
    BuildContext context, {
    required bool isCurrent,
    required bool isPlaying,
    required String? cover,
  }) {
    final durationMs = audio.durationMs;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color:
                selected || isCurrent ? AppColors.accent : Colors.transparent,
            // 多选的边框比「正在播」粗：勾选状态一眼要能数清，播放是背景信息
            width: selected ? 2 : (isCurrent ? 1 : 0),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
              path: cover,
              width: double.infinity,
              height: double.infinity,
              borderRadius: 0,
            ),
            if (isCurrent)
              Positioned(
                top: 0,
                left: 0,
                child: Material(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      isPlaying ? Icons.graphic_eq : Icons.play_arrow,
                      size: 14,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(4),
                child: _menu(context, onDark: true),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.black54,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                      ),
                    ),
                    // 时长拿不到就不占位：显示「--:--」比不显示更让人以为文件坏了
                    if (durationMs != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        formatDuration(Duration(milliseconds: durationMs)),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 9),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listRow(
    BuildContext context, {
    required bool isCurrent,
    required bool isPlaying,
  }) {
    final durationMs = audio.durationMs;
    final subtitle = _subtitle;
    return InkWell(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? AppColors.surfaceOf(context) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              // 三种状态与音频栏一致：勾选 > 正在播（在播/暂停图标）> 序号
              child: selected
                  ? const Icon(Icons.check_box,
                      size: 18, color: AppColors.accent)
                  : isCurrent
                      ? Icon(isPlaying ? Icons.graphic_eq : Icons.play_arrow,
                          size: 18, color: AppColors.accent)
                      : Text(
                          '${trackOrdinal ?? 0}',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.mutedOf(context)),
                        ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: isCurrent
                          ? AppColors.accent
                          : AppColors.textPrimaryOf(context),
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.mutedOf(context)),
                    ),
                ],
              ),
            ),
            if (durationMs != null)
              Text(
                formatDuration(Duration(milliseconds: durationMs)),
                style:
                    TextStyle(fontSize: 11, color: AppColors.mutedOf(context)),
              ),
            _menu(context, onDark: false),
          ],
        ),
      ),
    );
  }

  /// ⋮ 菜单：标签增删 + 这条音频自己的缩略图。
  ///
  /// 「设置缩略图」写的是 `media.cover_path`（音频行自己的封面），音频栏没有这个
  /// 入口，所以放在多媒体栏的磁贴上；「清除缩略图」显式传 null，跟「设置」时
  /// 用户按取消区分开。
  Widget _menu(BuildContext context, {required bool onDark}) {
    final id = audio.id;
    return PopupMenuButton<String>(
      key: ValueKey('audio-menu-$id'),
      icon: Icon(
        Icons.more_vert,
        size: 14,
        color: onDark ? Colors.white : AppColors.mutedOf(context),
      ),
      tooltip: '音频操作',
      padding: EdgeInsets.zero,
      // 与图片磁贴一样收窄触摸区：小格子里 M3 默认的 48 见方会盖住单击/长按
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(26),
        maximumSize: const Size.square(26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onSelected: (v) {
        switch (v) {
          case 'setCover':
            onSetCover();
          case 'clearCover':
            onClearCover();
          case 'tags':
            onEditTags();
          default:
            onRemoveTags();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          key: ValueKey('audio-tile-set-cover-$id'),
          value: 'setCover',
          child: const Text('设置缩略图...', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          key: ValueKey('audio-tile-clear-cover-$id'),
          value: 'clearCover',
          child: const Text('清除缩略图', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          key: ValueKey('audio-tags-menu-$id'),
          value: 'tags',
          child: const Text('标签...', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          key: ValueKey('audio-untag-menu-$id'),
          value: 'untag',
          child: const Text('移除标签...', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}
