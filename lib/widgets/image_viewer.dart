import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/database.dart';
import '../db/media_dao.dart';
import '../services/exif_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/image_cache_util.dart';
import '../utils/log_util.dart';

/// =============================================================
/// 阅读方向（BUILD_GUIDE 第 22.2 节）。
///
/// 值同时是 `folders.reading_direction` 的存储值。
/// =============================================================
enum ReadingDirection {
  /// 日漫：右到左。左方向键前进。
  rtl('rtl', '右到左'),

  /// 左到右。右方向键前进。
  ltr('ltr', '左到右');

  const ReadingDirection(this.value, this.label);

  final String value;
  final String label;

  static ReadingDirection fromValue(String? value) => values.firstWhere(
    (d) => d.value == value,
    orElse: () => ReadingDirection.rtl,
  );

  /// 「前进」对应的方向键。后退用另一侧。
  LogicalKeyboardKey get forwardKey => this == ReadingDirection.rtl
      ? LogicalKeyboardKey.arrowLeft
      : LogicalKeyboardKey.arrowRight;
}

/// =============================================================
/// 阅读适配模式（BUILD_GUIDE 第 22.3 节）。
///
/// 值同时是 `folders.reading_fit` 的存储值。
/// =============================================================
enum ReadingFit {
  /// 整页可见。
  page('page', '整页', BoxFit.contain),

  /// 铺满高度，横向可拖。
  height('height', '适高', BoxFit.fitHeight),

  /// 铺满宽度，纵向可拖。
  width('width', '适宽', BoxFit.fitWidth);

  const ReadingFit(this.value, this.label, this.boxFit);

  final String value;
  final String label;
  final BoxFit boxFit;

  static ReadingFit fromValue(String? value) =>
      values.firstWhere((f) => f.value == value, orElse: () => ReadingFit.page);

  /// S 键循环：整页 → 适高 → 适宽 → 整页。
  ReadingFit get next => values[(index + 1) % values.length];
}

/// =============================================================
/// Full-screen image viewer with zoom, pan, keyboard shortcuts,
/// animated page transitions, preloading, and EXIF metadata.
///
/// 阶段 4 在 PictureViewer2 的 754 行查看器上补入阅读模式：
/// 阅读方向、适应模式、无干扰全屏（BUILD_GUIDE 第 22 节）。
///
/// 阅读方向与适应模式在卷上持久化（`folders.reading_direction` /
/// `folders.reading_fit`）。测试与将来的调用方可以用
/// [initialDirection] / [initialFit] 注入初值，并用
/// [onDirectionChanged] / [onFitChanged] 接管写回；不注入时组件自己
/// 按 `AppState.currentFolderId` 读写这两列。
/// =============================================================
class ImageViewer extends StatefulWidget {
  final AppState state;

  /// 注入的阅读方向。为空时从当前卷读取，读不到用 `rtl`。
  final ReadingDirection? initialDirection;

  /// 注入的适应模式。为空时从当前卷读取，读不到用 `page`。
  final ReadingFit? initialFit;

  /// 阅读方向变化时回调。为空时组件自己写回当前卷。
  final ValueChanged<ReadingDirection>? onDirectionChanged;

  /// 适应模式变化时回调。为空时组件自己写回当前卷。
  final ValueChanged<ReadingFit>? onFitChanged;

  const ImageViewer({
    super.key,
    required this.state,
    this.initialDirection,
    this.initialFit,
    this.onDirectionChanged,
    this.onFitChanged,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final TransformationController _transformCtrl = TransformationController();
  final FocusNode _focusNode = FocusNode();

  /// 鼠标与键盘静止多久后自动隐藏控件（BUILD_GUIDE 22.4）。
  static const Duration _idleHideAfter = Duration(seconds: 3);

  bool _showUI = true;
  bool _showExif = false;
  double _zoomLevel = 1.0;
  bool _isFitToWindow = true;

  /// 本次手势累计的横向位移。判断「慢慢拖够了距离也算翻页」用，
  /// 只看松手瞬间的速度会让慢速拖动什么都不发生。
  double _dragDx = 0;

  bool _isImageLoading = true;
  int _prevViewerIndex = -1;
  int _displayedImageId = -1;

  /// 阅读方向（BUILD_GUIDE 22.2）。
  ReadingDirection _direction = ReadingDirection.rtl;

  /// 适应模式（BUILD_GUIDE 22.3）。
  ReadingFit _fit = ReadingFit.page;

  /// 无干扰全屏的静止计时器（BUILD_GUIDE 22.4）。
  Timer? _idleTimer;

  /// 当前图片文件是否不存在。由异步检查更新，build 里不做同步 stat。
  bool _fileMissing = false;

  final Map<int, ExifData?> _exifCache = {};
  ExifData? _currentExif;

  AppState get _st => widget.state;

  @override
  void initState() {
    super.initState();
    _direction = widget.initialDirection ?? ReadingDirection.rtl;
    _fit = widget.initialFit ?? ReadingFit.page;
    if (widget.initialDirection == null || widget.initialFit == null) {
      unawaited(_loadReadingSettingsFromVolume());
    }
    logInfo(
      'Viewer',
      'ImageViewer opened (dir=${_direction.value}, fit=${_fit.value})',
    );
    _prevViewerIndex = _st.viewerIndex;
    _onPageChanged();
    _bumpIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _focusNode.dispose();
    _transformCtrl.dispose();
    logInfo('Viewer', 'ImageViewer closed');
    super.dispose();
  }

  // ============================================================
  // 阅读模式设置：读写当前卷（BUILD_GUIDE 22.2 / 22.3）
  // ============================================================

  /// 从当前卷读回阅读方向与适应模式。
  ///
  /// 阶段 6 会把这段直连 SQL 换成 FolderDao / AppState 的卷级访问器；
  /// 现在 lib/db/** 与 app_state.dart 不归本文件改，所以先在这里读。
  Future<void> _loadReadingSettingsFromVolume() async {
    final folderId = _st.currentFolderId;
    if (folderId == null || !DatabaseManager.instance.isOpen) return;
    try {
      final rows = await DatabaseManager.instance.db.query(
        'folders',
        columns: ['reading_direction', 'reading_fit'],
        where: 'id = ?',
        whereArgs: [folderId],
        limit: 1,
      );
      if (!mounted || rows.isEmpty) return;
      final row = rows.first;
      setState(() {
        _direction = ReadingDirection.fromValue(
          row['reading_direction'] as String?,
        );
        _fit = ReadingFit.fromValue(row['reading_fit'] as String?);
      });
      logDebug(
        'Viewer',
        'Reading settings loaded for folder $folderId: ${_direction.value}/${_fit.value}',
      );
    } catch (e) {
      logWarn(
        'Viewer',
        'Failed to load reading settings for folder $folderId',
        e.toString(),
      );
    }
  }

  /// 把阅读设置写回当前卷。
  ///
  /// 有注入回调时优先交给回调，避免组件与数据层双重写。
  Future<void> _persistReadingSetting(String column, String value) async {
    final folderId = _st.currentFolderId;
    if (folderId == null || !DatabaseManager.instance.isOpen) return;
    try {
      await DatabaseManager.instance.db.update(
        'folders',
        {column: value},
        where: 'id = ?',
        whereArgs: [folderId],
      );
      logDebug(
        'Viewer',
        'Reading setting saved: folders.$column=$value (folder=$folderId)',
      );
    } catch (e) {
      logWarn(
        'Viewer',
        'Failed to save $column for folder $folderId',
        e.toString(),
      );
    }
  }

  /// 切换阅读方向。切换后立即写回该卷。
  void _setDirection(ReadingDirection direction) {
    if (direction == _direction) return;
    setState(() => _direction = direction);
    logInfo('Viewer', 'Reading direction: ${direction.value}');
    final cb = widget.onDirectionChanged;
    if (cb != null) {
      cb(direction);
    } else {
      unawaited(_persistReadingSetting('reading_direction', direction.value));
    }
    _bumpIdle();
  }

  void _toggleDirection() {
    _setDirection(
      _direction == ReadingDirection.rtl
          ? ReadingDirection.ltr
          : ReadingDirection.rtl,
    );
  }

  /// 切换适应模式。切换后立即写回该卷。
  void _setFit(ReadingFit fit) {
    if (fit == _fit) return;
    setState(() {
      _fit = fit;
      // 换基准后必须回到 1:1，否则旧的平移/缩放会叠在新画面上。
      _transformCtrl.value = Matrix4.identity();
      _zoomLevel = 1.0;
      _isFitToWindow = true;
    });
    logInfo('Viewer', 'Reading fit: ${fit.value}');
    final cb = widget.onFitChanged;
    if (cb != null) {
      cb(fit);
    } else {
      unawaited(_persistReadingSetting('reading_fit', fit.value));
    }
    _bumpIdle();
  }

  /// S 键：整页 → 适高 → 适宽 → 整页（BUILD_GUIDE 22.3）。
  void _cycleFit() => _setFit(_fit.next);

  // ============================================================
  // 无干扰全屏（BUILD_GUIDE 22.4）
  // ============================================================

  /// 重置静止计时。控件隐藏时不计时。
  void _bumpIdle() {
    _idleTimer?.cancel();
    if (!_showUI) return;
    _idleTimer = Timer(_idleHideAfter, () {
      if (!mounted) return;
      logDebug('Viewer', 'Controls auto-hidden after idle');
      setState(() => _showUI = false);
    });
  }

  void _setUiVisible(bool visible) {
    if (_showUI != visible) {
      setState(() => _showUI = visible);
      logDebug('Viewer', 'Controls ${visible ? 'shown' : 'hidden'}');
    }
    _bumpIdle();
  }

  void _toggleUi() => _setUiVisible(!_showUI);

  // ============================================================
  // Page change
  // ============================================================

  void _checkPageChanged() {
    final idx = _st.viewerIndex;
    if (idx == _prevViewerIndex) return;
    _prevViewerIndex = idx;
    logDebug(
      'Viewer',
      'Page changed: idx=$idx (${idx + 1}/${_st.viewerImages.length})',
    );
    _onPageChanged();
  }

  void _onPageChanged() {
    final img = _st.viewerImage;
    if (img == null) return;
    final id = img.id;
    if (id == null) return;

    _transformCtrl.value = Matrix4.identity();
    _zoomLevel = 1.0;
    _isFitToWindow = true;
    _isImageLoading = true;
    _fileMissing = false;
    _displayedImageId = id;

    // 文件内容被外部替换过就丢掉解码缓存。FileImage 的缓存键只有
    // path + scale，不驱逐的话原地显示的还是旧图。
    ImageCacheGuard.evictIfChanged(img.path);

    _checkFileExists(img.path);
    _loadExifForCurrent();
    _preloadAdjacent();
  }

  /// 文件存在性异步确认：同步 stat 放在 build 里会随每次重建做一次磁盘 IO。
  Future<void> _checkFileExists(String path) async {
    final checkedId = _displayedImageId;
    final exists = await File(path).exists();
    if (!mounted || checkedId != _displayedImageId) return;
    if (!exists && !_fileMissing) {
      setState(() => _fileMissing = true);
    } else if (exists && _fileMissing) {
      setState(() => _fileMissing = false);
    }
  }

  /// 适配窗口时按屏幕像素解码的宽度；1:1 或放大时返回 null（用原图）。
  ///
  /// 24MP 的图整幅解码约 96MB，而 ImageCache 默认上限只有 100MiB：
  /// 前后两张预载同时在缓存里就接近上限，滚动时会被迫反复丢弃重解码。
  ///
  /// 适高模式铺满的是屏幕高度，所以目标边取高度；其余取宽度。
  int? _fitCacheWidth(MediaItem item) {
    if (!_isFitToWindow) return null;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return null;
    final useHeight = _fit == ReadingFit.height;
    final target =
        ((useHeight ? media.size.height : media.size.width) *
                media.devicePixelRatio)
            .round();
    if (target <= 0) return null;
    final source = useHeight ? item.height : item.width;
    // 屏幕比原图长时放大解码没有意义
    if (source != null && source <= target) return null;
    return target;
  }

  /// 与 [Image] 实际使用的 provider 一致，预载才能命中同一份缓存。
  ImageProvider _providerFor(MediaItem item) {
    final file = File(item.path);
    final width = _fitCacheWidth(item);
    return width == null
        ? FileImage(file)
        : ResizeImage(FileImage(file), width: width);
  }

  // ============================================================
  // Zoom logic
  // ============================================================

  Matrix4 _getMatrix() => _transformCtrl.value;

  /// Get the current visual scale from the matrix.
  double _getCurrentScale() {
    final m = _getMatrix();
    return m.getMaxScaleOnAxis();
  }

  /// Apply a scale factor centered on a given viewport point (or center).
  /// `factor` > 1 = zoom in, < 1 = zoom out.  Clamped to [1, 20]。
  void _applyScale(double factor, {Offset? focal}) {
    final matrix = _getMatrix().clone();
    final current = matrix.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, 20.0);
    if ((target - current).abs() < 1e-6) return;

    // 缩回适应窗口就彻底归位：按焦点缩放会留下平移量，而零边界下
    // 适应窗口时拖不动，留着偏移就再也摆不正了。
    if (target <= 1.0 + 1e-6) {
      _transformCtrl.value = Matrix4.identity();
      setState(() {
        _zoomLevel = 1.0;
        _isFitToWindow = true;
      });
      return;
    }

    final size = context.size ?? const Size(1, 1);
    final focalPt = focal ?? Offset(size.width / 2, size.height / 2);

    // Convert focal point from viewport to scene coordinates
    final inv = Matrix4.inverted(matrix);
    final sceneFocal = MatrixUtils.transformPoint(inv, focalPt);

    matrix.translateByDouble(sceneFocal.dx, sceneFocal.dy, 0, 1);
    matrix.scaleByDouble(
      target / current,
      target / current,
      target / current,
      1,
    );
    matrix.translateByDouble(-sceneFocal.dx, -sceneFocal.dy, 0, 1);

    _transformCtrl.value = matrix;
    setState(() {
      _zoomLevel = target;
      _isFitToWindow = target <= 1.01;
    });
  }

  void _zoomIn() => _applyScale(1.4);
  void _zoomOut() => _applyScale(1.0 / 1.4);
  void _fitToWindow() {
    _transformCtrl.value = Matrix4.identity();
    setState(() {
      _zoomLevel = 1.0;
      _isFitToWindow = true;
    });
  }

  // ============================================================
  // Mouse wheel (Ctrl+Scroll to zoom)
  // ============================================================

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.controlLeft,
          ) ||
          HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.controlRight,
          )) {
        final dy = event.scrollDelta.dy;
        final factor = dy > 0 ? 1.0 / 1.15 : 1.15;
        _applyScale(factor, focal: event.localPosition);
      }
    }
  }

  // ============================================================
  // Navigation
  // ============================================================

  void _previous() {
    logDebug('Viewer', 'Navigate: prev');
    _st.navigateViewer(-1);
    _bumpIdle();
  }

  void _next() {
    logDebug('Viewer', 'Navigate: next');
    _st.navigateViewer(1);
    _bumpIdle();
  }

  /// 触控滑动翻页。画面跟随手指：左到右是向左推走当前页，
  /// 右到左是向右推走当前页（BUILD_GUIDE 22.2）。
  ///
  /// 两个判定：松手速度够快（跟手一甩），或者本次手势累计拖够了屏宽的
  /// 18%（慢慢拖到底也认）。只看速度的话慢拖会解不出任何结果。
  /// 放大状态下的横向拖动是平移，不翻页。
  void _onInteractionEnd(ScaleEndDetails details) {
    if (!_isFitToWindow) return;
    final vx = details.velocity.pixelsPerSecond.dx;
    final width = MediaQuery.sizeOf(context).width;
    final draggedEnough = width > 0 && _dragDx.abs() > width * 0.18;
    if (vx.abs() < 200 && !draggedEnough) return;
    final dx = draggedEnough && vx.abs() < 200 ? _dragDx : vx;
    final forward = _direction == ReadingDirection.ltr ? dx < 0 : dx > 0;
    if (forward) {
      _next();
    } else {
      _previous();
    }
  }

  // ============================================================
  // EXIF
  // ============================================================

  Future<void> _loadExifForCurrent() async {
    final img = _st.viewerImage;
    if (img == null) return;
    final id = img.id;
    if (id == null) return;

    if (_exifCache.containsKey(id)) {
      _currentExif = _exifCache[id];
      logDebug('Viewer', 'EXIF cache hit for id=$id');
      if (mounted) setState(() {});
      return;
    }

    try {
      final data = await ExifService.read(img.path);
      _exifCache[id] = data;
      _currentExif = data;
      logDebug('Viewer', 'EXIF loaded for id=$id: hasData=${data.hasData}');
    } catch (e) {
      _exifCache[id] = null;
      _currentExif = null;
      logWarn('Viewer', 'EXIF read failed: $e');
    }
    if (mounted) setState(() {});
  }

  // ============================================================
  // Preload adjacent images into Flutter image cache
  // ============================================================

  void _preloadAdjacent() {
    // 预载要读 MediaQuery 算解码宽度，而 initState / build 阶段不能读
    // InheritedWidget，推到下一帧做。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final imgs = _st.viewerImages;
      final idx = _st.viewerIndex;

      void preload(MediaItem item) {
        // precacheImage 自己会在完成/失败后移除监听，比手工
        // addListener 更可靠（手工那种永远不移除）。
        unawaited(
          precacheImage(_providerFor(item), context, onError: (_, _) {}),
        );
      }

      if (idx > 0) preload(imgs[idx - 1]);
      if (idx < imgs.length - 1) preload(imgs[idx + 1]);

      logDebug(
        'Viewer',
        'Preload: prev=${idx > 0} next=${idx < imgs.length - 1}',
      );
    });
  }

  // ============================================================
  // Keyboard（键位表见 BUILD_GUIDE 22.1）
  // ============================================================

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // 键盘有动作就认为「用户在操作」，重新计时自动隐藏。
    _bumpIdle();

    switch (event.logicalKey) {
      // 方向键语义随阅读方向翻转（BUILD_GUIDE 22.2）
      case LogicalKeyboardKey.arrowLeft:
        if (_direction == ReadingDirection.rtl) {
          _next();
        } else {
          _previous();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (_direction == ReadingDirection.ltr) {
          _next();
        } else {
          _previous();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _st.closeViewer();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.numpadAdd:
        _zoomIn();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.minus:
      case LogicalKeyboardKey.numpadSubtract:
        _zoomOut();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit0:
      case LogicalKeyboardKey.numpad0:
        _fitToWindow();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        _toggleUi();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        _cycleFit();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        setState(() => _showExif = !_showExif);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    _checkPageChanged();

    final img = _st.viewerImage;
    if (img == null) {
      logWarn('Viewer', 'Build called with null viewerImage');
      return const SizedBox.shrink();
    }

    final isFirst = _st.viewerIndex <= 0;
    final isLast = _st.viewerIndex >= _st.viewerImages.length - 1;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: MouseRegion(
          // 鼠标一动就重新计时，静止满 3 秒才隐藏（BUILD_GUIDE 22.4）
          onHover: (_) => _bumpIdle(),
          child: Scaffold(
            backgroundColor: AppColors.deep.withValues(alpha: 0.97),
            body: Stack(
              fit: StackFit.expand,
              children: [
                _buildImageArea(),
                if (_isImageLoading) _buildLoadingOverlay(),
                if (_showUI) _buildTopBar(img),
                if (_showUI) _buildBottomBar(isFirst, isLast),
                if (_showUI && _showExif) _buildExifPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Sub-widgets
  // ============================================================

  Widget _buildImageArea() {
    return GestureDetector(
      key: const ValueKey('viewer-image-area'),
      behavior: HitTestBehavior.opaque,
      onTap: _toggleUi,
      child: LayoutBuilder(
        builder: (context, viewport) => InteractiveViewer(
          transformationController: _transformCtrl,
          // 下限就是「适应窗口」：再往外缩只会得到一张比视口还小的图。
          minScale: 1.0,
          maxScale: 20.0,
          // 边界不能给无限：适应窗口时图与视口同大，无限边界会让任何一次
          // 滑动都把画面拖出视口并停在那里，触屏上等于看不到图。
          // 零边界下适应窗口时拖不动，放大后仍能在图内平移。
          boundaryMargin: EdgeInsets.zero,
          panEnabled: true,
          scaleEnabled: true,
          onInteractionStart: (_) => _dragDx = 0,
          onInteractionUpdate: (details) {
            // 双指缩放不算翻页位移。
            if (details.pointerCount <= 1) {
              _dragDx += details.focalPointDelta.dx;
            }
            setState(() {
              _zoomLevel = _getCurrentScale();
              _isFitToWindow = _zoomLevel <= 1.01;
            });
          },
          onInteractionEnd: _onInteractionEnd,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _displayedImageId == -1
                ? const SizedBox.shrink()
                : _buildImageWidget(
                    viewport: viewport,
                    key: ValueKey(_displayedImageId),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageWidget({required BoxConstraints viewport, Key? key}) {
    final img = _st.viewerImage;
    if (img == null) return const SizedBox.shrink();

    // 存在性由 _checkFileExists 异步确认，这里只读状态，不做同步 IO。
    if (_fileMissing) {
      return _buildErrorWidget('文件不存在: ${img.filename}');
    }

    final image = Image(
      image: _providerFor(img),
      key: key,
      fit: _fit.boxFit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isImageLoading) {
              setState(() => _isImageLoading = false);
            }
          });
        } else if (frame != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isImageLoading) {
              setState(() => _isImageLoading = false);
            }
          });
        }
        return child;
      },
      errorBuilder: (context, error, stack) => _buildErrorWidget(
        _isUnsupportedPreviewFormat(img) ? '该格式当前环境不可预览' : error.toString(),
      ),
    );

    return _frameForFit(image, img, viewport);
  }

  /// 适高 / 适宽要真的能拖动溢出部分（BUILD_GUIDE 22.3）。
  ///
  /// `Image` 只按盒子大小排布，超出盒子的部分会被自己的 clipRect 裁掉，
  /// 拖动外层盒子也露不出来。这里先把盒子撑到缩放后的真实尺寸，再用
  /// [OverflowBox] 让子节点不被父约束 clamp；裁剪与拖动都交给
  /// [InteractiveViewer]（`constrained: true` + `clipBehavior: hardEdge`）。
  Widget _frameForFit(Widget image, MediaItem item, BoxConstraints viewport) {
    if (_fit == ReadingFit.page) return image;

    final w = item.width;
    final h = item.height;
    final vw = viewport.maxWidth;
    final vh = viewport.maxHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return image;
    if (!vw.isFinite || !vh.isFinite) return image;

    final aspect = w / h;
    final double frameWidth;
    final double frameHeight;
    if (_fit == ReadingFit.height) {
      frameHeight = vh;
      frameWidth = vh * aspect;
    } else {
      frameWidth = vw;
      frameHeight = vw / aspect;
    }

    return OverflowBox(
      minWidth: 0,
      maxWidth: double.infinity,
      minHeight: 0,
      maxHeight: double.infinity,
      alignment: Alignment.center,
      child: SizedBox(width: frameWidth, height: frameHeight, child: image),
    );
  }

  /// HEIC / AVIF 在 image 包与本机 Flutter 上都不保证能解码
  /// （BUILD_GUIDE 22.10），失败时给出可读提示而不是解码器异常串。
  bool _isUnsupportedPreviewFormat(MediaItem item) {
    final ext = (item.ext.isNotEmpty ? item.ext : item.format ?? '')
        .toLowerCase()
        .replaceFirst('.', '');
    return ext == 'heic' || ext == 'heif' || ext == 'avif';
  }

  Widget _buildErrorWidget(String message) {
    // 文件缺失与解码失败两条路径都不会走到 frameBuilder，那只在 frameBuilder
    // 里的复位永远不会执行，「加载中」遮罩会一直盖住这条错误提示。
    // 这里补一个复位点，与 frameBuilder 里的复位互不冲突（都是置 false）。
    if (_isImageLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isImageLoading) setState(() => _isImageLoading = false);
      });
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            size: 64,
            color: AppColors.muted,
          ),
          const SizedBox(height: 16),
          const Text(
            '无法加载图片',
            style: TextStyle(color: AppColors.muted, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(color: AppColors.mutedLight, fontSize: 12),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _isImageLoading ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 150),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.lavender,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '加载中...',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(MediaItem img) {
    // 安卓边到边显示时状态栏会压在顶栏上，按钮点不到：把状态栏高度让出来，
    // 渐变仍铺到屏幕最顶端。带曲面侧边的手机左右边缘也会吃掉触摸区，
    // 所以横向同样让出系统窗体内边距（关闭按钮就在最右边）。
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final topInset = viewPadding.top;
    return Positioned(
      key: const ValueKey('viewer-top-bar'),
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 52 + topInset,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: 12 + viewPadding.left,
            right: 12 + viewPadding.right,
            top: topInset,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  img.filename,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _pageIndicator(),
              const SizedBox(width: 8),
              _zoomBadge(),
              const SizedBox(width: 4),
              _toolbarBtn(Icons.zoom_out, '缩小 (-)', _zoomOut),
              _pctBtn(),
              _toolbarBtn(Icons.zoom_in, '放大 (+)', _zoomIn),
              _toolbarBtn(Icons.fit_screen_outlined, '适应窗口 (0)', _fitToWindow),
              _toolbarBtn(
                Icons.aspect_ratio,
                '适应模式：${_fit.label} (S)',
                _cycleFit,
                key: const ValueKey('viewer-fit-button'),
                active: _fit != ReadingFit.page,
              ),
              _toolbarBtn(
                Icons.swap_horiz,
                '阅读方向：${_direction.label}',
                _toggleDirection,
                key: const ValueKey('viewer-direction-button'),
                active: _direction == ReadingDirection.rtl,
              ),
              _toolbarBtn(
                _showExif ? Icons.info : Icons.info_outline,
                'EXIF 信息 (I)',
                () => setState(() => _showExif = !_showExif),
                active: _showExif,
              ),
              const SizedBox(width: 8),
              _toolbarBtn(
                Icons.close,
                '关闭 (Esc)',
                () => _st.closeViewer(),
                key: const ValueKey('viewer-close-button'),
                isClose: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageIndicator() {
    final total = _st.viewerImages.length;
    final cur = _st.viewerIndex + 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$cur / $total',
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _zoomBadge() {
    final pct = (_zoomLevel * 100).round();
    final isFit = _isFitToWindow;
    return GestureDetector(
      onTap: _fitToWindow,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          isFit ? '适应' : '$pct%',
          style: TextStyle(
            color: isFit ? AppColors.success : AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _pctBtn() {
    final pct = (_zoomLevel * 100).round();
    return GestureDetector(
      onTap: _fitToWindow,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
        child: Text(
          '$pct%',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _toolbarBtn(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
    bool isClose = false,
    Key? key,
  }) {
    final Color fg;
    if (isClose) {
      fg = AppColors.danger;
    } else if (active) {
      fg = AppColors.lavender;
    } else {
      fg = AppColors.textSecondary;
    }

    return Tooltip(
      key: key,
      message: tooltip,
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }

  /// 翻页按钮跟着阅读方向走（BUILD_GUIDE 22.2）：
  /// 右到左时左侧按钮是「前进」，左到右时右侧按钮是「前进」。
  Widget _buildBottomBar(bool isFirst, bool isLast) {
    final rtl = _direction == ReadingDirection.rtl;
    final leftIsAdvance = rtl;
    // 安卓手势条同理：底部留出系统导航条的高度，否则按钮点不到；
    // 横向也让出窗体内边距，曲面屏上左右两个翻页按钮才不会贴到边缘。
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final bottomInset = viewPadding.bottom;

    return Positioned(
      key: const ValueKey('viewer-bottom-bar'),
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 52 + bottomInset,
        padding: EdgeInsets.only(
          bottom: bottomInset,
          left: viewPadding.left,
          right: viewPadding.right,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _navBtn(
                Icons.chevron_left,
                leftIsAdvance ? '下一张 (←)' : '上一张 (←)',
                leftIsAdvance ? _next : _previous,
                key: const ValueKey('viewer-left-button'),
                disabled: leftIsAdvance ? isLast : isFirst,
              ),
              const SizedBox(width: 4),
              _navBtn(
                Icons.chevron_right,
                leftIsAdvance ? '上一张 (→)' : '下一张 (→)',
                leftIsAdvance ? _previous : _next,
                key: const ValueKey('viewer-right-button'),
                disabled: leftIsAdvance ? isFirst : isLast,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navBtn(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    Key? key,
    bool disabled = false,
  }) {
    return Tooltip(
      key: key,
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: disabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 28,
              color: disabled ? AppColors.muted : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExifPanel() {
    final exif = _currentExif;
    // 顶栏现在被状态栏顶下来，面板也跟着让开，免得叠在一起。
    final top = 64 + MediaQuery.viewPaddingOf(context).top;
    if (exif == null || !exif.hasData) {
      return Positioned(
        key: const ValueKey('viewer-exif-panel'),
        right: 16,
        top: top,
        child: _exifCard([_exifRow(exif == null ? '加载中...' : '无 EXIF 数据', '')]),
      );
    }

    final rows = <Widget>[];
    if ((exif.make?.isNotEmpty == true) || (exif.model?.isNotEmpty == true)) {
      final camera = [
        exif.make,
        exif.model,
      ].where((s) => s != null && s.isNotEmpty).join(' ');
      rows.add(_exifRow('相机', camera));
    }
    if (exif.lensModel?.isNotEmpty == true) {
      rows.add(_exifRow('镜头', exif.lensModel!));
    }
    rows.add(_exifRow('尺寸', exif.dimensionDisplay));
    if (exif.isoSpeed != null) rows.add(_exifRow('ISO', exif.isoDisplay));
    if (exif.fNumber != null) rows.add(_exifRow('光圈', exif.fNumberDisplay));
    if (exif.exposureTime != null) {
      rows.add(_exifRow('快门', exif.exposureDisplay));
    }
    if (exif.focalLength != null) {
      rows.add(_exifRow('焦距', exif.focalDisplay));
    }
    if (exif.dateTime?.isNotEmpty == true) {
      rows.add(_exifRow('时间', exif.dateTime!));
    }
    if (exif.gpsLatitude != null && exif.gpsLongitude != null) {
      rows.add(
        _exifRow(
          'GPS',
          '${exif.gpsLatitude!.toStringAsFixed(4)}, ${exif.gpsLongitude!.toStringAsFixed(4)}',
        ),
      );
    }

    return AnimatedPositioned(
      key: const ValueKey('viewer-exif-panel'),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      right: 16,
      top: top,
      child: _exifCard(rows),
    );
  }

  Widget _exifCard(List<Widget> children) {
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: AppColors.lavender),
              SizedBox(width: 6),
              Text(
                'EXIF',
                style: TextStyle(
                  color: AppColors.lavender,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _exifRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.mutedLight, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
