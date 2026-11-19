/// 应用日志：写文件、能在 App 里看、能一键打包导出。
///
/// 为什么要这么细：
///   1. `adb logcat` 在这台机器上连不通（ADB 接口绑的是 WinUSB 驱动）
///   2. `debugPrint` 在 release 包里会被裁掉，用户装的正式包看不到
///   3. 书源抓取失败的原因藏在「HTTP 状态 / 规则匹配 / 节点数」三处，
///      只记一句「没抓到书」根本查不出来
///
/// 格式（单行，便于 grep）：
/// ```
/// 2026-11-19T20:01:33.123+08:00 [INFO ] explore: 开始 | op=fetchCategory cat=玄幻 entries=659 limit=24
/// ```
/// 带 `key=value` 的字段放在 `|` 后面，导出时能按 key 捞。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { debug, info, warn, error }

/// 全局日志器。任何地方 `AppLog.info('...')` 即可。
abstract final class AppLog {
  static Directory? _dir;
  static RandomAccessFile? _handle;
  static DateTime? _day;
  static int _written = 0;

  /// 单文件上限。抓书源会写很多行，给到 8 MB 一轮。
  static const _maxBytes = 8 * 1024 * 1024;

  /// 保留天数。出问题一般当天就要导，7 天足够。
  static const _keepDays = 7;

  /// 内存里留最近 2000 行，设置页不用读盘也能秒开。
  static final List<String> _recent = [];
  static const _recentLimit = 2000;

  /// debug 级别是否写盘（默认关，避免刷屏；查问题时可在日志页打开）。
  static bool verbose = false;

  static Future<void> init() async {
    try {
      // 日志放**下载目录**：`/sdcard/Download/fanhuo-logs/`
      //
      // 为什么不是 Android/data：Android 11 起那个目录连文件管理器都进不去，
      // 要额外授权，手机上根本找不到。下载目录谁都能开 ——
      // 文件管理、微信发送、数据线拷贝都行。
      Directory? dir;
      for (final path in const [
        '/sdcard/Download/fanhuo-logs',
        '/storage/emulated/0/Download/fanhuo-logs',
        '/storage/emulated/0/Documents/fanhuo-logs',
      ]) {
        try {
          final candidate = Directory(path);
          await candidate.create(recursive: true);
          // 真能写才算数
          final probe =
              File('${candidate.path}${Platform.pathSeparator}.probe');
          await probe.writeAsString('ok', flush: true);
          await probe.delete();
          dir = candidate;
          break;
        } catch (_) {
          continue;
        }
      }
      if (dir == null) {
        final base = await getApplicationSupportDirectory();
        dir = Directory('${base.path}${Platform.pathSeparator}logs');
        await dir.create(recursive: true);
      }
      _dir = dir;
      await _rotateIfNeeded();
      await _cleanupOld();
      info('AppLog', '日志已启用', fields: {
        'path': dir.path,
        'external': !dir.path.contains('/data/user/'),
        'verbose': verbose,
      });
    } catch (error) {
      debugPrint('AppLog 初始化失败：$error');
    }
  }

  /// 记一条。`fields` 会按 `key=value` 追加，方便导出后 grep。
  static void log(
    LogLevel level,
    String tag,
    Object? message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stack,
  }) {
    // DEBUG 级别默认不落盘，避免抓书源时把盘刷满
    if (level == LogLevel.debug && !verbose) {
      debugPrint('[$tag] $message');
      return;
    }
    final now = DateTime.now();
    final buffer = StringBuffer()
      ..write(_stamp(now))
      ..write(' [')
      ..write(level.name.toUpperCase().padRight(5))
      ..write('] ')
      ..write(tag)
      ..write(': ')
      ..write(message);
    if (fields != null && fields.isNotEmpty) {
      buffer.write(' | ');
      var first = true;
      for (final entry in fields.entries) {
        if (!first) buffer.write(' ');
        first = false;
        buffer
          ..write(entry.key)
          ..write('=')
          ..write(_oneLine('${entry.value}'));
      }
    }
    if (error != null) {
      buffer
        ..write(' || error=')
        ..write(_oneLine('$error'));
    }
    final line = buffer.toString();
    _recent.add(line);
    if (_recent.length > _recentLimit) _recent.removeAt(0);
    debugPrint(line);
    unawaited(_write(line, now));
    if (stack != null && level == LogLevel.error) {
      // 堆栈单独成行，避免主行过长
      final stackLines = stack.toString().split('\n').take(12);
      for (final s in stackLines) {
        final sl = '${_stamp(now)} [STACK] $tag: ${s.trim()}';
        _recent.add(sl);
        unawaited(_write(sl, now));
      }
    }
  }

  static void debug(String tag, Object? message, {Map<String, Object?>? fields}) =>
      log(LogLevel.debug, tag, message, fields: fields);
  static void info(String tag, Object? message, {Map<String, Object?>? fields}) =>
      log(LogLevel.info, tag, message, fields: fields);
  static void warn(String tag, Object? message,
          {Map<String, Object?>? fields, Object? error, StackTrace? stack}) =>
      log(LogLevel.warn, tag, message,
          fields: fields, error: error, stack: stack);
  static void error(String tag, Object? message,
          {Map<String, Object?>? fields, Object? error, StackTrace? stack}) =>
      log(LogLevel.error, tag, message,
          fields: fields, error: error, stack: stack);

  /// 计时器：`final t = AppLog.timer(); ... t.stop('tag', '做了什么')`
  static Timing timer() => Timing._(DateTime.now());

  /// 读最近 N 行（优先内存，内存不够再读盘）。
  static Future<String> dump({int lines = 1000}) async {
    final fromMemory = _recent.length >= lines
        ? _recent.sublist(_recent.length - lines)
        : _recent.toList();
    if (fromMemory.length >= lines || _dir == null) {
      return fromMemory.join('\n');
    }
    // 队列里可能还有没写完的，等它落盘再读
    await _queue;
    final file = await _currentFile();
    if (file == null || !await file.exists()) return fromMemory.join('\n');
    try {
      final all = await file.readAsLines();
      final tail = all.length > lines ? all.sublist(all.length - lines) : all;
      return tail.join('\n');
    } catch (_) {
      return fromMemory.join('\n');
    }
  }

  /// 导出 zip：所有日志文件 + 一份环境快照。返回 zip 路径与大小。
  static Future<ExportResult?> exportBundle({
    Map<String, String> extraFiles = const {},
  }) async {
    final dir = _dir;
    if (dir == null) return null;
    try {
      // 先把队列里没落盘的行全写完，否则导出的包是残缺的
      await _queue;
      await _handle?.flush();
      final stamp = _stamp(DateTime.now()).replaceAll(':', '').replaceAll('.', '');
      final zipFile = File('${dir.path}${Platform.pathSeparator}fanhuo-log-$stamp.zip');
      final sink = _ZipWriter();

      // 1. 环境快照
      final env = StringBuffer()
        ..writeln('导出时间：${DateTime.now().toIso8601String()}')
        ..writeln('应用包名：com.fanhuo.reader')
        ..writeln('平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Dart：${Platform.version}')
        ..writeln('日志分级：${verbose ? "详细" : "普通"}')
        ..writeln('日志目录：${dir.path}');
      sink.add('环境.txt', utf8.encode(env.toString()));

      // 2. 所有日志文件
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.log')) continue;
        final name = entity.uri.pathSegments.last;
        sink.add('logs/$name', await entity.readAsBytes());
      }

      // 3. 调用方附带的文件（书源快照、失败清单等）
      for (final entry in extraFiles.entries) {
        sink.add(entry.key, utf8.encode(entry.value));
      }

      final bytes = sink.close();
      await zipFile.writeAsBytes(bytes, flush: true);
      return ExportResult(path: zipFile.path, bytes: bytes.length);
    } catch (error, stack) {
      log(LogLevel.error, 'AppLog', '导出失败', error: error, stack: stack);
      return null;
    }
  }

  /// 日志文件路径（设置页显示给用户）。
  static Future<String> directoryPath() async => _dir?.path ?? '（未初始化）';

  /// 清空日志。
  static Future<void> clear() async {
    _recent.clear();
    try {
      await _handle?.close();
      _handle = null;
      final dir = _dir;
      if (dir == null) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          await entity.delete();
        }
      }
      info('AppLog', '日志已清空');
    } catch (_) {}
  }

  static String _stamp(DateTime now) {
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final base = '${now.year}-${_two(now.month)}-${_two(now.day)}'
        'T${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
    return '$base$sign$hh:$mm';
  }

  /// 字段值里的换行会把单行日志拆开，压成 `\n` 字面量。
  static String _oneLine(String value) =>
      value.replaceAll('\r', ' ').replaceAll('\n', r'\n');

  static Future<File?> _currentFile() async {
    final dir = _dir;
    if (dir == null) return null;
    final now = DateTime.now();
    return File(
        '${dir.path}${Platform.pathSeparator}app-${now.year}${_two(now.month)}${_two(now.day)}.log');
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static Future<void> _rotateIfNeeded() async {
    final now = DateTime.now();
    final dayChanged = _day == null ||
        _day!.year != now.year ||
        _day!.month != now.month ||
        _day!.day != now.day;
    if (dayChanged) {
      await _handle?.close();
      _handle = null;
      _day = now;
      _written = 0;
    }
    if (_written > _maxBytes) {
      await _handle?.close();
      _handle = null;
      final file = await _currentFile();
      if (file != null && await file.exists()) {
        await file.rename('${file.path}.1');
      }
      _written = 0;
    }
  }

  /// 写队列：所有写盘串行化。
  ///
  /// 为什么必须：`RandomAccessFile` 不允许同一个句柄上并发 await，
  /// 多路并发抓书源时同时进 `_write`，就会抛
  /// `FileSystemException: An async operation is currently pending`
  /// —— 1.9.1 的日志一个字都没落盘就是这个原因。
  static Future<void> _queue = Future<void>.value();

  /// 待写行数，用来在日志页显示「还有 N 行没落盘」。
  static int _pending = 0;
  static int get pendingWrites => _pending;

  static Future<void> _write(String line, DateTime now) {
    _pending++;
    _queue = _queue.then((_) async {
      try {
        await _writeNow(line);
      } catch (error) {
        debugPrint('AppLog 写入失败：$error');
      } finally {
        _pending--;
      }
    });
    return _queue;
  }

  static Future<void> _writeNow(String line) async {
    final dir = _dir;
    if (dir == null) return;
    await _rotateIfNeeded();
    _handle ??= await (await _currentFile())?.open(mode: FileMode.append);
    final handle = _handle;
    if (handle == null) return;
    final bytes = utf8.encode('$line\n');
    await handle.writeFrom(bytes);
    await handle.flush();
    _written += bytes.length;
  }

  static Future<void> _cleanupOld() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        // 导出的 zip 也一起清，不然会越堆越多
        if (!entity.path.endsWith('.log') &&
            !entity.path.endsWith('.zip')) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (_) {}
  }
}

/// 一次计时的结果。
class Timing {
  Timing._(this._started);

  final DateTime _started;

  int get ms => DateTime.now().difference(_started).inMilliseconds;

  /// 记一条带耗时的 info。
  void stop(String tag, String message, {Map<String, Object?>? fields}) {
    AppLog.info(tag, message, fields: {...?fields, 'ms': ms});
  }

  void warnIfSlow(String tag, String message,
      {int thresholdMs = 3000, Map<String, Object?>? fields}) {
    if (ms >= thresholdMs) {
      AppLog.warn(tag, message, fields: {...?fields, 'ms': ms});
    }
  }
}

/// 导出结果。
class ExportResult {
  const ExportResult({required this.path, required this.bytes});
  final String path;
  final int bytes;

  String get label => '${(bytes / 1024).toStringAsFixed(1)} KB';
}

/// 极简 ZIP 写入器（store 模式，不压缩）。
///
/// 为什么自己写：加 `archive` 依赖只为打个包不值得，日志本身是文本，
/// 不压缩也就几百 KB。store 模式实现只要正确的 CRC32 + 中央目录。
class _ZipWriter {
  final List<int> _out = [];
  final List<_ZipEntry> _entries = [];
  int _offset = 0;

  void add(String name, List<int> data) {
    final nameBytes = utf8.encode(name);
    final crc = _crc32(data);
    final localHeader = <int>[];
    void u16(int v) => localHeader.addAll([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(int v) => localHeader.addAll([
          v & 0xFF,
          (v >> 8) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 24) & 0xFF,
        ]);

    u32(0x04034b50); // local file header signature
    u16(20); // version needed
    u16(0x0800); // flags: UTF-8
    u16(0); // method: store
    u16(0); // mod time
    u16(0x21); // mod date (1996-01-01, 随便一个合法值)
    u32(crc);
    u32(data.length); // compressed
    u32(data.length); // uncompressed
    u16(nameBytes.length);
    u16(0); // extra len

    final headerOffset = _offset;
    _out
      ..addAll(localHeader)
      ..addAll(nameBytes)
      ..addAll(data);
    _offset += localHeader.length + nameBytes.length + data.length;

    _entries.add(_ZipEntry(
      name: nameBytes,
      crc: crc,
      size: data.length,
      offset: headerOffset,
    ));
  }

  List<int> close() {
    final cdStart = _offset;
    for (final e in _entries) {
      final h = <int>[];
      void u16(int v) => h.addAll([v & 0xFF, (v >> 8) & 0xFF]);
      void u32(int v) => h.addAll([
            v & 0xFF,
            (v >> 8) & 0xFF,
            (v >> 16) & 0xFF,
            (v >> 24) & 0xFF,
          ]);
      u32(0x02014b50); // central dir signature
      u16(20); // version made by
      u16(20); // version needed
      u16(0x0800); // flags
      u16(0); // method
      u16(0); // time
      u16(0x21); // date
      u32(e.crc);
      u32(e.size);
      u32(e.size);
      u16(e.name.length);
      u16(0); // extra
      u16(0); // comment
      u16(0); // disk
      u16(0); // internal attrs
      u32(0); // external attrs
      u32(e.offset);
      _out
        ..addAll(h)
        ..addAll(e.name);
      _offset += h.length + e.name.length;
    }
    final end = <int>[];
    void u16(int v) => end.addAll([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(int v) => end.addAll([
          v & 0xFF,
          (v >> 8) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 24) & 0xFF,
        ]);
    u32(0x06054b50); // end of central dir
    u16(0);
    u16(0);
    u16(_entries.length);
    u16(_entries.length);
    u32(_offset - cdStart);
    u32(cdStart);
    u16(0);
    _out.addAll(end);
    return _out;
  }
}

class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.crc,
    required this.size,
    required this.offset,
  });
  final List<int> name;
  final int crc;
  final int size;
  final int offset;
}

/// CRC32（ZIP 用的多项式）。
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
