// lib/services/app_logger.dart
import 'dart:io';

/// Simple file-based logger for release-mode diagnostics.
/// Writes to TEMP/singbird-DATE.log
class AppLogger {
  static final AppLogger _instance = AppLogger._();
  factory AppLogger() => _instance;

  final List<String> _buffer = [];
  File? _logFile;
  bool _enabled = false;

  AppLogger._();

  void init() {
    if (_enabled) return;
    try {
      final tmp = Directory.systemTemp.path;
      final now = DateTime.now();
      final date = '${now.year}${_pad(now.month)}${_pad(now.day)}';
      _logFile = File('$tmp\\singbird-$date.log');
      // Rotate: keep at most 3 recent log files
      _rotate(tmp, 3);
      _enabled = true;
      _write('=== AppLogger initialized ===');
    } catch (_) {
      // Can't log if logger init fails — silently continue
    }
  }

  void log(String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} [$tag] $message';
    // Always keep in buffer (up to 1000 lines)
    _buffer.add(line);
    while (_buffer.length > 1000) {
      _buffer.removeAt(0);
    }
    // Also write to file if enabled
    if (_enabled && _logFile != null) {
      _write(line);
    }
  }

  void _write(String line) {
    try {
      _logFile!.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  void _rotate(String dir, int keep) {
    try {
      final files = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('singbird-') && f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      while (files.length >= keep) {
        files.last.deleteSync();
        files.removeLast();
      }
    } catch (_) {}
  }

  /// Dump recent buffer (for debug UI)
  String dump() => _buffer.join('\n');

  String _pad(int n) => n < 10 ? '0$n' : '$n';
}
