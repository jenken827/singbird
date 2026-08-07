// lib/pages/route_detail_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class RouteDetailPage extends StatefulWidget {
  final String outboundTag;
  final int activeCount;
  const RouteDetailPage({super.key, required this.outboundTag, required this.activeCount});

  @override
  State<RouteDetailPage> createState() => _RouteDetailPageState();
}

class _RouteDetailPageState extends State<RouteDetailPage> {
  List<Map<String, dynamic>> _allRecords = [];
  List<Map<String, dynamic>> _filtered = [];
  final _searchCtrl = TextEditingController();
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:9090/connections'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final conns = data['connections'] as List? ?? [];
      _allRecords = conns.where((c) {
        final chains = c['chains'] as List? ?? [];
        final outbound = chains.isNotEmpty ? chains.last as String : '';
        return outbound == widget.outboundTag;
      }).map((c) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        return {
          'host': meta['host'] ?? c['destination'] ?? '',
          'dest_ip': meta['destinationIP'] ?? '',
          'upload': c['upload'] ?? 0,
          'download': c['download'] ?? 0,
          'start': c['start'] ?? '',
        };
      }).toList();
      _filter(_searchCtrl.text);
    } catch (_) {}
  }

  void _filter(String q) {
    final query = q.toLowerCase().trim();
    setState(() {
      _loading = false;
      if (query.isEmpty) {
        _filtered = List.from(_allRecords);
      } else {
        _filtered = _allRecords.where((r) {
          final host = (r['host'] as String?) ?? '';
          final ip = (r['dest_ip'] as String?) ?? '';
          return host.toLowerCase().contains(query) || ip.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  String _fmtBytes(dynamic v) {
    final b = (v as num?)?.toInt() ?? 0;
    if (b < 1024) return '${b}B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)}K';
    return '${(b / 1048576).toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Route: ${widget.outboundTag} (${_filtered.length}/${_allRecords.length})'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _filter,
              decoration: const InputDecoration(
                hintText: 'Filter by domain or IP...',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filtered.isEmpty
              ? Center(
                  child: Text(
                    _searchCtrl.text.isNotEmpty
                        ? 'No matches for "${_searchCtrl.text}"'
                        : 'No active connections on ${widget.outboundTag}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final r = _filtered[i];
                    final host = (r['host'] as String?)?.isNotEmpty == true
                        ? r['host'] as String
                        : (r['dest_ip'] as String?) ?? '';
                    final up = _fmtBytes(r['upload']);
                    final down = _fmtBytes(r['download']);
                    return ListTile(
                      dense: true,
                      title: Text(host, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                      subtitle: Text('↑$up ↓$down', style: const TextStyle(fontSize: 11)),
                    );
                  },
                ),
    );
  }
}
