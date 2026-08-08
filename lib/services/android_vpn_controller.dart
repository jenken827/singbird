// lib/services/android_vpn_controller.dart
// Android-specific VPN control via MethodChannel.
// Falls back silently on non-Android platforms.
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import '../main.dart' show talker;

class AndroidVpnController {
  static const _channel = MethodChannel('sing-box/monitor/control');

  // ── Singleton ──

  static final AndroidVpnController _instance = AndroidVpnController._();
  factory AndroidVpnController() => _instance;
  AndroidVpnController._();

  bool get _isAndroid => Platform.isAndroid;

  /// Start the Android VpnService (foreground service + TUN).
  /// Pass [configDir] — the directory containing sing-box-config.json
  /// and netbird-config.json. The Go engine reads these files directly.
  Future<void> startVpn({
    List<String>? allowedPackages,
    List<String>? disallowedPackages,
    String? configDir,
    bool? netbirdEnabled,
  }) async {
    if (!_isAndroid) return;
    final args = <String, dynamic>{};
    if (allowedPackages != null) args['allowedPackages'] = allowedPackages;
    if (disallowedPackages != null) args['disallowedPackages'] = disallowedPackages;
    if (configDir != null) args['configDir'] = configDir;
    if (netbirdEnabled != null) args['netbirdEnabled'] = netbirdEnabled;
    try {
      await _channel.invokeMethod('startVpn', args);
    } catch (e) {
      talker.error('startVpn failed: $e', 'AndroidVPN');
      rethrow;
    }
  }

  /// Stop the Android VpnService.
  Future<void> stopVpn() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('stopVpn');
  }

  /// Check if VPN is running.
  Future<bool> isVpnRunning() async {
    if (!_isAndroid) return false;
    try {
      final status = await _channel.invokeMethod<Map>('getVpnStatus');
      return status?['running'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Read native (Kotlin) side logs from file — survives crashes
  Future<String> readNativeLog() async {
    if (!_isAndroid) return 'Not available on this platform';
    try {
      final result = await _channel.invokeMethod<String>('readNativeLog');
      return result ?? '(empty log)';
    } catch (e) {
      return 'Error reading native log: $e';
    }
  }

  /// Read MarkerWriter markers (zero-dependency, always available)
  Future<String> readMarkers() async {
    if (!_isAndroid) return '';
    try {
      final result = await _channel.invokeMethod<String>('readMarkers');
      return result ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Read Go-side markers from go_markers.txt
  Future<String> readGoMarkers() async {
    if (!_isAndroid) return '';
    try {
      final result = await _channel.invokeMethod<String>('readGoMarkers');
      return result ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Read Go crash report (stderr redirect)
  Future<String> readCrashReport() async {
    if (!_isAndroid) return '';
    try {
      final result = await _channel.invokeMethod<String>('readCrashReport');
      return result ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Clear all native logs (markers, go markers, crash report)
  Future<bool> clearLogs() async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('clearLogs');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Set the sing-box config for the running service.
  /// Must be called after startVpn() to prevent Go engine crash.
  Future<void> setServiceConfig(String config) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('setServiceConfig', {'config': config});
  }

  /// Get current VPN status: running + active filters.
  Future<Map<String, dynamic>> getVpnStatus() async {
    if (!_isAndroid) return {'running': false};
    try {
      final status = await _channel.invokeMethod<Map>('getVpnStatus');
      return Map<String, dynamic>.from(status ?? {'running': false});
    } catch (_) {
      return {'running': false};
    }
  }

  // ── Per-app filter ──

  /// Set whitelist: only these apps route through VPN.
  Future<void> setAllowedPackages(List<String> packages) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('setAllowedPackages', {'packages': packages});
  }

  /// Set blacklist: these apps bypass VPN.
  Future<void> setDisallowedPackages(List<String> packages) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('setDisallowedPackages', {'packages': packages});
  }

  /// Block mode: these apps lose internet access (engine package_name→block
  /// rule). Clears allow/disallow — all apps flow through the VPN so the
  /// engine sees (and drops) the blocked ones.
  Future<void> setBlockedPackages(List<String> packages) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('setBlockedPackages', {'packages': packages});
  }

  /// Clear all app filters (all apps route through VPN).
  Future<void> clearAppFilter() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod('clearAppFilter');
  }

  /// Get list of installed apps with launcher activities.
  Future<List<Map<String, String>>> getInstalledApps() async {
    if (!_isAndroid) return [];
    try {
      final json = await _channel.invokeMethod<String>('getInstalledApps');
      if (json == null || json.isEmpty) return [];
      final List<dynamic> arr = jsonDecode(json);
      return arr
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
