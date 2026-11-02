/// DLsite 的 HTTP 抓取层。
///
/// 这里只发请求、判状态码、把响应体交给 `dlsite_models.dart` 解析。不碰数据库，
/// 也不碰界面。测试里用注入的 [DlsiteTransport] 顶掉真实网络。
library;

import 'dart:convert';
import 'dart:io';

import '../../utils/log_util.dart';
import 'dlsite_models.dart';
import 'dlsite_rate_limiter.dart';

/// 一次响应的最小信息。
class DlsiteResponse {
  const DlsiteResponse(this.status, this.body);

  final int status;
  final String body;
}

/// 传输层抽象。真实实现用 [HttpDlsiteTransport]。
abstract class DlsiteTransport {
  Future<DlsiteResponse> get(Uri url);
}

/// 用 `dart:io` 发 GET。只在 Windows 桌面与 Linux 上用。
class HttpDlsiteTransport implements DlsiteTransport {
  HttpDlsiteTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  @override
  Future<DlsiteResponse> get(Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader,
          'AsmrShelf/0.1 (personal music player; contact: local app)');
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      return DlsiteResponse(response.statusCode, body);
    } finally {
      client.close(force: true);
    }
  }
}

/// 抓取失败。[status] 为空表示连接层就失败了（超时、DNS）。
class DlsiteException implements Exception {
  const DlsiteException({this.status, required this.message});

  final int? status;
  final String message;

  @override
  String toString() =>
      'DlsiteException(${status == null ? '无状态码' : 'HTTP $status'}): $message';
}

/// 商品信息的抓取入口。
class DlsiteApi {
  DlsiteApi({
    DlsiteTransport? transport,
    DlsiteRateLimiter? limiter,
    DlsiteRetryPolicy? retry,
  })  : transport = transport ?? HttpDlsiteTransport(),
        limiter = limiter ?? DlsiteRateLimiter(),
        retry = retry ?? const DlsiteRetryPolicy();

  final DlsiteTransport transport;
  final DlsiteRateLimiter limiter;
  final DlsiteRetryPolicy retry;

  /// 站点前缀按作品所属分类走，`maniax` 覆盖同人与成人，`girls` 走另一套。
  static Uri productUri(String code, {String site = 'maniax'}) => Uri.parse(
      'https://www.dlsite.com/$site/api/=/product.json?workno=$code');

  /// 抓一部作品的元数据。
  ///
  /// 作品不存在时接口返回空数组，这里返回 null；网络与 HTTP 错误抛
  /// [DlsiteException]，由调用方决定提示文案。
  Future<DlsiteWork?> fetchWork(String code, {String site = 'maniax'}) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      throw const DlsiteException(message: '没有编号，抓不了');
    }
    final DlsiteResponse response;
    try {
      response = await retry.run(
        () => limiter.run(() => _get(productUri(normalized, site: site))),
        statusOf: (e) => e is DlsiteException ? e.status : null,
      );
    } on DlsiteException catch (e) {
      // 404 表示这个编号没有作品，属于正常结果，不当错误抛。
      if (e.status == 404) return null;
      rethrow;
    }
    if (response.body.trim() == '[]') return null;
    final work = parseProductJson(response.body);
    if (work == null) {
      throw const DlsiteException(message: '响应不是预期的商品结构');
    }
    return work;
  }

  Future<DlsiteResponse> _get(Uri url) async {
    try {
      final res = await transport.get(url);
      logInfo('DlsiteApi', 'GET $url -> ${res.status} (${res.body.length} 字节)');
      if (res.status != 200) {
        // 抛出来才能进重试策略：429/503 值得再试，403 直接失败。
        throw DlsiteException(
            status: res.status, message: '接口返回 HTTP ${res.status}');
      }
      return res;
    } on DlsiteException {
      rethrow;
    } catch (e) {
      throw DlsiteException(message: '连不上 DLsite：$e');
    }
  }
}
