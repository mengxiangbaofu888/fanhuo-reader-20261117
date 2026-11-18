/// 应用日志：把关键路径写成文件，方便「拔线也能查」。
///
/// 为什么要有这个：
///   1. `flutter run` / `adb logcat` 要连电脑，而 adb 枚举在这台机器上不通
///   2. `debugPrint` 在 release 包里会被裁掉，用户装的正式包看不到
///   3. 书源加载、引擎执行这些一失败就「界面上什么都不显示」的路径，
///      必须留一条能捞出来的证据链
///
/// 写在哪：应用私有目录 `files/fanhuo-logs/`（走 path_provider，
/// 不需要任何存储权限），采用按天切分 + 保留最近 7 天 + 单文件 2 MB 上限。
///
/// 怎么看：
///   - 设置页「查看日志」直接读出来显示
///   - 或 `adb shell run-as com.fanhuo.reader ls files/fanhuo-logs`
library;

import 'dart:async';
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
  static const _maxBytes = 2 * 1024 * 1024;
  static const _keepDays = 7;

  /// 内存里留最近 500 行，设置页不用读盘也能秒开。
  static final List<String> _recent = [];
  static const _recentLimit = 500;

  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      _dir = dir;
      await _rotateIfNeeded();
      await _cleanupOld();
      info('AppLog', '日志已启用：${dir.path}');
    } catch (error) {
      // 日志本身失败绝不能影响主流程
      debugPrint('AppLog 初始化失败：$error');
    }
  }

  /// 记一条。`tag` 用来筛，写文件时带时间戳。
  static void log(LogLevel level, String tag, Object? message) {
    final now = DateTime.now();
    final line =
        '${now.toIso8601String()} [${level.name.toUpperCase()}] $tag: $message';
    _recent.add(line);
    if (_recent.length > _recentLimit) _recent.removeAt(0);
    debugPrint(line);
    unawaited(_write(line, now));
  }

  static void debug(String tag, Object? message) =>
      log(LogLevel.debug, tag, message);
  static void info(String tag, Object? message) =>
      log(LogLevel.info, tag, message);
  static void warn(String tag, Object? message) =>
      log(LogLevel.warn, tag, message);
  static void error(String tag, Object? message, [StackTrace? stack]) {
    log(LogLevel.error, tag, message);
    if (stack != null) log(LogLevel.error, tag, stack.toString());
  }

  /// 读最近 N 行（优先内存，内存不够再读盘）。
  static Future<String> dump({int lines = 400}) async {
    final fromMemory = _recent.length >= lines
        ? _recent.sublist(_recent.length - lines)
        : _recent.toList();
    if (fromMemory.length >= lines || _dir == null) {
      return fromMemory.join('\n');
    }
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

  /// 日志文件路径（设置页显示给用户）。
  static Future<String> directoryPath() async =>
      _dir?.path ?? '（未初始化）';

  /// 清空日志。
  static Future<void> clear() async {
    _recent.clear();
    try {
      await _handle?.close();
      _handle = null;
      final dir = _dir;
      if (dir == null) return;
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
      info('AppLog', '日志已清空');
    } catch (_) {}
  }

  static Future<File?> _currentFile() async {
    final dir = _dir;
    if (dir == null) return null;
    final now = DateTime.now();
    final name =
        'app-${now.year}${_two(now.month)}${_two(now.day)}.log';
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 跨天或超限就换文件。
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

  static Future<void> _write(String line, DateTime now) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await _rotateIfNeeded();
      _handle ??= await (await _currentFile())?.open(mode: FileMode.append);
      final handle = _handle;
      if (handle == null) return;
      final bytes = '$line\n'.codeUnits;
      await handle.writeFrom(bytes);
      await handle.flush();
      _written += bytes.length;
    } catch (error) {
      // 写日志失败就放弃这一行，绝不让它影响业务
      debugPrint('AppLog 写入失败：$error');
    }
  }

  /// 只保留最近 7 天的文件。
  static Future<void> _cleanupOld() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }
}
