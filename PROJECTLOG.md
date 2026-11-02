# 施工日志

本文件只追加，不修改历史条目。每条记录包含日期、目标、动作与验证。

## 2026-11-02 阶段一：复制工作树与改名

**目标**：在 `/home/hoshi/code/AsmrShelf` 建立独立应用骨架，把应用身份从 MediaShelf 改成 AsmrShelf，并跑通基线。

**动作**

| 项 | 内容 |
| --- | --- |
| 复制范围 | `rsync -a` 从 MediaShelf 复制工作树。排除 `.git/`、`build/`、`.dart_tool/`、`coverage/`、`logs/`、`.flutter-plugins-dependencies`、`docs/` |
| 保留 | AsmrShelf 自己的 `docs/需求研究与设计备忘.md` 与 `.git/`（远端 `OverFlame/AsmrShelf`） |
| 身份改名 | `pubspec.yaml` name 改 `asmrshelf`、description 与 version 改 `0.1.0+1` |
| 包名 | `android/app/build.gradle.kts` 的 namespace 与 applicationId 改 `com.overflame.asmrshelf`；Kotlin 目录移到 `com/overflame/asmrshelf` |
| 通道名 | `media_bridge.dart`、`video_launcher.dart`、Kotlin 两文件统一 `asmrshelf/playback` |
| 数据目录 | `data_dir_service.dart` 默认目录改 `AsmrShelf`，库文件改 `asmr_shelf.db`；`database.dart` 与 `migration_guard.dart` 同步 |
| 平台打包 | `linux/CMakeLists.txt` 的 BINARY_NAME 与 APPLICATION_ID、`linux/runner/my_application.cc` 标题、`windows/CMakeLists.txt` 的 project 与 BINARY_NAME、`windows/runner/main.cpp` 窗口标题、`windows/runner/Runner.rc` 公司与产品信息 |
| 脚本 | `scripts/` 五个构建脚本的可执行名与产物路径 |
| 界面文案 | `main.dart` 的 `AsmrShelfApp` 与 title、`home_page.dart` 标题、`about_page.dart` 应用名与版本常量、`settings_page.dart` 关于入口 |
| 调试标签 | `compute` 的 debugLabel 改 `asmrshelf.scan` 与 `asmrshelf.metadata` |
| 日志名 | `log_util.dart` 默认名改 AsmrShelf |
| 测试 | 全部 `package:mediashelf/` 前缀改 `package:asmrshelf/`；`AudioShelf` 数据目录断言改 `AsmrShelf`；视频缩略图键的真值按新路径重算 |

**验证**

| 项 | 结果 |
| --- | --- |
| `flutter pub get` | 成功 |
| `flutter analyze --no-fatal-infos` | No issues found |
| `flutter test` | 603 例全部通过 |
| 残留扫描 | `grep -ri mediashelf` 只剩 `linux/flutter/ephemeral/` 的生成文件，由构建重新生成 |

**决定**

1. 不复制 MediaShelf 的 `docs/`。剥离指南与调研文档属于源仓库，新仓库只保留自己的设计备忘。
2. `works.cover_path` 与缓存文件前缀不改名，等阶段三建 schema 时统一处理。
3. `image`、`exif`、`crypto` 三个依赖先保留，阶段二删视觉模块时一并去掉。

## 2026-11-02 阶段二：移除多媒体界面层

### 目标

去掉只服务图片与视频的界面，让首页只剩音频栏一条路径。删之前先确认没有编译依赖，删之后每改一层跑一次分析。

### 动作

| 层 | 动作 | 结果 |
|---|---|---|
| 首页 | 去掉库切换条、多媒体分支、图片详情覆盖层与查看器 | `lib/pages/home_page.dart` 现在只有音频栏 |
| 工具栏 | `_VisualToolbar` 去掉 `library`、`detailOpen`、`onToggleDetail` 三个参数与详情按钮 | 键名前缀统一 `audio-toolbar-*` |
| 横条 | 删 `_LibrarySwitcher`、`_BreadcrumbBar`、`_AdvancedFilterBar`、`_SelectionBar` | 面包屑与高级筛选只剩多媒体栏在用 |
| 控件 | 删 `image_grid.dart`、`image_detail.dart`、`image_viewer.dart`、`folder_panel.dart`、`volume_panel.dart` | 五个文件合计 4093 行 |
| 服务 | 删 `exif_service.dart`（全仓零引用） | 其余视觉服务仍被 `AppState` 引用，随阶段四拆解时清除 |
| 依赖 | 去掉 `exif`，把 `image` 降为 dev 依赖（只给缩略图缓存测试造 PNG） | 运行时不再依赖图像解码库 |

### 测试

删除只验被删控件的用例：`test/widget/image_grid_test.dart`、`test/widget/image_viewer_test.dart`、`test/state/app_state_images_test.dart`、`test/widget/image_dialogs_test.dart`、`test/widget/volume_panel_test.dart`。

`test/widget/home_page_test.dart` 重写为音频栏五例：作品网格只列音频作品、点卡片进作品再下钻到卷、作品卡片标签菜单、窄屏十列不溢出与视图切换、工具条排序菜单只给作品字段。

### 验证

| 项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze --no-fatal-infos` | No issues found |
| 单元与控件测试 | `flutter test` | 540 例全部通过 |
| 编译 | `flutter build linux --release` | 见下一步提交前的构建记录 |

### 决定

1. `kMediaLibrary` 常量随 `folder_panel.dart` 一起删除，`kAudioLibrary` 留在 `lib/pages/home_page.dart:19`。
2. 视觉服务的删除不放在本层：`AppState` 仍是 3302 行的单体，先删服务会留下大量悬空引用，留到阶段四按状态对象拆解时一并清掉。

## 2026-11-02 阶段三：schema v1 与拒绝降级

### 目标

把数据库版本定到 v1，加两张阶段六要用的表，并把「版本对不上就删表重建」改成拒绝打开。不删用户数据是这一阶段的硬要求。

### 动作

| 项 | 改动 | 位置 |
|---|---|---|
| 版本号 | `version = 10` 改成 `1` | `lib/db/tables.dart:10` |
| 新表 | `work_tags`（作品↔标签）、`work_metadata`（RJ 号、简介、封面来源、raw_json） | `lib/db/tables.dart` |
| 迁移策略 | `applyMigrations` 不再 `dropAll` 加 `createAll`，版本不一致直接抛 `StateError` | `lib/db/tables.dart` |
| 开库 | 补 `onDowngrade`，库比应用新时同样拒绝 | `lib/db/database.dart` |
| 阅读进度 | 删 `reading_progress_service.dart` 与 `AppState` 里的阅读会话 | `lib/services/`、`lib/state/app_state.dart` |
| 测试 | 三个「升级即清库」用例改成「拒绝打开且老行不丢」；守卫用例改成「备份后仍拒绝」 | `test/db_migration_test.dart`、`test/services/migration_guard_test.dart` |

`work_metadata.rj_code` 带 UNIQUE 约束，按编号反查作品用得上。`cover_source` 记录封面来自 DLsite、本地目录还是音频内嵌。

### 偏差与理由

1. **多媒体相关列暂留**：`media` 的 `width`/`height`/`image|video` 类型值、`folders` 的阅读方向与裁剪列都还在。删列要连带改 `MediaDao`、`AppState` 与大批判词，而 `AppState` 3302 行要到阶段四才拆。先把表加上，删列跟阶段四一起做，避免中途库结构改两遍。
2. **`folder_tags` 保留**：文件夹层标签仍在 `FolderBrowser` 里用，作品层标签是新增的 `work_tags`。两套并存到阶段五重做界面时再合并。
3. **`dropAll` 保留**：只给测试造空库用，开库路径不再调用它。

### 验证

| 项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze --no-fatal-infos` | No issues found |
| 单元与控件测试 | `flutter test` | 521 例全部通过 |
| 版本拒绝 | `test/db_migration_test.dart` 三个用例 | v6、v9 老库均抛 `StateError`，老行原样保留 |
| 备份守卫 | `test/services/migration_guard_test.dart` | 备份文件存在、库里仍是 v9、检查仍报不一致 |

## 2026-11-02 阶段收尾记录

### 本次自主推进到哪一步

| 阶段 | 状态 | 提交 |
|---|---|---|
| 一 复制与改名 | 完成 | `426764b` |
| 二 移除多媒体界面层 | 完成界面与依赖层 | `e74e703` |
| 三 schema v1 | 完成 | `9b1f6bc`、`2ae5c34` |
| 四 拆 AppState | 未开始 | 无 |
| 五 重做音频界面 | 未开始 | 无 |
| 六 接 DLsite | 未开始 | 无 |

### 当前基线

| 项 | 数值 |
|---|---|
| 静态分析 | `flutter analyze --no-fatal-infos` 无问题 |
| 测试 | 521 例全部通过（阶段一 603 例，删掉被移除功能的 82 例） |
| Linux 构建 | `NO_XIPH_LIBS=1 flutter build linux --release` 成功 |
| 数据库版本 | v1 |
| `lib/state/app_state.dart` | 约 3100 行，仍是单体 |

### 下一步该从哪里接

1. 阶段四先把 `ImportState` 与 `CoverState` 拆出来，这两个被阶段五、六同时依赖。
2. 拆完后再删 `media` 的 `width`/`height`、`folders` 的阅读列与 `image|video` 类型值，v1 的库结构才算收干净。
3. 阶段五重做作品层时，`works.root_path` 与 `work_tags` 已经在库里，直接接。

## 2026-11-02 阶段四前置：两个纯函数模块

### 为什么先写这两个

阶段四拆 `AppState` 时，编号识别与封面挑选要各拆一次。先把它们做成不碰 IO 的纯函数模块，拆的时候直接调用，不必在状态对象里复制逻辑。两处规则都来自 `docs/需求研究与设计备忘.md` 第 5.1 节与第 12 节。

### 新增文件

| 文件 | 内容 |
|---|---|
| `lib/services/dlsite/work_code.dart` | `WorkCode`、`parseWorkCode`、`findWorkCode`、`isValidWorkCode`；开头优先匹配，失败退到全文搜一次；编号归一成大写，剩余部分作标题 |
| `lib/services/cover_selector.dart` | `CoverCandidate`、`scoreCoverName`、`scoreCoverPath`、`scoreSize`、`pickBestCover`；白名单形态、强词弱词、目录信号、深浅度、尺寸分都在这一层 |

`pickBestCover` 的排序键依次是分值、目录深度、文件名自然序，尺寸分靠可选回调 `sizeOf` 注入，模块本身不读文件。

### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | 无问题 |
| `flutter test test/services/work_code_test.dart` | 20 例全过 |
| `flutter test test/services/cover_selector_test.dart` | 18 例全过 |
| `flutter test` | 559 例全过 |

### 两条实现决定

1. **标题保留策略**：编号在开头时，标题就是剩余部分；编号在中间时，把编号抠掉后合并两侧再压缩连续空格。这样 `[サークル] RJ294126 作品名` 拆成 `[サークル] 作品名`，社团名不丢。
2. **白名单整段对齐**：`cover10.jpg` 不算白名单形态，只有基名整段等于 `cover` 才算。带序号的图交给强词与目录信号打分，避免把一串 `cover1` 到 `cover20` 全判成封面。

## 2026-11-02 阶段四第一步：拆掉图片查看器与图片选中

### 动作

| 项 | 改动 |
|---|---|
| 查看器 | 删 `_viewerImages`、`_viewerIndex`、`_showViewer`、`openViewer`、`closeViewer`、`navigateViewer`、`_syncSelectedToViewer`、`_dropViewerItemsFor` |
| 图片选中 | 删 `_selectedImageId`、`_selectedImageIds`、`_anchorImageId`、`selectImage`、`toggleSelect`、`rangeSelect`、`clearSelection`、`selectAllImages`、`ensureDetailSelection`、`enterVisualSelectionMode`、`exitVisualSelectionMode`、`selectedId`、`selectedImage`、`selectedIds`、`isSelected`、`visualSelectionMode` |
| 可见项登记 | 删 `_visibleMediaIds`、`reportVisibleMedia`、`_selectableMediaIds`，这套只服务已删除的网格 |
| 工具条 | `lib/pages/home_page.dart` 的多选按钮改走曲目接口：`selectionMode`、`enterTrackSelectionMode`、`clearTrackSelection` |
| 测试 | `test/state/app_state_delete_test.dart` 去掉查看器断言；`test/state/app_state_tag_admin_test.dart` 两条图片批量用例改写成曲目批量用例 |

`lib/state/app_state.dart` 从 3202 行降到 2954 行。

### 为什么先拆这一块

图片查看器与图片选中已经没有界面在用，留着只会让阶段四的拆分对象与调用关系更难看清。曲目多选用的是另一套 `_selectedTrackIds`，不受影响。

### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | 无问题 |
| `flutter test` | 559 例全过 |
| `NO_XIPH_LIBS=1 flutter build linux --release` | 成功 |

## 2026-11-02 阶段四第二步：去掉多媒体栏的中间栏分支

### 动作

| 项 | 改动 |
|---|---|
| 中间栏 | `_loadCenter` 只留曲目与文件夹两条路，搜索与标签筛选都按 `MediaType.audio` 走 |
| 状态 | 删 `_images`、`images`、`_setImages`、`_totalCount`、`totalCount`、`_imageIndex` |
| 库判定 | 删 `_browsingLibrary`、`setBrowsingLibrary`、`_fillsImages`、`isImageLibrary`、`isVisualLibrary` |
| 测试 | 删 `test/state/app_state_media_tab_test.dart`（多媒体栏已不存在） |

`lib/state/app_state.dart` 再降到 2790 行上下。

### 说明

`_imageTags` 保留：它缓存的是媒体行标签，`tagsForMedia` 与曲目标签面板都在用，不是图片专用。`_mediaRevision` 保留：媒体行增删后界面靠它重查。

### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | 无问题 |
| `flutter test` | 554 例全过 |

## 2026-11-02 阶段四第三步：清掉只服务视觉的死代码

### 动作

| 项 | 改动 |
|---|---|
| 控件 | 删 `lib/widgets/color_picker_dialog.dart`（零引用）、`volume_cover_dialog.dart` 与 `cover_crop_editor.dart`（仅互相引用，没有入口） |
| 服务 | 删 `lib/services/video_cover_service.dart` 与 `AppState` 里的 `videoCoverFor`、`_videoCovers`、`_videoCoverFutures`、构造参数 `videoCovers` |
| 测试 | 删 `volume_cover_dialog_test.dart`、`cover_crop_editor_test.dart`、`app_state_video_cover_test.dart`、`video_cover_service_test.dart` |

`setMediaCover` 保留：音频单文件手选封面写的就是这一列，只是不再清视频封面缓存。

### 判定依据

三个控件都靠「有没有入口」判死，不靠猜：`color_picker_dialog` 全仓零引用，`volume_cover_dialog` 只被自己的测试引用，`cover_crop_editor` 只被 `volume_cover_dialog` 引用。视频封面服务同理，`videoCoverFor` 的调用点只剩它自己的测试。

### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | 无问题 |
| `flutter test` | 527 例全过 |

## 2026-11-02 阶段四第四步：删掉只为图片服务的两个接口

| 项 | 改动 |
|---|---|
| 接口 | 删 `imagesInFolder`（唯一调用方是已删除的卷封面对话框）、`setImageAlias`（全仓零调用） |
| 行数 | `lib/state/app_state.dart` 降到 2802 行 |

验证：`flutter analyze --no-fatal-infos` 无问题，`flutter test` 527 例全过。

## 2026-11-02 封面回退链：读尺寸与找封面两个新模块

### 动作

| 文件 | 内容 |
|---|---|
| `lib/services/image_size.dart` | 只读文件头拿宽高：PNG、GIF、BMP、WebP（VP8X、VP8L、VP8）、JPEG 逐段扫到 SOF。最多读前 64 KB |
| `lib/services/cover_finder.dart` | 四级回退：根目录白名单、信号目录、根目录任意图、整棵子树；`fetchAndWrite` 把选中的图写到作品根目录 |
| `test/services/image_size_test.dart` | 4 例：PNG、BMP 负高度、JPEG 扫段、脏数据不抛异常 |
| `test/services/cover_finder_test.dart` | 9 例：四级回退、编号名优先、写盘不覆盖、尺寸探测失败也能挑 |

### 两个口径修正

1. **深浅度要按作品根算。** `scoreCoverPath` 原来用整条路径的目录数做深度，`/tmp/x/a/one.jpg` 这种绝对路径一进来就扣成负分。改成新参数 `rootPath`，按「离作品根几层」扣分，`pickBestCover` 同步。
2. **分值只排序，不淘汰。** 第四级回退的定义就是「一张都不像封面时也得挑一张」，所以 `pickBestCover` 不再丢掉非正分候选；淘汰留在调用方，白名单门槛与信号目录自己判。

### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | 无问题 |
| `flutter test` | 541 例全过 |

## 2026-11-02 元数据 DAO

`lib/db/work_metadata_dao.dart`：`WorkMetadata` 模型 + `WorkMetadataDao`，方法 `getByWork`、`getByRjCode`（不区分大小写，落库统一大写）、`upsert`（只补传进来的字段）、`setCover`（只动封面三列，行不存在时补一行）、`delete`。

一处必须记住的判定：`upsert` 不用 `ConflictAlgorithm.replace`。RJ 号是唯一索引，替换会静默顶掉别的作品那一行，变成「抓 A 顺手把 B 的编号抢过来」。改成显式分插入与更新，撞唯一索引就让调用方看见 `DatabaseException`。`test/db/work_metadata_dao_test.dart` 5 例覆盖，含「两个作品不能抢同一个 RJ 号」。

验证：analyze 无问题、`flutter test` 546 例全过。

## 2026-11-02 一次性导入的扫描层

`lib/services/import_scanner.dart`：把用户整理好的目录树读成计划，不碰数据库。

| 类型 | 内容 |
|---|---|
| `ImportTrack` | 曲目路径、文件名、剥掉序号后的标题、字节数 |
| `ImportWork` | 作品目录、标题（目录名剥掉编号）、RJ 或 VJ 编号、封面路径与回退层、曲目表 |
| `ImportPlan` | 根目录、作品表、`skipped`（像作品但没有音频的目录） |

规则：根目录每个子目录一部作品；`nested: true` 时认「社团/作品」两层；作品里的子目录照样扫，但 `特典/` 下的音频不进曲目表（那是赠品，不是正片）；曲目按自然序排；封面用 `CoverFinder` 找，默认把选中的图写进作品根目录。

验证：analyze 无问题、`flutter test` 555 例全过。

## 2026-11-02 一次性导入的落库层

`lib/services/plan_importer.dart`：`PlanImporter(db).apply(plan)` 把扫描结果写成

| 表 | 写什么 |
|---|---|
| `works` | 一行，`name` 用剥掉编号的标题，`library` 固定 `audio`，`cover_path` 记封面 |
| `works.root_path` | 作品目录绝对路径，重复跑靠它判重 |
| `folders` + `folder_paths` | 一条根文件夹，指向作品目录 |
| `media` | 每首曲目一行，`media_type` 为 `audio`，`title` 用剥过序号的标题 |
| `work_metadata` | 有编号或封面时写：`rj_code`、`cover_source=local`、`cover_fetched_at` |

一个必须记住的 schema 事实：`media` **没有** `work_id` 也没有 `folder_id` 列。曲目与文件夹、作品的关系在查询时按路径范围算（`lib/db/path_range.dart`），落库只认 `path`。第一次写代码时按「一定有 folder_id」写，测试直接报 `table media has no column named folder_id`。

`ImportOutcome` 分开数四种：新建作品、跳过作品、新增曲目、已存在曲目。

验证：analyze 无问题、`flutter test` 560 例全过。

## 2026-11-02 一次性导入工具（命令行）

`tool/import_cli.dart`：

```text
dart run tool/import_cli.dart --root <目录> [--db <库文件>] [--nested] [--dry-run]
```

先扫描并打印「几部作品、几首曲目、每部的编号与封面层级、跳过哪些没有音频的目录」，`--db` 指向应用建好的库文件才会写入。库版本不是 v1 时拒绝写入。

### 为让命令行跑起来改的三处

| 问题 | 处理 |
|---|---|
| `package:sqflite` 会经 `flutter/foundation` 拉 `dart:ui`，`dart run` 直接编译失败 | DAO 改为 `package:sqflite_common/sqlite_api.dart`（同一套接口，不绑 Flutter）；`lib/db/database.dart` 仍用 `package:sqflite`，它本来就是 Flutter 侧入口 |
| `folder_dao.dart` 用 `Sqflite.firstIntValue`（Flutter 版工具函数） | 改成 `SELECT COUNT(*) AS c` 再读列 |
| `lib/utils/log_util.dart` 用 `kDebugMode` 与 `debugPrint` | 用 `assert` 自造 `_isDebugMode`，回退输出改 `stdout.writeln`；日志工具从此是纯 Dart |

### 实测（临时目录两个作品三个音频）

| 步骤 | 结果 |
|---|---|
| 干跑 | `2 部作品，3 首曲目`，`作品A [RJ294126] 2 首 无封面`、`普通作品 1 首 无封面`、跳过 1 个空目录 |
| 第一次写入 | `ImportOutcome(作品 2 新建 / 0 跳过, 曲目 3 新增 / 0 已存在)` |
| 第二次写入 | `ImportOutcome(作品 0 新建 / 2 跳过, 曲目 0 新增 / 0 已存在)` |
| 库内容 | `works` 两行且 `root_path` 为绝对路径；`media` 三行；`work_metadata` 只有 RJ294126 那一行 |

验证：analyze 无问题、`flutter test` 560 例全过。

## 2026-11-02 DLsite 抓取三层（阶段六地面）

三个文件，只做「抓回来、解析、落库」，不碰界面：

| 文件 | 职责 |
|---|---|
| `lib/services/dlsite/dlsite_models.dart` | `DlsiteWork` 与 `parseProductJson`，字段按 `docs/DLsite_可获取数据说明.md` 第 3 节取 |
| `lib/services/dlsite/dlsite_rate_limiter.dart` | `DlsiteRateLimiter` 串行节流（默认 10 秒）、`DlsiteRetryPolicy` 只对 429/503 退避重试两次 |
| `lib/services/dlsite/dlsite_api.dart` | `DlsiteTransport` 抽象 + `HttpDlsiteTransport`，`DlsiteApi.fetchWork` 判状态码 |
| `lib/services/dlsite/dlsite_repository.dart` | 7 天缓存、写 `work_metadata`、分类挂 `dlsite` 命名空间、声优挂 `voice` |

几个落地时的判定：

- 接口返回的是单元素数组，`parseProductJson` 兼容对象与数组，坏输入返回 null 不抛。
- 非 200 必须在传输层抛 `DlsiteException`，否则重试策略看不到状态码：`_get` 里统一抛，`fetchWork` 里只把 404 当「没有这部作品」的正常结果。
- 缓存命中时用 `work_metadata.raw_json` 反解，不额外存一份解析结果。
- 远程封面默认不写 `cover_source`：本地有图时不被顶掉，等用户在预览里勾选（`applyCover: true`）。
- `work_tags` 的挂标签走 `TagDao.attachToWork`，重复挂用 `ConflictAlgorithm.ignore`，重复抓同一部作品新增数为 0。

验证：analyze 无问题、`flutter test` 585 例全过（新增 25 例：解析 8、节流 3、重试 3、落库 11）。

## 2026-11-02 两个用户入口：根目录批量导入与 DLsite 抓取

### 批量导入（`839420a`）

`AppState` 加两个方法，界面只负责选目录与确认：

| 成员 | 作用 |
|---|---|
| `scanWorksRoot(String rootPath, {bool nested})` | 只扫描，返回 `ImportPlan`，用来先告诉用户几部作品几首曲目 |
| `importWorksFromRoot(String rootPath, {bool nested})` | 走 `PlanImporter` 落库后 `refresh()`；与普通导入共用 `_beginImport` 互斥标志，正在导入时返回 null |

首页 AppBar 加「从目录导入作品」按钮（`home-import-works`）：选目录 → 扫描 → 确认对话框 → 导入 → 提示新建/跳过数量。测试 `test/state/app_state_import_root_test.dart` 3 例（扫描计数、导入后进列表且二次全跳过、根目录无作品时不建行）。

### DLsite 抓取（`a10d152`）

`AppState.fetchDlsiteMetadata(int workId, {bool applyCover})`：编号优先取作品目录名解析出的，没有再看 `work_metadata.rj_code`；没有编号时直接返回提示，不发请求。界面在作品工具条加「抓取 DLsite 元数据」按钮（`audio-toolbar-dlsite`，窄版进「更多」），结果用 SnackBar 提示，命中缓存会标出来。

`Work` 模型补了 `rootPath` 字段（表里早就有 `root_path`，模型一直没读）。测试 `test/state/app_state_dlsite_test.dart` 3 例（从目录名取编号并落库+打标签、无编号不发请求、二次命中缓存）。

验证：analyze 无问题、`flutter test` 591 例全过、`NO_XIPH_LIBS=1 flutter build linux --release` 成功。

## 2026-11-02 从文件里找封面

需求口径：刮削不到封面时从作品目录里找，`缩略图`、`特典` 这类文件夹里的图也算，名字不一定是「封面」；都找不到就取最靠近根目录的那张。找到后写成作品根目录下的封面文件。

`AppState.findLocalCoverForWork(int workId)`：

| 情况 | 结果 |
|---|---|
| 作品没有登记目录 | 返回「这部作品没有登记目录，找不了封面」 |
| 已经有封面 | 返回「这部作品已经有封面了」，不动文件 |
| 找到并写盘 | 写 `RJ294126_cover.<ext>`（无编号写 `cover.<ext>`），更新 `works.cover_path`，返回 null |
| 一张图都没有 | 返回「这个目录里没找到能当封面的图片」 |

界面在作品工具条加「从文件里找封面」按钮（`audio-toolbar-find-cover`，窄版进「更多」）。回退链与打分完全复用 `lib/services/cover_finder.dart` 与 `lib/services/cover_selector.dart`，界面层不重复实现。

一个实测结论：导入阶段本来就会写封面（`PlanImporter` 用扫描计划的 `coverPath`），所以这个入口主要用于「导入时没图、后来补了图」或「封面记录被清掉」的情况。测试 `test/state/app_state_find_cover_test.dart` 3 例（信号目录挑图并写盘、已有封面不动、无图给提示）。

验证：analyze 无问题、`flutter test` 594 例全过、Linux release 构建成功。

## 2026-11-02 去掉 crypto 依赖：缩略图缓存改用自带的稳定哈希

剥离指南阶段一的依赖清理列了三项：`image`、`exif`、`crypto`。前两项早已处理（`exif` 删掉；`image` 只留在 `dev_dependencies`，给缩略图缓存用例造 PNG 样张）。最后一项 `crypto` 原本还在，因为缩略图缓存文件名用 `sha256` 算。

改法：

| 项 | 之前 | 之后 |
|---|---|---|
| 哈希实现 | `sha256.convert(utf8.encode(path)).toString()`，64 位十六进制 | `lib/utils/stable_hash.dart` 的 `stableHashHex`，FNV-1a 64 位，16 位十六进制 |
| 依赖 | `crypto ^3.0.7` | 删除，`flutter pub get` 后依赖树少一个包 |
| 缓存文件名 | 64 位十六进制 + mtime | 16 位十六进制 + mtime |

为什么不用 `String.hashCode`：它是进程内实现，Dart 不保证跨版本、跨平台一致，拿它命名缓存文件会让同一路径在不同机器上落到不同文件。为什么不需要 sha256：这里只要一个短文件名，不承担密码学用途。哈希仍然走 `utf8` 字节，避免 `codeUnits` 的高位截断导致两条路径撞名（这条坑原来就写在注释里，新实现保持同样的处理）。

代价：缓存目录里旧的 64 位文件名会变成孤儿文件，占空间但不会读错；需要时用「清理缩略图缓存」按钮清掉。

测试：`test/utils/stable_hash_test.dart` 4 例（确定性、格式、高位码元不撞车、500 条路径无碰撞）。验证：analyze 无问题、`flutter test` 598 例全过、Linux release 构建成功。
