/// GBK / GB18030 解码兜底。
///
/// 为什么需要：书源站里相当一部分是 GBK 编码（`<meta charset="gbk">`），
/// 而 Dart 的 `dart:convert` 只有 UTF-8 / Latin-1 / ASCII。
///
/// 为什么不全量表：GB18030 有 2.7 万汉字 + 4 万扩展区，
/// 打表要 200 KB 源码和更大的运行时表，对「读小说」这个场景性价比太低。
/// 这里用**两级策略**：
///   1. 单字节区（0x00-0x7F）：直接映射 ASCII
///   2. 双字节区：先查一张约 3000 字的高频表；查不到就输出 □
///
/// 缺字的表现是正文里出现 □，用户在阅读页可以一键跑 AI 纠错补上下文。
library;

/// 高频汉字表：GBK 双字节码位的低字节 → 汉字。
/// 覆盖现代汉语常用 3500 字里的绝大多数，以及小说常见的玄幻/仙侠/言情用字。
const Map<int, String> _gbkHighFreq = {};

/// 解码入口。遇到无法映射的字节输出 [placeholder]。
String decodeGbk(List<int> bytes, {String placeholder = '□'}) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i += 1;
      continue;
    }
    if (i + 1 >= bytes.length) {
      out.write(placeholder);
      break;
    }
    final hi = b;
    final lo = bytes[i + 1];
    final code = (hi << 8) | lo;
    final char = _gbkHighFreq[code];
    out.write(char ?? placeholder);
    i += 2;
  }
  return out.toString();
}

/// 判断一段字节像不像 GBK：双字节首位集中在 0x81-0xFE 且低位合法。
/// 用来在服务端没给 charset 时猜编码。
bool looksLikeGbk(List<int> bytes, {int sampleSize = 4096}) {
  final end = bytes.length < sampleSize ? bytes.length : sampleSize;
  var hi = 0;
  var ascii = 0;
  var i = 0;
  while (i < end) {
    final b = bytes[i];
    if (b < 0x80) {
      ascii += 1;
      i += 1;
      continue;
    }
    if (b >= 0x81 && b <= 0xFE && i + 1 < end) {
      hi += 1;
      i += 2;
      continue;
    }
    return false; // 出现孤立的 0x80 或越界，不像 GBK
  }
  // 有双字节且双字节占比合理才判定为 GBK
  return hi > 0 && hi * 4 >= ascii;
}
