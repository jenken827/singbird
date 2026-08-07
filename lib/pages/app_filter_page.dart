// lib/pages/app_filter_page.dart
/// Per-app VPN filter settings for Android.
/// Lets user select which apps go through or bypass the VPN.
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/android_vpn_controller.dart';

class AppFilterPage extends StatefulWidget {
  const AppFilterPage({super.key});

  @override
  State<AppFilterPage> createState() => _AppFilterPageState();
}

class _AppFilterPageState extends State<AppFilterPage> {
  static const _channel = MethodChannel('sing-box/monitor/control');

  final _vpnCtrl = AndroidVpnController();

  // Filter mode
  bool _whitelistMode = true; // true = whitelist, false = blacklist

  // All installed apps
  List<Map<String, String>> _allApps = [];

  // Currently selected packages
  Set<String> _selected = {};

  bool _loading = true;
  String? _error;

  // Search
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!Platform.isAndroid) {
      setState(() {
        _loading = false;
        _error = 'Per-app filtering is only available on Android';
      });
      return;
    }

    setState(() => _loading = true);

    try {
      // Get current filter state
      final status = await _vpnCtrl.getVpnStatus();
      final allowed = (status['allowedPackages'] as List?)?.cast<String>() ?? [];
      final disallowed = (status['disallowedPackages'] as List?)?.cast<String>() ?? [];

      if (allowed.isNotEmpty) {
        _whitelistMode = true;
        _selected = allowed.toSet();
      } else if (disallowed.isNotEmpty) {
        _whitelistMode = false;
        _selected = disallowed.toSet();
      } else {
        _selected = {};
      }

      // Get installed apps
      final json = await _channel.invokeMethod<String>('getInstalledApps');
      if (json != null && json.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(json);
        _allApps = decoded
            .map((e) => Map<String, String>.from(e as Map))
            .toList();
      }
    } catch (e) {
      _error = 'Failed to load apps: $e';
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  List<Map<String, String>> get _filteredApps {
    final query = _searchQuery.trim().toLowerCase();
    var apps = _allApps;
    if (query.isNotEmpty) {
      apps = apps.where((a) {
        final name = (a['name'] ?? '').toLowerCase();
        final pkg = (a['packageName'] ?? '').toLowerCase();
        return name.contains(query) || pkg.contains(query);
      }).toList();
    }
    // Sort: selected first, then alphabetical
    apps.sort((a, b) {
      final aSel = _selected.contains(a['packageName']);
      final bSel = _selected.contains(b['packageName']);
      if (aSel && !bSel) return -1;
      if (!aSel && bSel) return 1;
      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });
    return apps;
  }

  Future<void> _save() async {
    try {
      if (_selected.isEmpty) {
        // Empty selection = no restriction (filter off)
        await _vpnCtrl.clearAppFilter();
      } else if (_whitelistMode) {
        await _vpnCtrl.setAllowedPackages(_selected.toList());
      } else {
        await _vpnCtrl.setDisallowedPackages(_selected.toList());
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _selected.isEmpty
                  ? 'Filter disabled — all apps go through VPN'
                  : 'App filter applied',
            ),
            backgroundColor: _selected.isEmpty ? Colors.blue : Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to apply filter: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _clearFilter() async {
    await _vpnCtrl.clearAppFilter();
    setState(() => _selected = {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App filter cleared — all apps go through VPN'),
          backgroundColor: Colors.blue,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Per-App VPN Filter'),
        actions: [
          // Always available: disable the filter (empty selection)
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Disable filter (all apps go through VPN)',
            onPressed: _clearFilter,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _save,
            icon: Icon(_selected.isEmpty ? Icons.offline_bolt : Icons.check),
            label: Text(
              _selected.isEmpty
                  ? 'Disable Filter — all apps go through VPN'
                  : 'Apply (${_selected.length} app${_selected.length == 1 ? '' : 's'})',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Mode toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: _ModeChip(
                  label: 'Whitelist (allow only)',
                  selected: _whitelistMode,
                  icon: Icons.checklist,
                  onTap: () => setState(() => _whitelistMode = true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ModeChip(
                  label: 'Blacklist (deny only)',
                  selected: !_whitelistMode,
                  icon: Icons.do_not_disturb_alt,
                  onTap: () => setState(() => _whitelistMode = false),
                ),
              ),
            ],
          ),
        ),

        // Mode explanation
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _whitelistMode
                ? 'Only selected apps will route through the VPN. Unselected apps use direct connection.'
                : 'Selected apps will bypass the VPN. Unselected apps route through the VPN normally.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ),

        const SizedBox(height: 8),

        // Search
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search apps...',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),

        const SizedBox(height: 4),

        // Count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '${_allApps.length} apps · ${_selected.length} selected',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),

        // App list
        Expanded(
          child: _filteredApps.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isNotEmpty
                        ? 'No matching apps'
                        : 'No apps found',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _filteredApps.length,
                  itemBuilder: (ctx, i) {
                    final app = _filteredApps[i];
                    final pkg = app['packageName'] ?? '';
                    final name = app['name'] ?? pkg;
                    final selected = _selected.contains(pkg);
                    return ListTile(
                      leading: Icon(
                        selected
                            ? (_whitelistMode
                                ? Icons.check_circle
                                : Icons.block)
                            : Icons.circle_outlined,
                        color: selected
                            ? (_whitelistMode ? Colors.green : Colors.orange)
                            : Colors.grey,
                      ),
                      title: Text(name,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(pkg,
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                      dense: true,
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _selected.remove(pkg);
                          } else {
                            _selected.add(pkg);
                          }
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.grey.shade900,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade700,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? null : Colors.grey,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
