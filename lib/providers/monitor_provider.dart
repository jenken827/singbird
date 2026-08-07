// lib/providers/monitor_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/monitor_event.dart';
import '../services/monitor_service.dart';

/// 实时监控开关 — 用户可配置
final liveMonitoringProvider =
    NotifierProvider<LiveMonitoringNotifier, bool>(LiveMonitoringNotifier.new);

class LiveMonitoringNotifier extends Notifier<bool> {
  @override
  bool build() => true; // default on

  /// 从 SharedPreferences 加载并覆盖
  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('live_monitoring');
    if (saved != null) state = saved;
  }

  /// 切换并持久化
  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('live_monitoring', state);
  }

  /// 设置指定值
  Future<void> set(bool v) async {
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('live_monitoring', v);
  }
}

final monitorServiceProvider = Provider<MonitorService>((ref) => MonitorService());

// 服务运行状态
final serviceRunningProvider =
    NotifierProvider<ServiceRunningNotifier, bool>(ServiceRunningNotifier.new);

class ServiceRunningNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool v) => state = v;
}

// DNS 记录 (最近 200 条)
final dnsRecordsProvider =
    NotifierProvider<DnsRecordsNotifier, List<DNSRecord>>(DnsRecordsNotifier.new);

class DnsRecordsNotifier extends Notifier<List<DNSRecord>> {
  StreamSubscription? _sub;

  @override
  List<DNSRecord> build() {
    final live = ref.watch(liveMonitoringProvider);
    _sub?.cancel();
    if (live) {
      _sub = MonitorService().dnsRecords.listen((record) {
        state = [record, ...state];
        if (state.length > 200) state = state.sublist(0, 200);
      });
    }
    ref.onDispose(() => _sub?.cancel());
    return [];
  }
}

// 活跃连接
final connectionsProvider =
    NotifierProvider<ConnectionsNotifier, Map<String, ConnectionRecord>>(
        ConnectionsNotifier.new);

class ConnectionsNotifier extends Notifier<Map<String, ConnectionRecord>> {
  StreamSubscription? _sub;
  StreamSubscription? _closeSub;

  @override
  Map<String, ConnectionRecord> build() {
    final live = ref.watch(liveMonitoringProvider);
    _sub?.cancel();
    _closeSub?.cancel();
    if (live) {
      _sub = MonitorService().connections.listen((conn) {
        state = {...state, conn.id: conn};
      });
      _closeSub = MonitorService().connectionsClosed.listen((conn) {
        state = Map.from(state)..remove(conn.id);
      });
    }
    ref.onDispose(() {
      _sub?.cancel();
      _closeSub?.cancel();
    });
    return {};
  }

  void removeClosed(String id) {
    state = Map.from(state)..remove(id);
  }
}

// 活跃连接列表
final activeConnectionsProvider = Provider<List<ConnectionRecord>>((ref) {
  return ref.watch(connectionsProvider).values.where((c) => !c.closed).toList();
});

// 告警事件 (最近 50 条)
final alertsProvider =
    NotifierProvider<AlertsNotifier, List<AlertEvent>>(AlertsNotifier.new);

class AlertsNotifier extends Notifier<List<AlertEvent>> {
  StreamSubscription? _sub;

  @override
  List<AlertEvent> build() {
    final live = ref.watch(liveMonitoringProvider);
    _sub?.cancel();
    if (live) {
      _sub = MonitorService().alerts.listen((alert) {
        state = [alert, ...state];
        if (state.length > 50) state = state.sublist(0, 50);
      });
    }
    ref.onDispose(() => _sub?.cancel());
    return [];
  }
}

// 总流量统计
class TrafficStats {
  final int totalUpload;
  final int totalDownload;

  const TrafficStats({required this.totalUpload, required this.totalDownload});

  String get uploadFormatted => _formatBytes(totalUpload);
  String get downloadFormatted => _formatBytes(totalDownload);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

final trafficStatsProvider = Provider<TrafficStats>((ref) {
  final conns = ref.watch(connectionsProvider);
  var up = 0;
  var down = 0;
  for (final c in conns.values) {
    up += c.uploadBytes;
    down += c.downloadBytes;
  }
  return TrafficStats(totalUpload: up, totalDownload: down);
});

// 路由分布统计
final routeDistributionProvider = Provider<Map<String, int>>((ref) {
  final conns = ref.watch(connectionsProvider);
  final dist = <String, int>{};
  for (final c in conns.values) {
    final tag = c.outbound.isEmpty ? 'unknown' : c.outbound;
    dist[tag] = (dist[tag] ?? 0) + 1;
  }
  return dist;
});
