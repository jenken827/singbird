// lib/services/monitor_service_windows.dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// 跨平台 Clash API 轮询 — 连接/流量/路由实时数据。
/// Windows: sing-box.exe 子进程监听 127.0.0.1:9090；
/// Android: 引擎在 app 进程内监听同地址（loopback 不走 VPN TUN）。
/// /monitor/* 为 Windows 后端的 SQLite 历史端点（Android 无则静默失败）。
class MonitorServiceWindows {
  static final MonitorServiceWindows _instance = MonitorServiceWindows._();
  factory MonitorServiceWindows() => _instance;
  MonitorServiceWindows._() {
    _startPolling();
  }

  static const _baseUrl = 'http://127.0.0.1:9090';
  static const _monitorUrl = 'http://127.0.0.1:9090/monitor';

  final _eventController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get events => _eventController.stream;

  // 共享 HTTP 客户端：复用 keep-alive 连接。顶层 http.get() 每次调用都
  // 新建连接+即关，1s 轮询会产生大量 TIME_WAIT(Windows 默认留存 240s)。
  final http.Client _client = http.Client();

  Timer? _timer;
  bool _running = true;
  final _seenConnections = <String>{};
  int _lastDnsTimestamp = 0; // track latest DNS to avoid duplicates

  void _startPolling() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_running) return;
      _fetchConnections();
      _fetchDNS();
    });
  }

  Future<Map<String, Map<String, int>>> _fetchLatencyMap() async {
    final map = <String, Map<String, int>>{};
    try {
      final resp = await _client
          .get(Uri.parse('$_monitorUrl/connections?limit=500'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return map;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      for (final r in data['connections'] as List? ?? []) {
        var destIp = r['dest_ip'] as String? ?? '';
        // Strip port: SQLite stores "IP:port", Clash API uses "IP" only
        final colon = destIp.lastIndexOf(':');
        if (colon > 0) destIp = destIp.substring(0, colon);
        final tcp = (r['tcp_latency_us'] as num?)?.toInt() ?? 0;
        final tls = (r['tls_latency_us'] as num?)?.toInt() ?? 0;
        if (destIp.isNotEmpty && (tcp > 0 || tls > 0)) {
          map[destIp] = {'tcp': tcp, 'tls': tls};
        }
      }
    } catch (_) {}
    return map;
  }

  Future<void> _fetchDNS() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_monitorUrl/dns?since=$_lastDnsTimestamp&limit=50'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final records = data['records'] as List? ?? [];
      for (final r in records.reversed) {
        final ts = (r['timestamp'] as num?)?.toInt() ?? 0;
        if (ts > _lastDnsTimestamp) _lastDnsTimestamp = ts;
        _eventController.add({
          'type': 'dns',
          'timestamp': ts,
          'domain': r['domain'] ?? '',
          'qtype': r['qtype'] ?? 'A',
          'transport': r['transport'] ?? '',
          'latency_us': (r['latency_us'] as num?)?.toInt() ?? 0,
          'status': r['status'] ?? '',
          'answers': r['answers'] ?? [],
          'ttl': (r['ttl'] as num?)?.toInt() ?? 0,
          'is_rejected': r['is_rejected'] ?? false,
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchConnections() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_baseUrl/connections'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return;

      final latencyMap = await _fetchLatencyMap();
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final connections = data['connections'] as List? ?? [];

      final thisCycle = <String>{};

      for (final c in connections) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        final id = c['id'] as String;
        final host = (meta['host'] as String?) ?? (meta['destinationIP'] as String?) ?? '';
        final rule = (c['rule'] as String?) ?? 'final';
        final chains = (c['chains'] as List?) ?? [];
        final outbound = chains.isNotEmpty ? chains.last as String : '';
        final upload = (c['upload'] as num?)?.toInt() ?? 0;
        final download = (c['download'] as num?)?.toInt() ?? 0;
        final start = c['start'] as String?;
        final startMs = start != null ? DateTime.tryParse(start)?.millisecondsSinceEpoch ?? 0 : 0;
        final destIp = (meta['destinationIP'] as String?) ?? '';
        final lat = latencyMap[destIp];

        thisCycle.add(id);
        _seenConnections.add(id);

        final processPath = (meta['processPath'] as String?) ?? '';

        _eventController.add({
          'type': 'connection',
          'id': id,
          'host': host,
          'dest_ip': destIp,
          'dest_port': meta['destinationPort'] ?? '0',
          'rule': rule,
          'outbound': outbound,
          'tcp_latency_us': lat?['tcp'] ?? 0,
          'tls_latency_us': lat?['tls'] ?? 0,
          'upload_bytes': upload,
          'download_bytes': download,
          'start_time': startMs,
          'closed': false,
          'process_path': processPath,
        });
      }

      // Emit close for connections that disappeared since last poll
      final stale = _seenConnections.difference(thisCycle);
      for (final id in stale) {
        _eventController.add({'type': 'connection_closed', 'id': id});
      }
      _seenConnections.removeAll(stale);
    } catch (_) {}
  }

  void dispose() {
    _running = false;
    _timer?.cancel();
    _client.close();
    _eventController.close();
  }

  // ---- History query methods (SQLite-backed via /monitor/*) ----

  /// Query DNS records from SQLite history.
  /// [since] is a unix ms timestamp; 0 means all.
  Future<List<Map<String, dynamic>>> queryDNS(
      {int since = 0, int limit = 200}) async {
    try {
      final resp = await _client
          .get(Uri.parse(
              '$_monitorUrl/dns?since=$since&limit=$limit'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final records = data['records'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Query connection records from SQLite history.
  Future<List<Map<String, dynamic>>> queryConnections(
      {int since = 0, int limit = 200}) async {
    try {
      final resp = await _client
          .get(Uri.parse(
              '$_monitorUrl/connections?since=$since&limit=$limit'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final records = data['connections'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Query alert events from SQLite history.
  Future<List<Map<String, dynamic>>> queryAlerts(
      {int since = 0, int limit = 50}) async {
    try {
      final resp = await _client
          .get(Uri.parse(
              '$_monitorUrl/alerts?since=$since&limit=$limit'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final records = data['alerts'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Query cumulative stats from all closed connections.
  Future<Map<String, dynamic>> queryStats() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_monitorUrl/stats'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return {};
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Health check — returns status and dropped record count.
  Future<Map<String, dynamic>> healthCheck() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_monitorUrl/health'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return {'status': 'error'};
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'status': 'unreachable'};
    }
  }
}
