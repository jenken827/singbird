// lib/pages/monitor_page.dart
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../services/monitor_service.dart';

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});
  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor (History)'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [Tab(text: 'DNS'), Tab(text: 'Connections')],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [DnsHistoryTab(), ConnectionHistoryTab()],
      ),
    );
  }
}

// ===================== DNS History Tab =====================
class DnsHistoryTab extends StatefulWidget {
  const DnsHistoryTab({super.key});
  @override
  State<DnsHistoryTab> createState() => _DnsHistoryTabState();
}

class _DnsHistoryTabState extends State<DnsHistoryTab> {
  final List<Map<String, dynamic>> _records = [];
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  String _query = '';
  bool _loading = false;
  bool _hasMore = true;
  int _maxTimestamp = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 100 &&
        !_loading && _hasMore) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final limit = more ? (_records.length + 100) : 100;
      final records = await MonitorService()
          .queryDNSHistory(since: 0, limit: limit);
      _records.clear();
      _records.addAll(records);
      _hasMore = records.length >= limit;
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      if (_records.isEmpty) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _records.isEmpty) _load();
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _filter(String q) => setState(() => _query = q.toLowerCase().trim());

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _records;
    return _records.where((r) {
      final d = (r['domain'] as String?) ?? '';
      final a = (r['answers'] as List?)?.join(' ') ?? '';
      return d.toLowerCase().contains(_query) || a.toLowerCase().contains(_query);
    }).toList();
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'NOERROR': return Colors.green;
      case 'NXDOMAIN': return Colors.orange;
      case 'REFUSED': return Colors.red;
      case 'SERVFAIL': return Colors.red.shade300;
      default: return status != null && status.isNotEmpty ? Colors.grey : Colors.green;
    }
  }

  // DNS 服务器 tag → 颜色（预置调色板，未识别 tag 灰色）
  Color _serverColor(String tag) {
    switch (tag) {
      case 'dns-direct': return Colors.teal;
      case 'dns-remote': return Colors.indigo;
      case 'dns-local': return Colors.blueGrey;
      default: return Colors.grey;
    }
  }

  Widget _serverChip(String? tag) {
    if (tag == null || tag.isEmpty) return const SizedBox.shrink();
    final bg = _serverColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(tag, style: TextStyle(fontSize: 10, color: bg, fontWeight: FontWeight.w500)),
    );
  }

  String _fmtUs(dynamic v) {
    final us = (v as num?)?.toInt() ?? 0;
    if (us < 1000) return '${us}us';
    return '${(us / 1000).toStringAsFixed(1)}ms';
  }

  String _fmtTime(dynamic ts) {
    final ms = (ts as num?)?.toInt() ?? 0;
    if (ms == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: _searchCtrl,
          onChanged: _filter,
          decoration: const InputDecoration(
            hintText: 'Filter domain or answer...',
            prefixIcon: Icon(Icons.search, size: 18),
            border: OutlineInputBorder(), isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Text('${list.length} records', style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: () => _load(), tooltip: 'Refresh'),
        ]),
      ),
      Expanded(
        child: _loading && _records.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : list.isEmpty
                ? const Center(child: Text('No DNS records'))
                : ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: list.length + (_hasMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= list.length) {
                        return const Padding(padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()));
                      }
                      final r = list[i];
                      final isRejected = r['status'] == 'REFUSED' || (r['is_rejected'] == true);
                      final answers = (r['answers'] as List?)?.join(', ') ?? '';
                      final sc = _statusColor(r['status'] as String?);
                      return ListTile(
                        dense: true,
                        leading: Icon(isRejected ? Icons.block : Icons.dns, color: isRejected ? Colors.red : Colors.green, size: 20),
                        title: Text(r['domain'] ?? '', style: const TextStyle(fontSize: 14)),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text('${r['qtype'] ?? ''}', style: const TextStyle(fontSize: 11)),
                              const SizedBox(width: 6),
                              _serverChip(r['transport'] as String?),
                              const SizedBox(width: 6),
                              Text(_fmtUs(r['latency_us']), style: const TextStyle(fontSize: 11)),
                            ]),
                            if (answers.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(answers, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            ],
                          ]),
                        ),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: sc.withOpacity(0.3), borderRadius: BorderRadius.circular(4)),
                              child: Text(r['status'] ?? 'OK', style: TextStyle(fontSize: 10, color: sc))),
                            const SizedBox(height: 2),
                            Text(_fmtTime(r['timestamp']), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                          ]),
                      );
                    }),
      ),
    ]);
  }
}

// ===================== Connection History Tab =====================
class ConnectionHistoryTab extends StatefulWidget {
  const ConnectionHistoryTab({super.key});
  @override
  State<ConnectionHistoryTab> createState() => _ConnectionHistoryTabState();
}

class _ConnectionHistoryTabState extends State<ConnectionHistoryTab> {
  final List<Map<String, dynamic>> _records = [];
  final Map<String, String> _appLabels = {};
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  String _query = '';
  bool _loading = false;
  bool _hasMore = true;
  int _maxTimestamp = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 100 &&
        !_loading && _hasMore) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final limit = more ? (_records.length + 100) : 100;
      final records = await MonitorService()
          .queryConnectionHistory(since: 0, limit: limit);
      _records.clear();
      _records.addAll(records);
      _hasMore = records.length >= limit;
      await _resolveLabels(records);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      if (_records.isEmpty) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _records.isEmpty) _load();
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 把记录里的包名批量解析为应用名（Android），Windows 路径跳过。
  Future<void> _resolveLabels(List<Map<String, dynamic>> records) async {
    if (!Platform.isAndroid) return;
    final pkgs = records
        .map((r) => (r['process_path'] as String?) ?? '')
        .where((p) => p.isNotEmpty && !p.contains('\\'))
        .toSet()
        .toList();
    if (pkgs.isEmpty) return;
    final map = await MonitorService().resolveAppLabels(pkgs);
    if (mounted && map.isNotEmpty) setState(() => _appLabels.addAll(map));
  }

  void _filter(String q) => setState(() => _query = q.toLowerCase().trim());

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _records;
    return _records.where((r) {
      final h = (r['host'] as String?) ?? '';
      final ip = (r['dest_ip'] as String?) ?? '';
      final pp = (r['process_path'] as String?) ?? '';
      final label = _appLabels[pp] ?? '';
      return h.toLowerCase().contains(_query) || ip.toLowerCase().contains(_query) ||
          pp.toLowerCase().contains(_query) || label.toLowerCase().contains(_query);
    }).toList();
  }

  Color _routeColor(String? tag) {
    switch (tag) {
      case 'proxy': return Colors.purple;
      case 'direct': return Colors.green;
      case 'block': return Colors.red;
      default: return Colors.grey;
    }
  }

  String _displayHost(Map<String, dynamic> r) {
    final h = r['host'] as String?;
    if (h != null && h.isNotEmpty) return h;
    final ip = r['dest_ip'] as String? ?? '';
    if (ip.isEmpty) return 'unknown';
    final colon = ip.lastIndexOf(':');
    return colon > 0 ? ip.substring(0, colon) : ip;
  }

  String _fmtBytes(dynamic v) {
    final b = (v as num?)?.toInt() ?? 0;
    if (b < 1024) return '${b}B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)}K';
    return '${(b / 1048576).toStringAsFixed(1)}M';
  }

  String _fmtUs(dynamic v) {
    final us = (v as num?)?.toInt() ?? 0;
    if (us == 0) return '-';
    if (us < 1000) return '${us}us';
    return '${(us / 1000).toStringAsFixed(0)}ms';
  }

  String _fmtTime(dynamic ts) {
    final ms = (ts as num?)?.toInt() ?? 0;
    if (ms == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: _searchCtrl,
          onChanged: _filter,
          decoration: const InputDecoration(
            hintText: 'Filter domain or IP...',
            prefixIcon: Icon(Icons.search, size: 18),
            border: OutlineInputBorder(), isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Text('${list.length} records', style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: () => _load(), tooltip: 'Refresh'),
        ]),
      ),
      Expanded(
        child: _loading && _records.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : list.isEmpty
                ? const Center(child: Text('No connection records'))
                : ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: list.length + (_hasMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= list.length) {
                        return const Padding(padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()));
                      }
                      final r = list[i];
                      final rc = _routeColor(r['outbound'] as String?);
                      final pp = (r['process_path'] as String?) ?? '';
                      final label = _appLabels[pp];
                      final ppLabel = pp.isNotEmpty
                          ? (label != null && label != pp
                              ? '$label ($pp)'
                              : pp.split('\\').last)
                          : null;
                      final err = (r['error'] as String?) ?? '';
                      return ListTile(
                        dense: true,
                        leading: Icon(err.isNotEmpty ? Icons.error_outline : Icons.link, color: err.isNotEmpty ? Colors.red : rc, size: 20),
                        title: Text(_displayHost(r), style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            '${ppLabel != null ? '$ppLabel · ' : ''}TCP ${_fmtUs(r['tcp_latency_us'])} | TLS ${_fmtUs(r['tls_latency_us'])} | ↑${_fmtBytes(r['upload_bytes'])} ↓${_fmtBytes(r['download_bytes'])}',
                            style: const TextStyle(fontSize: 11)),
                          if (err.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Tooltip(
                              message: err,
                              child: Text('✗ $err', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10, color: Colors.red)),
                            ),
                          ],
                        ]),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: rc.withOpacity(0.3), borderRadius: BorderRadius.circular(4)),
                              child: Text(r['outbound'] ?? '?', style: TextStyle(fontSize: 10, color: rc))),
                            const SizedBox(height: 2),
                            Text(_fmtTime(r['start_time']), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                          ]),
                      );
                    }),
      ),
    ]);
  }
}
