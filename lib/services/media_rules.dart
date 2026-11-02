/// 媒体类型白名单与路径归一化的唯一来源（BUILD_GUIDE 第 9.2、20.3 节）。
///
/// 扫描、导入、迁移与校验工具都从这里取规则，扩展名集合不许在别处再写一份。
/// 这个文件不依赖 Flutter，`dart run tool/migrate_check.dart` 才能跑纯 Dart 入口。
library;

/// 支持的音频格式
const audioExtensions = {
  '.mp3',
  '.wav',
  '.flac',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
};

/// 支持的图片格式
const imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
  '.tiff',
  '.tif',
  '.ico',
  '.heic',
  '.avif',
};

/// 支持的视频格式
const videoExtensions = {
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.m4v',
  '.flv',
  '.wmv',
  '.mpg',
  '.mpeg',
  '.ts',
  '.3gp',
};

/// 现在能解析的字幕格式，也是匹配规则使用的集合
const subtitleExtensions = {'.vtt', '.srt', '.lrc'};

/// 认得出、但还没有解析器的字幕格式（BUILD_GUIDE 第 23.3 节）
///
/// 扫描与入库要收下这些文件，界面按 `parsed: false` 标成「暂不支持解析」。
const placeholderSubtitleExtensions = {
  '.ass',
  '.ssa',
  '.ttml',
  '.dfxp',
  '.smi',
  '.sami',
};

/// 识别用的全部字幕扩展名：可解析的加占位格式
const knownSubtitleExtensions = {
  ...subtitleExtensions,
  ...placeholderSubtitleExtensions,
};

bool isAudioFile(String path) => _hasAny(path, audioExtensions);

bool isImageFile(String path) => _hasAny(path, imageExtensions);

bool isVideoFile(String path) => _hasAny(path, videoExtensions);

/// 认得出是字幕（含占位格式），扫描用这个。
bool isSubtitleFile(String path) => _hasAny(path, knownSubtitleExtensions);

/// 有解析器的字幕格式，匹配与解析用这个。
bool isParsableSubtitleFile(String path) => _hasAny(path, subtitleExtensions);

/// 按扩展名判定媒体类型，返回 `audio` / `image` / `video`，认不出返回 null。
///
/// 字幕不在返回值里：扫描侧用 [isSubtitleFile] 判断，媒体类型四值里的
/// `subtitle` 由字幕模块显式写入（BUILD_GUIDE 第 23 节）。
String? mediaTypeOfPath(String path) {
  if (isAudioFile(path)) return 'audio';
  if (isImageFile(path)) return 'image';
  if (isVideoFile(path)) return 'video';
  return null;
}

/// 取小写扩展名（含点）。没有扩展名或点在目录名里时返回空串。
///
/// `a` 与 `.gitignore` 返回空串，`a.tar.gz` 返回 `.gz`。
String extOfPath(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash + 1) return '';
  return path.substring(dot).toLowerCase();
}

/// 归一化路径，供 `media.name_lower` 模糊匹配用。
String nameLowerOfPath(String path) => path.toLowerCase();

/// 取路径里的文件名部分（最后一段），两种分隔符都认。
String baseNameOfPath(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

/// 取文件名主干：文件名去掉最后一个扩展名，两种分隔符都认。
///
/// 不要用 `p.basenameWithoutExtension` 代替：它只认**当前平台**的分隔符，
/// 而库里的路径字符串是在哪台机器上建的库就带哪台机器的分隔符。Windows 上
/// 建的库搬到 Linux 后，`D:\Music\a.mp3.srt` 的主干会被算成整条路径，
/// 字幕匹配档位、封面白名单这些判定会集体失效。
String stemOfPath(String path) {
  final name = baseNameOfPath(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// 自然排序键：把文件名主干里的连续数字补到四位，扩展名原样小写跟在后面。
///
/// `第1话.mp3` 存成 `第0001话.mp3`，`第10话.mp3` 存成 `第0010话.mp3`，
/// 这样按字符比较就能得到数值顺序（BUILD_GUIDE 第 20.2 节）。
/// 扩展名里的数字不补零，免得 `.mp3` 变成 `.mp0003`。
/// 超过四位的数字组原样保留，不截断。
String naturalSortKey(String name) {
  final slash = name.lastIndexOf(RegExp(r'[\\/]'));
  final dot = name.lastIndexOf('.');
  final hasExt = dot > slash + 1 && dot > 0;
  final stem = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot).toLowerCase() : '';
  return '${_padDigits(stem)}$ext';
}

/// 把字符串里的连续数字组补到四位。
String _padDigits(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final code = input.codeUnitAt(i);
    if (code >= 0x30 && code <= 0x39) {
      var j = i;
      while (j < input.length) {
        final c = input.codeUnitAt(j);
        if (c < 0x30 || c > 0x39) break;
        j++;
      }
      final digits = input.substring(i, j);
      if (digits.length < 4) {
        out.write('0' * (4 - digits.length));
      }
      out.write(digits);
      i = j;
    } else {
      out.writeCharCode(code);
      i++;
    }
  }
  return out.toString();
}

/// 路径对应的自然排序键，落 `media.sort_key` 用。
String sortKeyOfPath(String path) => naturalSortKey(baseNameOfPath(path));

/// Dart 侧的自然序比较（BUILD_GUIDE 第 20.2 节）。
///
/// `folders` 与 `works` 数量在百级，不加 sort_key 列，比较时即时算。
/// 所以「第10卷」排在「第2卷」后面。
int naturalCompare(String a, String b) =>
    naturalSortKey(a).compareTo(naturalSortKey(b));

bool _hasAny(String path, Set<String> exts) {
  final lower = path.toLowerCase();
  return exts.any((e) => lower.endsWith(e));
}
