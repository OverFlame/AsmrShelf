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
