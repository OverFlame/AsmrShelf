# AsmrShelf 构建指南

本文件写给接手实现的 AI 代理。
路径以 /home/hoshi/code 为根。
先读第 1 节到第 3 节。
再按第 11 节的阶段顺序动手。

## 1 目标与范围

AsmrShelf 合并两个现有应用。
两边都是本地媒体库。
合并后统一管理音频、图片、视频。
工作目录固定为 /home/hoshi/code/AsmrShelf。

已确认的范围：

| 项 | 决定 |
|---|---|
| 骨架 | AudioShelf |
| 项目名 | AsmrShelf |
| pubspec 名 | asmrshelf |
| 数据库 | 单一新库 asmr_shelf.db，另写迁移脚本 |
| 平台 | Windows 与 Linux 优先 |
| 视频 v1 | 识别、列表、卡片、拉起外部播放器 |
| 视频缩略图 | 统一图标，不引入解码依赖 |
| Android | 保留代码，首版不验收 |
| 许可证 | 暂定 MIT，见第 15 节 |

首版不做这些事：

- 在应用内解码与播放视频。
- 提取视频首帧。
- 读视频时长与分辨率。
- iOS 与 macOS 平台目录。
- web 平台。

原因：内嵌视频播放器要引入原生解码栈。
外链播放器把这件事交给系统。
音频链路沿用现有实现，改动面最小。

## 2 现状事实

两个仓库同源分叉。
下面的数字与行号都已核对。

### 2.1 同一祖先

lib 下的目录同名：db/、pages/、services/、state/、theme/、utils/、widgets/。
文件也大量同名。

| 文件 | AudioShelf 行数 | PictureViewer2 行数 |
|---|---|---|
| lib/main.dart | 90 | 85 |
| lib/db/database.dart | 92 | 80 |
| lib/db/tables.dart | 190 | 119 |
| lib/db/folder_dao.dart | 308 | 274 |
| lib/db/tag_dao.dart | 351 | 386 |
| lib/services/data_dir_service.dart | 163 | 113 |
| lib/services/file_scanner.dart | 137 | 77 |
| lib/services/import_service.dart | 239 | 343 |
| lib/services/settings_service.dart | 142 | 179 |
| lib/state/app_state.dart | 1172 | 1085 |
| lib/utils/filter_expression.dart | 263 | 317 |
| lib/utils/log_util.dart | 76 | 83 |
| lib/widgets/tag_panel.dart | 816 | 821 |

lib 目录总量：AudioShelf 7566 行。
PictureViewer2 10805 行。

两边 lib 内部用相对导入。
只有测试用 package: 前缀。
AudioShelf 有 16 个测试文件用 package:audioshelf/。
PictureViewer2 有 18 个测试文件用 package:pictureviewer/。

### 2.2 数据库冲突

这是第一难点。

| 冲突 | 证据 |
|---|---|
| 库文件名不同 | AudioShelf/lib/db/database.dart:48 写 audioshelf.db；PictureViewer2/lib/db/database.dart:32 写 pv2.db |
| 版本号相同 | 两份 lib/db/tables.dart:5 都写 version = 4 |
| 四张表重名 | tags、folders、folder_paths、folder_tags |
| folders 的列不同 | AudioShelf/lib/db/tables.dart:26 有 work_id；PictureViewer2/lib/db/tables.dart:57 没有 |
| folder_paths.recursive 默认值不同 | AudioShelf/lib/db/tables.dart:36 默认 0；PictureViewer2/lib/db/tables.dart:70 默认 1 |
| 唯一索引名不同 | AudioShelf/lib/db/tables.dart:41 用 idx_folder_paths_unique；PictureViewer2/lib/db/tables.dart:74 用 idx_folder_paths_uniq |
| 媒体表不同名 | AudioShelf 用 tracks；PictureViewer2 用 images |
| 播放历史指向曲目 | AudioShelf/lib/db/tables.dart:100 的 play_history.track_id 引用 tracks |

结论：直接叠加两边的 DDL 会失败。
统一表结构见第 7 节。
迁移方案见第 8 节。

### 2.3 数据目录

两个应用的数据根不同。

| 应用 | 默认根 | 库文件名 | 指针文件 |
|---|---|---|---|
| AudioShelf | getApplicationSupportDirectory()/AudioShelf | audioshelf.db | .datadir |
| PictureViewer2 | getApplicationDocumentsDirectory()/PictureViewer | pv2.db | .datadir |

证据：AudioShelf/lib/services/data_dir_service.dart:29 与 :30。PictureViewer2/lib/services/data_dir_service.dart:30 与 :31。
Linux 上两个根的差异是 ~/.local/share 与 ~/Documents。
指针文件路径由 AudioShelf/lib/services/data_dir_service.dart:33 给出。
指针文件始终位于默认根下，内容是实际数据目录。

### 2.4 独有能力

AudioShelf 独有：

| 能力 | 位置 |
|---|---|
| 音频播放控制器 | lib/state/player_controller.dart:15 |
| Android 前台服务与媒体会话 | lib/services/media_bridge.dart:31 |
| 字幕解析 | lib/services/subtitle_parser.dart:22 |
| 音频元数据 | lib/services/metadata_service.dart:30 |
| 封面写入与限制 | lib/services/cover_service.dart:10 |
| 作品集 | lib/db/work_dao.dart:5 |
| 播放条 | lib/widgets/player_bar.dart |
| 文件夹浏览 | lib/widgets/folder_browser.dart |
| 字幕页 | lib/pages/subtitle_page.dart |

PictureViewer2 独有：

| 能力 | 位置 |
|---|---|
| 三层缩略图缓存 | lib/services/thumbnail_cache.dart:52 |
| EXIF 数据 | lib/services/exif_service.dart:90 |
| 图片查看器 | lib/widgets/image_viewer.dart |
| 图片详情 | lib/widgets/image_detail.dart |
| 桌面拖放 | lib/pages/home_page.dart:73 |
| 颜色工具 | lib/utils/color_util.dart |
| 图像缓存工具 | lib/utils/image_cache_util.dart |
| 原子写文件 | lib/utils/file_io.dart |
| 路径比较与重名 | lib/utils/path_util.dart |
| LIKE 转义 | lib/db/sql_like.dart |
| CI | .github/workflows/ci.yml |
| 表达式深度护栏 | lib/utils/filter_expression.dart:167 |

最后一行的差别要注意。
PictureViewer2 的解析器带 maxDepth = 256。
AudioShelf 的版本没有这道护栏。
迁入时取 PictureViewer2 的版本。

### 2.5 测试

| 仓库 | 测试文件 | 用例数 |
|---|---|---|
| AudioShelf/test | 17，另有 test/support 1 个辅助文件 | 72 |
| PictureViewer2/test | 18 | 127 |

PictureViewer2 有两个大用例：
test/widget/narrow_window_test.dart，312 行。
test/perf/library_scale_test.dart，291 行。

## 3 命名与仓库

| 项 | 值 |
|---|---|
| 目录 | /home/hoshi/code/AsmrShelf |
| pubspec 名 | asmrshelf |
| MaterialApp title | AsmrShelf |
| Android namespace | com.overflame.asmrshelf |
| Android applicationId | com.overflame.asmrshelf |
| 远端建议 | git@github.com:<用户名>/AsmrShelf.git |
| 默认分支 | main |

改名步骤见下表。

| 步 | 动作 |
|---|---|
| 1 | 改 pubspec 的 name 字段 |
| 2 | 改 android/app/build.gradle.kts:8 的 namespace |
| 3 | 改 android/app/build.gradle.kts:19 的 applicationId |
| 4 | 移 Kotlin 目录到 com/asmrshelf/asmrshelf/ |
| 5 | 改 Kotlin 文件首行的 package 声明 |
| 6 | 替换测试文件的 package:audioshelf/ 前缀 |
| 7 | 改 AndroidManifest.xml 里 .MainActivity 与 .PlaybackService 的引用 |

lib 内部用相对导入，改名不动 lib。

## 4 目标目录结构

```
AsmrShelf/
├── BUILD_GUIDE.md
├── PROJECTLOG.md
├── README.md
├── pubspec.yaml
├── analysis_options.yaml
├── .gitignore
├── android/                     # 迁自 AudioShelf，改包名
├── linux/                       # 迁自 AudioShelf
├── windows/                     # 迁自 AudioShelf
├── .github/workflows/ci.yml     # 迁自 PictureViewer2
├── lib/
│   ├── main.dart
│   ├── db/
│   │   ├── database.dart
│   │   ├── folder_dao.dart
│   │   ├── media_dao.dart       # 新建：合并 track_dao 与 image_dao
│   │   ├── sql_like.dart        # 迁自 PictureViewer2
│   │   ├── tables.dart          # 重写为 v5
│   │   ├── tag_dao.dart
│   │   └── work_dao.dart
│   ├── pages/
│   │   ├── about_page.dart
│   │   ├── home_page.dart
│   │   ├── settings_page.dart
│   │   └── subtitle_page.dart
│   ├── services/
│   │   ├── cover_service.dart
│   │   ├── data_dir_service.dart
│   │   ├── exif_service.dart
│   │   ├── file_scanner.dart
│   │   ├── import_service.dart
│   │   ├── media_bridge.dart
│   │   ├── metadata_service.dart
│   │   ├── migration_service.dart   # 新建
│   │   ├── settings_service.dart
│   │   ├── subtitle_parser.dart
│   │   ├── thumbnail_cache.dart
│   │   └── video_launcher.dart      # 新建
│   ├── state/
│   │   ├── app_state.dart
│   │   └── player_controller.dart
│   ├── theme/
│   │   ├── app_theme.dart
│   │   └── catppuccin.dart
│   ├── utils/
│   │   ├── color_util.dart
│   │   ├── file_io.dart
│   │   ├── filter_expression.dart
│   │   ├── format.dart
│   │   ├── image_cache_util.dart
│   │   ├── log_util.dart
│   │   └── path_util.dart
│   └── widgets/
│       ├── color_picker_dialog.dart
│       ├── cover_image.dart
│       ├── dialogs.dart
│       ├── export_actions.dart
│       ├── filter_dialog.dart
│       ├── folder_browser.dart
│       ├── folder_panel.dart
│       ├── image_detail.dart
│       ├── image_grid.dart
│       ├── image_viewer.dart
│       ├── move_folder_dialog.dart
│       ├── player_bar.dart
│       ├── tag_panel.dart
│       ├── tag_picker_dialog.dart
│       ├── video_grid.dart          # 新建
│       └── works_grid.dart
├── scripts/
│   ├── build_android.sh
│   ├── build_linux.sh
│   ├── build_windows.ps1
│   ├── build_windows_remote.sh
│   └── pack_for_windows.sh
├── tool/
│   └── migrate_check.dart           # 新建
└── test/
    ├── db/
    ├── perf/
    ├── services/
    ├── state/
    ├── support/
    ├── utils/
    └── widget/
```

data/ 与 logs/ 是运行期目录，不入库。

## 5 依赖合并

### 5.1 版本表

| 依赖 | AudioShelf | PictureViewer2 | AsmrShelf |
|---|---|---|---|
| flutter SDK | ^3.12.0 | ^3.12.2 | ^3.12.2 |
| cupertino_icons | ^1.0.8 | ^1.0.8 | ^1.0.8 |
| provider | ^6.1.5+1 | ^6.1.5+1 | ^6.1.5+1 |
| sqflite | ^2.4.3 | ^2.4.3 | ^2.4.3 |
| sqflite_common_ffi | ^2.4.2+1 | ^2.4.2 | ^2.4.2+1 |
| path_provider | ^2.1.6 | ^2.1.6 | ^2.1.6 |
| path | ^1.9.1 | ^1.9.1 | ^1.9.1 |
| file_picker | ^12.1.2 | ^11.0.2 | ^12.1.2 |
| shared_preferences | ^2.5.5 | ^2.5.0 | ^2.5.5 |
| audio_metadata_reader | ^1.7.1 | 无 | ^1.7.1 |
| flutter_soloud | ^4.1.7 | 无 | ^4.1.7 |
| crypto | 无 | ^3.0.7 | ^3.0.7 |
| image | 无 | ^4.9.1 | ^4.9.1 |
| desktop_drop | 无 | ^0.4.4 | ^0.4.4 |
| exif | 无 | ^3.3.0 | ^3.3.0 |
| flutter_lints (dev) | ^6.0.0 | ^6.0.0 | ^6.0.0 |
| path_provider_platform_interface (dev) | ^2.1.3 | 无 | ^2.1.3 |

锁文件里解析到的版本：
file_picker 在 AudioShelf 是 12.1.2，在 PictureViewer2 是 11.0.3。
sqflite_common_ffi 在 AudioShelf 是 2.4.2+1，在 PictureViewer2 是 2.4.2。

### 5.2 file_picker 升级

两边都用静态调用形式。

- PictureViewer2/lib/widgets/folder_panel.dart:336 用 FilePicker.pickFiles。
- PictureViewer2/lib/widgets/image_grid.dart:151 用 FilePicker.getDirectoryPath。
- AudioShelf/lib/widgets/dialogs.dart:43 用 FilePicker.pickFile。
- AudioShelf/lib/widgets/dialogs.dart:59 用 FilePicker.getDirectoryPath。

调用形式相同，升级风险低。
迁入后跑 flutter analyze 确认。

### 5.3 sqlite3 来源

两边的写法不同。

AudioShelf/pubspec.yaml:26 到 :30：

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
      name_windows: winsqlite3
```

PictureViewer2/pubspec.yaml:105 到 :111：

```yaml
hooks:
  user_defines:
    sqlite3:
      source:
        windows: sqlite3
        linux: system
        macos: system
```

采用 AudioShelf 的写法。
原因：Windows 上用系统 winsqlite3.dll，构建不访问 GitHub。
PictureViewer2 的 Windows 分支要求 sqlite3.dll 就位。
那是 scripts/build_windows.ps1 下载的。
迁入打包脚本时删掉那段下载。

## 6 平台与构建

### 6.1 本机环境

Flutter 3.47.5 与 Dart 3.13.4 装在 ~/flutter。
构建前先导出：

```bash
export PATH="$HOME/flutter/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
```

DSH 的 bash 工具不读 ~/.zshrc。
每次都要在命令里导出。

### 6.2 Linux

必须导出 NO_XIPH_LIBS=1。
AudioShelf/scripts/build_linux.sh:17 已有这一行。
原因：flutter_soloud 自带的 libopus 在 glibc 2.43 上编译。
Ubuntu 24.04 只有 glibc 2.39。
禁用后规避运行时加载失败。

构建脚本以 PictureViewer2/scripts/build_linux.sh 为底。
它有 259 行，带参数解析、日志与 sqlite3 探测。
选项说明见该文件第 10 行。
--sqlite 的取值见第 44 行。
默认取值 system，不访问 GitHub。
产物在 build/linux/<架构>/<模式>/bundle/。

合并时保留 NO_XIPH_LIBS，删除 --sqlite download 分支。

### 6.3 Windows

sqlite3 用 winsqlite3.dll，见第 5.3 节。
打包脚本迁 PictureViewer2/scripts/pack_for_windows.sh。
构建脚本用 scripts/build_windows.ps1。
删掉下载 sqlite3.dll 的步骤。

### 6.4 Android（延后）

保留 android/ 目录。
保留的权限见 AudioShelf/android/app/src/main/AndroidManifest.xml：
第 3 行所有文件访问，第 14 行与第 15 行前台服务，第 16 行通知。
保留 AudioShelf/android/app/src/main/kotlin/com/audioshelf/audioshelf/PlaybackService.kt。
首版只做改名，不验收。

### 6.5 CI

迁 PictureViewer2/.github/workflows/ci.yml。
它装 libsqlite3-dev，见第 22 行。
它固定 Flutter 3.47.5，见第 27 行。
它用 --no-fatal-infos 放行 info，见第 36 行。
它跑 flutter test，见第 39 行。

## 7 数据层设计

### 7.1 决策

- 用单表 media 存音频、图片、视频与字幕。
- 标签表 tags 与关联表 media_tags 通用。
- folders 与 works 各加 library 列，取值 audio、image、video。
- folders 保留 work_id 列，取值可空。
- 不保留 tracks 表与 images 表。

原因：标签、筛选、排序、文件夹树、选择集只写一套代码。
分三张表会把 AppState 的双套逻辑变成三套。

库归属、规则标签与导入入口的完整口径见第 18 节。

### 7.2 版本策略

Tables.version 从 5 开始。
createStatements 写入合并后的完整 DDL。
migrations 只保留 5 之后的增量。
老库不做就地升级，走第 8 节的导入流程。
原因：两边版本号都是 4，但语义不同。

### 7.3 DDL（v5）

```sql
CREATE TABLE works (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT    NOT NULL,
  library     TEXT    NOT NULL CHECK (library IN ('audio', 'video')),
  cover_path  TEXT,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);

CREATE TABLE media (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  path          TEXT    NOT NULL UNIQUE,
  media_type    TEXT    NOT NULL CHECK (media_type IN ('audio', 'image', 'video', 'subtitle')),
  ext           TEXT    NOT NULL DEFAULT '',
  name_lower    TEXT    NOT NULL DEFAULT '',
  filename      TEXT    NOT NULL,
  format        TEXT,
  file_size     INTEGER,
  file_mtime    INTEGER,
  added_at      INTEGER NOT NULL,
  title         TEXT,
  artist        TEXT,
  album         TEXT,
  duration_ms   INTEGER,
  width         INTEGER,
  height        INTEGER,
  hash          TEXT,
  note          TEXT,
  alias         TEXT,
  subtitle_path TEXT,
  cover_path    TEXT
);
CREATE INDEX IF NOT EXISTS idx_media_type ON media(media_type);
CREATE INDEX IF NOT EXISTS idx_media_ext ON media(ext);
CREATE INDEX IF NOT EXISTS idx_media_name_lower ON media(name_lower);
CREATE INDEX IF NOT EXISTS idx_media_hash ON media(hash);
CREATE INDEX IF NOT EXISTS idx_media_added_at ON media(added_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_title ON media(title);

CREATE TABLE tags (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  namespace  TEXT    NOT NULL DEFAULT 'general',
  name       TEXT    NOT NULL,
  color      TEXT    NOT NULL DEFAULT '#cba6f7',
  UNIQUE(namespace, name)
);
CREATE INDEX IF NOT EXISTS idx_tags_namespace ON tags(namespace);
CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name);

CREATE TABLE media_tags (
  media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  tag_id   INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
  PRIMARY KEY (media_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_media_tags_tag ON media_tags(tag_id);

CREATE TABLE folders (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  name    TEXT    NOT NULL,
  parent  INTEGER REFERENCES folders(id),
  library TEXT    NOT NULL CHECK (library IN ('audio', 'image', 'video')),
  work_id INTEGER REFERENCES works(id) ON DELETE SET NULL,
  UNIQUE(name, parent)
);

CREATE TABLE folder_paths (
  folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  path      TEXT    NOT NULL,
  recursive INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_folder_paths_path ON folder_paths(path);
CREATE UNIQUE INDEX IF NOT EXISTS idx_folder_paths_unique
  ON folder_paths(folder_id, path);

CREATE TABLE folder_tags (
  folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  tag_id    INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
  PRIMARY KEY (folder_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_folder_tags_tag ON folder_tags(tag_id);

CREATE TABLE play_history (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  played_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_play_history_media ON play_history(media_id);
CREATE INDEX IF NOT EXISTS idx_play_history_time ON play_history(played_at);
```

与两边的差异清单：

| 项 | 处置 |
|---|---|
| tracks 与 images | 合并为 media，新增 media_type |
| track_tags 与 image_tags | 合并为 media_tags |
| play_history.track_id | 改名 media_id |
| folders.work_id | 保留 |
| folder_paths 默认值 | 取 1，与 PictureViewer2 一致 |
| 唯一索引名 | 统一用 idx_folder_paths_unique |
| tags 与 folder_tags | 与两边一致，不改 |
| media_type 取值 | 四值，含 subtitle |
| media 新增列 | ext 与 name_lower，各带索引 |
| works.library | 新增，取值 audio 或 video |
| folders.library | 新增，取值 audio、image 或 video |
| 字幕 | 从 tracks.subtitle_path 的列改为 media 行 |
| 查找口径 | 一律带 library 条件，见第 18 节 |

### 7.4 过渡视图（可选）

阶段 2 到阶段 5 之间可建两个只读视图。
这样能先跑通查询，再改写入路径。

```sql
CREATE VIEW tracks AS SELECT * FROM media WHERE media_type = 'audio';
CREATE VIEW images AS SELECT * FROM media WHERE media_type = 'image';
```

视图不能写。
写入必须走 MediaDao。
阶段 6 结束前删掉视图。

### 7.5 模型类

lib/db/media_dao.dart 定义 MediaType 与 MediaItem。
字段与 media 表一一对应。
可参考 AudioShelf/lib/db/track_dao.dart:5 与 PictureViewer2/lib/db/image_dao.dart:6。

### 7.6 缩略图补齐（2026-09-28 补）

缩略图默认 300 像素，落在缓存目录，按原图路径加尺寸哈希命名（lib/services/thumbnail_cache.dart:126）。
导入时不生成缩略图：几百张原图同步解码会把导入卡住。
导入一结束，AppState 把新路径交给后台队列（lib/state/app_state.dart:1561 的 `backfillThumbnails`）。

| 规则 | 内容 |
| --- | --- |
| 去重 | 同一路径只排队一次 |
| 并发 | 逐张串行；已有的文件跳过 |
| 通知 | 每补 8 张 `thumbEpoch` 加一，卡片据此重画 |
| 触发 | 导入后自动，以及每次进入新的库 / 文件夹 / 作品上下文（lib/widgets/image_grid.dart:207） |

老库的图在磁盘上没有缩略图，进入上下文时补一次，不必重启应用。

## 8 迁移方案

### 8.1 输入

| 来源 | 库文件名 | 默认位置 |
|---|---|---|
| AudioShelf | audioshelf.db | <应用支持目录>/AudioShelf |
| PictureViewer2 | pv2.db | <文档目录>/PictureViewer |

实际位置先读默认根下的 .datadir 指针文件。
指针文件机制见 AudioShelf/lib/services/data_dir_service.dart:33。

### 8.2 路线

新建 lib/services/migration_service.dart。
它在 Dart 侧跨库读取：只读打开老库，逐表 SELECT，事务内写新库。
不用 SQLite 的 ATTACH。
原因：便于单测，也避开 sqflite 的方言差异。

对齐键：

- media 用 path。path 在两边都有 UNIQUE 约束。
- tags 用 (namespace, name)。

导入顺序：

先导结构，顺序如下。

1. tags。
2. works。只来自 AudioShelf。
3. folders。
4. folder_paths。
5. folder_tags。

再导媒体，顺序如下。

1. media。AudioShelf 的 tracks 记为 audio，PictureViewer2 的 images 记为 image。
2. media_tags。
3. play_history。

每步都要 old_id 到 new_id 的映射表。

### 8.3 folders 的冲突处置

用 library 列区分两棵树的归属，见第 18.2 节。

- AudioShelf 的整棵树写入时 library 取 audio。
- PictureViewer2 的整棵树写入时 library 取 image，parent 保持原结构。
- 两边根文件夹各有自己的库，不会进入对方根列表。
- folder_paths 与 folder_tags 的 folder_id 按映射改写。
- 同一路径在两边都出现时得到两个 folders 行，各行 library 不同。

这样两边的路径映射、文件夹标签与根列表都能保住。
原方案「新建图片库合成根」在本节作废，原因是根列表要靠名字判身份。

### 8.4 冲突与失败处置

- 同一 path 出现在两个老库：保留先到者，写一条日志。
- media_type 与扩展名不符：按扩展名判定，写日志。
- 老库缺表或缺列：跳过该表，写日志，不中断整体迁移。
- 迁移不改老库。开始前把老库复制到 <老数据目录>/migration-backup-<时间戳>/。

### 8.5 校验

新建 tool/migrate_check.dart。
它报告并断言这些项：

- 源库的 path 集合与目标库的 path 集合相等。
- media 行数等于 tracks 行数加 images 行数。
- media_tags 行数等于 track_tags 行数加 image_tags 行数。
- 每条 media 记录的 media_type 与扩展名判定一致。
- PRAGMA integrity_check 返回 ok。

运行方式：

```bash
dart run tool/migrate_check.dart \
  --src-a "$HOME/.local/share/AudioShelf/audioshelf.db" \
  --src-b "$HOME/Documents/PictureViewer/pv2.db" \
  --dst "$HOME/.local/share/AsmrShelf/asmr_shelf.db"
```

路径按第 8.1 节的实际值填。

## 9 视频能力（v1）

### 9.1 扩展名

视频集合放在 lib/services/file_scanner.dart。
与 AudioShelf/lib/services/file_scanner.dart:9 的音频集合并列。

```dart
const videoExtensions = {
  '.mp4', '.mkv', '.avi', '.mov', '.webm', '.m4v',
  '.flv', '.wmv', '.mpg', '.mpeg', '.ts', '.3gp',
};
```

音频集合保持 {'.mp3', '.wav'}。
图片集合保持 PictureViewer2/lib/services/file_scanner.dart:6 的 9 个扩展名。

### 9.2 类型判定

加一个函数 mediaTypeOfPath。
输入路径，返回 audio、image、video 或 null。
扫描与导入都调它。

### 9.3 卡片

- 用统一图标 Icons.movie。
- 显示文件名、格式、文件大小。
- 不显示时长，也不显示分辨率。
- 双击卡片调 VideoLauncher。
- 卡片数据来自 media 表，media_type 为 video。

### 9.4 外链接口

新建 lib/services/video_launcher.dart。

```dart
enum LaunchResult { ok, unsupportedPlatform, failed }

class VideoLauncher {
  VideoLauncher({Future<Process> Function(String, List<String>)? start})
      : _start = start ?? Process.start;

  final Future<Process> Function(String, List<String>) _start;

  Future<LaunchResult> open(String path) async {
    // 见下面的分派表
  }
}
```

分派表：

| 平台 | 命令 | 参数 |
|---|---|---|
| Windows | cmd | /c start "" <路径> |
| Linux | xdg-open | <路径> |
| 其他 | 无 | 返回 unsupportedPlatform |

要点：

- 用参数数组，不拼 shell 字符串。路径含空格或中文时安全。
- Windows 的 start 命令第一个参数是窗口标题，传空串占位。
- 返回 ok 只表示已交给系统，不代表播放结束。
- 进程启动失败时捕获 ProcessException，返回 failed。
- 失败要写日志，界面弹提示，不静默。

### 9.5 Android 预留

平台分支留一个 case，返回 unsupportedPlatform。
后续实现用 Intent.ACTION_VIEW。
MIME 类型由扩展名给出。
URI 用 FileProvider 生成。
不要用 file:// URI 直接交给外部播放器。

### 9.6 测试

新建 test/services/video_launcher_test.dart。
注入假的 start 函数。
断言命令名与参数数组。
不真起播放器。

## 10 模块映射

### 10.1 来自 PictureViewer2

| 源 | 目标 | 处置 |
|---|---|---|
| lib/db/image_dao.dart | lib/db/media_dao.dart | 与 track_dao 合并 |
| lib/db/sql_like.dart | lib/db/sql_like.dart | 直接迁入 |
| lib/db/tag_dao.dart | lib/db/tag_dao.dart | 与 AudioShelf 版合并 |
| lib/db/folder_dao.dart | lib/db/folder_dao.dart | 与 AudioShelf 版合并 |
| lib/services/thumbnail_cache.dart | 同名 | 直接迁入 |
| lib/services/exif_service.dart | 同名 | 直接迁入 |
| lib/services/import_service.dart | 同名 | 与 AudioShelf 版合并 |
| lib/services/file_scanner.dart | 同名 | 合并并加视频判定 |
| lib/services/settings_service.dart | 同名 | 与 AudioShelf 版合并 |
| lib/services/data_dir_service.dart | 同名 | 改用 AudioShelf 版为底 |
| lib/state/app_state.dart | 同名 | 作为统一状态底本 |
| lib/utils/filter_expression.dart | 同名 | 直接迁入，带深度护栏 |
| lib/utils/log_util.dart | 同名 | 两边合并为一份 |
| lib/utils/path_util.dart | 同名 | 直接迁入 |
| lib/utils/file_io.dart | 同名 | 直接迁入 |
| lib/utils/color_util.dart | 同名 | 直接迁入 |
| lib/utils/image_cache_util.dart | 同名 | 直接迁入 |
| lib/theme/catppuccin.dart | 同名 | 备选主题 |
| lib/pages/about_page.dart | 同名 | 直接迁入 |
| lib/pages/home_page.dart | 同名 | 与 AudioShelf 版合并 |
| lib/pages/settings_page.dart | 同名 | 与 AudioShelf 版合并 |
| lib/widgets/image_viewer.dart | 同名 | 直接迁入 |
| lib/widgets/image_grid.dart | 同名 | 直接迁入 |
| lib/widgets/image_detail.dart | 同名 | 直接迁入 |
| lib/widgets/folder_panel.dart | 同名 | 直接迁入 |
| lib/widgets/filter_dialog.dart | 同名 | 直接迁入 |
| lib/widgets/color_picker_dialog.dart | 同名 | 直接迁入 |
| lib/widgets/move_folder_dialog.dart | 同名 | 直接迁入 |
| lib/widgets/export_actions.dart | 同名 | 直接迁入 |
| lib/widgets/tag_picker_dialog.dart | 同名 | 直接迁入 |
| lib/widgets/tag_panel.dart | lib/widgets/tag_panel.dart | 与 AudioShelf 版合并 |
| test/ | test/ | 按目录迁入，改导入前缀 |
| scripts/build_linux.sh | 同名 | 作为底本 |
| scripts/build_windows.ps1 | 同名 | 作为底本 |
| scripts/pack_for_windows.sh | 同名 | 作为底本，删 sqlite3 下载 |
| .github/workflows/ci.yml | 同名 | 直接迁入 |
| .gitignore | 同名 | 作为底本，加 data/ 与 logs/ |

### 10.2 保留 AudioShelf

| 位置 | 处置 |
|---|---|
| lib/state/player_controller.dart | 保留 |
| lib/services/media_bridge.dart | 保留，改 MethodChannel 名前缀 |
| lib/services/subtitle_parser.dart | 保留 |
| lib/services/metadata_service.dart | 保留 |
| lib/services/cover_service.dart | 保留 |
| lib/db/work_dao.dart | 保留 |
| lib/pages/subtitle_page.dart | 保留 |
| lib/widgets/player_bar.dart | 保留 |
| lib/widgets/cover_image.dart | 保留 |
| lib/widgets/works_grid.dart | 保留 |
| lib/widgets/folder_browser.dart | 保留，与 folder_panel 对齐 |
| lib/widgets/dialogs.dart | 保留，改 file_picker 调用 |
| lib/utils/format.dart | 保留 |
| lib/theme/app_theme.dart | 保留为默认主题 |
| android/ | 保留，改包名 |
| scripts/build_android.sh | 保留 |
| scripts/build_windows_remote.sh | 保留 |
| pubspec.yaml 的 hooks 段 | 保留 |

### 10.3 丢弃

- PictureViewer2 的 ios/、macos/、web/ 目录。
- AudioShelf 的 PROJECT_LOG.md，改由新的 PROJECTLOG.md 记录。
- PictureViewer2 的 scripts/*.projectlog.md。
- 两边的 docs/ 工作稿，需要时再抄进新仓库。
- AudioShelf/lib/db/track_dao.dart 与 PictureViewer2/lib/db/image_dao.dart 合并后不再单独存在。

## 11 阶段计划

每阶段的命令都在这两行导出之后跑：

```bash
export PATH="$HOME/flutter/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/lib"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn PUB_HOSTED_URL=https://pub.flutter-io.cn
```

### 阶段 0 建仓与改名

动作：

1. 复制 AudioShelf 到 /home/hoshi/code/AsmrShelf。
2. 删掉 .git，重新 git init，分支 master。
3. 按第 3 节改名。

验收：

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

通过标准：analyze 无 error。
test 通过数不低于 72。

### 阶段 1 依赖合并

动作：按第 5 节写 pubspec.yaml。

验收：

```bash
flutter pub get
grep -A3 '^  file_picker:' pubspec.lock
grep -A3 '^  sqflite_common_ffi:' pubspec.lock
flutter analyze --no-fatal-infos
```

通过标准：file_picker 为 12.1.2。
sqflite_common_ffi 为 2.4.2+1。

### 阶段 2 数据层统一

动作：

1. 写 lib/db/tables.dart 的 v5 内容，含 media_type 四值、ext 与 name_lower 列、folders.library 与 works.library。
2. 新建 lib/db/media_dao.dart，定义 MediaType 与 MediaItem。
3. 合并 lib/db/tag_dao.dart 与 lib/db/folder_dao.dart，文件夹反查一律带 library 条件。
4. 改 database.dart 的库文件名与 PRAGMA 写法。
5. 标签表达式解析器识别 kind 与 ext 两个规则 namespace，并补 test/db 用例覆盖按库取根、按库反查与规则标签翻译。

验收：

```bash
flutter test test/db
```

通过标准：建库成功，PRAGMA integrity_check 返回 ok。
老 db 用例改到 media 之后全部通过。

### 阶段 3 迁移服务

动作：新建 migration_service.dart 与 tool/migrate_check.dart。

验收：

```bash
dart run tool/migrate_check.dart --src-a <老库 A> --src-b <老库 B> --dst <新库>
```

通过标准：五类检查全部通过，见第 8.5 节。

### 阶段 4 图片栈迁入

动作：按第 10.1 节迁入图片相关模块。
图片入口按第 18.6 节提供不依赖库树的全库图片视图。

验收：

```bash
flutter test test/services test/utils
flutter analyze --no-fatal-infos
```

通过标准：缩略图与 EXIF 用例通过。
手动打开一张图片，缩略图与 EXIF 面板正常。

### 阶段 5 视频识别与外链

动作：

1. 加 videoExtensions 与 mediaTypeOfPath。
2. 新建 video_launcher.dart。
3. 新建 video_grid.dart 并接入卡片。
4. 写 video_launcher_test.dart。
剧集树按第 18.6 节的形状建，复用 works 加 library 列。

验收：

```bash
flutter test test/services/video_launcher_test.dart
```

通过标准：假 runner 的断言通过。
Windows 与 Linux 各手动拉起一次外部播放器。

### 阶段 6 统一 AppState

动作：

1. 以 PictureViewer2/lib/state/app_state.dart 为底。
2. 并入 AudioShelf 的作品集、字幕、播放队列、选择集。
3. 删掉第 7.4 节的过渡视图。
4. 库树查询带 library 条件，全库类型视图在三种模式里各有一个入口。
5. 字幕标签默认进 notTagIds 并持久化到 shared_preferences。

验收：

```bash
flutter test test/state test/widget
```

通过标准：tag_filter 用例通过。
app_smoke_test 与 narrow_window_test 通过。

### 阶段 7 设置、主题与页面

动作：

1. 合并 settings_page 与 home_page。
2. 主题先用 AudioShelf/lib/theme/app_theme.dart。
3. Catppuccin 留作可选主题。

验收：

```bash
flutter analyze --no-fatal-infos
flutter test
```

通过标准：设置页能改主题与缓存上限。
切换数据目录并重启后，新目录生效。

### 阶段 8 打包与 CI

动作：迁入第 6.2 节与第 6.3 节的脚本，迁入 ci.yml。

验收：

```bash
bash scripts/build_linux.sh --mode release
ls build/linux/x64/release/bundle/
```

通过标准：bundle 目录存在，可执行文件能启动。
CI 在远端跑绿。

### 阶段 9 Android（延后）

动作：

1. 改包名与 Kotlin 目录。
2. 补 Intent 与 FileProvider 分派。
3. 验证所有文件访问权限下的扫描。

验收：

```bash
flutter build apk --release
```

通过标准：实机能扫描一个目录，能拉起外部播放器。

## 12 UI 布局（占位）

等用户给出布局后填写本节。
需要覆盖的界面：

| 界面 | 要点 |
|---|---|
| 主窗口与导航结构 | 待定 |
| 网格视图与列表视图 | 待定 |
| 左侧文件夹面板 | 待定 |
| 右侧标签面板 | 待定 |
| 底部播放条 | 待定 |
| 图片查看器 | 见第 22 节漫画阅读模式 |
| 视频卡片与播放按钮 | 待定 |
| 设置页与关于页 | 待定 |

布局常量先集中在 lib/theme/app_theme.dart。

### 12.1 窄窗与安全区（2026-09-28 补）

界面在最窄的可视宽度下也不能溢出。三条口径：

| 界面 | 口径 | 位置 |
| --- | --- | --- |
| 视觉库工具栏 | 中间列小于 500 时走紧凑样式，图标按钮收到 36 见方；小于 220 时排序收进「更多」，按钮收到 30 见方 | lib/pages/home_page.dart:393 |
| 多选栏 | 宽度小于 520 时改成图标按钮；小于 300 时收到 30 见方、文字只留数量，动作区可横向滚动 | lib/pages/home_page.dart:806 |
| 图片查看器 | 顶栏与底栏让开 viewPadding 的左右与上下。曲面侧边屏上「关闭」与翻页按钮不贴边 | lib/widgets/image_viewer.dart:885 |

回「作品」层用面包屑上的按钮，位置见 lib/pages/home_page.dart:696。

## 13 工程约定

| 类别 | 约定 |
|---|---|
| 记录 | 应用根建 PROJECTLOG.md，只追加 |
| 记录 | 每条记录写日期、目标、动作、验证 |
| 日志 | 走统一入口 lib/utils/log_util.dart |
| 日志 | 带时间戳、级别与模块名 |
| 日志 | 关键路径打点，错误分支不静默 |
| 日志 | 敏感信息不进日志，例如完整路径里的用户名 |
| 存储 | 持久化落 <应用根>/data/，日志落 <应用根>/logs/ |
| 存储 | 路径只从 DataDirService 解析，不在各处拼路径 |
| 存储 | 支持 APP_DATA_DIR 与 APP_LOG_DIR 覆盖 |
| 存储 | data/ 与 logs/ 进 .gitignore |
| 文档 | 中文正文按 ASD-STE100 中文版写 |

## 14 已知坑

| 坑 | 依据 |
|---|---|
| Linux 构建必须 NO_XIPH_LIBS=1 | AudioShelf/scripts/build_linux.sh:17 |
| WAL 语句要用 rawQuery 执行，Android 上 execSQL 会报错 | AudioShelf/lib/db/database.dart:77；PictureViewer2/lib/db/database.dart:62 用了 execute，迁入时必须改 |
| FFI 初始化只在 Windows 与 Linux 上做 | AudioShelf/lib/db/database.dart:42 到 :45；PictureViewer2/lib/db/database.dart:28 到 :29 无条件调用，迁入时必须加平台守卫 |
| 外键开关放在 onConfigure 里 | AudioShelf/lib/db/database.dart:55 |
| 启动失败要显示错误页，避免白屏 | AudioShelf/lib/main.dart:45 到 :48 |
| 老库不要就地升级，两边版本号都是 4 但表结构不同 | 第 8 节 |
| 缩略图目录里有几万个小文件，回收放后台不阻塞启动 | PictureViewer2/lib/main.dart:30 |
| 两边的数据根不同，迁移前先读 .datadir 指针文件 | 第 8.1 节 |
| Android 外部播放器不能用 file:// URI | 第 9.5 节 |
| 文件删除时的曲目清理逻辑依赖 tracks 表名，合并后要跟着改 | AudioShelf/lib/state/app_state.dart:534 |
| Material 3 图标按钮默认 48 见方触摸区，手机小磁贴只有 80 到 90 像素 | lib/widgets/image_grid.dart:681；⋮ 会吃掉整张磁贴的单击与长按，收到 26 见方并关掉 tapTargetSize |
| `pumpAndSettle` 遇到 indeterminate 进度圈会一直等到超时 | 详情面板要解码真图，用 `runAsync` 加 `pump` 循环，见 test/widget/home_page_test.dart |
| 本机 `dart format` 是 Dart 3.13 的 tall 样式，跑一次会重排整个仓库 | 清理办法见 PROJECTLOG 的 `1.4.0+21` 条目 |

## 15 未决项

| 项 | 现状 | 需要用户确认 |
|---|---|---|
| UI 布局 | 未给 | 布局与交互细节 |
| 许可证 | 暂定 MIT | 是否保留 BSD 3-Clause 的署名 |
| 远端仓库 | git@github.com:OverFlame/AsmrShelf.git | 推送口径已定：main 直推，master 已退役 |
| 主题 | 暂用原创主题 | 还是 Catppuccin |
| Android | 首版不验收 | 何时补 |
| 数据目录 | 暂用 AudioShelf 的支持目录 | 是否统一到新目录名 |
| 设置存储 | 两边都用 settings.json | 是否改用 shared_preferences |

folder_paths.recursive 的默认值已定，取 1。
AudioShelf 的老数据按原值导入。

分类、标签、库归属与导入入口的口径已在第 18 节定稿。
字幕默认只做同目录匹配，全库扫描由用户发起并确认结果。
封面候选放宽到作品根下整棵子树。

## 16 附录：文件行数对照

### 16.1 AudioShelf lib

| 文件 | 行数 |
|---|---|
| lib/db/database.dart | 92 |
| lib/db/folder_dao.dart | 308 |
| lib/db/tables.dart | 190 |
| lib/db/tag_dao.dart | 351 |
| lib/db/track_dao.dart | 350 |
| lib/db/work_dao.dart | 96 |
| lib/main.dart | 90 |
| lib/pages/home_page.dart | 164 |
| lib/pages/settings_page.dart | 167 |
| lib/pages/subtitle_page.dart | 283 |
| lib/services/cover_service.dart | 162 |
| lib/services/data_dir_service.dart | 163 |
| lib/services/file_scanner.dart | 137 |
| lib/services/import_service.dart | 239 |
| lib/services/media_bridge.dart | 232 |
| lib/services/metadata_service.dart | 81 |
| lib/services/settings_service.dart | 142 |
| lib/services/subtitle_parser.dart | 212 |
| lib/state/app_state.dart | 1172 |
| lib/state/player_controller.dart | 311 |
| lib/theme/app_theme.dart | 214 |
| lib/utils/filter_expression.dart | 263 |
| lib/utils/format.dart | 10 |
| lib/utils/log_util.dart | 76 |
| lib/widgets/cover_image.dart | 57 |
| lib/widgets/dialogs.dart | 308 |
| lib/widgets/folder_browser.dart | 499 |
| lib/widgets/player_bar.dart | 236 |
| lib/widgets/tag_panel.dart | 816 |
| lib/widgets/works_grid.dart | 145 |
| 合计 | 7566 |

### 16.2 PictureViewer2 lib

| 文件 | 行数 |
|---|---|
| lib/db/database.dart | 80 |
| lib/db/folder_dao.dart | 274 |
| lib/db/image_dao.dart | 516 |
| lib/db/sql_like.dart | 17 |
| lib/db/tables.dart | 119 |
| lib/db/tag_dao.dart | 386 |
| lib/main.dart | 85 |
| lib/pages/about_page.dart | 114 |
| lib/pages/home_page.dart | 728 |
| lib/pages/settings_page.dart | 562 |
| lib/services/data_dir_service.dart | 113 |
| lib/services/exif_service.dart | 273 |
| lib/services/file_scanner.dart | 77 |
| lib/services/import_service.dart | 343 |
| lib/services/settings_service.dart | 179 |
| lib/services/thumbnail_cache.dart | 339 |
| lib/state/app_state.dart | 1085 |
| lib/theme/catppuccin.dart | 195 |
| lib/utils/color_util.dart | 48 |
| lib/utils/file_io.dart | 77 |
| lib/utils/filter_expression.dart | 317 |
| lib/utils/image_cache_util.dart | 45 |
| lib/utils/log_util.dart | 83 |
| lib/utils/path_util.dart | 59 |
| lib/widgets/color_picker_dialog.dart | 427 |
| lib/widgets/export_actions.dart | 122 |
| lib/widgets/filter_dialog.dart | 244 |
| lib/widgets/folder_panel.dart | 753 |
| lib/widgets/image_detail.dart | 827 |
| lib/widgets/image_grid.dart | 388 |
| lib/widgets/image_viewer.dart | 754 |
| lib/widgets/move_folder_dialog.dart | 218 |
| lib/widgets/tag_panel.dart | 821 |
| lib/widgets/tag_picker_dialog.dart | 137 |
| 合计 | 10805 |

## 17 媒体类型判定与查找（建议）

本节补第 9.2 节的类型判定与第 7 节的查找设计。表内命中行数都是实测结果，复现方式见 PROJECTLOG.md。

### 17.1 判定分两层

第一层看扩展名，第二层看文件头魔数。v1 只做第一层。

| 层 | 做法 | 代价 |
| --- | --- | --- |
| 扩展名 | 三张集合表加一个 `mediaTypeOfPath` | 零 IO |
| 魔数 | 读前 16 字节比对签名 | 每文件一次 open |

扩展名集合的唯一来源是 `lib/services/file_scanner.dart`。扫描、导入、拖放三处都调 `mediaTypeOfPath`，不要各写一份判断。`path.toLowerCase()` 要保留，Windows 上扩展名大小写不定。

### 17.2 歧义与边界

| 输入 | 判定 | 说明 |
| --- | --- | --- |
| `a.MP4` | video | 先转小写 |
| `a.tar.gz` | null | 只取最后一段扩展名 |
| `.mp3.txt` | null | 扩展名是 txt |
| 无扩展名 | null | 不做魔数探测时返回 null |
| `.ts` | video | 与 TypeScript 源文件重名，桌面端按视频处理 |

### 17.3 分类存放

单表 `media` 加 `media_type` 列，见第 7 节。查找按列走，不要用 `path LIKE '%.mp4'`，前缀通配符用不上索引。

建议加索引：

| 索引 | 列 | 用途 |
| --- | --- | --- |
| `idx_media_type` | `media_type` | 按类型分栏与计数 |
| `idx_media_folder_type` | `folder_id, media_type` | 文件夹内按类型列 |
| `idx_media_name_lower` | `name_lower` | 文件名前缀搜索 |

`name_lower` 是冗余列，写入时存小写文件名。

### 17.4 查找

文件名前缀搜索用 `name_lower LIKE 'abc%'`，这种写法能走索引。`LIKE '%abc%'` 走不了，会全表扫。

中文子串搜索要 FTS5。系统库 3.46.1 上三种方式的实测命中行数：

| 查询 | unicode61 | trigram | LIKE |
| --- | --- | --- | --- |
| 音乐 | 0 | 0 | 1 |
| 播放器 | 0 | 1 | 1 |
| 音乐播放 | 0 | 1 | 未测 |
| avorit | 0 | 1 | 1 |
| favorite | 1 | 1 | 未测 |
| favor* | 1 | 1 | 未测 |

读法：unicode61 把连续汉字当成一个词，查询字符串比词短就不命中。trigram 支持中文子串，但查询短于三字同样不命中。`LIKE` 任何子串都能命中，代价是全表扫。

结论：中文搜索用 `tokenize='trigram'`，长度不足三字的查询交给 `LIKE`。`name_lower` 上的索引负责前缀，FTS5 表只放文件名与标签。

### 17.5 扫描一次遍历

`FileScanner._scan` 现在只返回音频、字幕、封面三样。加图片与视频时建议把结果改成按类型分组的映射，同一棵树不要遍历三遍。封面图的文件名白名单（`cover`、`folder`、`front` 等）只在音频目录里生效。

### 17.6 待验证

Android 与 Windows 上的 FTS5 可用性没验。Android 走系统 SQLite，版本随设备。建议启动时探测一次：建一张 FTS5 临时表，失败就退回 `LIKE`。

## 18 库归属、规则标签与导入入口（定稿）

本节记录与用户对齐的决定，日期 2026-09-27。
本节取代第 8.3 节的「图片库」合成根方案。
第 17 节讲类型判定、索引与查找，本节讲归属、标签与筛选。

### 18.1 三层分工

| 层 | 职责 |
| --- | --- |
| 扫描层 | 一次遍历，四种类型都写进 media 行 |
| 组织层 | 三个导入入口各建一棵 folders.library 树 |
| 展示层 | 库树浏览加全库类型视图 |

理由：同一物理目录里装什么由用户决定。
类型决定文件是什么，库树决定怎么分组。
两层分开，音频文件夹里的图片才能在图片模式里看见。

### 18.2 库归属

| 约定 | 内容 |
| --- | --- |
| 新增列 | folders 与 works 各加 library，取值 audio、image、video，不允许为空 |
| 写入方 | 导入入口，子节点从父节点继承 |
| 查询条件 | 音频侧 `library = 'audio' AND work_id IS NULL AND parent IS NULL`，图片侧 `library = 'image' AND parent IS NULL`，视频侧 `library = 'video' AND parent IS NULL` |
| 反查 | getByPath 与 ensureByPath 必须带库条件。两者现在按路径反查取 id 最小者，命中后还会改写 parent 与 work_id（lib/db/folder_dao.dart:195 与 :214）。不带库条件，后导入的一方会抢走前一方建的节点 |
| 与作品集的关系 | 正交。work_id 只说属于哪个作品集或剧集 |
| 根节点唯一性 | UNIQUE(name, parent) 对 NULL 不生效，仍由代码先查后插（PictureViewer2/lib/db/folder_dao.dart:52） |
| 升级路径 | 每个库需要独立名字、图标与默认视图时，再升成 libraries 表加 folders.library_id |

### 18.3 同一目录多库并存

- 允许。同一目录从两个入口各导入一次，会得到两个 folders 行。
- 两行的 library 不同，指向同一批物理文件。物理文件不会重复，media.path 有唯一约束。
- 封面只是作品的展示属性，存在 works.cover_path。同一批图片在图片库里全部可见，音频库只显示封面那一张。
- 封面候选放宽到作品根下整棵子树，不再限于根目录。
- 选择规则保持确定。先取白名单命名的图片，再按路径字典序取第一张。都没有就用第一首音频的内嵌封面（lib/services/import_service.dart:191）。

### 18.4 规则标签

- kind 与 ext 两类标签只在 tags 表里放定义，不写 media_tags 与 folder_tags 的关联行。
- 筛选时翻译成列条件：kind 音频翻译成 `media_type = 'audio'`，ext vtt 翻译成 `ext = 'vtt'`。标签表达式解析器要能识别这两个 namespace（lib/db/tag_dao.dart:271 的 _resolveTagRef）。
- 计数不查 media_tags，改走 media 表的 GROUP BY。
- 自动标签因此没有重建与失效问题。文件扩展名一变，标签跟着变。
- 用户手动打的标签仍走 media_tags，与规则标签互不干扰。

### 18.5 字幕

- 字幕升格为 media 行，media_type 取 subtitle。格式、编码与匹配规则见第 23 节。
- 默认只做同目录匹配：`a.mp4.srt` 优先，其次 `a.srt`（lib/services/file_scanner.dart:97）。
- 允许用户手动指定某条字幕归属某个媒体。
- 另提供「全库扫描」按钮，由用户发起，扫完弹出匹配结果供用户确认，不做静默绑定。
- 字幕标签默认处于排除状态：初始筛选把字幕类标签放进 notTagIds（lib/db/tag_dao.dart:211 已支持），状态存 shared_preferences。用户取消反选后，字幕文件出现在文件树。

### 18.6 三个导入入口

- 图片入口的组织方式是系列与卷，见第 20 节。音频入口同样是系列与卷，见第 19 节。
- 视频入口的组织方式是剧集树，形状为总剧集文件夹（可无）、一季一个文件夹、一集一个文件。视频剧集复用 works 表加 library 列，直接沿用 setWorkMany、未归类与 listRootsByWork 一整套。
- 建树按入口类型判空，落库不判空。今天 `if (scanned.audioPaths.isEmpty) return;`（lib/services/import_service.dart:68）会连带丢掉图片，要拆成两层。
- 全库类型视图：图片、音频、视频三种模式各提供一个不依赖库树的全部条目入口，按物理目录分组。这样从没走图片入口导入的图片也能看见。
- 批量导入：图片库与视频库各提供「每个子文件夹一个作品」的入口，一次选父目录。含媒体的直接子目录各建一个作品，名字取子目录名。子目录都不含该库媒体时退回单目录导入。音频库不用这个入口，系列与卷见第 19 节。位置：lib/state/app_state.dart:1911、lib/widgets/folder_panel.dart:469、lib/widgets/works_grid.dart:132。

### 18.7 落地顺序

阶段 2 建表与 DAO，含 library 列与规则标签解析。
阶段 4 接入图片入口与全库图片视图，含字幕解析与匹配能力。
阶段 5 建剧集树与视频入口。
阶段 4 还含系列与卷的建表增量与导入入口，见第 19 节。
阶段 6 统一 AppState，接库树筛选、字幕默认反选与三种类型的全库视图。

## 19 系列与卷（定稿）

2026-09-27 定稿。音频入口的组织方式按本节执行。第 18.6 节里「组织成专辑树」那一句由本节取代。

### 19.1 层级映射

| 你的概念 | 落库位置 | 键值 |
| --- | --- | --- |
| 系列 | works 行 | library 取 audio |
| 卷 | 该系列下的一级文件夹 | folders 行，parent 指向系列根 |
| 曲目与特典音声 | media 行 | media_type 取 audio |
| 特典图片 | media 行 | media_type 取 image |
| 正篇字幕 | media 行 | media_type 取 subtitle |

一个系列装多卷，与视频侧「一个剧集装多季」同构。卷与磁盘目录一一对应，一卷就是一个目录。

### 19.2 卷封面

- `folders` 加 `cover_path` 列。这是第 5 版之后的 v6 增量。
- 自动候选按顺序取第一个命中项：

| 顺序 | 来源 |
| --- | --- |
| 1 | 卷子树里的白名单图 |
| 2 | 路径字典序第一张图 |
| 3 | 卷内第一首曲目的内嵌封面 |
| 4 | 系列封面兜底 |

- 允许手动指定。手动结果优先，后续自动扫描不再覆盖。自定义裁剪见第 21 节。
- 白名单只有七个名字，见 `lib/services/file_scanner.dart:127`。名字不命中的卷封面选不上，所以手动指定是必需项。

### 19.3 特典标记

- 卷文件夹下的固定子目录名视作特典：特典、SP、Bonus。名字表放 `lib/services/file_scanner.dart`。
- 导入时给命中的曲目自动打普通标签「特典」，写进 `media_tags`。
- 用户可以改，可以删。自动打标只在导入那一次发生。

### 19.4 卷内图片

- 音频库的卷详情加「本卷图片」区。
- 按路径前缀查该卷子树里的 image 行，写法参考 `lib/db/track_dao.dart:158` 的 `queryDirectInDir`。
- 同一张图片在图片库照常可见，物理文件只存一份，`media` 行也只有一行。
- 当封面的那张图照常在图片区显示。

### 19.5 系列导入入口

- 音频入口支持按系列导入。选中的目录当一个系列，其下每个含音频的一级子目录各成一卷。
- 导入系列时跳过导入根那一层文件夹。今天会建，见 `lib/services/import_service.dart:176`，树会多一层。
- 单卷导入照旧，建成只有一个卷的系列。
- 已有专辑并成系列的路径保留：移入作品集走 `setWorkMany`，历史数据不用迁移。

### 19.6 落地顺序

| 阶段 | 内容 |
| --- | --- |
| 阶段 4 | `folders.cover_path` 的 v6 增量、卷封面读写与手动指定、系列导入入口、特典自动标签 |
| 阶段 6 | 统一 AppState 接卷封面、卷内图片区与特典筛选 |
| 未排期 | 卷自己的排序。今天按名字字典序，名字带卷号就够用 |

阶段 3 是迁移服务，与本节无关。

## 20 三种媒体的组织形式（定稿）

2026-09-27 定稿。本节记录三种媒体在现实世界的形态盘点与改进清单。

### 20.1 层级统一

三边共用一套层级。

| 层 | 音频 | 图片 | 视频 |
| --- | --- | --- | --- |
| 系列 | 有声小说系列 | 漫画系列 | 剧集 |
| 卷 | 一卷 | 一本 | 一季 |
| 条目 | 曲目 | 页 | 一集 |

- 系列落 `works` 行。`works.library` 的 CHECK 要加 `'image'`，见 `lib/db/tables.dart:16`。
- 卷落 `folders` 行，取一级文件夹。`folders.library` 已有三值，见 `lib/db/tables.dart:63`。
- 卷封面落 `folders.cover_path`，三边共用一列。裁剪见第 21 节。
- 条目落 `media` 行，按 `media_type` 分流。

### 20.2 自然排序

数字要按数值比，不能按字符比。否则第 10 页排在第 2 页前面。

- `media` 加 `sort_key` 列，并建索引。
- 插入时把文件名里的连续数字补零。例如 `第1话` 存成 `第0001话`。
- 排序走 `sort_key`，为空时回落 `filename COLLATE NOCASE`。
- 三边共用：漫画页序、剧集集号、多卷卷号。
- `folders` 与 `works` 数量在百级，排序改成 Dart 侧自然比较，不加列。

### 20.3 扩展名白名单

位置统一在 `lib/services/file_scanner.dart`。

| 类型 | 补进来的 | 依据 |
| --- | --- | --- |
| 音频 | `.flac` `.m4a` `.aac` `.ogg` `.opus` | 无损与常见压缩格式，见 `lib/services/file_scanner.dart:9` |
| 图片 | `.heic` `.avif` | 手机相册与网页常见格式，显示口径见第 22.10 节 |
| 视频 | 保持 12 个 | 见第 9.1 节 |

### 20.4 作品与条目并存

- 作品下允许直接放条目，同时保留子文件夹。
- 今天的限制见 `lib/state/app_state.dart:228-231`，作品层把条目写死成空列表。
- 直接条目的判定：路径落在该作品某个根的路径前缀下，且不属于任何子文件夹。
- 用途：电影系列、单卷散图、单曲作品。

### 20.5 图片侧漫画

- 漫画系列落 `works`，`library` 取 `image`。
- 一本落一级文件夹，话落二级文件夹。
- 页落 `media` 行，顺序按 `sort_key`。
- 卷封面复用 20.1 的列，候选顺序与音频一致。手动指定与裁剪见第 21 节。
- 番外与特典走同一套子目录名打标。

### 20.6 落点

| 阶段 | 内容 |
| --- | --- |
| 阶段 4 | `works.library` 加 `image`、`media.sort_key`、扩展名白名单、图片侧系列与卷、阅读器核心与 v6 增量 |
| 阶段 6 | 统一 AppState 接作品平铺条目、卷封面与卷内图片区 |

### 20.7 后置与不做

后置：压缩包识别、EXIF 拍摄日期列、特典名字表可配。阅读与观看进度改到第 22.6 节。

压缩包指 CBZ、CBR 与 ZIP，先只当一条条目。

不做：整轨 cue 分轨、BDMV 原盘折叠、画集扫描的自动跨页拼接、跨媒体系列、古典乐多创作者元数据。阅读器的并排页对见第 22.5 节。

## 21 封面与裁剪（定稿）

2026-09-27 定稿。三种媒体的封面共用一套存储与渲染。

### 21.1 封面的三种来源

| 来源 | 存储 | 可否手动 |
| --- | --- | --- |
| 系列封面 | `works.cover_path` | 可 |
| 卷封面 | `folders.cover_path` | 可 |
| 曲目内嵌封面 | `media.cover_path` | 只读，属自动缓存 |

- 手动指定挑哪张图，见第 19.2 节。
- 手动裁剪改怎么显示，见 21.2。
- 图片侧完全照用：系列封面落 `works.cover_path`，卷封面落 `folders.cover_path`。

### 21.2 裁剪的存储

- `works` 与 `folders` 各加一列 `cover_crop`，类型 TEXT。
- 内容为四个归一化数，顺序是左、上、右、下，取值 0 到 1，用逗号分隔。例如 `0.05,0.10,0.95,0.60`。
- 空串或 NULL 表示不裁，按等比适应显示。
- 原图永不改动。裁剪只影响渲染。这是媒体库的底线。

### 21.3 裁剪的计算

显示时按目标区的宽高比把裁剪框扩成同一比例。

- 中心取裁剪框中心。
- 面积取满足目标比例的最小矩形。
- 超出原图的部分向内收。
- 这段算法是纯函数，单独建文件与用例。

### 21.4 交互

- 封面菜单加「自定义裁剪范围」，弹出裁剪框，可拖动、可缩放、可锁比例。
- 另加「恢复默认」，清空 `cover_crop`。
- 网格卡片按卡片比例裁剪，详情页显示全图。
- 自动候选出来的封面同样可裁。
- 手动指定先在软件里挑，不先开系统选图：作品封面列作品里的图片，卷封面列本文件夹（含子文件夹）里的图片。手机上少点好几层。系统选图留作出口。位置：lib/widgets/cover_pick.dart:95、lib/widgets/dialogs.dart:65、lib/widgets/volume_cover_dialog.dart:106。

### 21.5 落点

阶段 4 做存储与算法，阶段 6 做交互与显示。

后置：按显示位置存多套裁剪参数。

## 22 漫画阅读模式（定稿）

2026-09-27 定稿。基础是 PictureViewer2 的图片查看器。本节记录改造成漫画阅读模式的决定。

### 22.1 复用与新增

基础文件 `lib/widgets/image_viewer.dart`（754 行）随阶段 4 原样迁入。缩放、键盘、预载与降采样逻辑不动。

| 能力 | 现状 | 位置 |
| --- | --- | --- |
| 缩放平移 | 0.05 倍到 50 倍 | `PictureViewer2/lib/widgets/image_viewer.dart:358` |
| 键盘 | 方向键、Esc、加减号、0、F、I | 同文件 `:275` |
| 相邻预载 | 前后各一张 | 同文件 `:246` |
| 大图降采样 | 按屏幕物理宽解码 | 同文件 `:118` |
| 缓存上限 | 默认 2048MB，可调 256 到 8192 | `lib/state/app_state.dart:139`、`:667` |

新增五项：阅读方向、适应模式、无干扰全屏、并排页对存储、阅读进度。

键位在阅读模式下固定如下。方向键语义随阅读方向翻转。

| 键 | 作用 |
| --- | --- |
| 方向键左右 | 翻页，语义随 `reading_direction` |
| Esc | 退出阅读模式 |
| 加减号与 0 | 缩放与复位 |
| F | 全屏开关，沿用现状 |
| S | 适应模式循环 |
| I | 详情面板开关，沿用现状 |

### 22.2 阅读方向

方向记在卷，即 `folders` 加一列。

```sql
reading_direction TEXT NOT NULL DEFAULT 'rtl' CHECK (reading_direction IN ('rtl', 'ltr'))
```

- `rtl` 指日漫右到左。此时左方向键前进，右方向键后退。
- `ltr` 与之相反。
- 翻页按钮与触控滑动跟着这一列走。
- 阅读器内可切换，切换后立即写回该卷。

### 22.3 适应模式

适应模式同样记在卷。

```sql
reading_fit TEXT NOT NULL DEFAULT 'page' CHECK (reading_fit IN ('page', 'height', 'width'))
```

| 取值 | 画面 | BoxFit |
| --- | --- | --- |
| `page` | 整页可见 | `contain` |
| `height` | 铺满高度，横向可拖 | `fitHeight` |
| `width` | 铺满宽度，纵向可拖 | `fitWidth` |

S 键按整页、适高、适宽循环，切换后写回该卷。

### 22.4 无干扰全屏

- 进入阅读模式后隐藏顶栏、底栏与 EXIF 面板。
- 点击画面切换显隐，鼠标静止 3 秒后自动隐藏。
- Esc 退出阅读模式。
- v1 不做缩略图导航条。

### 22.5 并排页对的存储（预留）

v1 不做双页并排显示，先把存储建好，免去后置时再改表结构。

```sql
CREATE TABLE reading_spreads (
  volume_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  left_media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  right_media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  PRIMARY KEY (volume_id, left_media_id)
)
```

- v1 建表，不写入，不读取显示，界面不提供标记入口。
- 后置实现时按此表显示并排。右到左时第 1 页单独占右侧。
- 本节按预留存储理解用户的持久化要求。若要在 v1 就支持单对页并排显示，落点需要调整。

### 22.6 阅读进度

按用户决定随阶段 6 一起做。

```sql
CREATE TABLE reading_progress (
  volume_id INTEGER PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
  media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  page_index INTEGER NOT NULL DEFAULT 0,
  finished INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
)
```

- 进入阅读器时从该卷上次的 `media_id` 与 `page_index` 开始。
- 翻页更新本行，写入做 1 秒节流。
- 视频与音频的观看进度可复用同一张表，等卷换成作品主键那一刻再议。

### 22.7 入口

- 卷即一级文件夹的工具栏加「阅读」按钮。
- 网格中双击一张图片，从该张进入阅读器。
- 音频库卷详情的「本卷图片」区双击走同一入口，见第 19.4 节。

### 22.8 不做的

- 上下连续滚动即条漫模式，后置。
- 双页并排显示，后置，存储已在 22.5 预留。
- 画集扫描的自动跨页拼接，与第 20.7 节一致。
- 压缩包内直接阅读，与第 20.7 节一致。

### 22.9 落点

| 阶段 | 做什么 |
| --- | --- |
| 阶段 4 | `tables.dart` v6 增量（`folders` 两列、`reading_spreads` 表）、查看器改造、阅读器入口 |
| 阶段 6 | `reading_progress` 表与读写、卷层入口、本卷图片区联动 |

### 22.10 HEIC 与 AVIF 的显示口径

第 20.3 节把 HEIC 与 AVIF 补进白名单。这两类格式的解码能力要单独说明。

- 实测 `~/.pub-cache/hosted/pub.dev/image-4.10.1/lib/src/formats/` 无解码器，目录里只有 bmp、gif、ico、jpeg、png、pnm、psd、pvr、tga、tiff、webp、exr。
- Flutter 侧对这两类格式的支持按平台而异，本机未验证。
- 按用户决定，文件照常入库并显示条目，界面标注「不可预览」。
- 落地做法：显示处捕获解码失败，落到占位卡并给出格式提示。阅读器遇到该类页可跳过。
- 建议加运行时探针。用 `instantiateImageCodec` 试解一张样本，成功才启用预览，避免硬编码平台名单。

## 23 字幕格式与编码（定稿）

2026-09-27 定稿。第 18.5 节定了字幕的归属与反选，本节定格式、编码与匹配。

### 23.1 今天的支持度

| 环节 | 现状 | 位置 |
| --- | --- | --- |
| 扫描白名单 | 只认 `.vtt` `.srt` `.lrc` | `lib/services/file_scanner.dart:12`、`:19` |
| 匹配规则 | 同目录两级，`a.mp3.srt` 优先，其次 `a.srt` | `lib/services/file_scanner.dart:97` |
| 解析分派 | `switch (ext)` 只这三分支，其余返回空 | `lib/services/subtitle_parser.dart:43` |
| 编码 | 先 UTF-8，失败退 latin1 | `lib/services/subtitle_parser.dart:31` |
| 时间戳 | 三种形态加逗号小数点 | `lib/services/subtitle_parser.dart:174` |
| 清洗 | 去尖括号标签、花括号标签与 HTML 实体 | `lib/services/subtitle_parser.dart:200` |
| 展示 | 独立页按播放位置高亮滚动，空则显示「无字幕」 | `lib/pages/subtitle_page.dart:45`、`:261` |

实测结论：VTT 与 SRT 可用，LRC 基本可用。ASS 与 SSA 完全不支持，动漫外挂字幕的主要格式落空。

### 23.2 编码

按用户决定引入 [fast_gbk](https://pub.dev/packages/fast_gbk)（BSD-3-Clause，1.0.0，纯 Dart）。

| 项 | 做法 |
| --- | --- |
| 依赖 | 加在阶段 4，写 `fast_gbk: ^1.0.0` |
| 探测链 | UTF-8，失败后按 GBK 解，再失败退 latin1 |
| 畸形字节 | `GbkCodec(allowMalformed: true)`，输出替换符，不抛异常 |
| GB18030 四字节 | 罕见字不支持，按畸形字节处理 |
| 署名 | 补进 `THIRD_PARTY_NOTICES.md` |
| BOM | 不用处理。实测 Dart 的 UTF-8 解码器自己剥掉 |
| 今天的缺陷 | GBK 字节走 UTF-8 抛 `FormatException`，退到 latin1 后中文变成乱码 |

### 23.3 解析器注册表

解析接口按扩展名注册，格式扩展只需补一个解码函数。

```dart
typedef SubtitleDecoder = SubtitleDocument Function(String content);

class SubtitleDocument {
  final List<LyricLine> lines;
  final bool hasTiming;
  final bool parsed;
  final String? note;
}
```

| 项 | 做法 |
| --- | --- |
| 已实现解码器 | `.vtt`、`.srt`、`.lrc` |
| 占位解码器 | `.ass`、`.ssa`、`.ttml`、`.dfxp`、`.smi`、`.sami`，返回 `parsed: false` 与提示文案 |
| 白名单分组 | `subtitleExtensions` 放可解析格式用于匹配，`knownSubtitleExtensions` 另含占位格式用于扫描与入库 |
| 界面区分 | 按 `parsed` 判定，占位格式显示条目并标注「该格式暂不支持解析」 |
| 范围 | 本轮只准备接口，六种格式的解析留到有需求时补 |

### 23.4 LRC 增强

- 元数据行里的 `[offset:±ms]` 生效，整体平移所有时间戳，允许负数。
- 无时间标签的纯文本歌词不再整篇丢弃。`hasTiming` 取 false，界面整篇静态显示并提示「该歌词无时间标签」。
- 不做 A2 逐字扩展，也不放开三位分钟。

### 23.5 匹配规则

- 语言后缀参与匹配：`a.<lang>.<ext>` 与 `a.<lang>-<region>.<ext>`。
- 语言名表放 `lib/services/file_scanner.dart`，含 zh、chs、cht、chi、eng、jpn、jp、kor、sc、tc、简、繁、日、英。
- 组合形式一并认，例如 `zh-CN`、`简日`、`CHS&JPN`。
- 比较统一转小写，大小写不敏感。
- 一个媒体允许挂多条字幕。`ScanResult.subtitleByAudio` 从 `Map<String, String>` 改成 `Map<String, List<String>>`，见 `lib/services/file_scanner.dart:27`。

### 23.6 归属模型

阶段 6 落 `media` 表两列。

```sql
subtitle_of INTEGER REFERENCES media(id) ON DELETE SET NULL
is_default_subtitle INTEGER NOT NULL DEFAULT 0
```

- 一个媒体行挂多条字幕行，`is_default_subtitle` 标出默认项。
- 加索引 `idx_media_subtitle_of`。
- 默认项选择顺序：用户上次选定，其次文件名完全匹配，再次语言优先级。
- `media.subtitle_path` 列在新模型下废弃。迁移期与新列并存，阶段 6 之后再删。

### 23.7 落点

| 阶段 | 做什么 |
| --- | --- |
| 阶段 4 | 加 fast_gbk 依赖、编码探测链、解析器注册表、白名单分组 |
| 阶段 4 | LRC 两项增强、匹配规则三项、`ScanResult` 改多值 |
| 阶段 6 | `media` 两列与索引、默认项选择、多字幕切换、默认反选、手动指定与全库扫描弹窗 |

### 23.8 后置与不做

后置：字幕时间轴手动微调、A2 逐字高亮、三位分钟、自动获取字幕。

不做：SUB 与 IDX 位图字幕解析。位图字幕需要配 idx 索引与位图坐标，与文本字幕不是一条路。只识别扩展名并提示。

## 24 播放增强（定稿）

本节定稿四项播放能力。实施顺序为功能 1、功能 3、功能 2。功能 4 等许可证核实结果，暂不排期。

### 24.1 播放模式补全

基线代码在 `lib/state/player_controller.dart`。

| 能力 | 现状 | 结论 |
| --- | --- | --- |
| 单曲循环 | 已有 `RepeatMode.one`（`lib/state/player_controller.dart:10`） | 保留 |
| 列表循环 | 已有 `RepeatMode.all` | 保留 |
| 播完停止 | 已有 `RepeatMode.off` | 保留 |
| 随机 | 已有开关（`:31`），索引每次现算（`:241`） | 改洗牌队列 |
| 播放速度 | 无 | 新增 |
| 队列编辑 | 无 | 新增 |
| 连播入口 | 无 | 新增 |
| 模式持久化 | 无 | 新增 |

落地要点：

| 序号 | 项 | 做法 |
| --- | --- | --- |
| 1 | 速度 | 调 `SoLoud.setRelativePlaySpeed(handle, speed)`（`flutter_soloud-4.1.7/lib/src/soloud.dart:2503`）。范围 0.5 到 2.0，步长 0.25 |
| 2 | 洗牌 | 进入随机时生成一次乱序表，按表推进。表走完再重排，避免短时间重复 |
| 3 | 队列编辑 | 新增 `playNext(TrackItem)`、`removeAt(int)`、`reorder(int, int)`，配套 `List<TrackItem> get queue` 与 `int get index` |
| 4 | 持久化 | 在 `lib/services/settings_service.dart` 加三个键。写法照 `setCoverCacheLimitMB`（`:136-140`） |
| 5 | 连播入口 | 文件夹菜单（`lib/widgets/folder_browser.dart:267`）与作品菜单（`lib/widgets/works_grid.dart:106`）各加一项，调用 `lib/state/app_state.dart:958` 的 `playTracks` |
| 6 | 界面 | `lib/widgets/player_bar.dart` 加速率与队列按钮。队列面板新建 `lib/widgets/queue_panel.dart`，用 `ReorderableListView` |
| 7 | 后置项 | 交叉淡化、淡入淡出、播放位置记忆 |


验收：

- `flutter analyze --no-fatal-infos` 无 error。
- 新增 `test/state/player_controller_test.dart`。用例覆盖洗牌不重复、队列删除与重排、速度边界钳制、模式持久化回读。

### 24.2 外链播放列表

目标是让整部剧集按顺序进入外部播放器。本机无 PotPlayer 与 VLC，参数细节待真机确认。

新建两个文件。

- `lib/services/playlist_writer.dart`。写 UTF-8 的 m3u8。首行 `#EXTM3U`，每项一行 `#EXTINF:<秒>,<标题>` 加一行绝对路径。输出到数据目录的 `playlist/` 子目录。
- `lib/services/video_launcher.dart`。接口按第 9.4 节。`enum LaunchResult { ok, unsupportedPlatform, failed }`。构造函数注入 `Future<Process> Function(String, List<String>)?`。

平台分派表：

| 平台 | 命令 | 结果 |
| --- | --- | --- |
| Windows | `cmd /c start "" <播放列表路径>` | ok |
| Linux | `xdg-open <播放列表路径>` | ok |
| 其他 | 不执行 | unsupportedPlatform |

选定 m3u8 的理由有两条。PotPlayer 与 VLC 都支持该格式。纯文本便于用户检查。

菜单入口放右键菜单，覆盖文件夹与剧集卡片。文案为「用外部播放器播放」。

待真机实测项：

- PotPlayer 与 VLC 接收多文件命令行参数的形式。
- 含空格路径传给 `start` 时的引号处理。
- VLC 的 `--playlist-enqueue` 行为。
- Android 走 `Intent.ACTION_VIEW` 加 FileProvider，见第 9.5 节。v1 不做。

验收：

- 新增 `test/services/playlist_writer_test.dart`。断言行序、时长取整、标题回退。
- 新增 `test/services/video_launcher_test.dart`。注入假 `start`，断言命令与参数。
- 真机验收在 Windows 机器上补做。

### 24.3 收藏选段

引擎已支持排他循环区间，不用定时器轮询。

- 首播时传边界：`play(..., looping: true, loopingStartAt: start, loopingEndAt: end)`（`flutter_soloud-4.1.7/lib/src/soloud.dart:1996-2006`）。
- 播放中改边界：`setLoopPoint`（`:2698`）与 `setLoopEndPoint`（`:2731`）。
- 单次跳转用 `seek`（`:2821`）。

表结构随 `media` 的下一版增量加。

```sql
CREATE TABLE media_segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  name TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_media_segments_media ON media_segments(media_id);
```

循环优先级：

| 优先级 | 条件 | 行为 |
| --- | --- | --- |
| 1 | 选段循环开启 | 只循环该段 |
| 2 | `RepeatMode.one` | 循环整曲 |
| 3 | `RepeatMode.all` | 顺序推进 |
| 4 | `RepeatMode.off` | 播完停止 |

界面放播放条。按钮文案为「选区」。拖动两个手柄定范围，松手才生效。段列表支持命名、跳转、循环、删除。

约束：

- 起止按毫秒存。`end_ms` 必须大于 `start_ms`。
- 越界值收口到曲目时长内。
- 一轨可存多段。

验收：

- 新增 `test/services/segment_service_test.dart`。覆盖起止换算、越界收口、优先级判定。
- 新增 `test/state/player_controller_test.dart` 的段循环用例。

### 24.4 内置视频播放器

状态为后置。第 9 节的 v1 范围暂时不变，仍不做应用内解码播放视频。

后端候选：

| 候选人 | 许可证 | 平台 | 结论 |
| --- | --- | --- | --- |
| media_kit | MIT 封装 | Windows / Linux / Android | 首选候选 |
| video_player | BSD-3-Clause | 不含 Windows 与 Linux | 排除 |
| flutter_vlc_player | GPL-2.0+ | 全平台 | 排除，触强 copyleft |
| 外部进程 | 无新增 | 全平台 | 等价功能 3，作兜底 |

libmpv 许可证核实结果（2026-09-28，本地实测）：

- `media_kit-1.2.6/LICENSE` 是 MIT。README 的 License 节不提 libmpv。
- Windows 库包在构建时下载预编译包。文件名见 `media_kit_libs_windows_video-1.0.11/windows/CMakeLists.txt:67`，来源是 `media-kit/libmpv-win32-video-build` 的 release（`:70`），以 `libmpv-2.dll` 动态链接（`:169`）。
- Linux 库包不打包 libmpv，改用系统库（`media_kit_libs_linux-1.2.1/linux/CMakeLists.txt`）。
- 该预编译包的构建选项未知。mpv 上游是多文件 LGPL-2.1+ 混部分 GPL-2+。最终许可证取决于 gpl 选项。本次核实未拿到可信结论。

三条定案路径：

1. 在 Windows 机器下载该 7z，查内部许可证文件或 `libmpv-2.dll` 的版本信息。
2. 询问 media_kit 维护者，参考 issue #20。
3. 自建 LGPL-only 的 libmpv，构建时关闭 gpl 选项。H.264 与 HEVC 解码属 LGPL 部分，可行。

法律口径：GPL 与 LGPL 的义务在分发时触发。自用不分发时不产生义务。要分发就需要 LGPL-only 加动态链接加声明，或改走外部进程。

### 24.5 第三方许可证口径

现有文件 `THIRD_PARTY_NOTICES.md` 已声明：只收 MIT、BSD、Apache、Zlib 等宽松许可证，不收 GPL 与 AGPL。

新增依赖时按三条执行。

1. 先查许可证，再写进 `pubspec.yaml`。
2. 宽松许可证直接收。LGPL 组件只在动态链接且附声明时收。
3. 每次新增依赖，同步追加 `THIRD_PARTY_NOTICES.md`。

### 24.6 落点

| 阶段 | 内容 |
| --- | --- |
| 阶段 10 | 播放模式补全（24.1） |
| 阶段 11 | 外链播放列表（24.2） |
| 阶段 12 | 收藏选段（24.3），含 `media_segments` 建表 |
| 待定 | 内置视频播放器（24.4），等许可证定案 |

阶段 10 到 12 插在阶段 4 之前实施。改动集中在播放层，与数据层重构不冲突。原阶段 4 到 9 的排期不变。
