import 'dart:typed_data';

/// 测试素材：手搓的最小音频文件，避免往仓库里塞二进制。
Uint8List _syncSafe(int n) => Uint8List.fromList(
    [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]);

/// 造一个带内嵌封面的最小 mp3：ID3v2.3 标签 + 一个 APIC 帧 + 假音频帧。
Uint8List mp3WithEmbeddedCover(List<int> image) {
  const mime = 'image/jpeg';
  final payload = <int>[0x00, ...mime.codeUnits, 0x00, 0x03, 0x00, ...image];
  final frame = <int>[
    ...'APIC'.codeUnits,
    (payload.length >> 24) & 0xFF,
    (payload.length >> 16) & 0xFF,
    (payload.length >> 8) & 0xFF,
    payload.length & 0xFF,
    0x00,
    0x00,
    ...payload,
  ];
  final tag = <int>[
    ...'ID3'.codeUnits,
    0x03,
    0x00,
    0x00,
    ..._syncSafe(frame.length),
    ...frame,
  ];
  return Uint8List.fromList(
      [...tag, 0xFF, 0xFB, 0x90, 0x00, ...List.filled(400, 0)]);
}
