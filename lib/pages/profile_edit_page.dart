// lib/pages/profile_edit_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/profile.dart';

class ProfileEditPage extends StatefulWidget {
  final Profile profile;
  const ProfileEditPage({super.key, required this.profile});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late TextEditingController _nameCtrl;
  late TextEditingController _configCtrl;
  late TextEditingController _nbSetupKeyCtrl;
  late TextEditingController _nbMgmtUrlCtrl;
  late TextEditingController _nbDeviceNameCtrl;
  bool _modified = false;
  String? _jsonError;
  bool _nbKeyVisible = false;

  bool get _isSingBox => widget.profile.type == ProfileType.singBox;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.profile.name);
    _configCtrl = TextEditingController(
        text: _isSingBox ? _formatJson(widget.profile.config) : '');
    _nbSetupKeyCtrl = TextEditingController(
        text: widget.profile.netbirdSetupKey ?? '');
    _nbMgmtUrlCtrl = TextEditingController(
        text: widget.profile.netbirdManagementUrl ??
            'https://api.netbird.io:443');
    _nbDeviceNameCtrl = TextEditingController(
        text: widget.profile.netbirdDeviceName ?? 'sing-netbird');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _configCtrl.dispose();
    _nbSetupKeyCtrl.dispose();
    _nbMgmtUrlCtrl.dispose();
    _nbDeviceNameCtrl.dispose();
    super.dispose();
  }

  String _formatJson(String raw) {
    try {
      final obj = jsonDecode(raw);
      return _prettyPrint(obj);
    } catch (_) {
      return raw;
    }
  }

  String _prettyPrint(dynamic obj) {
    const indent = '  ';
    final buf = StringBuffer();
    _writeJson(obj, buf, 0, indent);
    return buf.toString();
  }

  void _writeJson(dynamic obj, StringBuffer buf, int depth, String indent) {
    if (obj is Map) {
      if (obj.isEmpty) { buf.write('{}'); return; }
      buf.writeln('{');
      final keys = obj.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        buf.write(indent * (depth + 1));
        buf.write('"${keys[i]}": ');
        _writeJson(obj[keys[i]], buf, depth + 1, indent);
        if (i < keys.length - 1) buf.write(',');
        buf.writeln();
      }
      buf.write(indent * depth);
      buf.write('}');
    } else if (obj is List) {
      if (obj.isEmpty) { buf.write('[]'); return; }
      buf.writeln('[');
      for (var i = 0; i < obj.length; i++) {
        buf.write(indent * (depth + 2));
        _writeJson(obj[i], buf, depth + 2, indent);
        if (i < obj.length - 1) buf.write(',');
        buf.writeln();
      }
      buf.write(indent * (depth + 1));
      buf.write(']');
    } else if (obj is String) {
      buf.write('"$obj"');
    } else if (obj is num || obj is bool) {
      buf.write('$obj');
    } else {
      buf.write('null');
    }
  }

  void _clear() {
    setState(() {
      _configCtrl.clear();
      _jsonError = null;
      _modified = true;
    });
  }

  void _validate() {
    setState(() {
      try {
        final decoded = jsonDecode(_configCtrl.text);
        _configCtrl.text = _prettyPrint(decoded);
        _jsonError = null;
        _modified = true;
      } catch (e) {
        _jsonError = e.toString();
      }
    });
  }

  void _save() {
    if (_isSingBox && _jsonError != null) return;
    final updated = widget.profile.copyWith(
      name: _nameCtrl.text.trim().isEmpty ? 'Unnamed' : _nameCtrl.text.trim(),
      config: _isSingBox ? _configCtrl.text : '',
      netbirdSetupKey: _nbSetupKeyCtrl.text.trim().isEmpty
          ? null : _nbSetupKeyCtrl.text.trim(),
      netbirdManagementUrl: _nbMgmtUrlCtrl.text.trim().isEmpty
          ? null : _nbMgmtUrlCtrl.text.trim(),
      netbirdDeviceName: _nbDeviceNameCtrl.text.trim().isEmpty
          ? null : _nbDeviceNameCtrl.text.trim(),
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSingBox ? 'Edit sing-box Config' : 'Edit Netbird Config'),
        actions: [
          TextButton(
            onPressed: _modified ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Profile Name ──
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _modified = true),
              ),
            ),

            if (_isSingBox) ...[
              // ── sing-box JSON editor ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text('Configuration (JSON)',
                        style: TextStyle(fontWeight: FontWeight.bold,
                            fontSize: 13, color: Colors.grey.shade400)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _clear,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Clear'),
                    ),
                    TextButton.icon(
                      onPressed: _validate,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Format & Validate'),
                    ),
                  ],
                ),
              ),
              if (_jsonError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Colors.red.shade900,
                    child: Text(_jsonError!,
                        style: const TextStyle(fontSize: 12,
                            color: Colors.white)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  height: 280,
                  child: TextField(
                    controller: _configCtrl,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, height: 1.4),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(10),
                    ),
                    onChanged: (_) => setState(() => _modified = true),
                  ),
                ),
              ),
            ] else ...[
              // ── Netbird config fields ──
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('Netbird VPN Settings',
                    style: TextStyle(fontWeight: FontWeight.bold,
                        fontSize: 14, color: Colors.grey.shade300)),
              ),
              _nbField('Setup Key', _nbSetupKeyCtrl, obscure: true,
                  toggleable: true),
              _nbField('Management URL', _nbMgmtUrlCtrl),
              _nbField('Device Name', _nbDeviceNameCtrl),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _nbField(String label, TextEditingController ctrl,
      {bool obscure = false, bool toggleable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: ctrl,
        obscureText: obscure && !_nbKeyVisible,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: toggleable
              ? IconButton(
                  icon: Icon(
                    _nbKeyVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  tooltip: _nbKeyVisible ? 'Hide' : 'Show',
                  onPressed: () =>
                      setState(() => _nbKeyVisible = !_nbKeyVisible),
                )
              : null,
        ),
        onChanged: (_) => setState(() => _modified = true),
      ),
    );
  }
}
