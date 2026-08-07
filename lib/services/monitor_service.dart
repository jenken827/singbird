// lib/services/monitor_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import '../models/monitor_event.dart';
import 'monitor_service_windows.dart';
import 'singbox_controller.dart';

class MonitorService {
  static const _controlChannel = MethodChannel('sing-box/monitor/control');

  static final MonitorService _instance = MonitorService._();
  factory MonitorService() => _instance;
  MonitorService._() {
    // Clash API polling works on ALL platforms: on Android the engine runs
    // in-process and listens on 127.0.0.1:9090 (loopback bypasses the VPN
    // TUN), on Windows sing-box.exe listens on the same address.
    _clashPoller = MonitorServiceWindows();
  }

  final sbCtrl = SingBoxController.instance();

  MonitorServiceWindows? _clashPoller;

  /// 实时事件流 (connection/dns/alert) — 来自 Clash API 轮询
  Stream<dynamic> get events => _clashPoller!.events;

  /// 封装后的事件流
  Stream<DNSRecord> get dnsRecords => events
      .where((e) => e is Map && e['type'] == 'dns')
      .map((e) => DNSRecord.fromJson(e));

  Stream<ConnectionRecord> get connections => events
      .where((e) => e is Map && e['type'] == 'connection')
      .map((e) => ConnectionRecord.fromJson(e));

  Stream<ConnectionRecord> get connectionsClosed => events
      .where((e) => e is Map && e['type'] == 'connection_closed')
      .map((e) => ConnectionRecord.fromJson(e));

  Stream<AlertEvent> get alerts => events
      .where((e) => e is Map && e['type'] == 'alert')
      .map((e) => AlertEvent.fromJson(e));

  /// 启动代理
  Future<void> startService() async {
    if (Platform.isAndroid) {
      // Android: use startVpn to properly establish TUN via VpnService
      await _controlChannel.invokeMethod('startVpn');
      return;
    }
    await sbCtrl.start();
  }

  /// 停止代理
  Future<void> stopService() async {
    if (Platform.isAndroid) {
      // Android: stop VpnService
      await _controlChannel.invokeMethod('stopVpn');
      return;
    }
    await sbCtrl.stop();
  }

  /// 获取服务状态
  Future<bool> isRunning() async {
    if (Platform.isAndroid) {
      // Android: query VpnService status
      final status = await _controlChannel.invokeMethod<Map>('getVpnStatus');
      return status?['running'] == true;
    }
    return sbCtrl.isRunning;
  }

  /// 获取最近 N 条 DNS 记录
  Future<List<DNSRecord>> getDNSHistory(int limit) async {
    final json = await _controlChannel.invokeMethod('getDNSHistory', limit);
    if (json == null) return [];
    return (jsonDecode(json) as List)
        .map((e) => DNSRecord.fromJson(e))
        .toList();
  }

  /// 获取最近 N 条连接记录
  Future<List<ConnectionRecord>> getConnectionHistory(int limit) async {
    final json = await _controlChannel.invokeMethod(
      'getConnectionHistory',
      limit,
    );
    if (json == null) return [];
    return (jsonDecode(json) as List)
        .map((e) => ConnectionRecord.fromJson(e))
        .toList();
  }

  /// 添加告警规则
  Future<int> addAlertRule(AlertRule rule) async {
    return await _controlChannel.invokeMethod('addAlertRule', rule.toJson());
  }

  /// 删除告警规则
  Future<void> deleteAlertRule(int ruleId) async {
    await _controlChannel.invokeMethod('deleteAlertRule', ruleId);
  }

  /// 获取所有告警规则
  Future<List<AlertRule>> getAlertRules() async {
    final json = await _controlChannel.invokeMethod('getAlertRules');
    if (json == null) return [];
    return (jsonDecode(json) as List)
        .map((e) => AlertRule.fromJson(e))
        .toList();
  }

  // ---- History query methods (cross-platform) ----

  /// Query DNS records from SQLite history (Windows via HTTP, Android via MethodChannel).
  Future<List<Map<String, dynamic>>> queryDNSHistory({
    int since = 0,
    int limit = 200,
  }) async {
    if (Platform.isAndroid) {
      // Android: via MethodChannel
      final json = await _controlChannel.invokeMethod('queryDNSHistory', {
        'since': since,
        'limit': limit,
      });
      if (json == null) return [];
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    }
    return _clashPoller!.queryDNS(since: since, limit: limit);
  }

  /// Query connection records from SQLite history.
  Future<List<Map<String, dynamic>>> queryConnectionHistory({
    int since = 0,
    int limit = 200,
  }) async {
    if (Platform.isAndroid) {
      final json = await _controlChannel.invokeMethod('queryConnectionHistory', {
        'since': since,
        'limit': limit,
      });
      if (json == null) return [];
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    }
    return _clashPoller!.queryConnections(since: since, limit: limit);
  }

  /// Query cumulative stats.
  Future<Map<String, dynamic>> queryStats() async {
    if (Platform.isAndroid) {
      final json = await _controlChannel.invokeMethod('queryStats');
      if (json == null) return {};
      return jsonDecode(json) as Map<String, dynamic>;
    }
    return _clashPoller!.queryStats();
  }
}
