# AsmrShelf

本地 ASMR 音声库。以「作品」为单位管理本地音频，支持导入、播放、标签、续播与 DLsite 元数据补全。

> **现状**：从 MediaShelf 剥离进行中。阶段一「复制与改名」、阶段二「移除多媒体界面层」、阶段三「schema v1」已完成；阶段四「拆 AppState」清掉了视觉状态，并拆出 `SettingsState`、`ImportState`、`TagState`、`CoverState`、`LibraryState`、`PlaybackState`、`DlsiteState` 七个状态对象；阶段六「接 DLsite」已通（解析、10 秒节流、429/503 与连接错误重试、7 天缓存、写 `work_metadata`、分类与声优成标签、预览对话框、远程封面下载、作品详情头）；设置页可填 DLsite 代理（如 `http://127.0.0.1:7897`），API 与封面下载共用。作品支持按 RJ 号排序；同系列已导入 ≥2 部时首页合成「书套」，可进系列页查看成员，侧栏与面包屑保留系列节点，系列卡多选按整组作品处理。DLsite 返回空数组 `[]` 时会明确提示编号无公开元数据。首页只剩音频栏；数据库版本 v1，版本不一致直接拒绝打开，不删用户数据。另有一次性的「从根目录导入作品」入口（`tool/import_cli.dart` 与首页按钮）、作品级的「从文件里找封面」与「抓取 DLsite 元数据」两个按钮、作品层多选与批量删除/刷新/打标签/排队抓取，以及设置页的「自动导入」：支持多根目录、扫描并确认（新建/有新增/无变化/已忽略/读不了五态）与忽略列表，导入后还可选择自动排队刮削（默认关）；「数据」页能导出手动备份。

## 阶段进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 一 | 复制工作树、改名、基线验证 | 完成（`426764b`） |
| 二 | 删多媒体界面层与视觉依赖 | 完成（`e74e703`） |
| 三 | schema v1、拒绝降级、作品标签与元数据表 | 完成（`9b1f6bc` 及补充） |
| 四 | 拆 AppState 为七个状态对象 | 完成 |
| 五 | 重做音频界面 | 已按指南核对：三栏、详情头、曲目行、播放条齐 |
| 六 | 接 DLsite 元数据 | 完成：抓取、预览、应用、远程封面、作品详情头 |
| 七 | 测试与验收 | 完成：720 例全过，DLsite 抓取用固定响应覆盖 12 种情况，并覆盖代理、连接重试、RJ 排序与系列书套；Windows 侧用户确认可跑 |
| 八 | 发布准备（图标、签名、隐私说明、无网络与坏库启动验收） | 部分完成：应用图标、Windows 版本资源、关于页非官方声明、手动备份导出、无网络与坏库启动测试已有；代码签名、安装包与隐私说明页未做 |

## 目标与边界

| 项 | 决定 |
| --- | --- |
| 首发平台 | Windows（音频都在 Windows 本机） |
| 次要平台 | Linux，只用于验证能否编译、有无致命错误 |
| 应用名 | AsmrShelf |
| 包名 | `com.overflame.asmrshelf` |
| 不做 | 与 MediaShelf 共用数据库和数据目录，也不读它的库 |

## 技术栈

| 层 | 选型 |
| --- | --- |
| 界面 | Flutter 3.47 + Provider |
| 存储 | sqflite；桌面走 sqflite_common_ffi |
| 播放 | flutter_soloud 4.1.7 |
| 标签读取 | audio_metadata_reader |
| 文件选择 | file_picker |

## 构建与运行

Linux 构建必须设置 `NO_XIPH_LIBS=1`。sqlite3 走系统库：Linux 用自带的 `libsqlite3.so`，Windows 用系统自带的 `winsqlite3.dll`。

```bash
export PATH="$HOME/flutter/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/lib"
flutter pub get
flutter analyze
flutter test
```

一次性把整理好的音频目录导进库（命令行，Windows 上也在仓库根执行）：

```bash
dart run tool/import_cli.dart --root <作品根目录> --db <应用库文件> [--nested] [--dry-run]
```

`--db` 指向应用支持目录下的 `AsmrShelf/asmr_shelf.db`。不加 `--db` 只做扫描预览。

打包脚本在 `scripts/`。

## 数据位置

应用私有支持目录下的 `AsmrShelf/`，库文件 `asmr_shelf.db`。同目录还有 `covers/`、`settings.json` 与 `logs/`。目录可用 `APP_DATA_DIR` 覆盖。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/需求研究与设计备忘.md` | 代码理解、四项需求设计、封面回退链与写盘规则 |
| `docs/DLsite_可获取数据说明.md` | DLsite 接口实测：能抓到什么、抓不到什么、抓取纪律 |
| `docs/剥离阶段交接清单.md` | 阶段进度、剩余偏差、阶段四到六的接续顺序 |
| `BUILD_GUIDE.md` | 施工手册（沿用自 MediaShelf，阶段推进时逐步改写） |
| `PROJECT_STEPS.md` | 环境、验收、提交与版本号约定 |
| `PROJECTLOG.md` | 逐阶段记录 |
