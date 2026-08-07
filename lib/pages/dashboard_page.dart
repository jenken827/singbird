// lib/pages/dashboard_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:singbird/services/dir.dart';
import '../providers/monitor_provider.dart';
import '../services/singbox_controller.dart';
import '../services/local_storage.dart';
import '../services/android_vpn_controller.dart';
import '../services/profile_store.dart';
import '../main.dart' show talker;
import '../services/log_writer.dart';
import '../models/monitor_event.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  String? _lastError;
  bool _connecting = false;

  // Android-specific
  final _androidVpn = AndroidVpnController();
  bool _isAndroid = false;
  bool _vpnRunning = false;
  Timer? _vpnTimer;

  SingBoxController get _ctrl => SingBoxController.instance();
  bool get _running => _isAndroid ? _vpnRunning : _ctrl.isRunning;

  @override
  void initState() {
    super.initState();
    _isAndroid = Platform.isAndroid;
    talker.info('Dashboard init: android=$_isAndroid', 'Dashboard');
    _init();
    _ctrl.statusStream.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event == 'connected') {
          _lastError = null;
          _connecting = false;
          talker.info('Engine connected', 'Dashboard');
        } else if (event.startsWith('error:')) {
          _connecting = false;
          _lastError = _ctrl.lastError;
          talker.error('Engine error: $_lastError', 'Dashboard');
        } else if (event == 'connecting') {
          _connecting = true;
        } else if (event.startsWith('exited:')) {
          _connecting = false;
        } else if (event == 'stopped') {
          _connecting = false;
        }
      });
    });
    if (_isAndroid) {
      // Poll Kotlin-side VPN state (Dart Process is null on Android)
      _queryVpnStatus();
      _vpnTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _queryVpnStatus();
      });
    }
  }

  Future<void> _queryVpnStatus() async {
    try {
      final status = await _androidVpn.getVpnStatus();
      if (!mounted) return;
      setState(() {
        _vpnRunning = status['running'] == true;
        if (_vpnRunning) _connecting = false;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _vpnTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await ProfileStore().load();
      // Sync loaded profiles into the controller. This is critical:
      // build() runs before this async load completes, so instance() was
      // created with empty store and _configContent is still null.
      _ctrl.reloadFromStore();
      if (mounted) setState(() {});
      // Auto-start service if enabled (desktop only — Android uses VpnService)
      if (!Platform.isAndroid &&
          GetIt.I.get<LocalStorage>().getAutoStart() &&
          !_ctrl.isRunning) {
        talker.info('Auto-start enabled, starting engine...', 'Dashboard');
        try {
          await _ctrl.start();
        } catch (e, st) {
          talker.error('Auto-start failed: $e', 'Dashboard', st);
        }
      }
    } catch (e, st) {
      talker.error('Dashboard init error: $e', 'Dashboard', st);
    }
  }

  Future<void> _toggle() async {
    talker.info(
      '_toggle called, running=$_running android=$_isAndroid',
      'Dashboard',
    );
    LogWriter().info('Dashboard', '_toggle running=$_running');

    if (!_ctrl.hasConfig) {
      talker.warning('_forwardConfig returned false, aborting', 'Dashboard');
      LogWriter().info('Dashboard', '_forwardConfig failed');
      return;
    }
    try {
      if (_running) {
        // Stop
        talker.info('Stopping VPN...', 'Dashboard');
        if (_isAndroid) {
          await _androidVpn.stopVpn();
        } else {
          await _ctrl.stop();
        }
      } else {
        // Start
        talker.info('Starting...', 'Dashboard');

        if (_isAndroid) {
          talker.info('Calling startVpn with config file path...', 'Dashboard');
          LogWriter().info('Dashboard', 'startVpn() with file path');

          // Inject Android-required settings before starting:
          // - remove tun interface_name (VpnService assigns tun0; a fixed
          //   name like "singtun" makes sing-box fail to exclude its own
          //   TUN from default-interface detection → "no available network
          //   interface" on every outbound)
          // - ensure route.auto_detect_interface=true (protect() support)
          await _injectAndroidConfig();
          await _androidVpn.startVpn(
            configDir: dataDir,
            netbirdEnabled: _ctrl.isNetbirdEnabled,
          );
        } else {
          await _ctrl.start();
        }
      }
      // Wait a moment then refresh status
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) setState(() => _lastError = null);
    } catch (e, st) {
      talker.error('_toggle Error: $e', 'Dashboard', st);
      LogWriter().error('Dashboard', '_toggle failed', e, st);
      if (mounted) {
        setState(() => _lastError = e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Inject Android-required settings into the sing-box config file:
  /// - remove tun `interface_name` (VpnService assigns tun0; a fixed name
  ///   like "singtun" breaks sing-box's own-TUN exclusion in default
  ///   interface detection → "no available network interface" on outbound)
  /// - force `stack: gvisor` — the working combo verified on this device
  ///   (Android 10 MIUI): with `mixed` the gvisor TCP half fails to start
  ///   (DNS/UDP works, TCP packets hit tun0 but are never processed → timeout)
  /// - force `route.auto_detect_interface: false` — SELinux blocks
  ///   /proc/net on MIUI, so interface auto-detection is unreliable;
  ///   protect() is applied unconditionally on Android sockets instead
  Future<void> _injectAndroidConfig() async {
    final content = _ctrl.configContent;
    if (content == null || content.isEmpty) return;
    try {
      final json = jsonDecode(content);
      if (json is Map) {
        json['route'] ??= <String, dynamic>{};
        json['route']['auto_detect_interface'] = false;
        final inbounds = json['inbounds'];
        if (inbounds is List) {
          for (final ib in inbounds) {
            if (ib is Map && ib['type'] == 'tun') {
              ib.remove('interface_name');
              ib['stack'] = 'gvisor';
              talker.info(
                'Android TUN: stack=gvisor, no interface_name',
                'Dashboard',
              );
            }
          }
        }
        await File(_ctrl.configPath).writeAsString(jsonEncode(json));
        talker.info(
          'Android config injected to ${_ctrl.configPath}',
          'Dashboard',
        );
      }
    } catch (e) {
      talker.error('_injectAndroidConfig failed: $e', 'Dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      final sbOk = _ctrl.hasConfig;
      final traffic = ref.watch(trafficStatsProvider);
      final activeConns = ref.watch(activeConnectionsProvider);
      final alerts = ref.watch(alertsProvider);
      final routeDist = ref.watch(routeDistributionProvider);

      return Scaffold(
        appBar: AppBar(title: Text('Dashboard')),
        body: RefreshIndicator(
          onRefresh: () async => setState(() {}),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _EngineCard(
                title: _isAndroid ? 'VPN Service' : 'SingBird',
                subtitle:
                    _ctrl.isNetbirdEnabled
                        ? 'sing-box + Netbird'
                        : 'sing-box only',
                icon: _isAndroid ? Icons.vpn_lock : Icons.cloud,
                isRunning: _running,
                connecting: _connecting,
                hasConfig: sbOk,
                onToggle: _toggle,
              ),
              const SizedBox(height: 16),
              if (_lastError != null)
                Card(
                  color: Colors.red.shade900,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _lastError!,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_isAndroid && _running)
                Card(
                  color: Colors.green.shade900.withOpacity(0.3),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Colors.green,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'VPN is running. Check the notification shade for status.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_isAndroid && _running) ...[
                const SizedBox(height: 12),
                _ConnectivityTestCard(),
              ],
              if (_running) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _TrafficItem(
                          icon: Icons.download,
                          label: 'Download',
                          value: traffic.downloadFormatted,
                          color: Colors.blue,
                        ),
                        _TrafficItem(
                          icon: Icons.upload,
                          label: 'Upload',
                          value: traffic.uploadFormatted,
                          color: Colors.green,
                        ),
                        _TrafficItem(
                          icon: Icons.link,
                          label: 'Connections',
                          value: '${activeConns.length}',
                          color: Colors.orange,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_running && routeDist.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Route Distribution',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        ...routeDist.entries.map((e) {
                          final colors = {
                            'proxy': Colors.cyan,
                            'direct': Colors.green,
                            'block': Colors.red,
                          };
                          return _RouteBar(
                            label: e.key,
                            count: e.value,
                            total: routeDist.values.fold(0, (a, b) => a + b),
                            color: colors[e.key] ?? Colors.grey,
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              if (_running && alerts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  color: Colors.red.shade900,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.warning, color: Colors.yellow),
                            const SizedBox(width: 8),
                            Text(
                              'Alerts (${alerts.length})',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...alerts
                            .take(3)
                            .map(
                              (a) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  a.message,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                        if (alerts.length > 3)
                          Text(
                            '+${alerts.length - 3} more...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade400,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_running && activeConns.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.link,
                              size: 18,
                              color: Colors.cyan,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Active Connections (${activeConns.length})',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 8),
                        ...activeConns
                            .take(20)
                            .map((c) => _ConnectionRow(conn: c)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    } catch (e, st) {
      talker.error('Dashboard build error: $e', 'Dashboard', st);
      // Fallback render on build error
      return Scaffold(
        appBar: AppBar(title: const Text('sing-box VPN')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Failed to render dashboard',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  '$e',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }
}

// ── Sub-widgets ──

class _EngineCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isRunning;
  final bool connecting;
  final bool hasConfig;
  final VoidCallback onToggle;

  const _EngineCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isRunning,
    this.connecting = false,
    required this.hasConfig,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final Color buttonColor;
    if (connecting) {
      buttonColor = Colors.orange;
    } else if (isRunning) {
      buttonColor = Colors.red;
    } else {
      buttonColor = Theme.of(context).colorScheme.primary;
    }
    return Card(
      color: Colors.transparent,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 32,
                  color: isRunning ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: hasConfig ? onToggle : null,
                style: FilledButton.styleFrom(
                  backgroundColor: buttonColor,
                  foregroundColor: Colors.white,
                ),
                icon:
                    connecting
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : Icon(isRunning ? Icons.stop : Icons.play_arrow),
                label: Text(
                  connecting
                      ? 'Connecting…'
                      : isRunning
                      ? 'Stop'
                      : 'Start',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrafficItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _TrafficItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
        ),
      ],
    );
  }
}

class _RouteBar extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  final Color color;

  const _RouteBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total > 0 ? count / total : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text('$count', style: const TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              backgroundColor: Colors.grey.shade800,
              color: color,
              minHeight: 8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Android-specific connectivity test card (ported from original netbird UI)
class _ConnectivityTestCard extends StatefulWidget {
  @override
  State<_ConnectivityTestCard> createState() => _ConnectivityTestCardState();
}

class _ConnectivityTestCardState extends State<_ConnectivityTestCard> {
  String? _testResult;

  Future<void> _testConnectivity() async {
    setState(() => _testResult = 'Testing...');
    try {
      final result = await Process.run('ping', [
        '-c',
        '3',
        '-W',
        '2',
        '8.8.8.8',
      ]);
      setState(() {
        _testResult =
            result.exitCode == 0
                ? 'Connectivity OK'
                : 'Ping failed (exit ${result.exitCode})';
      });
    } catch (e) {
      setState(() => _testResult = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _testResult ?? 'Tap to test connectivity',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(onPressed: _testConnectivity, child: const Text('Test')),
          ],
        ),
      ),
    );
  }
}

// ── Active Connection Row ──

class _ConnectionRow extends StatelessWidget {
  final ConnectionRecord conn;
  const _ConnectionRow({required this.conn});

  Color _tagColor(String tag) {
    switch (tag) {
      case 'proxy':
        return Colors.cyan;
      case 'direct':
        return Colors.green;
      case 'block':
        return Colors.red;
      case 'dns':
        return Colors.amber;
      case 'bypass':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final host =
        (conn.host != null && conn.host!.isNotEmpty)
            ? conn.host!
            : '${conn.destIp}:${conn.destPort}';
    final elapsed =
        conn.durationMs != null ? _formatDuration(conn.durationMs!) : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: const BoxDecoration(
              color: Colors.greenAccent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              host,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: _tagColor(conn.outbound).withOpacity(0.25),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              conn.outbound,
              style: TextStyle(fontSize: 10, color: _tagColor(conn.outbound)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              '${_formatBytes(conn.uploadBytes)}↑ ${_formatBytes(conn.downloadBytes)}↓',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              elapsed,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

String _formatDuration(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return '${(ms / 60000).toStringAsFixed(1)}m';
}
