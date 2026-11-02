# AsmrShelf

本地 ASMR 音声库。以「作品」为单位管理本地音频，支持导入、播放、标签、续播与 DLsite 元数据补全。

> **现状**：从 MediaShelf 剥离进行中。阶段一「复制与改名」已完成，代码仍是完整的多媒体骨架，视觉模块与相关依赖将在阶段二删除。

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

打包脚本在 `scripts/`。

## 数据位置

应用私有支持目录下的 `AsmrShelf/`，库文件 `asmr_shelf.db`。同目录还有 `covers/`、`settings.json` 与 `logs/`。目录可用 `APP_DATA_DIR` 覆盖。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/需求研究与设计备忘.md` | 代码理解、四项需求设计、封面回退链与写盘规则 |
| `BUILD_GUIDE.md` | 施工手册（沿用自 MediaShelf，阶段推进时逐步改写） |
| `PROJECT_STEPS.md` | 环境、验收、提交与版本号约定 |
| `PROJECTLOG.md` | 逐阶段记录 |
