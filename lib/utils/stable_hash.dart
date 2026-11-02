/// 稳定的 64 位哈希：同样输入永远得到同样输出，不依赖运行环境。
///
/// 用 FNV-1a 而不是 `String.hashCode`：后者是进程内的，Dart 不保证跨版本、
/// 跨平台一致，拿它命名缓存文件会出现「同一条路径在不同机器上落到不同文件」。
/// 也不用 sha256：这里只需要一个短文件名，不需要密码学强度，少一个依赖。
library;

import 'dart:convert';

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;
const int _mask64 = 0xFFFFFFFFFFFFFFFF;

/// 把 [text] 的 UTF-8 字节做 FNV-1a 64 位哈希，返回 16 位小写十六进制。
String stableHashHex(String text) {
  var hash = _fnvOffset;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    // Dart 的 int 在 VM 上是 64 位有符号，乘完截到 64 位再掩掉符号位。
    hash = (hash * _fnvPrime) & _mask64;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
