// lib/pages/settings_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talker_flutter/talker_flutter.dart';
import '../models/profile.dart';
import '../services/profile_store.dart';
import '../services/singbox_controller.dart';
import '../services/local_storage.dart';
import '../services/log_writer.dart';
import '../services/dir.dart';
import '../services/android_vpn_controller.dart';
import '../providers/theme_provider.dart';
import '../services/version_service.dart';
import '../providers/monitor_provider.dart';
import '../services/windows_process_filter.dart';
import 'profiles_page.dart';
import 'app_filter_page.dart';
import '../main.dart' show talker;

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _store = ProfileStore();
  String? _sbActiveName;

  // Android VPN state
  bool _androidAppFilterActive = false;

  // Windows app filter state
  bool _winFilterActive = false;

  // Netbird credential fields
  late TextEditingController _nbSetupKeyCtrl;
  late TextEditingController _nbMgmtUrlCtrl;
  late TextEditingController _nbDeviceNameCtrl;
  bool _nbEnabled = false;
  bool _autoStart = false;
  bool _nbKeyVisible = false;

  @override
  void initState() {
    super.initState();
    _nbSetupKeyCtrl = TextEditingController();
    _nbMgmtUrlCtrl = TextEditingController(text: 'https://api.netbird.io:443');
    _nbDeviceNameCtrl = TextEditingController(text: 'sing-netbird');
    _load();
    if (Platform.isAndroid) {
      _queryAndroidVpn();
    }
    if (Platform.isWindows) {
      _queryWinFilter();
    }
  }

  @override
  void dispose() {
    _nbSetupKeyCtrl.dispose();
    _nbMgmtUrlCtrl.dispose();
    _nbDeviceNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _store.load();
    ref.read(liveMonitoringProvider.notifier).loadFromPrefs();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // Sync active sing-box config to controller
    final activeSb = _store.activeSingBox;
    if (activeSb != null) {
      SingBoxController.instance().setConfig(activeSb.config);
    }
    // Load persisted netbird credentials
    final savedKey = prefs.getString('nb_setup_key') ?? '';
    final savedUrl =
        prefs.getString('nb_mgmt_url') ?? 'https://api.netbird.io:443';
    final savedName = prefs.getString('nb_device_name') ?? 'sing-netbird';
    _nbSetupKeyCtrl.text = savedKey;
    _nbMgmtUrlCtrl.text = savedUrl;
    _nbDeviceNameCtrl.text = savedName;
    if (savedKey.isNotEmpty) {
      SingBoxController.instance().setNetbirdConfig(
        setupKey: savedKey,
        managementUrl: savedUrl,
        deviceName: savedName,
      );
    }
    setState(() {
      _sbActiveName = _store.activeSingBox?.name;
      _nbEnabled = GetIt.I.get<LocalStorage>().getNetbirdEnable();
      _autoStart = GetIt.I.get<LocalStorage>().getAutoStart();
    });
  }

  // ── Android VPN ──

  Future<void> _queryAndroidVpn() async {
    try {
      final status = await AndroidVpnController().getVpnStatus();
      if (!mounted) return;
      setState(() {
        final allowed =
            (status['allowedPackages'] as List?)?.cast<String>() ?? [];
        final disallowed =
            (status['disallowedPackages'] as List?)?.cast<String>() ?? [];
        _androidAppFilterActive = allowed.isNotEmpty || disallowed.isNotEmpty;
      });
    } catch (_) {
      // Silent on error
    }
  }

  // ── Windows App Filter ──

  Future<void> _queryWinFilter() async {
    try {
      final mode = await WindowsProcessFilter.loadMode();
      final selected = await WindowsProcessFilter.loadSelected();
      final blocked = await WindowsProcessFilter.loadBlocked();
      final manualPair = await WindowsProcessFilter.loadManualPair();
      final manualBlock = await WindowsProcessFilter.loadManualBlock();
      if (!mounted) return;
      setState(() => _winFilterActive =
          (mode != 'none' && (selected.isNotEmpty || manualPair.isNotEmpty)) ||
              blocked.isNotEmpty ||
              manualBlock.isNotEmpty);
    } catch (_) {
      // Silent on error
    }
  }

  Future<void> _showNativeLog(BuildContext context) async {
    if (Platform.isAndroid) {
      // Android: read from native Kotlin side
      final nativeLog = await AndroidVpnController().readNativeLog();
      final markersLog = await AndroidVpnController().readMarkers();
      final goMarkersLog = await AndroidVpnController().readGoMarkers();
      final crashReport = await AndroidVpnController().readCrashReport();
      final crashSection =
          crashReport.isNotEmpty ? '\n\n═══ CRASH REPORT ═══\n$crashReport' : '';
      final fullLog = markersLog.isNotEmpty
          ? '═══ MARKERS (crash-safe) ═══\n$markersLog\n\n═══ GO MARKERS ═══\n$goMarkersLog\n\n═══ FILELOGGER ═══\n$nativeLog$crashSection'
          : nativeLog;
      _showLogDialog(context, 'Native Logs', fullLog, Colors.redAccent);
    } else {
      // Desktop: engine run.log + LogWriter app log. Talker history is
      // in-memory only and duplicates the app log — kept out of this view.
      final engineLog = await _readEngineLog();
      final appLog = await LogWriter().readLatest();
      final fullLog = [
        if (engineLog.isNotEmpty) '═══ ENGINE LOG (run.log) ═══\n$engineLog',
        if (appLog.isNotEmpty) '\n═══ APP LOG ═══\n$appLog',
      ].join('\n');
      _showLogDialog(context, 'Logs', fullLog.isNotEmpty ? fullLog : '(empty)', Colors.cyan);
    }
  }

  Future<String> _readEngineLog() async {
    try {
      final dir = dataDir;
      final file = File('$dir${Platform.pathSeparator}run.log');
      if (!await file.exists()) return '(engine not started yet)';
      final stat = await file.stat();
      if (stat.size > 100 * 1024) {
        // Only read last 100KB
        final raf = await file.open(mode: FileMode.read);
        await raf.setPosition(stat.size > 100 * 1024 ? stat.size - 100 * 1024 : 0);
        final content = await raf.read(100 * 1024);
        await raf.close();
        return utf8.decode(content);
      }
      return await file.readAsString();
    } catch (e) {
      return 'Error reading engine log: $e';
    }
  }

  /// View the engine's own log file (config `log.output`) with path + size.
  Future<void> _showEngineLogFileDialog(BuildContext context) async {
    final ctrl = SingBoxController.instance();
    final path = ctrl.engineLogPath;
    if (path == null) {
      _showLogDialog(
        context,
        'Engine Log File',
        '当前配置未设置 log.output\n(stderr/stdout 输出到 run.log)',
        Colors.lightBlue,
      );
      return;
    }
    final content = await ctrl.readEngineLog();
    if (!mounted) return;
    String sizeStr = '';
    try {
      final f = File(path);
      if (f.existsSync()) {
        final stat = f.statSync();
        sizeStr = ' (${(stat.size / 1024 / 1024).toStringAsFixed(2)} MB)';
      }
    } catch (_) {}
    if (!context.mounted) return;
    final header =
        '路径: $path$sizeStr\n────────────────────────────────\n';
    _showLogDialog(
      context,
      'Engine Log File',
      header + (content.isEmpty ? '(empty)' : content),
      Colors.lightBlue,
    );
  }

  void _showLogDialog(BuildContext context, String title, String content, Color iconColor) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.terminal, color: iconColor, size: 20),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.greenAccent
                    : Colors.green.shade800,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveNetbirdCredentials() async {
    final ctrl = SingBoxController.instance();
    final setupKey =
        _nbSetupKeyCtrl.text.trim().isEmpty
            ? null
            : _nbSetupKeyCtrl.text.trim();
    ctrl.setNetbirdConfig(
      setupKey: setupKey,
      managementUrl: _nbMgmtUrlCtrl.text.trim(),
      deviceName: _nbDeviceNameCtrl.text.trim(),
    );
    // Persist so credentials survive app restarts
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nb_setup_key', setupKey ?? '');
    await prefs.setString('nb_mgmt_url', _nbMgmtUrlCtrl.text.trim());
    await prefs.setString('nb_device_name', _nbDeviceNameCtrl.text.trim());

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Credentials saved + config written')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── sing-box Config ──
          Card(
            child: ListTile(
              leading: const Icon(Icons.description),
              title: const Text('sing-box Config'),
              subtitle: Text(_sbActiveName ?? 'None'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (_) => const ProfilesPage(type: ProfileType.singBox),
                  ),
                );
                _load();
              },
            ),
          ),
          const SizedBox(height: 12),

          // ── Appearance: Theme Mode ──
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.palette_outlined, size: 20, color: Colors.purple),
                      SizedBox(width: 12),
                      Text('Theme Mode',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          icon: Icon(Icons.brightness_auto, size: 16),
                          label: Text('System'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode, size: 16),
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode, size: 16),
                          label: Text('Dark'),
                        ),
                      ],
                      selected: {ref.watch(themeModeProvider)},
                      onSelectionChanged: (sel) {
                        ref.read(themeModeProvider.notifier).set(sel.first);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Auto Start ──
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.rocket_launch, color: Colors.lightBlue),
              title: const Text('Auto Start Service'),
              subtitle: const Text(
                'Start sing-box automatically when the app launches',
                style: TextStyle(fontSize: 12),
              ),
              value: _autoStart,
              onChanged: (v) async {
                setState(() => _autoStart = v);
                await GetIt.I.get<LocalStorage>().saveAutoStart(v);
              },
            ),
          ),
          const SizedBox(height: 12),

          // ── Live Monitoring (all platforms) ──
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.monitor_heart, color: Colors.cyan),
              title: const Text('Live Monitoring'),
              subtitle: Text(
                'Real-time traffic, connections & alerts.\nDisable to save battery.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                ),
              ),
              value: ref.watch(liveMonitoringProvider),
              onChanged: (v) {
                ref.read(liveMonitoringProvider.notifier).set(v);
              },
            ),
          ),
          const SizedBox(height: 12),

          // ── Android VPN Settings ──
          if (Platform.isAndroid) ...[
            Card(
              child: Column(
                children: [
                  // Per-app filter
                  ListTile(
                    leading: const Icon(Icons.apps),
                    title: const Text('Per-App VPN Filter'),
                    subtitle: Text(
                      _androidAppFilterActive
                          ? 'Active — some apps filtered'
                          : 'Off — all apps go through VPN',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AppFilterPage(),
                        ),
                      );
                      _queryAndroidVpn();
                    },
                  ),

                  // ── Native Logs ──
                  ListTile(
                    leading: const Icon(
                      Icons.terminal,
                      color: Colors.redAccent,
                    ),
                    title: const Text('Native Logs (Kotlin)'),
                    subtitle: Text(
                      'Crash-safe native log — survives app restart',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showNativeLog(context),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: Colors.grey,
                    ),
                    title: const Text('Clear Native Logs'),
                    subtitle: Text(
                      'Delete all markers, Go markers, and crash reports',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    trailing: const Icon(Icons.delete_sweep, size: 18),
                    onTap: () async {
                      await AndroidVpnController().clearLogs();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Native logs cleared')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ── Windows App Filter ──
          if (Platform.isWindows) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.apps),
                title: const Text('Per-App Filter'),
                subtitle: Text(
                  _winFilterActive
                      ? 'Active — selected processes filtered'
                      : 'Off — all processes use proxy rules',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AppFilterPage(),
                    ),
                  );
                  _queryWinFilter();
                },
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ── Logs (Desktop) ──
          if (!Platform.isAndroid) ...[
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.terminal, color: Colors.cyan),
                    title: const Text('Engine Log'),
                    subtitle: Text(
                      'Go engine stderr captured from run.log',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showNativeLog(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: Colors.grey),
                    title: const Text('Clear Engine Log'),
                    subtitle: Text(
                      'Delete run.log (engine stderr)',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    trailing: const Icon(Icons.delete_sweep, size: 18),
                    onTap: () async {
                      final ok =
                          await SingBoxController.instance().clearLog();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ok
                                  ? 'Engine log cleared'
                                  : 'Failed to clear engine log',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ── Engine Log File (config log.output) — cross-platform ──
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.article_outlined,
                    color: Colors.lightBlue,
                  ),
                  title: const Text('Engine Log File'),
                  subtitle: Text(
                    'sing-box 自身日志 (log.output)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _showEngineLogFileDialog(context),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.grey,
                  ),
                  title: const Text('Clear Engine Log File'),
                  subtitle: Text(
                    '截断清空 — 引擎运行中也可用',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  trailing: const Icon(Icons.delete_sweep, size: 18),
                  onTap: () async {
                    final ok = await SingBoxController
                        .instance()
                        .clearEngineLogFile();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Engine log file cleared'
                                : 'Failed to clear engine log file',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Debug Logs ──
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report, color: Colors.amber),
              title: const Text('Debug Logs'),
              subtitle: const Text('View app logs for troubleshooting'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TalkerScreen(talker: talker),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // ── Netbird ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Netbird',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable Netbird Engine'),
                    subtitle: Text(
                      'Start netbird alongside sing-box',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    value: _nbEnabled,
                    onChanged: (v) async {
                      setState(() => _nbEnabled = v);
                      await GetIt.I.get<LocalStorage>().saveNetbirdEnable(v);
                    },
                  ),
                  const Divider(height: 8),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _nbSetupKeyCtrl,
                    obscureText: !_nbKeyVisible,
                    decoration: InputDecoration(
                      labelText: 'Setup Key',
                      hintText: 'Enter netbird setup key',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _nbKeyVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        tooltip: _nbKeyVisible ? 'Hide' : 'Show',
                        onPressed: () =>
                            setState(() => _nbKeyVisible = !_nbKeyVisible),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nbMgmtUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Management URL',
                      hintText: 'https://api.netbird.io:443',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nbDeviceNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Device Name',
                      hintText: 'sing-netbird',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveNetbirdCredentials,
                      child: const Text('Save Credentials'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── About / Version ──
          _AboutCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Version info card — frontend (Flutter) + backend (sing-box / netbird).
class _AboutCard extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends ConsumerState<_AboutCard> {
  BackendVersion? _backend;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final v = await VersionService.fetchBackend();
    if (mounted) setState(() => _backend = v);
  }

  String _commit(String c) => c.isEmpty ? '-' : c;

  @override
  Widget build(BuildContext context) {
    final backend = _backend;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 20, color: Colors.teal),
                const SizedBox(width: 12),
                const Text(
                  'About',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh',
                  onPressed: _fetch,
                ),
              ],
            ),
            const Divider(height: 8),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'SingBird — unified network toolkit: full sing-box proxy engine '
                'and Netbird P2P VPN client with real-time monitoring.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            _row('Frontend', VersionService.frontendLabel),
            _row('Built', VersionService.frontendBuildTime),
            _row(
              'sing-box',
              backend == null
                  ? '…'
                  : '${backend.singBoxVersion} (${_commit(backend.singBoxCommit)})',
            ),
            _row(
              'sing-box built',
              backend == null ? '…' : (backend.singBoxBuildTime.isEmpty ? '-' : backend.singBoxBuildTime),
            ),
            _row(
              'netbird',
              backend == null
                  ? '…'
                  : '${backend.netbirdVersion} (${_commit(backend.netbirdCommit)})',
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12.5),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
