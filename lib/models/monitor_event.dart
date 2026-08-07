// lib/models/monitor_event.dart

enum MonitorEventType { dns, connectionNew, connectionUpdate, connectionClosed, alert }

class DNSRecord {
  final int timestamp;
  final String domain;
  final String qtype;
  final String transport;
  final int latencyUs;
  final String status;
  final List<String> answers;
  final int ttl;
  final bool isRejected;

  const DNSRecord({
    required this.timestamp,
    required this.domain,
    required this.qtype,
    required this.transport,
    required this.latencyUs,
    required this.status,
    required this.answers,
    required this.ttl,
    this.isRejected = false,
  });

  factory DNSRecord.fromJson(Map<String, dynamic> json) => DNSRecord(
        timestamp: _parseInt(json['timestamp'], 0),
        domain: json['domain'] ?? '',
        qtype: json['qtype'] ?? 'A',
        transport: json['transport'] ?? '',
        latencyUs: _parseInt(json['latency_us'], 0),
        status: json['status'] ?? '',
        answers: List<String>.from(json['answers'] ?? []),
        ttl: _parseInt(json['ttl'], 0),
        isRejected: json['is_rejected'] ?? false,
      );

  double get latencyMs => latencyUs / 1000.0;
}

class ConnectionRecord {
  final String id;
  final String? host;
  final String destIp;
  final int destPort;
  final String rule;
  final String outbound;
  final int tcpLatencyUs;
  final int tlsLatencyUs;
  final int? dnsLatencyUs;
  final String? tlsVersion;
  final int uploadBytes;
  final int downloadBytes;
  final int startTime;
  final int? endTime;
  final int? durationMs;
  final bool closed;
  final String processPath;

  const ConnectionRecord({
    required this.id,
    this.host,
    required this.destIp,
    required this.destPort,
    required this.rule,
    required this.outbound,
    this.tcpLatencyUs = 0,
    this.tlsLatencyUs = 0,
    this.dnsLatencyUs,
    this.tlsVersion,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    required this.startTime,
    this.endTime,
    this.durationMs,
    this.closed = false,
    this.processPath = '',
  });

  factory ConnectionRecord.fromJson(Map<String, dynamic> json) => ConnectionRecord(
        id: json['id'] ?? '',
        host: json['host'],
        destIp: json['dest_ip'] ?? '',
        destPort: _parseInt(json['dest_port'], 0),
        rule: json['rule'] ?? '',
        outbound: json['outbound'] ?? '',
        tcpLatencyUs: _parseInt64(json['tcp_latency_us'], 0),
        tlsLatencyUs: _parseInt64(json['tls_latency_us'], 0),
        dnsLatencyUs: _parseInt64Nullable(json['dns_latency_us']),
        tlsVersion: json['tls_version'],
        uploadBytes: _parseInt64(json['upload_bytes'], 0),
        downloadBytes: _parseInt64(json['download_bytes'], 0),
        startTime: _parseInt64(json['start_time'], 0),
        endTime: _parseInt64Nullable(json['end_time']),
        durationMs: _parseIntNullable(json['duration_ms']),
        closed: json['closed'] ?? false,
        processPath: json['process_path'] ?? '',
      );

  double get tcpLatencyMs => tcpLatencyUs / 1000.0;
  double get tlsLatencyMs => tlsLatencyUs / 1000.0;
  double get totalLatencyMs => (tcpLatencyUs + tlsLatencyUs) / 1000.0;
}

class AlertEvent {
  final int ruleId;
  final String ruleName;
  final String? connectionId;
  final int actualValue;
  final int threshold;
  final String message;
  final int timestamp;

  const AlertEvent({
    required this.ruleId,
    required this.ruleName,
    this.connectionId,
    required this.actualValue,
    required this.threshold,
    required this.message,
    required this.timestamp,
  });

  factory AlertEvent.fromJson(Map<String, dynamic> json) => AlertEvent(
        ruleId: json['rule_id'] ?? 0,
        ruleName: json['rule_name'] ?? '',
        connectionId: json['connection_id'],
        actualValue: json['actual_value'] ?? 0,
        threshold: json['threshold'] ?? 0,
        message: json['message'] ?? '',
        timestamp: json['timestamp'] ?? 0,
      );
}

class AlertRule {
  final int? id;
  final String name;
  final String metric;
  final String operator;
  final int thresholdUs;
  final String? targetPattern;
  final bool enabled;

  const AlertRule({
    this.id,
    required this.name,
    required this.metric,
    required this.operator,
    required this.thresholdUs,
    this.targetPattern,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'metric': metric,
        'operator': operator,
        'threshold_us': thresholdUs,
        'target_pattern': targetPattern ?? '',
        'enabled': enabled,
      };

  factory AlertRule.fromJson(Map<String, dynamic> json) => AlertRule(
        id: json['id'],
        name: json['name'] ?? '',
        metric: json['metric'] ?? '',
        operator: json['operator'] ?? 'gt',
        thresholdUs: json['threshold_us'] ?? 0,
        targetPattern: json['target_pattern'],
        enabled: json['enabled'] ?? true,
      );
}

// ---- JSON parsing helpers (safe against String/int mismatches) ----

int _parseInt(dynamic v, int fallback) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int _parseInt64(dynamic v, int fallback) => _parseInt(v, fallback);

int? _parseIntNullable(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

int? _parseInt64Nullable(dynamic v) => _parseIntNullable(v);
