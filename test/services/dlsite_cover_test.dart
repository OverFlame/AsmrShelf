import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/dlsite/dlsite_cover.dart';

Uint8List _png() => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0, 0, 0, 0, 0, 0, 0, 0,
    ]);

void main() {
  test('只接受 dlsite.com 与 dlsite.jp 的地址', () async {
    final called = <Uri>[];
    final downloader = DlsiteCoverDownloader(fetch: (url) async {
      called.add(url);
      return DlsiteImage(bytes: _png());
    });

    // 协议相对地址补成 https 后照常下载。
    expect(await downloader.download('//img.dlsite.jp/main.jpg'), isNotEmpty);
    expect(called.single.toString(), 'https://img.dlsite.jp/main.jpg');

    // 别的域一个请求都不发。
    for (final url in [
      'https://evil.example/main.jpg',
      'https://dlsite.com.evil.example/x.jpg',
      'http://127.0.0.1:8080/cover.jpg',
      'file:///etc/passwd',
    ]) {
      await expectLater(
        downloader.download(url),
        throwsA(isA<DlsiteImageException>()),
        reason: url,
      );
    }
    expect(called, hasLength(1));
  });

  test('响应为空、过大、404 都当作失败', () async {
    await expectLater(
      DlsiteCoverDownloader(fetch: (_) async => null).download(
          'https://img.dlsite.jp/a.jpg'),
      throwsA(isA<DlsiteImageException>()),
    );
    await expectLater(
      DlsiteCoverDownloader(fetch: (_) async => DlsiteImage(bytes: Uint8List(0)))
          .download('https://img.dlsite.jp/a.jpg'),
      throwsA(isA<DlsiteImageException>()),
    );
    await expectLater(
      DlsiteCoverDownloader(
        fetch: (_) async => DlsiteImage(bytes: Uint8List(64)),
        maxBytes: 16,
      ).download('https://img.dlsite.jp/a.jpg'),
      throwsA(isA<DlsiteImageException>()),
    );
  });

  test('正常返回字节', () async {
    final bytes = _png();
    final got = await DlsiteCoverDownloader(
      fetch: (_) async => DlsiteImage(bytes: bytes),
    ).download('https://img.dlsite.jp/a.jpg');
    expect(got, bytes);
  });
}
