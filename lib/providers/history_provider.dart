// lib/providers/history_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/monitor_event.dart';
import '../services/monitor_service.dart';

/// Provider for DNS history (from SQLite).
/// Refreshes when the user explicitly calls refresh.
final dnsHistoryProvider =
    NotifierProvider<DnsHistoryNotifier, List<DNSRecord>>(DnsHistoryNotifier.new);

class DnsHistoryNotifier extends Notifier<List<DNSRecord>> {
  @override
  List<DNSRecord> build() => [];

  Future<void> load({int since = 0, int limit = 500}) async {
    final raw = await MonitorService().queryDNSHistory(since: since, limit: limit);
    state = raw.map((e) => DNSRecord.fromJson(e)).toList();
  }

  Future<void> loadRecent() async {
    // Load last 1 hour
    final oneHourAgo = DateTime.now().millisecondsSinceEpoch - 3600000;
    await load(since: oneHourAgo, limit: 500);
  }
}

/// Provider for connection history (from SQLite).
final connectionHistoryProvider = NotifierProvider<ConnectionHistoryNotifier,
    List<ConnectionRecord>>(ConnectionHistoryNotifier.new);

class ConnectionHistoryNotifier extends Notifier<List<ConnectionRecord>> {
  @override
  List<ConnectionRecord> build() => [];

  Future<void> load({int since = 0, int limit = 500}) async {
    final raw =
        await MonitorService().queryConnectionHistory(since: since, limit: limit);
    state = raw.map((e) => ConnectionRecord.fromJson(e)).toList();
  }

  Future<void> loadRecent() async {
    final oneHourAgo = DateTime.now().millisecondsSinceEpoch - 3600000;
    await load(since: oneHourAgo, limit: 500);
  }

  List<ConnectionRecord> get active =>
      state.where((c) => !c.closed).toList();

  List<ConnectionRecord> get closed =>
      state.where((c) => c.closed).toList();
}

/// Provider for cumulative traffic stats (from SQLite, all-time).
final cumulativeStatsProvider =
    NotifierProvider<CumulativeStatsNotifier, Map<String, dynamic>>(
        CumulativeStatsNotifier.new);

class CumulativeStatsNotifier extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() => {};

  Future<void> refresh() async {
    state = await MonitorService().queryStats();
  }

  int get uploadBytes => (state['upload_bytes'] as num?)?.toInt() ?? 0;
  int get downloadBytes => (state['download_bytes'] as num?)?.toInt() ?? 0;
  int get dropped => (state['dropped'] as num?)?.toInt() ?? 0;
}
