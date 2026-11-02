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
