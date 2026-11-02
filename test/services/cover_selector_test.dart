import 'package:asmrshelf/services/cover_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('文件名形态', () {
    test('通用白名单 40 分', () {
      expect(scoreCoverName('cover.jpg'), 40);
      expect(scoreCoverName('Folder.PNG'), 40);
      expect(scoreCoverName('front.webp'), 40);
    });

    test('编号形态 40 分，编号一致 45 分', () {
      expect(scoreCoverName('RJ294126_cover.jpg'), 40);
      expect(scoreCoverName('RJ294126_cover.jpg', code: 'RJ294126'), 45);
      expect(scoreCoverName('VJ010010 cover.jpg', code: 'RJ294126'), 40);
      expect(scoreCoverName('rj294126-cover.png', code: 'rj294126'), 45);
    });

    test('强词 35 分，弱词 25 分', () {
      expect(scoreCoverName('封面.png'), 35);
      expect(scoreCoverName('表紙.jpg'), 35);
      expect(scoreCoverName('缩略图.jpg'), 25);
      expect(scoreCoverName('thumbnail.png'), 25);
    });

    test('文件名就是编号时 30 分', () {
      expect(scoreCoverName('RJ294126.jpg', code: 'RJ294126'), 30);
    });

    test('不是图片返回 0', () {
      expect(scoreCoverName('cover.txt'), 0);
      expect(scoreCoverName('track01.mp3'), 0);
    });
  });

  group('路径信号', () {
    test('根目录白名单优先于深层白名单', () {
      final root = scoreCoverPath('cover.jpg');
      final deep = scoreCoverPath('disk1/extra/cover.jpg');
      expect(root, greaterThan(deep));
    });

    test('目录命中强词给 20 分', () {
      expect(
        scoreCoverPath('封面素材/a.png'),
        greaterThan(scoreCoverPath('杂项/a.png')),
      );
    });

    test('特典目录加 10 分', () {
      expect(
        scoreCoverPath('特典/img0001.jpg'),
        greaterThan(scoreCoverPath('img0001.jpg')),
      );
    });
  });

  group('尺寸分', () {
    test('竖版或方图加 15 分，横版不加', () {
      expect(scoreSize(600, 800), 15);
      expect(scoreSize(800, 600), 0);
    });

    test('长边小于 300 扣 20 分', () {
      expect(scoreSize(200, 200), -5);
    });

    test('非法尺寸不加不扣', () {
      expect(scoreSize(0, 100), 0);
    });
  });

  group('挑选', () {
    test('白名单胜过同目录的随意命名', () {
      final picked = pickBestCover([
        'a/image01.jpg',
        'a/cover.jpg',
      ]);
      expect(picked!.path, 'a/cover.jpg');
    });

    test('编号形态压过弱词', () {
      final picked = pickBestCover([
        '缩略图.jpg',
        'RJ294126_cover.jpg',
      ], code: 'RJ294126');
      expect(picked!.path, 'RJ294126_cover.jpg');
    });

    test('同分时浅目录优先', () {
      final picked = pickBestCover([
        'a/b/cover.jpg',
        'cover.jpg',
      ]);
      expect(picked!.path, 'cover.jpg');
    });

    test('同分同深时自然序', () {
      final picked = pickBestCover([
        '封面10.jpg',
        '封面2.jpg',
      ]);
      expect(picked!.path, '封面2.jpg');
    });

    test('尺寸分能改写结果', () {
      final picked = pickBestCover(
        ['cover.jpg', '封面.jpg'],
        sizeOf: (path) => path == 'cover.jpg'
            ? (width: 120, height: 120)
            : (width: 800, height: 1100),
      );
      expect(picked!.path, '封面.jpg');
    });

    test('没有候选时返回 null', () {
      expect(pickBestCover(['track01.mp3', 'readme.txt']), isNull);
    });

    test('exists 过滤掉已失联的路径', () {
      final picked = pickBestCover(
        ['cover.jpg', 'front.jpg'],
        exists: (path) => path == 'front.jpg',
      );
      expect(picked!.path, 'front.jpg');
    });
  });
}
