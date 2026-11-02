# AsmrShelf 项目建议步骤

本文写动手步骤。方案依据看 [BUILD_GUIDE.md](BUILD_GUIDE.md)，已完成记录看 [PROJECTLOG.md](PROJECTLOG.md)。

## 1 三份文档的分工

| 文档 | 回答什么 | 更新方式 |
| --- | --- | --- |
| BUILD_GUIDE.md | 为什么这么做 | 方案变了才改 |
| PROJECT_STEPS.md | 怎么动手，怎么验收 | 每阶段完成后回填状态 |
| PROJECTLOG.md | 已经做了什么 | 只追加 |

## 2 开工前的固定步骤

### 2.1 导出环境

每个新终端先跑这两行：

```bash
export PATH="$HOME/flutter/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/lib"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn PUB_HOSTED_URL=https://pub.flutter-io.cn
```

要碰 Android 再加一行：

```bash
export ANDROID_HOME="$HOME/Android/Sdk" ANDROID_SDK_ROOT="$HOME/Android/Sdk"
```

DSH 的终端跑 `bash -c`，不读 `~/.zshrc` 与 `~/.zshenv`。这两行要跟命令写在同一条里。

### 2.2 一个批次只推一个阶段

跨阶段混做，验收信号就说不清是哪一步带来的。

### 2.3 先立基线

```bash
git status --short
flutter analyze --no-fatal-infos
flutter test
```

三条都干净再动手。基线不干净就先修基线，单独提交一次。

### 2.4 先把验收命令写出来

动手前把本阶段的验收命令写进 PROJECTLOG 草稿。写不出命令，说明这一步还没想清楚。

## 3 收工步骤

按顺序做，缺一步不算收工：

| 步 | 动作 |
| --- | --- |
| 1 | 跑本阶段验收命令，留下原始输出 |
| 2 | `flutter analyze --no-fatal-infos` 无 error，info 数不超过基线 |
| 3 | `flutter test` 全过 |
| 4 | 追加 PROJECTLOG 记录，写日期、目标、动作、验证 |
| 5 | 中文正文过一遍 ste-lint-zh |
| 6 | 写中文提交信息，然后提交 |

## 4 阶段总览

| 阶段 | 目标 | 状态 |
| --- | --- | --- |
| 0 | 建仓与改名 | 已完成，提交 `7f155ab` |
| 1 | 依赖合并 | 已完成，提交 `c2ec53c` |
| 2 | 数据层统一 | 已完成，提交 `5b36a64` |
| 3 | 迁移服务 | 已完成，提交 `586a72f` |
| 4 | 图片栈迁入 | 已完成，提交 `1317c9e`（含阅读器与字幕解析） |
| 5 | 视频识别与外链 | 已完成，提交 `1317c9e` |
| 6 | 统一 AppState | 已完成，提交 `1317c9e`（含阅读进度与字幕归属） |
| 7 | 设置、主题与页面 | 已完成，提交 `1317c9e` |
| 8 | 打包与 CI | 已完成，提交 `1317c9e`（CI 按用户要求并入阶段 9） |
| 9 | Android 验收 | 已完成，提交见下（CI 与 Android 外链分派） |
| 10 | 播放模式补全 | 已完成，提交 `a7ce52d` |
| 11 | 外链播放列表 | 已完成，提交 `7dc6c75` |
| 12 | 收藏选段 | 已完成，提交 `95f2150`；插在阶段 4 前，见第 24.3 节 |

## 5 逐阶段步骤

### 阶段 1 依赖合并

依据：BUILD_GUIDE 第 5 节。

动作：

1. 按第 5.1 节的版本表改 `pubspec.yaml`。
2. 按第 5.2 节把 file_picker 升到 12.1.2。
3. 按第 5.3 节处理 sqlite3 来源。

验收：

```bash
flutter pub get
grep -A3 '^  file_picker:' pubspec.lock
grep -A3 '^  sqflite_common_ffi:' pubspec.lock
flutter analyze --no-fatal-infos
```

通过标准：`file_picker` 为 12.1.2，`sqflite_common_ffi` 为 2.4.2+1，analyze 无 error。

### 阶段 2 数据层统一

依据：BUILD_GUIDE 第 7 节、第 17 节与第 18 节。

动作：

1. 写 `lib/db/tables.dart` 的 v5 内容，`Tables.version` 取 5。
2. `media` 单表带 `media_type` 四值，另加 `ext` 与 `name_lower` 列及索引；`folders` 与 `works` 各加 `library` 列。
3. 新建 `lib/db/media_dao.dart`。
4. 合并 `lib/db/tag_dao.dart` 与 `lib/db/folder_dao.dart`，反查带库条件；标签表达式解析器识别 `kind` 与 `ext` 两个规则 namespace。
5. 改 `lib/db/database.dart:48` 的库文件名与 PRAGMA 写法。

验收：

```bash
flutter test
flutter analyze --no-fatal-infos
```

通过标准：建库成功，`PRAGMA integrity_check` 返回 ok，老用例改到 `media` 后全过，analyze 无 error。

结果（2026-09-27）：

- `flutter analyze --no-fatal-infos`：6 条 info，0 error，与阶段 0 基线逐条相同。
- `flutter test`：75 用例全过，阶段 0 与阶段 1 的基线是 72。
- 新用例里的 `PRAGMA integrity_check` 返回 ok。
- `pubspec.yaml` 版本号改 `0.3.0+3`。

风险：

- WAL 语句必须用 `rawQuery`，见第 14 节。
- FFI 初始化只在 Windows 与 Linux 做，要加平台守卫。
- 外键开关放 `onConfigure`。
- 反查不带库条件时，两棵树的节点会互相抢，见 BUILD_GUIDE 第 18.2 节。
- 字幕改成 media 行后，涉及 `tracks.subtitle_path` 的老用例要跟着改。

### 阶段 3 迁移服务

依据：BUILD_GUIDE 第 8 节。

动作：

1. 新建 `lib/services/migration_service.dart`，Dart 侧跨库只读 SELECT，事务写新库。
2. 新建 `tool/migrate_check.dart`，做第 8.5 节的五类断言。
3. PictureViewer2 的文件夹树挂到新建根「图片库」下，避开 `folders` 的唯一约束。

验收：

```bash
dart run tool/migrate_check.dart --src-a <老库 A> --src-b <老库 B> --dst <新库>
```

通过标准：五类检查全过，见第 8.5 节。

风险：

- 老库不要就地升级。两边版本号都是 4，表结构不同。
- 迁移前先读 `.datadir` 指针文件，两边数据根不一样。

### 阶段 10 播放模式补全

依据：BUILD_GUIDE 第 24.1 节。

动作：

1. 在 `lib/state/player_controller.dart` 加洗牌队列、队列编辑三个方法与速度控制。
2. 在 `lib/services/settings_service.dart` 加 `repeat_mode`、`shuffle`、`play_speed` 三个键。
3. 在 `lib/widgets/player_bar.dart` 加速率与队列按钮，新建 `lib/widgets/queue_panel.dart`。
4. 在文件夹与作品菜单加连播入口，调用 `lib/state/app_state.dart:958` 的 `playTracks`。

验收：

```bash
flutter test test/state
flutter analyze --no-fatal-infos
```

通过标准：洗牌不重复、队列删除与重排、速度边界、模式回读四组用例通过。

结果（2026-09-28）：

- `flutter analyze --no-fatal-infos`：6 条 info，0 error。
- `flutter test`：102 用例全过，阶段 3 的基线是 84。
- 提交 `a7ce52d`，`pubspec.yaml` 版本号改 `0.5.0+10`。
- 踩坑两条：`RepeatMode` 与 Flutter 同名枚举冲突，要 `hide`；`ReorderableListView.onReorder` 已废弃，改用 `onReorderItem`。

### 阶段 11 外链播放列表

依据：BUILD_GUIDE 第 24.2 节。

动作：

1. 新建 `lib/services/playlist_writer.dart`，写 UTF-8 的 m3u8 到数据目录 `playlist/`。
2. 新建 `lib/services/video_launcher.dart`，按第 9.4 节做平台分派。
3. 在剧集与卷的右键菜单加「用外部播放器播放」。

验收：

```bash
flutter test test/services
flutter analyze --no-fatal-infos
```

通过标准：m3u8 行序与命令参数用例通过。真机验收在 Windows 机器上补做。

结果（2026-09-28）：

- `flutter analyze --no-fatal-infos`：6 条 info，0 error。
- `flutter test`：111 用例全过，阶段 10 的基线是 102。
- 提交 `7dc6c75`，`pubspec.yaml` 版本号改 `0.6.0+11`。
- 覆盖缺口：Windows 真机未验，播放器参数三项待实测。

### 阶段 12 收藏选段

依据：BUILD_GUIDE 第 24.3 节。

动作：

1. 加 `media_segments` 表与索引，随 `media` 的下一版增量走。
2. 新建 `lib/services/segment_service.dart`，管起止校验与优先级判定。
3. 在播放条加选区按钮与段列表。

验收：

```bash
flutter test test/services test/state
flutter analyze --no-fatal-infos
```

通过标准：起止换算、越界收口、优先级判定用例通过。

结果（2026-09-28）：

- `flutter analyze --no-fatal-infos`：6 条 info，0 error。
- `flutter test`：143 用例全过，阶段 11 的基线是 111。
- 提交 `95f2150`，`pubspec.yaml` 版本号改 `0.7.0+12`。
- 覆盖缺口：Windows 与 Android 真机未验，窄屏下「选区」按钮的位置未覆盖。

### 阶段 4 图片栈迁入

依据：BUILD_GUIDE 第 10.1 节的模块映射。

动作：

1. 按第 10.1 节的表迁入图片相关模块，`lib/services/data_dir_service.dart` 仍用 AudioShelf 版为底。
3. 做系列、卷与封面：`folders.cover_path` 与 `cover_crop` 增量、卷封面与手动指定。自定义裁剪、系列导入入口与特典自动标签见 BUILD_GUIDE 第 19 与 21 节。
4. 做自然排序与扩展名：`media.sort_key`、音频补 FLAC／M4A／AAC／OGG／OPUS、图片补 HEIC／AVIF，见 BUILD_GUIDE 第 20 节。
5. 做阅读器核心：`folders.reading_direction` 与 `reading_fit`、`reading_spreads` 表、查看器改造与阅读入口，见 BUILD_GUIDE 第 22 节。
6. 做字幕解析与匹配：加 `fast_gbk` 依赖、编码探测链、解析器注册表、LRC 两项增强、匹配规则三项，见 BUILD_GUIDE 第 23 节。

验收：

```bash
flutter test test/services test/utils
flutter analyze --no-fatal-infos
```

通过标准：缩略图与 EXIF 用例通过。手动打开一张图片，缩略图与 EXIF 面板正常。

风险：缩略图目录可能有几万个小文件，回收放后台，别阻塞启动。

### 阶段 5 视频识别与外链

依据：BUILD_GUIDE 第 9 节与第 17 节。

动作：

1. 在 `lib/services/file_scanner.dart` 加 `videoExtensions` 与 `mediaTypeOfPath`。
2. 新建 `lib/services/video_launcher.dart`，`start` 可注入。
3. 新建 `lib/widgets/video_grid.dart` 并接入卡片，缩略图用 `Icons.movie`。
4. 新建 `test/services/video_launcher_test.dart`，注入假 `start`。

验收：

```bash
flutter test test/services/video_launcher_test.dart
```

通过标准：假 runner 的断言全过。Windows 与 Linux 各手动拉起一次外部播放器。

风险：Android 外链不能用 `file://` URI，见第 9.5 节。

### 阶段 6 统一 AppState

依据：BUILD_GUIDE 第 10 节与第 7.4 节。

动作：

1. 以 PictureViewer2 的 `lib/state/app_state.dart` 为底。
2. 并入 AudioShelf 的作品集、字幕、播放队列、选择集。
3. 删掉第 7.4 节的过渡视图，并改按 `media` 表名清理那段删除逻辑。
5. 做阅读进度：`reading_progress` 表与节流写入、卷层「阅读」入口、本卷图片区联动，见 BUILD_GUIDE 第 22.6 与 22.7 节。
6. 做字幕归属：`media.subtitle_of` 与 `is_default_subtitle` 两列、默认项选择、多字幕切换，见 BUILD_GUIDE 第 23.6 节。

验收：

```bash
flutter test test/state test/widget
```

通过标准：`tag_filter` 用例通过。`app_smoke_test` 与 `narrow_window_test` 通过。

### 阶段 7 设置、主题与页面

依据：BUILD_GUIDE 第 12 节与第 13 节。

动作：

1. 合并 `lib/pages/settings_page.dart` 与 `lib/pages/home_page.dart`。
2. 主题先用 `lib/theme/app_theme.dart`，Catppuccin 留作可选。
3. 存储改落 `<应用根>/data/` 与 `<应用根>/logs/`，路径只从 `DataDirService` 解析。
4. 支持 `APP_DATA_DIR` 与 `APP_LOG_DIR` 覆盖。

验收：

```bash
flutter analyze --no-fatal-infos
flutter test
```

通过标准：设置页能改主题与缓存上限。切换数据目录并重启后，新目录生效。

风险：这一步会动数据目录名。开工前先问用户，见第 9 节。

### 阶段 8 打包与 CI

依据：BUILD_GUIDE 第 6.2、6.3、6.5 节。

动作：

1. 迁入 `scripts/build_linux.sh` 与 `scripts/build_windows_remote.sh`。
2. 迁入 `.github/workflows/ci.yml`。

验收：

```bash
bash scripts/build_linux.sh --mode release
ls build/linux/x64/release/bundle/
```

通过标准：bundle 目录存在，可执行文件能启动。CI 在远端跑绿。

风险：Linux 构建必须带 `NO_XIPH_LIBS=1`。

### 阶段 9 Android 验收

依据：BUILD_GUIDE 第 6.4 与第 9.5 节。

动作：

1. 补 Intent 与 FileProvider 分派。
2. 验证「所有文件访问」权限下的扫描。
3. 包名与 Kotlin 目录已在阶段 0 改完，不要重复改。
4. 建 CI，见 BUILD_GUIDE 第 6.5 节。

验收：

```bash
flutter build apk --release
```

通过标准：实机能扫描一个目录，能拉起外部播放器。

已落地的部分：

| 项 | 落点 |
| --- | --- |
| 外链分派 | `android/app/src/main/kotlin/com/asmrshelf/asmrshelf/MainActivity.kt` 的 `openVideo` 与 `openWithSystemPlayer()` |
| URI | FileProvider 生成 `content://`，只授一次读权限，不用 `file://` |
| 共享目录 | `android/app/src/main/res/xml/file_paths.xml`（external / external-files / files / cache） |
| 包可见性 | manifest 的 `queries` 声明 `ACTION_VIEW` 配 `video/*` 与 `application/x-mpegurl` |
| Dart 侧 | `lib/services/video_launcher.dart`：`detectOs()` 认 Android，`open()` 走通道 `asmrshelf/playback` 的 `openVideo` |
| MIME | `VideoLauncher.mimeByExtension` 按扩展名给，认不出给 `video/*` |
| CI | `.github/workflows/ci.yml`，固定 Flutter 3.47.5，先装 `libsqlite3-dev` |

待设备确认：本机 `adb devices` 为空，没有 Android 真机与模拟器。
「实机能扫描一个目录、能拉起外部播放器」这条只能由用户在设备上核对。

## 6 原生代码的额外验收

`analysis_options.yaml` 排除了 android、linux、windows。改了这三个目录，analyze 与 test 都覆盖不到。

改完就跑一次真构建。

```bash
NO_XIPH_LIBS=1 flutter build linux --release
flutter build apk --debug
```

再做一次产物级核对。

```bash
aapt2 dump badging build/app/outputs/flutter-apk/app-debug.apk | grep -E '^package|application-label|launchable-activity'
```

阶段 0 踩过一条：第一轮全树搜旧名字时漏掉了 `windows/runner/Runner.rc`。原因是 grep 加了 include 白名单。全树搜旧名字不要加白名单。

## 7 验收命令速查

| 阶段 | 命令 | 通过标准 |
| --- | --- | --- |
| 1 | `flutter pub get` 加两条 grep | 版本号对得上 |
| 2 | `flutter test test/db` | `integrity_check` 返回 ok |
| 3 | `dart run tool/migrate_check.dart` | 五类检查全过 |
| 4 | `flutter test test/services test/utils` | 缩略图与 EXIF 用例过 |
| 5 | `flutter test test/services/video_launcher_test.dart` | 假 runner 断言过 |
| 6 | `flutter test test/state test/widget` | 标签筛选与冒烟用例过 |
| 7 | `flutter analyze` 加 `flutter test` | 设置生效 |
| 8 | `bash scripts/build_linux.sh --mode release` | bundle 可启动 |
| 9 | `flutter build apk --release` | 实机可用 |

## 8 提交与报告口径

提交信息用中文，写清动词与范围。示例：`chore: 阶段 0 建仓与改名（AudioShelf → AsmrShelf）`。

一个阶段一个提交，不带无关改动。

### 8.1 版本号规则

`pubspec.yaml` 的版本号是三段式加构建号，构建号与 Android 的 versionCode 对齐。

| 段 | 规则 |
| --- | --- |
| 主版本 | 首个可用版本前保持 0 |
| 次版本 | 每完成一个阶段加 1 |
| 修订号 | 阶段内的小修加 1 |
| 构建号 | `+` 后跟阶段序号加 1 |

阶段 0 记作 `0.1.0+1`，阶段 1 记作 `0.2.0+2`，阶段 9 收尾到 `1.0.0`。每阶段收工时改一次。版本号只在 `pubspec.yaml` 维护。

交付报告按这个形状写：

| 顺序 | 内容 |
| --- | --- |
| 1 | 第一行是读者的下一步动作 |
| 2 | 改了什么，带 `file:line` |
| 3 | 验证，写用例数与命令输出 |
| 4 | 覆盖缺口，写没做到的事 |
| 5 | KPI 方框 |
| 6 | 结尾报 ste-lint 分数 |

中文正文按 ASD-STE100 中文版写。检查命令：

```bash
python3 ~/.dsh/skills/asd-ste100-zh/scripts/ste-lint-zh.py --shape <文件>
```

阶段 0 踩过一条：单条列表超过 5 项，ste-lint 判成 `action_list`。长清单改成表格。

## 9 每阶段开工前要问用户的未决项

| 阶段 | 要确认什么 |
| --- | --- |
| 7 | 数据目录是否统一到新名字 |
| 7 | 设置是否改用 shared_preferences |
| 7 | 主题用原创主题还是 Catppuccin |
| 8 到 9 | 远端仓库所有者与 CI 平台 |
| 9 | Android 何时开始验收 |

用户给出 UI 布局前，BUILD_GUIDE 第 12 节是占位。

## 10 现状与下一步

已确认：项目名 AsmrShelf，骨架 AudioShelf，单库加迁移脚本，Windows 与 Linux 优先，视频 v1 只拉外部播放器。

远端是 `git@github.com:OverFlame/AsmrShelf.git`。`main` 是唯一开发分支，直接推送。`master` 已退役。

分类查找走规则标签加 `media` 列条件，库归属走 `folders.library` 与 `works.library`，口径见 BUILD_GUIDE 第 18 节。

`LICENSE` 是 MIT 原文，BUILD_GUIDE 第 15 节里那条 BSD 3-Clause 署名问题不存在。

阶段 4 到阶段 8 已完成，提交 `1317c9e`。CI 按用户要求并入阶段 9。

删除文件夹与删除作品改成深度删除，`0.8.1+14`。软件内的文件夹、子文件夹与其中媒体记录一起移除，磁盘文件不动。

三库各自的列表分层与查询分流修好，`0.8.2+15`。作品按库过滤，视觉库作品层只平铺媒体，视频库的文件夹层与搜索走视频类型。

视频库标签入口补齐，`0.8.3+16`。视频卡片菜单能直接打标签，标签筛选与高级筛选对视频同样生效。

阶段 9 完成 Android 外链分派与 CI，`1.0.0+17`。全部阶段到此收工。

标签管理与多选批量操作补齐，`1.1.0+18`。标签面板按命名空间折叠（默认收起 `ext`，状态持久化），规则标签只给折叠，自建标签可改名 / 改色 / 删除（删除前报会解除多少条关联），新建标签按库里已有的命名空间联想并在同名时提醒。图片 / 视频磁贴长按进多选，曲目工具栏也能开多选，选择条支持全选、批量加标签、移除标签、从软件移除记录（磁盘文件不动）。

剩下两项只能在设备上确认。Windows 侧跑 `scripts\build_windows.ps1`，核对构建与外链播放。
Android 侧在真机上核对扫描与外部播放器（本机没有设备）。

标签对话框折叠、左栏固定表头与图片/视频库标签栏，`1.2.0+19`。作品打标签的对话框改成按命名空间分组、标题可收起（搜索时忽略折叠，折叠状态与左栏共用）；左栏标签面板的表头、搜索框与筛选条固定在顶上，只有标签列表滚，窗口太矮时退回整体滚；图片库与视频库的左栏加「文件夹 / 标签」两个页签，各库分别记住自己的选择；浅色主题补齐网格、列表、详情与对话框的配色（全屏查看器仍保持深色底）。

看图模式与视觉库排序修好，`1.3.0+20`。缩略图服务的 `init()` 此前从没被调用过，导致进库不出缩略图、图片详情预览失效、缓存用量读不到，现由 `AppState.init()` 负责启动，没初始化就读目录改成明确报错；查看器不再被手势拖出视口（边界收成零、缩放区间 1 到 20 倍、缩回最小自动归位），滑动翻页同时认速度与拖够屏宽 18%，顶栏 / 底栏 / EXIF 面板都给状态栏与导航条留白；`sort_key` 是加列时留下的空值，老库启动时统一回填，作品层的排序也不再被文件名字符串序覆盖；图片库与视频库的工具栏新增排序（文件名 / 修改时间 / 文件大小 / 加入时间，可反序，按库记住），查看器翻页时详情面板跟着走。这一轮起不再跑 `dart format`（本机新 SDK 的 tall 样式会重排整个仓库）。
