import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../services/subtitle_style.dart';

/// 持久化的界面设置：主题、排序、列数、布局尺寸、视图模式与字幕外观。
///
/// 从 [AppState] 里拆出来的第一个状态对象。这里只管「值与落盘」，
/// 排序变了要重查数据这类副作用留在 [AppState] 的转发层，避免状态对象
/// 反向依赖整个应用。
class SettingsState extends ChangeNotifier {
  SettingsState();

  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  String _sortKey = 'filename';
  String get sortKey => _sortKey;

  bool _sortDescending = false;
  bool get sortDescending => _sortDescending;

  String _imageSortKey = 'name';
  String get visualSortKey => _imageSortKey;

  bool _imageSortDesc = false;
  bool get visualSortDescending => _imageSortDesc;

  String _worksSortKey = 'added';
  String get worksSortKey => _worksSortKey;

  bool _worksSortDesc = true;
  bool get worksSortDescending => _worksSortDesc;

  int _gridColumns = 4;
  int get gridColumns => _gridColumns;

  double _leftWidth = SettingsService.defaultLeftWidth;

  /// 宽屏左栏宽度。界面层还会按窗口宽度再夹一次。
  double get leftWidth => _leftWidth;

  double _libraryHeight = SettingsService.defaultLibraryHeight;

  /// 左栏里作品集列表的高度。标签区占剩余空间。
  double get libraryHeight => _libraryHeight;

  String _viewMode = 'grid';
  String get viewMode => _viewMode;

  bool _subtitleOpacityAuto = true;

  /// 非当前句的透明度是否按封面明暗自动算。
  bool get subtitleOpacityAuto => _subtitleOpacityAuto;

  double _subtitleInactiveOpacity = SubtitleStyle.defaultInactiveOpacity;

  /// 固定模式下非当前句的透明度。
  double get subtitleInactiveOpacity => _subtitleInactiveOpacity;

  int _subtitleResumeSeconds = SettingsService.defaultSubtitleResumeSeconds;

  /// 滑动之后留在原地的秒数。
  int get subtitleResumeSeconds => _subtitleResumeSeconds;

  String _dlsiteProxy = '';

  /// 抓 DLsite 用的 HTTP 代理，空串表示直连。
  String get dlsiteProxy => _dlsiteProxy;

  /// 从磁盘读一次。只赋值，不回写：刚读到的值再写一遍没有意义。
  void load(SettingsService ss) {
    _themeMode = ss.themeMode;
    _sortKey = ss.sortKey;
    _sortDescending = ss.sortDescending;
    _imageSortKey = ss.imageSortKey;
    _imageSortDesc = ss.imageSortDescending;
    _worksSortKey = ss.worksSortKey;
    _worksSortDesc = ss.worksSortDescending;
    _gridColumns = ss.gridColumns;
    _leftWidth = ss.leftWidth;
    _libraryHeight = ss.libraryHeight;
    _viewMode = ss.viewMode;
    _subtitleOpacityAuto = ss.subtitleOpacityAuto;
    _subtitleInactiveOpacity = ss.subtitleInactiveOpacity;
    _subtitleResumeSeconds = ss.subtitleResumeSeconds;
    _dlsiteProxy = ss.dlsiteProxy;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await SettingsService.instance.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setSortKey(String key) async {
    _sortKey = key;
    await SettingsService.instance.setSortKey(key);
    notifyListeners();
  }

  Future<void> setSortDescending(bool desc) async {
    _sortDescending = desc;
    await SettingsService.instance.setSortDescending(desc);
    notifyListeners();
  }

  Future<void> setVisualSortKey(String key) async {
    _imageSortKey = key;
    await SettingsService.instance.setImageSortKey(key);
    notifyListeners();
  }

  Future<void> setVisualSortDescending(bool desc) async {
    _imageSortDesc = desc;
    await SettingsService.instance.setImageSortDescending(desc);
    notifyListeners();
  }

  Future<void> setWorksSortKey(String key) async {
    _worksSortKey = key;
    await SettingsService.instance.setWorksSortKey(key);
    notifyListeners();
  }

  Future<void> setWorksSortDescending(bool desc) async {
    _worksSortDesc = desc;
    await SettingsService.instance.setWorksSortDescending(desc);
    notifyListeners();
  }

  Future<void> setGridColumns(int cols) async {
    _gridColumns = cols.clamp(2, 10);
    await SettingsService.instance.setGridColumns(_gridColumns);
    notifyListeners();
  }

  Future<void> setLeftWidth(double width) async {
    _leftWidth = width.clamp(
        SettingsService.minLeftWidth, SettingsService.maxLeftWidth);
    await SettingsService.instance.setLeftWidth(_leftWidth);
    notifyListeners();
  }

  Future<void> setLibraryHeight(double height) async {
    _libraryHeight = height.clamp(
        SettingsService.minLibraryHeight, SettingsService.maxLibraryHeight);
    await SettingsService.instance.setLibraryHeight(_libraryHeight);
    notifyListeners();
  }

  /// 恢复默认布局。只动两个尺寸，不碰主题、列数、排序与筛选。
  Future<void> resetLayoutSizes() async {
    _leftWidth = SettingsService.defaultLeftWidth;
    _libraryHeight = SettingsService.defaultLibraryHeight;
    await SettingsService.instance.setLeftWidth(_leftWidth);
    await SettingsService.instance.setLibraryHeight(_libraryHeight);
    notifyListeners();
  }

  Future<void> setSubtitleOpacityAuto(bool auto) async {
    _subtitleOpacityAuto = auto;
    await SettingsService.instance.setSubtitleOpacityAuto(auto);
    notifyListeners();
  }

  Future<void> setSubtitleInactiveOpacity(double value) async {
    _subtitleInactiveOpacity = SubtitleStyle.clampInactiveOpacity(value);
    await SettingsService.instance
        .setSubtitleInactiveOpacity(_subtitleInactiveOpacity);
    notifyListeners();
  }

  Future<void> setSubtitleResumeSeconds(int seconds) async {
    _subtitleResumeSeconds = seconds.clamp(
        SettingsService.minSubtitleResumeSeconds,
        SettingsService.maxSubtitleResumeSeconds);
    await SettingsService.instance
        .setSubtitleResumeSeconds(_subtitleResumeSeconds);
    notifyListeners();
  }

  Future<void> setViewMode(String mode) async {
    _viewMode = mode == 'list' ? 'list' : 'grid';
    await SettingsService.instance.setViewMode(_viewMode);
    notifyListeners();
  }

  Future<void> setDlsiteProxy(String proxy) async {
    _dlsiteProxy = proxy;
    await SettingsService.instance.setDlsiteProxy(proxy);
    notifyListeners();
  }
}
