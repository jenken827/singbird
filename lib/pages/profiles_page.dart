// lib/pages/profiles_page.dart
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/profile_store.dart';
import '../services/singbox_controller.dart';
import 'profile_edit_page.dart';

class ProfilesPage extends StatefulWidget {
  final ProfileType type;
  const ProfilesPage({super.key, required this.type});

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  final _store = ProfileStore();
  final _ctrl = SingBoxController.instance();
  List<Profile> _profiles = [];
  bool _loaded = false;

  String get _title => widget.type == ProfileType.singBox
      ? 'sing-box Profiles'
      : 'Netbird Profiles';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    setState(() {
      _profiles = _store.getByType(widget.type);
      _loaded = true;
    });
  }

  Future<void> _toggleActive(String id) async {
    await _store.setActive(id);
    _syncActiveToController();
    _load();
  }

  Future<void> _delete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Profile'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.remove(id);
      _load();
    }
  }

  Future<void> _createNew() async {
    final profile = Profile(
      id: _store.newId(),
      type: widget.type,
      name: widget.type == ProfileType.singBox
          ? 'New Config'
          : 'New Netbird Config',
      config: widget.type == ProfileType.singBox ? _defaultConfig() : '',
    );

    // For netbird, pre-fill default management URL
    if (widget.type == ProfileType.netbird) {
      profile.netbirdManagementUrl = 'https://api.netbird.io:443';
      profile.netbirdDeviceName = 'sing-netbird';
    }

    await _store.add(profile);

    final updated = await Navigator.push<Profile>(
      context,
      MaterialPageRoute(
          builder: (_) => ProfileEditPage(profile: profile)),
    );
    if (!mounted) return;
    if (updated != null) {
      await _store.update(updated);
      // New profile may not be flagged active; getActive() falls back to
      // first item, so sync whatever the store resolves as active.
      _syncActiveToController();
      _load();
    }
  }

  Future<void> _edit(Profile profile) async {
    final updated = await Navigator.push<Profile>(
      context,
      MaterialPageRoute(
          builder: (_) => ProfileEditPage(profile: profile)),
    );
    if (!mounted) return;
    if (updated != null) {
      await _store.update(updated);
      if (updated.active) _syncToController(updated);
      _load();
    }
  }

  void _syncToController(Profile p) {
    if (p.type == ProfileType.singBox) {
      _ctrl.setConfig(p.config);
    } else if (p.type == ProfileType.netbird) {
      _ctrl.setNetbirdConfig(
        setupKey: p.netbirdSetupKey,
        managementUrl: p.netbirdManagementUrl,
        deviceName: p.netbirdDeviceName,
      );
    }
  }

  void _syncActiveToController() {
    final profiles = _store.getByType(widget.type);
    final active = profiles.where((p) => p.active).firstOrNull;
    if (active != null) _syncToController(active);
  }

  String _defaultConfig() => '''{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [{"type": "https", "tag": "dns-local", "server": "dns.alidns.com", "path": "/dns-query"}],
    "final": "dns-local"
  },
  "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "mtu": 1500, "auto_route": true, "strict_route": false, "stack": "mixed"}],
  "outbounds": [
    {"type": "vless", "tag": "proxy", "server": "YOUR_SERVER", "server_port": 443, "uuid": "YOUR_UUID", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": "YOUR_SNI", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": "YOUR_KEY", "short_id": "YOUR_SID"}}},
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {"auto_detect_interface": true, "final": "proxy"}
}''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
              icon: const Icon(Icons.add), onPressed: _createNew),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNew,
        child: const Icon(Icons.add),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description_outlined,
                          size: 64, color: Colors.grey.shade600),
                      const SizedBox(height: 16),
                      Text('No ${widget.type == ProfileType.singBox ? 'sing-box' : 'netbird'} profiles yet',
                          style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _createNew,
                        icon: const Icon(Icons.add),
                        label: const Text('Create Profile'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _profiles.length,
                  itemBuilder: (ctx, i) {
                    final p = _profiles[i];
                    final subtitle = p.type == ProfileType.singBox
                        ? '${p.config.length} chars  ·  ${_formatDate(p.updatedAt)}'
                        : '${p.netbirdManagementUrl ?? ""}  ·  ${_formatDate(p.updatedAt)}';
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: Icon(
                          p.active
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color:
                              p.active ? Colors.green : Colors.grey,
                        ),
                        title: Text(p.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(subtitle,
                            style: const TextStyle(fontSize: 12)),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') _edit(p);
                            if (v == 'activate') _toggleActive(p.id);
                            if (v == 'delete') _delete(p.id);
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                                value: 'edit', child: Text('Edit')),
                            if (!p.active)
                              const PopupMenuItem(
                                  value: 'activate',
                                  child: Text('Set Active')),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                        onTap: () => _edit(p),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
