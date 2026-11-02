import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/track_dao.dart';
import '../services/subtitle_parser.dart';
import '../services/subtitle_style.dart';
import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';

/// 字幕模式（全屏）：模糊封面背景 + 可滑动/点击跳转的字幕
class SubtitlePage extends StatefulWidget {
  const SubtitlePage({super.key});

  @override
  State<SubtitlePage> createState() => _SubtitlePageState();
}

class _SubtitlePageState extends State<SubtitlePage> {
  static const double _itemExtent = 56.0;

  final ScrollController _scroll = ScrollController();
  bool _userScrolling = false;
  int _lastIndex = -1;
  Timer? _resumeTimer;
  double _viewportHeight = 400;

  /// 自动模式的输入：当前封面解码后算出的平均亮度。
  String? _coverPath;
  double? _coverLuminance;
  bool _decodingCover = false;

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final appState = context.watch<AppState>();
    final track = player.currentTrack;

    final doc = track == null
        ? SubtitleDocument.empty
        : appState.subtitleFor(track);
    final lines = doc.lines;
    final cover = track == null ? null : appState.coverForTrack(track);
    // 自动模式按封面明暗算透明度，固定模式用用户设的值。
    final inactiveOpacity = appState.subtitleOpacityAuto
        ? SubtitleStyle.autoInactiveOpacity(_luminanceOf(cover))
        : appState.subtitleInactiveOpacity;

    // 无时间标签的歌词（纯文本 LRC）不做逐行同步，整篇静态显示。
    final currentIndex = doc.hasTiming ? _currentIndex(lines, player.position) : -1;

    // 自动滚动到当前行
    if (currentIndex != _lastIndex && currentIndex >= 0 && !_userScrolling) {
      _lastIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollTo(currentIndex);
      });
    }

    return Scaffold(
      backgroundColor: AppColors.deep,
      body: Stack(
        children: [
          _background(cover),
          SafeArea(
            child: Column(
              children: [
                _topBar(context, track),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewportHeight = constraints.maxHeight;
                      return _lyricsView(
                        doc,
                        currentIndex,
                        player,
                        inactiveOpacity,
                        Duration(seconds: appState.subtitleResumeSeconds),
                      );
                    },
                  ),
                ),
                _bottomBar(player),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _background(String? cover) {
    Widget? image;
    if (cover != null && File(cover).existsSync()) {
      image = Image.file(File(cover), fit: BoxFit.cover);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image != null)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36),
              child: image,
            ),
          ),
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }

  Widget _topBar(BuildContext context, TrackItem? track) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.keyboard_arrow_down,
                size: 28, color: Colors.white70),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track?.displayTitle ?? '未在播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
                if (track != null)
                  Text(
                    track.artist ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 当前封面的平均亮度。第一次遇到这张封面时在后台解码，先返回 null。
  double? _luminanceOf(String? cover) {
    if (cover == null || cover.isEmpty) return null;
    if (cover == _coverPath) return _coverLuminance;
    if (!_decodingCover) {
      _decodingCover = true;
      _coverPath = cover;
      _coverLuminance = null;
      unawaited(SubtitleStyle.luminanceOfCover(cover).then((value) {
        if (!mounted) return;
        _decodingCover = false;
        // 解码期间可能已经换了另一首，只认还在用的那张封面。
        if (cover == _coverPath) {
          setState(() => _coverLuminance = value);
        }
      }));
    }
    return null;
  }

  Widget _lyricsView(SubtitleDocument doc, int currentIndex,
      PlayerController player, double inactiveOpacity, Duration resumeDelay) {
    // 占位格式（.ass/.ssa/.ttml 等）：解析器只回了提示文案。
    if (!doc.parsed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            doc.note ?? '该格式暂不支持解析',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ),
      );
    }

    if (doc.lines.isEmpty) {
      return Center(
        child: Text(doc.note ?? '无字幕',
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
      );
    }

    // 无时间标签的歌词整篇静态显示：不逐行高亮，点击也不跳转。
    if (!doc.hasTiming) {
      return Column(
        children: [
          _hint(doc.note ?? '该歌词无时间标签'),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              itemCount: doc.lines.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  doc.lines[i].text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 16, height: 1.4),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          _userScrolling = true;
        } else if (n is ScrollEndNotification && n.dragDetails != null) {
          _resumeTimer?.cancel();
          _resumeTimer = Timer(resumeDelay, () {
            if (mounted) setState(() => _userScrolling = false);
          });
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _itemExtent,
        padding: EdgeInsets.symmetric(vertical: _viewportHeight / 2 - _itemExtent / 2),
        itemCount: doc.lines.length,
        itemBuilder: (context, i) {
          final line = doc.lines[i];
          final active = i == currentIndex;
          return GestureDetector(
            onTap: () => player.seek(Duration(milliseconds: line.startMs)),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
              child: Text(
                line.text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active
                      ? Colors.white
                      : Colors.white.withValues(alpha: inactiveOpacity),
                  fontSize: active ? 22 : 16,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  height: 1.3,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 顶部一条提示（例如「该歌词无时间标签」）。
  Widget _hint(String text) {
    return Container(
      width: double.infinity,
      color: Colors.white10,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _bottomBar(PlayerController player) {
    final maxMs = player.duration.inMilliseconds;
    final posMs = player.position.inMilliseconds.clamp(0, maxMs > 0 ? maxMs : 0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(formatDuration(player.position),
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: Colors.white24,
                  ),
                  child: Slider(
                    value: maxMs > 0 ? posMs.toDouble() : 0,
                    max: maxMs > 0 ? maxMs.toDouble() : 1,
                    onChanged: (v) =>
                        player.seek(Duration(milliseconds: v.round())),
                  ),
                ),
              ),
              Text(formatDuration(player.duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一首',
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 30),
                onPressed: () => player.previous(),
              ),
              IconButton(
                tooltip: player.playing ? '暂停' : '播放',
                icon: Icon(
                  player.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  color: Colors.white,
                  size: 52,
                ),
                onPressed: () => player.togglePlay(),
              ),
              IconButton(
                tooltip: '下一首',
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 30),
                onPressed: () => player.next(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _currentIndex(List<LyricLine> lines, Duration pos) {
    final ms = pos.inMilliseconds;
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (ms >= lines[i].startMs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _scrollTo(int index) {
    if (!_scroll.hasClients) return;
    // 列表上下内边距各留了半个视口，所以第 index 句的中心本来就在视口正中；
    // 滚到 index * _itemExtent 就是把它摆正，多余的偏移会把它推到视口底部。
    final target = index * _itemExtent;
    final maxExtent = _scroll.position.maxScrollExtent;
    final clamped = target.clamp(0.0, maxExtent < 0 ? 0.0 : maxExtent);
    _scroll.animateTo(clamped,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }
}
