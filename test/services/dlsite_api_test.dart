import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/dlsite/dlsite_rate_limiter.dart';

/// 固定响应体顶掉真实网络：一份能解析的、一份空的、一份残缺的、一份错误页。
const String okBody = '''
[{
  "workno": "RJ294126",
  "work_name": "作品名",
  "maker_name": "社团",
  "image_main": {"url": "//img.dlsite.jp/a.jpg", "width": 560, "height": 420},
  "genres": [{"name": "ASMR", "id": 497}],
  "creaters": {"voice_by": [{"id": 1, "name": "声优"}]}
}]''';

const String htmlErrorPage = '''
<!DOCTYPE html><html><head><title>エラー</title></head>
<body><h1>403 Forbidden</h1></body></html>
''';

/// 记录调用次数的假传输层，可按顺序吐出预设响应或抛错。
class FakeTransport implements DlsiteTransport {
  FakeTransport(this.responses);

  final List<Object> responses;
  int calls = 0;
  final List<Uri> urls = [];

  @override
  Future<DlsiteResponse> get(Uri url) async {
    urls.add(url);
    final i = calls < responses.length ? calls : responses.length - 1;
    calls++;
    final next = responses[i];
    if (next is Exception) throw next;
    return next as DlsiteResponse;
  }
}

/// 测试不等待 10 秒节流与退避。
DlsiteApi buildApi(FakeTransport transport, {int maxAttempts = 1}) => DlsiteApi(
  transport: transport,
  limiter: DlsiteRateLimiter(minInterval: Duration.zero, sleep: (_) async {}),
  retry: DlsiteRetryPolicy(maxAttempts: maxAttempts, baseDelay: Duration.zero),
);

void main() {
  group('正常响应', () {
    test('数组里有一条就解析成作品', () async {
      final transport = FakeTransport([const DlsiteResponse(200, okBody)]);
      final work = await buildApi(transport).fetchWork('rj294126');
      expect(work, isNotNull);
      expect(work!.workNo, 'RJ294126');
      expect(work.title, '作品名');
      expect(
        transport.urls.single.toString(),
        'https://www.dlsite.com/maniax/api/=/product.json?workno=RJ294126',
      );
    });

    test('空数组给出「空数据」提示，而不是笼统的没找到', () async {
      final transport = FakeTransport([const DlsiteResponse(200, '[]')]);
      await expectLater(
        buildApi(transport).fetchWork('RJ294126'),
        throwsA(isA<DlsiteException>()
            .having((e) => e.message, 'message', contains('空数据'))),
      );
    });

    test('404 同样当没找到', () async {
      final transport = FakeTransport([const DlsiteResponse(404, '')]);
      expect(await buildApi(transport).fetchWork('RJ294126'), isNull);
    });

    test('字段缺失时其余字段照常解析', () async {
      final transport = FakeTransport([
        const DlsiteResponse(200, '[{"workno": "RJ294126"}]'),
      ]);
      final work = await buildApi(transport).fetchWork('RJ294126');
      expect(work!.workNo, 'RJ294126');
      expect(work.title, isEmpty);
      expect(work.genres, isEmpty);
    });

    test('协议相对图片地址补成 https', () async {
      final transport = FakeTransport([const DlsiteResponse(200, okBody)]);
      final work = await buildApi(transport).fetchWork('RJ294126');
      expect(work!.cover!.url, startsWith('https://img.dlsite.jp/'));
    });
  });

  group('失败响应', () {
    test('500 抛带状态码的异常', () async {
      final transport = FakeTransport([const DlsiteResponse(500, 'oops')]);
      await expectLater(
        buildApi(transport).fetchWork('RJ294126'),
        throwsA(isA<DlsiteException>().having((e) => e.status, 'status', 500)),
      );
    });

    test('403 不重试，只发一次请求', () async {
      final transport = FakeTransport([const DlsiteResponse(403, '')]);
      await expectLater(
        buildApi(transport, maxAttempts: 3).fetchWork('RJ294126'),
        throwsA(isA<DlsiteException>()),
      );
      expect(transport.calls, 1);
    });

    test('503 重试用尽后抛最后一次的错误', () async {
      final transport = FakeTransport([const DlsiteResponse(503, 'busy')]);
      await expectLater(
        buildApi(transport, maxAttempts: 3).fetchWork('RJ294126'),
        throwsA(isA<DlsiteException>().having((e) => e.status, 'status', 503)),
      );
      expect(transport.calls, 3);
    });

    test('503 后恢复时取到第二次的响应', () async {
      final transport = FakeTransport([
        const DlsiteResponse(503, 'busy'),
        const DlsiteResponse(200, okBody),
      ]);
      final work = await buildApi(
        transport,
        maxAttempts: 3,
      ).fetchWork('RJ294126');
      expect(work, isNotNull);
      expect(transport.calls, 2);
    });

    test('超时抛不带状态码的异常', () async {
      final transport = FakeTransport([
        TimeoutException('连接超时', Duration.zero),
      ]);
      await expectLater(
        buildApi(transport).fetchWork('RJ294126'),
        throwsA(
          isA<DlsiteException>().having((e) => e.status, 'status', isNull),
        ),
      );
    });

    test('连接错误也重试：两次失败后第三次成功', () async {
      final transport = FakeTransport([
        TimeoutException('连接超时', Duration.zero),
        const SocketException('DNS 失败'),
        const DlsiteResponse(200, okBody),
      ]);
      final work = await buildApi(
        transport,
        maxAttempts: 3,
      ).fetchWork('RJ294126');
      expect(work, isNotNull);
      expect(transport.calls, 3);
    });

    test('连接错误重试用尽后抛最后一次的无状态码异常', () async {
      final transport = FakeTransport([
        TimeoutException('连接超时', Duration.zero),
      ]);
      await expectLater(
        buildApi(transport, maxAttempts: 3).fetchWork('RJ294126'),
        throwsA(
          isA<DlsiteException>().having((e) => e.status, 'status', isNull),
        ),
      );
      expect(transport.calls, 3);
    });

    test('非法 JSON 与 HTML 错误页都报「不是预期的商品结构」', () async {
      for (final body in ['{not json', htmlErrorPage]) {
        final transport = FakeTransport([DlsiteResponse(200, body)]);
        await expectLater(
          buildApi(transport).fetchWork('RJ294126'),
          throwsA(
            isA<DlsiteException>().having(
              (e) => e.message,
              'message',
              contains('不是预期的商品结构'),
            ),
          ),
          reason: '响应体开头：${body.substring(0, 8)}',
        );
      }
    });

    test('空编号不发请求', () async {
      final transport = FakeTransport([const DlsiteResponse(200, okBody)]);
      await expectLater(
        buildApi(transport).fetchWork('   '),
        throwsA(isA<DlsiteException>()),
      );
      expect(transport.calls, 0);
    });
  });

  group('代理', () {
    test('留空表示直连', () {
      expect(normalizeDlsiteProxy('   '), isEmpty);
      expect(proxyDirectiveFor(''), 'DIRECT');
    });

    test('不带协议的 host:port 补成 http', () {
      expect(normalizeDlsiteProxy('127.0.0.1:7897'), 'http://127.0.0.1:7897');
      expect(proxyDirectiveFor('127.0.0.1:7897'), 'PROXY 127.0.0.1:7897');
    });

    test('保留 https 代理与尾部斜杠会被去掉', () {
      expect(
        normalizeDlsiteProxy(' https://proxy.example:8443/ '),
        'https://proxy.example:8443',
      );
      expect(
        proxyDirectiveFor('https://proxy.example:8443/'),
        'PROXY proxy.example:8443',
      );
    });

    test('拒绝 SOCKS、带路径和带账号的地址', () {
      for (final bad in [
        'socks5://127.0.0.1:7897',
        'http://127.0.0.1:7897/proxy',
        'http://user:pass@127.0.0.1:7897',
      ]) {
        expect(
          () => normalizeDlsiteProxy(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });
}
