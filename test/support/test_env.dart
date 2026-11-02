import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 把 `getApplicationSupportDirectory()` 指到指定目录。
///
/// 三十多个测试文件各抄过一份同样的实现，这里留一份。
class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}
