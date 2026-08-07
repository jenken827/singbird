// lib/services/singbox_controller.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:singbird/services/dir.dart';
import 'package:singbird/services/local_storage.dart';
import 'package:singbird/services/profile_store.dart';
import 'app_logger.dart';

/// Backend engine manager
enum ConnectionStatus { disconnected, connecting, connected }

class SingBoxController {
  SingBoxController._();
  static SingBoxController? _instance;

  static SingBoxController instance() {
    if (_instance != null) return _instance!;
    _instance = SingBoxController._();
    _instance!._initExePath();
    final store = ProfileStore();
    final sb = store.activeSingBox;
    final nb = store.activeNetbird;

    final sbOk = sb != null && sb.config.isNotEmpty;
    if (sbOk) {
      _instance!._configContent = sb.config;
    }

    if (nb != null && nb.hasNetbirdConfig) {
      _instance!._setNetbirdConfig(
        setupKey: nb.netbirdSetupKey,
        managementUrl: nb.netbirdManagementUrl,
        deviceName: nb.netbirdDeviceName,
      );
    }
    return _instance!;
  }

  Process? _process;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  bool get isRunning => _process != null;
  ConnectionStatus get connectionStatus => _status;

  // Netbird config

  bool get isNetbirdEnabled => GetIt.I.get<LocalStorage>().getNetbirdEnable();

  String? _exePath;
  String? get exePath => _exePath;
  String? _exeParent; // cached exe directory, resolved once
  String configPath = '$dataDir${Platform.pathSeparator}sing-box-config.json';
  String? _configContent;

  /// The current config content string (may be null/empty if not set).
  String? get configContent => _configContent;

  // Netbird config
  String netbirdConfigPath =
      '$dataDir${Platform.pathSeparator}netbird-config.json';
  String? _nbSetupKey;
  String? _nbManagementUrl;
  String? _nbDeviceName;

  // Windows-only: find sing-box.exe
  void _initExePath() {
    if (!Platform.isWindows) {
      _exePath = '';
      return;
    }
    final bundled =
        '${Directory.current.path}${Platform.pathSeparator}sing-box.exe';
    _exePath = File(bundled).existsSync() ? bundled : null;
    _exeParent = _exePath == null ? null : Directory(_exePath!).parent.path;
    AppLogger().log('ctrl', 'findExe: chosen=$_exePath, parent=$_exeParent');
  }

  String? _lastError;
  String? get lastError => _lastError;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  void _log(String msg) => AppLogger().log('ctrl', msg);

  /// Console echo, safe in console-less launches.
  ///
  /// The Windows runner is a GUI-subsystem exe (and elevated via the
  /// requireAdministrator manifest), so it often has NO console at all:
  /// stderr is an invalid handle (errno 6 = EBADF, "句柄无效"). Writing to it
  /// throws inside the stdio sink's internal StreamController dispatch and the
  /// error is reported to the zone — try/catch around writeln() does NOT catch
  /// it (proven: the error bypasses the synchronous call stack). The guard
  /// below skips the echo entirely when no terminal is attached; the file log
  /// (run.log / singbox.log) still captures everything.
  void _echo(String line) {
    if (!stderr.hasTerminal) return;
    try {
      stderr.writeln(line);
    } catch (_) {
      // belt & suspenders for any other sync write error
    }
  }

  // ---- File-based backend log ----
  IOSink? _logFileSink;

  void _openLogFile() {
    unawaited(_closeLogFile());
    try {
      _logFileSink = File(
        '$dataDir${Platform.pathSeparator}run.log',
      ).openWrite(mode: FileMode.append);
    } catch (e) {
      _echo('[log] open: $e');
    }
  }

  /// Flush and close the run.log sink.
  ///
  /// Returns a Future: IOSink.close() is asynchronous and the Windows file
  /// handle is only released once it completes. Callers that need the file
  /// free (e.g. clearLog -> delete) MUST await this; otherwise delete races
  /// the close and fails with errno 32 (sharing violation).
  Future<void> _closeLogFile() async {
    try {
      await _logFileSink?.flush();
      await _logFileSink?.close();
    } catch (_) {}
    _logFileSink = null;
  }

  void _writeLog(String s) {
    try {
      _logFileSink?.write(s);
    } catch (_) {}
  }

  /// Clear run.log even while the engine is running.
  ///
  /// The append sink must be closed first: on Windows a file with an open
  /// handle cannot be deleted (sharing violation) — which is why the old UI
  /// handler silently failed while the engine was up. If the engine is still
  /// running, reopen a fresh sink so stderr capture continues.
  Future<bool> clearLog() async {
    try {
      await _closeLogFile();
      final f = File('$dataDir${Platform.pathSeparator}run.log');
      if (await f.exists()) await f.delete();
      if (_process != null) _openLogFile();
      return true;
    } catch (e) {
      _log('clearLog failed: $e');
      return false;
    }
  }

  // ---- Engine's own log file (config `log.output`) ----

  /// Resolve the absolute path of the engine's own log file from the active
  /// config's `log.output`. Returns null when unset (empty/stderr/stdout).
  ///
  /// Path resolution mirrors the engine:
  /// - Windows (CLI child process, no filemanager registered): relative paths
  ///   resolve against the process cwd = exe dir (Process.start workingDirectory).
  /// - Android (libbox, filemanager.WithDefault(sWorkingPath=filesDir)):
  ///   relative paths join onto filesDir — which equals Flutter's
  ///   getApplicationSupportDirectory(), i.e. dataDir.
  String? get engineLogPath {
    if (_configContent == null || _configContent!.isEmpty) return null;
    try {
      final cfg = jsonDecode(_configContent!);
      final output = cfg['log']?['output'] as String?;
      if (output == null || output.isEmpty) return null;
      if (output == 'stderr' || output == 'stdout') return null;
      final f = File(output);
      if (f.isAbsolute) return output;
      final base =
          Platform.isWindows ? (_exeParent ?? Directory.current.path) : dataDir;
      return '$base${Platform.pathSeparator}$output';
    } catch (_) {
      return null;
    }
  }

  /// Read the tail (last 100KB) of the engine log file for display.
  Future<String> readEngineLog() async {
    final path = engineLogPath;
    if (path == null) return '(no log.output configured)';
    try {
      final file = File(path);
      if (!await file.exists()) return '(engine log file not created yet)';
      final stat = await file.stat();
      if (stat.size > 100 * 1024) {
        final raf = await file.open(mode: FileMode.read);
        await raf.setPosition(stat.size - 100 * 1024);
        final content = await raf.read(100 * 1024);
        await raf.close();
        return utf8.decode(content);
      }
      return await file.readAsString();
    } catch (e) {
      return 'Error reading engine log: $e';
    }
  }

  /// Clear the engine's own log file. Works even while the engine is running:
  /// the engine holds the file with O_APPEND, so instead of deleting (which
  /// fails with a sharing violation on Windows) we truncate to 0 — O_APPEND
  /// writes then continue from the new EOF, so no gaps or stale data.
  Future<bool> clearEngineLogFile() async {
    final path = engineLogPath;
    if (path == null) return false;
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      if (_process != null) {
        final raf = await f.open(mode: FileMode.write); // truncate to 0
        await raf.close();
      } else {
        await f.delete();
      }
      _log('clearEngineLogFile: cleared $path');
      return true;
    } catch (e) {
      _log('clearEngineLogFile failed: $e');
      return false;
    }
  }

  // ── PID file (crash recovery) ──

  String get _pidPath => '$dataDir${Platform.pathSeparator}sing-box.pid';

  Future<void> _savePid(int pid) async {
    try {
      await File(_pidPath).writeAsString('$pid');
    } catch (e) {
      _log('savePid failed: $e');
    }
  }

  void _delPid() {
    try {
      final f = File(_pidPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _killGhost() async {
    final pidFile = File(_pidPath);
    if (!pidFile.existsSync()) return;
    var pidStr = await pidFile.readAsString();
    pidFile.deleteSync();
    pidStr = pidStr.trim();
    if (pidStr.isEmpty) return;
    _log('killGhost: killing orphan PID=$pidStr');
    await Process.run('taskkill', ['/pid', pidStr], runInShell: true);
    await Future.delayed(const Duration(milliseconds: 500));
    await Process.run('taskkill', ['/f', '/pid', pidStr], runInShell: true);
  }

  void setConfig(String configJson) {
    if (configJson != _configContent) {
      _configContent = configJson;
      if (configPath.isNotEmpty) {
        _writeIfChanged(configPath, configJson);
      }
    }
  }

  /// Reload active profiles from ProfileStore into this controller.
  /// Call after profile add/edit/activate so the dashboard reflects changes
  /// without needing to restart the app.
  void reloadFromStore() {
    final store = ProfileStore();
    final sb = store.activeSingBox;
    if (sb != null && sb.config.isNotEmpty) {
      setConfig(sb.config);
    }
    final nb = store.activeNetbird;
    if (nb != null && nb.hasNetbirdConfig) {
      setNetbirdConfig(
        setupKey: nb.netbirdSetupKey,
        managementUrl: nb.netbirdManagementUrl,
        deviceName: nb.netbirdDeviceName,
      );
    }
  }

  bool get hasConfig => _configContent != null && _configContent!.isNotEmpty;

  /// Parse Clash API external_controller from current config.
  String? get clashApiUrl {
    if (_configContent == null) return null;
    try {
      final cfg = jsonDecode(_configContent!);
      final addr =
          cfg['experimental']?['clash_api']?['external_controller'] ??
          '127.0.0.1:9090';
      return 'http://$addr';
    } catch (_) {
      return 'http://127.0.0.1:9090';
    }
  }

  // ---- netbird config ----
  void setNetbirdConfig({
    String? setupKey,
    String? managementUrl,
    String? deviceName,
  }) {
    _setNetbirdConfig(
      setupKey: setupKey,
      managementUrl: managementUrl,
      deviceName: deviceName,
    );
    _writeNetbirdConfigToFile();
  }

  void _setNetbirdConfig({
    String? setupKey,
    String? managementUrl,
    String? deviceName,
  }) {
    _nbSetupKey = setupKey;
    _nbManagementUrl = managementUrl;
    _nbDeviceName = deviceName;
  }

  bool get hasNetbirdConfig =>
      (_nbSetupKey != null && _nbSetupKey!.isNotEmpty) &&
      (_nbManagementUrl != null && _nbManagementUrl!.isNotEmpty);

  // ──────────  Start / Stop  ──────────

  /// Start sing-box as a child process.

  /// Write [content] to [path] only if it differs from the current file content.
  /// Returns true if the file was actually written.
  Future<bool> _writeIfChanged(String path, String content) async {
    final file = File(path);
    if (file.existsSync()) {
      try {
        final old = await file.readAsString();
        if (old == content) return false;
      } catch (_) {}
    }
    await file.writeAsString(content);
    return true;
  }

  Future<void> start() async {
    _lastError = null;
    // Cold start
    if (_configContent == null || _configContent!.isEmpty) {
      _lastError = 'No sing-box config loaded';
      _statusController.add('error:$_lastError');
      throw Exception(_lastError);
    }
    if (_exePath == null) {
      _lastError = 'Cannot find sing-box.exe';
      _statusController.add('error:$_lastError');
      throw Exception(_lastError);
    }

    await _startProcess();
  }

  /// Launch sing-box as a child process.
  Future<void> _startProcess() async {
    final nbEnabled = isNetbirdEnabled;
    final args = [
      'run-all',
      '-c',
      configPath,
      '--disable-color',
      '--enable-netbird=$nbEnabled',
    ];

    try {
      await _killGhost();
      await _cleanupLeftovers();
      _process = await Process.start(
        _exePath!,
        args,
        workingDirectory: _exeParent,
      );
      _log('start: process started PID=${_process!.pid}');
      _savePid(_process!.pid);
      _openLogFile();
      _writeLog('=== sing-box started PID=${_process!.pid} ===\n');
      _status = ConnectionStatus.connecting;
      _statusController.add('connecting');
      // Poll Clash API for sing-box readiness
      _waitForApi();
      _process!.stderr.transform(utf8.decoder).listen((data) {
        _writeLog(data);
        _echo('[sb/stderr] $data');
        if (data.contains('FATAL')) {
          _lastError = data;
          _statusController.add('error:$data');
        }
        // Detect sing-box ready from stderr (fallback if API poll fails)
        if ((data.contains('tcp server started') ||
                data.contains('restful api listening') ||
                data.contains('sing-box started')) &&
            _status != ConnectionStatus.connected) {
          _markConnected('stderr');
        }
      });
      _process!.exitCode.then((code) {
        _writeLog('=== exited: code=$code ===\n');
        unawaited(_closeLogFile());
        _delPid();
        _log('process exited: code=$code');
        _echo('[sb] process exited: code=$code');
        _process = null;
        _status = ConnectionStatus.disconnected;
        _statusController.add('exited:$code');
      });
    } catch (e) {
      _log('ENGINE FAILED: $e');
      _lastError = e.toString();
      _statusController.add('error:$e');
      rethrow;
    }
  }

  /// Poll Clash API until sing-box responds, then mark as connected.
  int _apiPollCount = 0;
  static const int _apiPollIntervalMs = 1500;
  static const int _apiPollMaxAttempts = 50; // ~75s timeout
  void _waitForApi() {
    _apiPollCount = 0;
    _pollApiOnce();
  }

  void _pollApiOnce() {
    if (_process == null) return;
    if (_apiPollCount > _apiPollMaxAttempts) {
      _lastError = 'Connection timed out — engine failed to start';
      _statusController.add('error:$_lastError');
      return;
    }
    _apiPollCount++;
    final baseUrl = clashApiUrl;
    HttpClient()
        .getUrl(Uri.parse('$baseUrl/version'))
        .then((req) => req.close())
        .then((_) => _markConnected('api'))
        .catchError((_) {
          if (_process == null) return;
          Future.delayed(
            const Duration(milliseconds: _apiPollIntervalMs),
            _pollApiOnce,
          );
        });
  }

  void _markConnected(String source) {
    if (_process == null || _status == ConnectionStatus.connected) return;
    _status = ConnectionStatus.connected;
    _statusController.add('connected');
  }

  Future<bool> _writeNetbirdConfigFile() async {
    final nbConfig = <String, dynamic>{};
    if (_nbSetupKey != null && _nbSetupKey!.isNotEmpty) {
      nbConfig['setup_key'] = _nbSetupKey;
    }
    if (_nbManagementUrl != null && _nbManagementUrl!.isNotEmpty) {
      nbConfig['management_url'] = _nbManagementUrl;
    }
    if (_nbDeviceName != null && _nbDeviceName!.isNotEmpty) {
      nbConfig['device_name'] = _nbDeviceName;
    }
    nbConfig['log_level'] = 'info';
    return _writeIfChanged(netbirdConfigPath, jsonEncode(nbConfig));
  }

  /// Public wrapper — only purges old state when credentials actually change.
  Future<void> _writeNetbirdConfigToFile() async {
    // Read existing config to determine if credentials changed
    final oldFile = File(netbirdConfigPath);
    String? oldSetupKey;
    String? oldMgmtUrl;
    if (oldFile.existsSync()) {
      try {
        final oldCfg = jsonDecode(await oldFile.readAsString());
        oldSetupKey = oldCfg['setup_key'] as String?;
        oldMgmtUrl = oldCfg['management_url'] as String?;
      } catch (_) {}
    }
    final newSetupKey = _nbSetupKey?.isNotEmpty == true ? _nbSetupKey : null;
    final newMgmtUrl =
        _nbManagementUrl?.isNotEmpty == true ? _nbManagementUrl : null;

    if (newSetupKey != oldSetupKey || newMgmtUrl != oldMgmtUrl) {
      // Credentials changed — purge old state
      final stateDir = Directory('$dataDir${Platform.pathSeparator}nb-state');
      if (stateDir.existsSync()) {
        stateDir.deleteSync(recursive: true);
        _log('nb-state purged (credentials changed)');
      }
    }
    await _writeNetbirdConfigFile();
  }

  /// Stop sing-box child process.
  ///
  /// 优雅关闭: 先 POST /monitor/shutdown 让引擎走完整 TUN/路由清理后正常退出。
  /// Windows 上 Dart 的 Process.kill 等价 TerminateProcess, 引擎拿不到任何
  /// 清理机会, 会残留 TUN/路由状态 —— 断网重连事故中"退出后网络仍异常"
  /// 的隐患之一。请求失败/超时才退回硬杀。
  Future<void> stop() async {
    _log('stop: stopping process');
    _status = ConnectionStatus.disconnected;
    _statusController.add('stopped');
    if (_process != null) {
      final proc = _process!;
      await _requestGracefulShutdown();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 8));
        _log('stop: graceful exit');
      } on TimeoutException {
        _log('stop: graceful shutdown timeout, hard kill');
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
      }
      _process = null;
    }
    _delPid();
  }

  /// POST /monitor/shutdown — 请求引擎优雅关闭 (fire-and-forget, 不依赖响应)。
  Future<void> _requestGracefulShutdown() async {
    try {
      final client =
          HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client.postUrl(
          Uri.parse('$clashApiUrl/monitor/shutdown'),
        );
        req.headers.contentType = ContentType.json;
        final resp = await req.close().timeout(const Duration(seconds: 2));
        await resp.drain<void>().timeout(const Duration(seconds: 1));
        _log('stop: shutdown request sent (HTTP ${resp.statusCode})');
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      _log('stop: shutdown request failed: $e (falling back to kill)');
    }
  }

  /// 防御性清理: 硬杀/崩溃后可能残留的 singtun 适配器。
  /// wintun 在进程退出时通常自动删除适配器, 这里只兜底 (孤儿进程已被
  /// killGhost 处理, 适配器会随进程退出消失)。
  Future<void> _cleanupLeftovers() async {
    if (!Platform.isWindows) return;
    try {
      final r = await Process.run('netsh', [
        'interface',
        'delete',
        'interface',
        'name=singtun',
      ]);
      _log('cleanupLeftovers: netsh delete singtun → exit ${r.exitCode}');
    } catch (e) {
      _log('cleanupLeftovers: $e');
    }
  }

  void dispose() {
    stop();
    _statusController.close();
  }
}
