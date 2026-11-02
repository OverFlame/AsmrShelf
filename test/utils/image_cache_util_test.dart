import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/utils/image_cache_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv2_cache_guard');
    ImageCacheGuard.reset();
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() async {
    imageCache.clear();
    imageCache.clearLiveImages();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('第一次见到某个路径不算内容变化', () {
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);
  });

  test('mtime 变了返回 true，随后回到 false', () {
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);

    f.writeAsBytesSync([4, 5, 6]);
    f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));

    expect(ImageCacheGuard.evictIfChanged(f.path), isTrue);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);
  });

  test('文件不在了返回 false', () {
    expect(ImageCacheGuard.evictIfChanged('${dir.path}/nope.jpg'), isFalse);
  });

  test('内容变了但 mtime 没变不驱逐（记账只认 mtime）', () {
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final stamp = f.lastModifiedSync();
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);

    f.writeAsBytesSync([9, 9, 9, 9]);
    f.setLastModifiedSync(stamp);

    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);
  });

  test('forget 之后重新按首次对待', () {
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);

    f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    ImageCacheGuard.forget(f.path);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);
    expect(ImageCacheGuard.evictIfChanged(f.path), isFalse);
  });

  test('invalidate 第一次见到也驱逐，覆盖同一路径换图', () async {
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final provider = FileImage(f);
    final image = await createTestImage(width: 1, height: 1);
    imageCache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(
        Future<ImageInfo>.value(ImageInfo(image: image)),
      ),
    );
    expect(imageCache.containsKey(provider), isTrue);

    ImageCacheGuard.invalidate(f.path);
    expect(imageCache.containsKey(provider), isFalse);
  });
}
