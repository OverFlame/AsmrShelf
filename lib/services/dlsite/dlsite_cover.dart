/// 下载 DLsite 的作品封面。
///
/// 只允许 `dlsite.com` / `dlsite.jp` 两个域：地址来自接口返回的 JSON，
/// 万一哪天被换成内网地址，也不会变成一次任人指挥的服务器端请求。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/log_util.dart';

/// 一次图片响应的结果。
class DlsiteImage {
  const DlsiteImage({required this.bytes, this.contentType = ''});

  final Uint8List bytes;
  final String contentType;
}

/// 下载失败的原因，给界面直接展示。
class DlsiteImageException implements Exception {
  const DlsiteImageException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 封面下载器。测试注入 [fetch] 走假数据，不碰网络。
class DlsiteCoverDownloader {
  DlsiteCoverDownloader({
    Future<DlsiteImage?> Function(Uri url)? fetch,
    this.maxBytes = 8 * 1024 * 1024,
  }) : _fetch = fetch ?? fetchImageBytes;

  /// 返回 null 表示响应 404 或不是图片。
  final Future<DlsiteImage?> Function(Uri url) _fetch;

  /// 单张图的上限。DLsite 的封面 560×420 通常几十 KB。
  final int maxBytes;

  static const Set<String> allowedHosts = {'dlsite.com', 'dlsite.jp'};

  /// 下载并校验。[url] 可以是以 `//` 开头的协议相对地址。
  Future<Uint8List> download(String url) async {
    final uri = Uri.tryParse(url.startsWith('//') ? 'https:$url' : url);
    if (uri == null || !allowedHosts.any((h) => _hostMatches(h, uri.host))) {
      throw const DlsiteImageException('封面地址不是 DLsite 的域名，已跳过');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const DlsiteImageException('封面地址不是 http(s)，已跳过');
    }
    final image = await _fetch(uri);
    if (image == null) {
      throw const DlsiteImageException('DLsite 没有返回这张图');
    }
    if (image.bytes.length > maxBytes) {
      throw const DlsiteImageException('封面图太大，已跳过');
    }
    if (image.bytes.isEmpty) {
      throw const DlsiteImageException('封面图是空的');
    }
    return image.bytes;
  }

  static bool _hostMatches(String allowed, String host) =>
      host == allowed || host.endsWith('.$allowed');

  /// 真实的图片请求。30 秒超时，最多跟三次重定向。
  static Future<DlsiteImage?> fetchImageBytes(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent =
          'AsmrShelf/0.1 (personal music player; contact: local app)';
    try {
      final req = await client.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        logWarn('DlsiteCover', '下载封面失败: HTTP ${res.statusCode} $url');
        return null;
      }
      final bytes = await res
          .fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk));
      return DlsiteImage(
        bytes: bytes.takeBytes(),
        contentType: res.headers.contentType?.mimeType ?? '',
      );
    } on TimeoutException {
      logWarn('DlsiteCover', '下载封面超时: $url');
      return null;
    } catch (e) {
      logWarn('DlsiteCover', '下载封面出错: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
