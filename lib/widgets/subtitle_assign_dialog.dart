import 'package:flutter/material.dart';

import '../services/subtitle_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 字幕归属（BUILD_GUIDE 第 18.5、23.6 节）。
///
/// 一条音频名下可以挂多条字幕，其中恰好一条是默认项。默认项的挑选顺序
/// （上次选定 → 文件名匹配 → 语言优先级）由 [SubtitleService] 负责，
/// 这里只提供三种人工动作：设为默认、解除归属、把未归属的字幕挂到本曲。
class SubtitleAssignDialog extends StatefulWidget {
  const SubtitleAssignDialog({
    super.key,
    required this.state,
    required this.audioId,
    required this.audioLabel,
  });

  final AppState state;
  final int audioId;
  final String audioLabel;

  static Future<void> show(
    BuildContext context, {
    required AppState state,
    required int audioId,
    required String audioLabel,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => SubtitleAssignDialog(
        state: state,
        audioId: audioId,
        audioLabel: audioLabel,
      ),
    );
  }

  @override
  State<SubtitleAssignDialog> createState() => _SubtitleAssignDialogState();
}

class _SubtitleAssignDialogState extends State<SubtitleAssignDialog> {
  List<SubtitleEntry> _entries = const [];
  List<SubtitleEntry> _unassigned = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.state.subtitleEntriesFor(widget.audioId);
    final unassigned = await widget.state.unassignedSubtitles();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _unassigned = unassigned;
      _loading = false;
    });
  }

  Future<void> _setDefault(int id) async {
    await widget.state.setDefaultSubtitle(id);
    await _load();
  }

  Future<void> _detach(int id) async {
    await widget.state.detachSubtitle(id);
    await _load();
  }

  Future<void> _attach(int id) async {
    await widget.state.attachSubtitleToAudio(id, widget.audioId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text('字幕归属 · ${widget.audioLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary)),
      content: SizedBox(
        width: 560,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionTitle('本曲名下的字幕', '${_entries.length} 条'),
                  Expanded(flex: 3, child: _attachedList()),
                  const SizedBox(height: 8),
                  _sectionTitle('未归属的字幕', '${_unassigned.length} 条'),
                  Expanded(flex: 2, child: _unassignedList()),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('subtitle-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, String count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
          const SizedBox(width: 6),
          Text(count,
              style: TextStyle(fontSize: 11, color: AppColors.mutedLighter)),
        ],
      ),
    );
  }

  Widget _attachedList() {
    if (_entries.isEmpty) {
      return _empty('这条音频还没有归属字幕，导入时按文件名自动匹配');
    }
    return ListView(
      key: const ValueKey('subtitle-attached-list'),
      children: [
        for (final entry in _entries)
          ListTile(
            key: ValueKey('subtitle-row-${entry.id}'),
            dense: true,
            selected: entry.isDefault,
            selectedTileColor: AppColors.accent.withValues(alpha: 0.12),
            leading: Icon(
              entry.isDefault
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: entry.isDefault ? AppColors.accent : AppColors.mutedLight,
            ),
            title: Text(entry.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
            subtitle: Text(
              entry.language == null
                  ? entry.ext
                  : '${entry.language} · ${entry.ext}',
              style: TextStyle(fontSize: 11, color: AppColors.mutedLighter),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: ValueKey('subtitle-default-${entry.id}'),
                  onPressed:
                      entry.isDefault ? null : () => _setDefault(entry.id),
                  child: const Text('设为默认'),
                ),
                IconButton(
                  key: ValueKey('subtitle-detach-${entry.id}'),
                  tooltip: '解除归属',
                  iconSize: 16,
                  onPressed: () => _detach(entry.id),
                  icon: const Icon(Icons.link_off, color: AppColors.danger),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _unassignedList() {
    if (_unassigned.isEmpty) {
      return _empty('没有未归属的字幕');
    }
    return ListView(
      key: const ValueKey('subtitle-unassigned-list'),
      children: [
        for (final entry in _unassigned)
          ListTile(
            key: ValueKey('subtitle-unassigned-${entry.id}'),
            dense: true,
            title: Text(entry.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
            subtitle: Text(entry.ext,
                style: TextStyle(fontSize: 11, color: AppColors.mutedLighter)),
            trailing: TextButton(
              key: ValueKey('subtitle-attach-${entry.id}'),
              onPressed: () => _attach(entry.id),
              child: const Text('归属到本曲'),
            ),
          ),
      ],
    );
  }

  Widget _empty(String text) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.mutedLight)),
    );
  }
}
