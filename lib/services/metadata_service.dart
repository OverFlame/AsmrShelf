import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import '../utils/log_util.dart';

/// 解析后的曲目元数据
class TrackMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final Uint8List? pictureBytes;
  final String? pictureMimetype;

  const TrackMetadata({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.pictureBytes,
    this.pictureMimetype,
  });

  static const empty = TrackMetadata();
}

/// 元数据读取服务（基于 audio_metadata_reader，支持 mp3 / wav）
class MetadataService {
  MetadataService._();

  static TrackMetadata read(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return TrackMetadata.empty;
      final m = readMetadata(f, getImage: true);
      int? durationMs;
      if (m.duration != null) {
        durationMs = m.duration!.inMilliseconds;
      }
      Uint8List? pic;
      String? mime;
      if (m.pictures.isNotEmpty) {
        pic = m.pictures.first.bytes;
        mime = m.pictures.first.mimetype;
      }
      return TrackMetadata(
        title: m.title,
        artist: m.artist,
        album: m.album,
        durationMs: durationMs,
        pictureBytes: pic,
        pictureMimetype: mime,
      );
    } catch (e) {
      logDebug('Metadata', '读取元数据失败 $path: $e');
      return TrackMetadata.empty;
    }
  }

  /// 解析一批曲目的元数据，返回顺序与 [paths] 一致。
  ///
  /// [read] 要整块读文件、还要解码内嵌封面，在调用方 isolate 上跑会把界面
  /// 卡住一帧以上；整批丢给 [compute] 在单独 isolate 里跑（报告第 25 项）。
  static Future<List<TrackMetadata>> readAll(List<String> paths) {
    if (paths.isEmpty) return Future.value(const <TrackMetadata>[]);
    return compute(_readAllSync, paths, debugLabel: 'asmrshelf.metadata');
  }

  /// 测试用：判断 [_readAllSync] 是否跑在调用方 isolate 上。
  ///
  /// 每个 isolate 有自己的静态变量，解析跑到别的 isolate 时这里的值不变。
  @visibleForTesting
  static bool debugParsedOnCallerIsolate = false;

  static List<TrackMetadata> _readAllSync(List<String> paths) {
    debugParsedOnCallerIsolate = true;
    return paths.map(read).toList();
  }
}
