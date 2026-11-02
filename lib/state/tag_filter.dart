/// 标签筛选的三个集合：同时满足（AND）、满足其一（OR）、全部排除（NOT）。
///
/// 独立成文件是因为 [TagState] 与 [AppState] 都要用它，放在任一状态对象里
/// 都会让两者互相 import。
class TagFilter {
  final List<int> andTagIds;
  final List<int> orTagIds;
  final List<int> notTagIds;

  const TagFilter({
    this.andTagIds = const [],
    this.orTagIds = const [],
    this.notTagIds = const [],
  });

  bool get active =>
      andTagIds.isNotEmpty || orTagIds.isNotEmpty || notTagIds.isNotEmpty;
}
