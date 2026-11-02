import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/media_rules.dart';

void main() {
  group('baseNameOfPath', () {
    test('两种分隔符都取最后一段', () {
      expect(baseNameOfPath('/m/第1卷/第10话.mp3'), '第10话.mp3');
      expect(baseNameOfPath(r'C:\m\第1卷\第10话.mp3'), '第10话.mp3');
      expect(baseNameOfPath('第10话.mp3'), '第10话.mp3');
      expect(baseNameOfPath('/m/第1卷/'), '');
    });
  });

  group('naturalSortKey', () {
    test('连续数字补到四位', () {
      expect(naturalSortKey('第1话.mp3'), '第0001话.mp3');
      expect(naturalSortKey('第10话.mp3'), '第0010话.mp3');
      expect(naturalSortKey('第100话.mp3'), '第0100话.mp3');
      expect(naturalSortKey('第1000话.mp3'), '第1000话.mp3');
    });

    test('超过四位的数字组原样保留', () {
      expect(naturalSortKey('第10000话.mp3'), '第10000话.mp3');
      expect(naturalSortKey('img20260928.png'), 'img20260928.png');
    });

    test('多组数字各自补零，非数字部分不动', () {
      expect(naturalSortKey('s1e2.mp4'), 's0001e0002.mp4');
      expect(naturalSortKey('A-7-B-12.ogg'), 'A-0007-B-0012.ogg');
    });

    test('没有数字时原样返回', () {
      expect(naturalSortKey('cover.jpg'), 'cover.jpg');
      expect(naturalSortKey(''), '');
      expect(naturalSortKey('第 十 话.mp3'), '第 十 话.mp3');
    });

    test('扩展名里的数字不补零，扩展名统一小写', () {
      expect(naturalSortKey('a.mp3'), 'a.mp3');
      expect(naturalSortKey('第2话.MP3'), '第0002话.mp3');
      expect(naturalSortKey('a.mp10'), 'a.mp10');
    });

    test('按键排序得到数值顺序', () {
      final names = ['第10话', '第2话', '第100话', '第1话', '第20话'];
      names.sort((a, b) => naturalSortKey(a).compareTo(naturalSortKey(b)));
      expect(names, ['第1话', '第2话', '第10话', '第20话', '第100话']);
    });
  });

  group('sortKeyOfPath', () {
    test('只看文件名，目录里的数字不参与', () {
      expect(sortKeyOfPath('/m/第2卷/第10话.mp3'), naturalSortKey('第10话.mp3'));
      expect(sortKeyOfPath(r'C:\m\第2卷\第3话.mp3'), naturalSortKey('第3话.mp3'));
    });
  });

  group('extOfPath 边界', () {
    test('无扩展名与点开头文件返回空串', () {
      expect(extOfPath('/m/README'), '');
      expect(extOfPath('/m/.gitignore'), '');
      expect(extOfPath('a'), '');
    });

    test('取最后一段扩展名并转小写', () {
      expect(extOfPath('/m/A.MP3'), '.mp3');
      expect(extOfPath('/m/a.tar.gz'), '.gz');
      expect(extOfPath(r'C:\m\a.PnG'), '.png');
    });

    test('点在目录名里不算扩展名', () {
      expect(extOfPath('/m/v1.2/README'), '');
    });
  });

  group('mediaTypeOfPath 与四个判定函数', () {
    test('音频、图片、视频各归各类', () {
      expect(mediaTypeOfPath('/m/a.flac'), 'audio');
      expect(mediaTypeOfPath('/m/a.HEIC'), 'image');
      expect(mediaTypeOfPath('/m/a.MKV'), 'video');
      expect(mediaTypeOfPath('/m/a.srt'), isNull,
          reason: '字幕不在这条判定里，扫描侧用 isSubtitleFile');
    });

    test('字幕扩展名自己一条路', () {
      // 能解析的三种：扫描、匹配、界面同步都走它们
      expect(isSubtitleFile('/m/a.vtt'), isTrue);
      expect(isSubtitleFile('/m/a.SRT'), isTrue);
      expect(isSubtitleFile('/m/a.lrc'), isTrue);
      expect(isParsableSubtitleFile('/m/a.vtt'), isTrue);
      expect(isParsableSubtitleFile('/m/a.SRT'), isTrue);
      expect(isParsableSubtitleFile('/m/a.lrc'), isTrue);
    });

    test('占位格式算字幕但不参与解析与匹配', () {
      for (final ext in placeholderSubtitleExtensions) {
        final path = '/m/a$ext';
        expect(isSubtitleFile(path), isTrue, reason: '$ext 要能被扫描到');
        expect(isParsableSubtitleFile(path), isFalse,
            reason: '$ext 没有解析器');
      }
      expect(placeholderSubtitleExtensions.length, 6);
      expect(knownSubtitleExtensions.length,
          subtitleExtensions.length + placeholderSubtitleExtensions.length);
    });

    test('扩展名匹配不看目录里的点号', () {
      expect(isImageFile('/m/v1.2/readme'), isFalse);
      expect(isVideoFile('/m/clip.mp4/readme'), isFalse,
          reason: '末尾不是 .mp4 就不算视频');
    });
  });
}
