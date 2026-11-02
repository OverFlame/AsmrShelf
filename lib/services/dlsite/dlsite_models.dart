/// DLsite `product.json` 的解析模型。
///
/// 只取应用要用的字段，其余原样留在 [DlsiteWork.rawJson] 里。字段含义与实测值
/// 见 `docs/DLsite_可获取数据说明.md` 第 3 节。这里不联网、不落库。
library;

import 'dart:convert';

/// 一个创作者条目（声优、画师、剧本、音乐、社团）。
class DlsiteCreator {
  const DlsiteCreator({
    required this.id,
    required this.name,
    required this.role,
  });

  /// DLsite 的创作者 id，可作去重键。
  final String id;
  final String name;

  /// 角色键：`voice_by`、`illust_by`、`scenario_by`、`created_by`、`music_by`。
  final String role;

  @override
  String toString() => '$role:$name($id)';
}

/// 一个分类标签。
class DlsiteGenre {
  const DlsiteGenre({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String toString() => '$name($id)';
}

/// 一张图：主图或样图。
class DlsiteImage {
  const DlsiteImage({required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  /// 接口里的地址是协议相对的，入库前补 `https:`。
  static String absoluteUrl(String url) =>
      url.startsWith('//') ? 'https:$url' : url;
}

/// 一部作品的元数据。
class DlsiteWork {
  const DlsiteWork({
    required this.workNo,
    required this.title,
    required this.rawJson,
    this.titleKana,
    this.altName,
    this.workType,
    this.ageCategory,
    this.makerName,
    this.makerId,
    this.seriesName,
    this.seriesId,
    this.description,
    this.rating,
    this.ratingCount,
    this.cover,
    this.samples = const [],
    this.genres = const [],
    this.creators = const [],
    this.languageEditions = const [],
    this.fileType,
    this.fileSizeBytes,
    this.releaseDate,
  });

  final String workNo;
  final String title;
  final String? titleKana;
  final String? altName;

  /// `ボイス・ASMR` 这类作品类型，用来筛掉非音频作品。
  final String? workType;

  /// `adult`、`general` 这类分级。
  final String? ageCategory;
  final String? makerName;
  final String? makerId;
  final String? seriesName;
  final String? seriesId;

  /// `intro_s`，纯文本，可能带 `○` 审查替换符。
  final String? description;

  /// 0 至 50 的整数，展示时除以 10。
  final int? rating;
  final int? ratingCount;

  /// `image_main`，560×420 的裁切版。
  final DlsiteImage? cover;

  /// `image_samples`，只在预览时按需下载，不预存。
  final List<DlsiteImage> samples;
  final List<DlsiteGenre> genres;
  final List<DlsiteCreator> creators;

  /// 官方多语言版本（`RJ…` 与语言名）。
  final List<String> languageEditions;
  final String? fileType;
  final int? fileSizeBytes;
  final String? releaseDate;
  final String rawJson;

  /// 声优名单。
  List<DlsiteCreator> get voiceActors =>
      creators.where((c) => c.role == 'voice_by').toList();

  /// 展示用的星级，0 至 5。
  double? get stars => rating == null ? null : rating! / 10;

  List<String> get genreNames => [for (final g in genres) g.name];

  /// 从接口的原始对象里取字段。缺字段不报错，取不到就是 null。
  factory DlsiteWork.fromJson(Map<String, Object?> map, {required String rawJson}) {
    int? asInt(Object? v) => switch (v) {
          final int i => i,
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        };

    List<DlsiteImage> images(Object? v) {
      if (v is! List) return const [];
      return [
        for (final item in v)
          if (item is Map && (item['url'] is String))
            DlsiteImage(
              url: DlsiteImage.absoluteUrl(item['url'] as String),
              width: asInt(item['width']),
              height: asInt(item['height']),
            ),
      ];
    }

    final creators = <DlsiteCreator>[];
    final creatorMap = map['creaters'];
    if (creatorMap is Map) {
      for (final entry in creatorMap.entries) {
        final role = entry.key.toString();
        final items = entry.value;
        if (items is! List) continue;
        for (final item in items) {
          if (item is! Map) continue;
          final name = item['name'];
          if (name is! String || name.isEmpty) continue;
          creators.add(DlsiteCreator(
            id: item['id']?.toString() ?? '',
            name: name,
            role: role,
          ));
        }
      }
    }

    final genres = <DlsiteGenre>[];
    final genreList = map['genres'];
    if (genreList is List) {
      for (final item in genreList) {
        if (item is! Map) continue;
        final name = item['name'];
        if (name is! String || name.isEmpty) continue;
        genres.add(DlsiteGenre(id: item['id']?.toString() ?? '', name: name));
      }
    }

    final editions = <String>[];
    final editionList = map['language_editions'];
    if (editionList is List) {
      for (final item in editionList) {
        if (item is! Map) continue;
        final language = item['language'];
        final workNo = item['workno'];
        if (language is String && workNo is String) {
          editions.add('$language $workNo');
        }
      }
    }

    final mainImage = map['image_main'];
    final release = map['regist_date'] ?? map['release_date'];

    return DlsiteWork(
      workNo: (map['workno'] ?? map['product_id'] ?? '').toString().toUpperCase(),
      title: (map['work_name'] ?? map['title_name'] ?? '').toString(),
      rawJson: rawJson,
      titleKana: map['work_name_kana'] as String?,
      altName: map['alt_name'] as String?,
      workType: map['work_type_string'] as String?,
      ageCategory: map['age_category_string'] as String?,
      makerName: map['maker_name'] as String?,
      makerId: map['maker_id']?.toString(),
      seriesName: map['series_name'] as String?,
      seriesId: map['series_id']?.toString(),
      description: map['intro_s'] as String?,
      rating: asInt(map['rate_average_star']),
      ratingCount: asInt(map['rate_count']),
      cover: mainImage is Map && mainImage['url'] is String
          ? DlsiteImage(
              url: DlsiteImage.absoluteUrl(mainImage['url'] as String),
              width: asInt(mainImage['width']),
              height: asInt(mainImage['height']),
            )
          : null,
      samples: images(map['image_samples']),
      genres: genres,
      creators: creators,
      languageEditions: editions,
      fileType: map['file_type_string'] as String?,
      fileSizeBytes: asInt(map['contents_file_size']),
      releaseDate: release is String ? release : null,
    );
  }
}

/// 解析 `product.json` 的响应体。
///
/// 接口返回的是单元素数组（实测），也兼容直接返回对象的情况。结构不对时返回
/// null，由调用方提示「这个 RJ 号没取到数据」。
DlsiteWork? parseProductJson(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  final first = switch (decoded) {
    List list => list.isEmpty ? null : list.first,
    Map<String, Object?> single => single,
    _ => null,
  };
  if (first is! Map) return null;
  return DlsiteWork.fromJson(
      Map<String, Object?>.from(first), rawJson: body);
}

