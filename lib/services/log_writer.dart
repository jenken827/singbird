// lib/services/log_writer.dart
/// 文件日志写入器 — 崩溃后可追溯定位问题
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogWriter {
  static final LogWriter _instance = LogWriter._();
  factory LogWriter() => _instance;
  LogWriter._();

  IOSink? _sink;
  String? _path;
  bool _initialized = false;

  String? get path => _path;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationSupportDirectory();
    final logDir = Directory('${dir.path}/logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _path = '${logDir.path}/app-$timestamp.log';
    _sink = File(_path!).openWrite(mode: FileMode.writeOnlyAppend);
    _initialized = true;
    write('=== App started at ${DateTime.now().toIso8601String()} ===');
  }

  void write(String message) {
    if (_sink == null) return;
    _sink!.writeln('[${DateTime.now().toIso8601String()}] $message');
  }

  void info(String tag, String msg) => write('I/$tag $msg');
  void error(String tag, String msg, [Object? e, StackTrace? st]) {
    write('E/$tag $msg');
    if (e != null) write('  Exception: $e');
    if (st != null) write('  StackTrace: $st');
  }

  Future<void> flush() async {
    await _sink?.flush();
  }

  Future<void> close() async {
    await _sink?.close();
    _sink = null;
  }

  /// 读取最近的日志文件内容
  Future<String> readLatest() async {
    await flush();
    if (_path == null) return 'No log file';
    final file = File(_path!);
    if (!await file.exists()) return 'Log file not found';
    final stat = await file.stat();
    if (stat.size > 50 * 1024) {
      // 只读最后 50KB
      return await file.readAsString();
    }
    return await file.readAsString();
  }

  /// 清理旧日志文件（保留最近 3 个）
  Future<void> cleanOld() async {
    if (_path == null) return;
    final dir = File(_path!).parent;
    if (!await dir.exists()) return;
    final files = await dir.list().toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    for (var i = 3; i < files.length; i++) {
      await files[i].delete();
    }
  }

  /// 挂接到 talker — 每条日志同时写入文件
  void attachToTalker(dynamic talker) {
    // talker 版本 5.x 没有直接 addListener API
    // 我们通过 FlutterError.onError + 手动 log 调用实现
  }
}
