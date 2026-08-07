// lib/services/version_service.dart
/// Version info for the frontend (Flutter) and backend (sing-box + netbird).
/// - Frontend: pubspec version + build hash (injected via --dart-define)
/// - Backend (Android): via libbox (MethodChannel)
/// - Backend (Windows): parse `sing-box version` output
import 'dart:convert';
import 'dart:io' show Platform, Process;
import 'package:flutter/services.dart';
import 'singbox_controller.dart';

class BackendVersion {
  final String singBoxVersion;
  final String singBoxCommit;
  final String singBoxBuildTime;
  final String netbirdVersion;
  final String netbirdCommit;

  const BackendVersion({
    required this.singBoxVersion,
    required this.singBoxCommit,
    required this.singBoxBuildTime,
    required this.netbirdVersion,
    required this.netbirdCommit,
  });

  factory BackendVersion.empty() =>
      const BackendVersion(
        singBoxVersion: 'unknown',
        singBoxCommit: '',
        singBoxBuildTime: '',
        netbirdVersion: 'N/A',
        netbirdCommit: '',
      );
}

class VersionService {
  static const _channel = MethodChannel('sing-box/monitor/control');

  /// Frontend version (pubspec.yaml `version:`), bumped manually.
  static const String frontendVersion = '1.0.0';

  /// Frontend build hash — injected at build time with
  /// `--dart-define=FLUTTER_BUILD_HASH=<git rev-parse --short HEAD>`.
  static const String frontendBuildHash = String.fromEnvironment(
    'FLUTTER_BUILD_HASH',
    defaultValue: 'dev',
  );

  /// Frontend build time (ISO 8601) — injected at build time with
  /// `--dart-define=FLUTTER_BUILD_TIME=$(date +%Y-%m-%dT%H:%M:%S)`.
  static const String frontendBuildTime = String.fromEnvironment(
    'FLUTTER_BUILD_TIME',
    defaultValue: 'unknown',
  );

  /// Build number (pubspec `version: 1.0.0+1`).
  static const String buildNumber = '1';

  static String get frontendLabel =>
      'v$frontendVersion+$buildNumber ($frontendBuildHash)';

  static Future<BackendVersion> fetchBackend() async {
    if (Platform.isAndroid) {
      try {
        final json = await _channel.invokeMethod<String>('getBackendVersion');
        if (json == null || json.isEmpty) return BackendVersion.empty();
        final map = jsonDecode(json) as Map<String, dynamic>;
        return BackendVersion(
          singBoxVersion: map['singBoxVersion'] as String? ?? 'unknown',
          singBoxCommit: map['singBoxCommit'] as String? ?? '',
          singBoxBuildTime: map['singBoxBuildTime'] as String? ?? '',
          netbirdVersion: map['netbirdVersion'] as String? ?? 'N/A',
          netbirdCommit: map['netbirdCommit'] as String? ?? '',
        );
      } catch (_) {
        return BackendVersion.empty();
      }
    }
    // Desktop: run `sing-box version` and parse
    return _fetchFromCli();
  }

  static Future<BackendVersion> _fetchFromCli() async {
    final ctrl = SingBoxController.instance();
    final exe = ctrl.exePath;
    if (exe == null || exe.isEmpty) return BackendVersion.empty();
    try {
      final result = await Process.run(exe, ['version']);
      if (result.exitCode != 0) return BackendVersion.empty();
      final out = (result.stdout as String? ?? '') +
          (result.stderr as String? ?? '');
      final lines = out.split('\n');

      String? version;
      String? revision;
      String? buildTime;
      String? netbirdVersion;
      String? netbirdCommit;
      for (final line in lines) {
        final v = RegExp(r'sing-box version (.+)').firstMatch(line);
        if (v != null) version = v.group(1)?.trim();
        final r = RegExp(r'Revision:\s*(\S+)').firstMatch(line);
        if (r != null) {
          revision = r.group(1)?.trim();
          // Truncate to 12 chars to match the Android (SingBoxCommit) format
          if ((revision?.length ?? 0) > 12) revision = revision!.substring(0, 12);
        }
        final t = RegExp(r'BuildTime:\s*(\S+)').firstMatch(line);
        if (t != null) buildTime = t.group(1)?.trim();
        final nb = RegExp(r'Netbird:\s*([^\s(]+)(?:\s*\(([^)]*)\))?').firstMatch(line);
        if (nb != null) {
          netbirdVersion = nb.group(1)?.trim();
          netbirdCommit = nb.group(2)?.trim() ?? '';
        }
      }
      return BackendVersion(
        singBoxVersion: version ?? 'unknown',
        singBoxCommit: revision ?? '',
        singBoxBuildTime: buildTime ?? '',
        netbirdVersion: netbirdVersion ?? 'N/A',
        netbirdCommit: netbirdCommit ?? '',
      );
    } catch (_) {
      return BackendVersion.empty();
    }
  }
}
