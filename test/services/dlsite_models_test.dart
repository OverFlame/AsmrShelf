import 'package:asmrshelf/services/dlsite/dlsite_models.dart';
import 'package:asmrshelf/services/dlsite/dlsite_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份按实测结构裁小的响应：只留解析要用的字段。
const String sampleBody = '''
[{
  "workno": "RJ294126",
  "work_name": "作品名",
  "work_name_kana": "さくひんめい",
  "alt_name": "作品名 [副标题]",
  "work_type_string": "ボイス・ASMR",
  "age_category_string": "adult",
  "maker_name": "社团",
  "maker_id": "RG51931",
  "series_name": "系列",
  "series_id": "SRI0000026279",
  "intro_s": "简介文本",
  "rate_average_star": 50,
  "rate_count": 25497,
  "file_type_string": "WAV",
  "contents_file_size": 15297032709,
  "regist_date": "2020-08-30",
  "image_main": {
    "url": "//img.dlsite.jp/modpub/images2/work/doujin/RJ295000/RJ294126_img_main.jpg",
    "width": 560,
    "height": 420
  },
  "image_samples": [
    {"url": "//img.dlsite.jp/x_img_smp1.jpg", "width": 753, "height": 424},
    {"url": "https://img.dlsite.jp/x_img_smp2.jpg", "width": 753, "height": 424}
  ],
  "genres": [
    {"name": "ASMR", "id": 497},
    {"name": "癒し", "id": "056"}
  ],
  "creaters": {
    "voice_by": [{"id": 17394, "name": "逢坂成美"}],
    "illust_by": [{"id": 40902, "name": "ぬこぷし"}],
    "scenario_by": [],
    "created_by": [{"id": 38910, "name": "遊助Ｄ"}],
    "music_by": [{"id": 43429, "name": "青春×フェティシズム"}]
  },
  "language_editions": [
    {"language": "日本語", "workno": "RJ294126"},
    {"language": "簡体中文（公式翻訳）", "workno": "RJ324692"}
  ]
}]
''';

void main() {
  group('product.json 解析', () {
    test('身份、标题、社团与分级', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.workNo, 'RJ294126');
      expect(work.title, '作品名');
      expect(work.titleKana, 'さくひんめい');
      expect(work.altName, '作品名 [副标题]');
      expect(work.workType, 'ボイス・ASMR');
      expect(work.ageCategory, 'adult');
      expect(work.makerName, '社团');
      expect(work.makerId, 'RG51931');
      expect(work.seriesName, '系列');
      expect(work.description, '简介文本');
    });

    test('评分除以 10，文件体积按整数解析', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.rating, 50);
      expect(work.stars, 5.0);
      expect(work.ratingCount, 25497);
      expect(work.fileType, 'WAV');
      expect(work.fileSizeBytes, 15297032709);
      expect(work.releaseDate, '2020-08-30');
    });

    test('图片地址补上 https:，主图与样图分开', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.cover!.url,
          'https://img.dlsite.jp/modpub/images2/work/doujin/RJ295000/RJ294126_img_main.jpg');
      expect(work.cover!.width, 560);
      expect(work.samples.length, 2);
      expect(work.samples.first.url, 'https://img.dlsite.jp/x_img_smp1.jpg');
      expect(work.samples.last.url, 'https://img.dlsite.jp/x_img_smp2.jpg');
    });

    test('分类与创作者按角色分组，空角色不产生空条目', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.genreNames, ['ASMR', '癒し']);
      expect(work.genres.last.id, '056');
      expect(work.creators.length, 4);
      expect(work.voiceActors.single.name, '逢坂成美');
      expect(work.creators.map((c) => c.role).toSet(),
          {'voice_by', 'illust_by', 'created_by', 'music_by'});
    });

    test('多语言版本带 RJ 号', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.languageEditions,
          ['日本語 RJ294126', '簡体中文（公式翻訳） RJ324692']);
    });

    test('原始响应整段保留，落库要用', () {
      final work = parseProductJson(sampleBody)!;
      expect(work.rawJson, sampleBody);
    });

    test('坏输入返回 null，不抛异常', () {
      expect(parseProductJson('not json'), isNull);
      expect(parseProductJson('[]'), isNull);
      expect(parseProductJson('{"workno":'), isNull);
      expect(parseProductJson('"字符串"'), isNull);
    });

    test('缺字段时留空，不崩', () {
      final work = parseProductJson('[{"workno":"rj123456"}]')!;
      expect(work.workNo, 'RJ123456');
      expect(work.title, '');
      expect(work.cover, isNull);
      expect(work.stars, isNull);
      expect(work.creators, isEmpty);
    });
  });

  group('节流器', () {
    test('两次调用之间至少隔 minInterval', () async {
      var fakeNow = DateTime(2026, 1, 1);
      final slept = <Duration>[];
      final limiter = DlsiteRateLimiter(
        now: () => fakeNow,
        sleep: (d) async {
          slept.add(d);
          fakeNow = fakeNow.add(d);
        },
      );

      await limiter.run(() async => 1);
      final second = await limiter.run(() async => 2);

      expect(second, 2);
      expect(slept.length, 1);
      expect(slept.single, const Duration(seconds: 10));
    });

    test('已过够久的请求不睡', () async {
      var fakeNow = DateTime(2026, 1, 1);
      final slept = <Duration>[];
      final limiter = DlsiteRateLimiter(
        now: () => fakeNow,
        sleep: (d) async {
          slept.add(d);
          fakeNow = fakeNow.add(d);
        },
      );

      await limiter.run(() async => 1);
      fakeNow = fakeNow.add(const Duration(seconds: 30));
      await limiter.run(() async => 2);
      expect(slept, isEmpty);
    });

    test('三个请求串行，总等待是两次间隔', () async {
      var fakeNow = DateTime(2026, 1, 1);
      final slept = <Duration>[];
      final limiter = DlsiteRateLimiter(
        now: () => fakeNow,
        sleep: (d) async {
          slept.add(d);
          fakeNow = fakeNow.add(d);
        },
      );

      final order = <int>[];
      await Future.wait([
        limiter.run(() async => order.add(1)),
        limiter.run(() async => order.add(2)),
        limiter.run(() async => order.add(3)),
      ]);

      expect(order, [1, 2, 3]);
      expect(slept.length, 2);
    });
  });

  group('重试策略', () {
    test('429 与 503 退避重试两次后成功', () async {
      var calls = 0;
      final delays = <Duration>[];
      const policy = DlsiteRetryPolicy();
      final result = await policy.run(
        () async {
          calls++;
          if (calls < 3) throw const _HttpError(503);
          return 'ok';
        },
        statusOf: (e) => e is _HttpError ? e.status : null,
        sleep: (d) async => delays.add(d),
      );

      expect(result, 'ok');
      expect(calls, 3);
      expect(delays, [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
      ]);
    });

    test('403 不重试，原样抛出', () async {
      var calls = 0;
      const policy = DlsiteRetryPolicy();
      await expectLater(
        policy.run(
          () async {
            calls++;
            throw const _HttpError(403);
          },
          statusOf: (e) => e is _HttpError ? e.status : null,
          sleep: (d) async {},
        ),
        throwsA(isA<_HttpError>()),
      );
      expect(calls, 1);
    });

    test('重试用尽后抛最后一次的错误', () async {
      var calls = 0;
      const policy = DlsiteRetryPolicy();
      await expectLater(
        policy.run(
          () async {
            calls++;
            throw const _HttpError(429);
          },
          statusOf: (e) => e is _HttpError ? e.status : null,
          sleep: (d) async {},
        ),
        throwsA(isA<_HttpError>()),
      );
      expect(calls, 3);
    });
  });
}

class _HttpError implements Exception {
  const _HttpError(this.status);
  final int status;
}
