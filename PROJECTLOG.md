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
| 四 拆 AppState | 未开始 | — |
| 五 重做音频界面 | 未开始 | — |
| 六 接 DLsite | 未开始 | — |

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
