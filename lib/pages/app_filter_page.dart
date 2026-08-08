// lib/pages/app_filter_page.dart
// Per-app VPN filter: Android 用 VpnService 内核级过滤（包名），
// Windows 用 process_name 路由规则注入（运行中进程快照）。
//
// 模式模型：
// - 白名单/黑名单：互斥的一对（radio），共享一份选中集 `_selected`
// - Block：独立开关 + 独立选中集 `_blocked`，最高优先级，可与白/黑名单并存
// - 一个应用只能存在于一份清单中（block 里的应用在白/黑名单里置灰锁定，反之亦然）
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/android_vpn_controller.dart';
import '../services/windows_process_filter.dart';

class AppFilterPage extends StatefulWidget {
  const AppFilterPage({super.key});

  @override
  State<AppFilterPage> createState() => _AppFilterPageState();
}

class _AppFilterPageState extends State<AppFilterPage> {
  static const _channel = MethodChannel('sing-box/monitor/control');

  final _vpnCtrl = AndroidVpnController();

  // 白/黑名单（互斥 radio）：whitelist | blacklist
  String _pairMode = 'whitelist';

  // true = 列表当前编辑 block 清单（block 独立，不与白/黑名单互斥）
  bool _blockView = false;

  // 白/黑名单共享选中集（Android: allowed/disallowed；Windows: process_name）
  Set<String> _selected = {};

  // block 独立选中集（最高优先级）
  Set<String> _blocked = {};

  // Windows 手动输入（按视图分流存储）
  List<String> _manualPair = [];
  List<String> _manualBlock = [];
  final _manualCtrl = TextEditingController();

  // All installed apps / running processes
  List<Map<String, String>> _allApps = [];

  // Windows 进程树（树形展示；选中仍按 exe 名，与 process_name 规则一致）
  List<ProcNode> _procTree = [];
  Set<int> _expanded = {}; // 展开的节点 PID（折叠组用代表实例 PID）

  bool _loading = true;
  bool _appsLoading = true; // 应用列表异步填充（Windows CIM / Android 枚举慢）
  String? _error;

  // Search
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // ── 视图辅助 ──

  /// 当前视图的选中集。
  Set<String> get _viewSelected => _blockView ? _blocked : _selected;

  /// 当前视图的手动清单。
  List<String> get _viewManual => _blockView ? _manualBlock : _manualPair;

  /// 当前视图之外的另一份清单（用于跨清单锁定）。
  Set<String> get _otherSelected => _blockView ? _selected : _blocked;

  bool get _hasAnySelection =>
      _selected.isNotEmpty ||
      _blocked.isNotEmpty ||
      _manualPair.isNotEmpty ||
      _manualBlock.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      setState(() {
        _loading = false;
        _error = 'Per-app filtering is only available on Android and Windows';
      });
      return;
    }

    setState(() {
      _loading = true;
      _appsLoading = true;
    });

    try {
      if (Platform.isAndroid) {
        // 选择状态（MethodChannel 快）→ 页面壳先渲染，避免整页 spinner
        final status = await _vpnCtrl.getVpnStatus();
        _blocked =
            ((status['blockedPackages'] as List?)?.cast<String>() ?? []).toSet();
        final allowed =
            (status['allowedPackages'] as List?)?.cast<String>() ?? [];
        final disallowed =
            (status['disallowedPackages'] as List?)?.cast<String>() ?? [];
        if (allowed.isNotEmpty) {
          _pairMode = 'whitelist';
          _selected = allowed.toSet();
        } else if (disallowed.isNotEmpty) {
          _pairMode = 'blacklist';
          _selected = disallowed.toSet();
        } else {
          _selected = {};
        }
        if (mounted) setState(() => _loading = false);

        // 应用列表：Kotlin 侧后台线程枚举 + 缓存，Dart 侧异步填充
        final json = await _channel.invokeMethod<String>(
            'getInstalledApps', {'refresh': refresh});
        if (json != null && json.isNotEmpty) {
          final List<dynamic> decoded = jsonDecode(json);
          _allApps = decoded
              .map((e) => Map<String, String>.from(e as Map))
              .toList();
        }
      } else {
        // Windows: prefs（快）→ 壳先渲染；进程快照（CIM 慢）异步填充
        var mode = await WindowsProcessFilter.loadMode();
        _selected = await WindowsProcessFilter.loadSelected();
        _blocked = (await WindowsProcessFilter.loadBlocked()).toSet();
        _manualPair = await WindowsProcessFilter.loadManualPair();
        _manualBlock = await WindowsProcessFilter.loadManualBlock();
        // 旧版迁移：mode=='block' 时选中项归入 block 清单
        if (mode == 'block') {
          _blocked = {..._blocked, ..._selected};
          _selected = {};
          mode = 'none';
        }
        _pairMode = (mode == 'blacklist') ? 'blacklist' : 'whitelist';
        _blockView = false;
        if (mounted) setState(() => _loading = false);

        final procs = await WindowsProcessFilter.listProcesses(refresh: refresh);
        // 进程树展示（同名子进程折叠计数）；选中仍按 exe 名
        _procTree = buildProcessTree(procs);
        _allApps = [];
        _expanded = _defaultExpanded(_procTree, _viewSelected);
      }
    } catch (e) {
      _error = 'Failed to load apps: $e';
    }

    if (mounted) {
      setState(() {
        _loading = false;
        _appsLoading = false;
      });
    }
  }

  /// Windows 手动输入（逐条添加；按当前视图分流并立即持久化合并） ──

  Future<void> _addManualEntry() async {
    final v = _manualCtrl.text.trim();
    if (v.isEmpty) return;
    final n = WindowsProcessFilter.nameFromEntry(v);
    if (n.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid exe path/name'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    // 跨清单锁定：该应用已在另一份清单中则拒绝（大小写不敏感，Windows exe 名）
    if (_otherSelected.map((s) => s.toLowerCase()).contains(n.toLowerCase()) ||
        _otherManualNames().contains(n.toLowerCase())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('App is already in the other list (Block / Whitelist-Blacklist)'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // 读-合并-写（按视图分流）
    if (_blockView) {
      final persisted = await WindowsProcessFilter.loadManualBlock();
      final merged = [...persisted];
      if (!merged.contains(v)) merged.add(v);
      await WindowsProcessFilter.saveManualBlock(merged);
      if (!mounted) return;
      setState(() => _manualBlock = merged);
    } else {
      final persisted = await WindowsProcessFilter.loadManualPair();
      final merged = [...persisted];
      if (!merged.contains(v)) merged.add(v);
      await WindowsProcessFilter.saveManualPair(merged);
      if (!mounted) return;
      setState(() => _manualPair = merged);
    }
    _manualCtrl.clear();
  }

  Set<String> _otherManualNames() {
    final other = _blockView ? _manualPair : _manualBlock;
    return other
        .map((e) => WindowsProcessFilter.nameFromEntry(e).toLowerCase())
        .toSet();
  }

  Future<void> _removeManualEntry(String entry) async {
    if (_blockView) {
      final persisted = await WindowsProcessFilter.loadManualBlock();
      final merged = persisted.where((e) => e != entry).toList();
      await WindowsProcessFilter.saveManualBlock(merged);
      if (!mounted) return;
      setState(() => _manualBlock = merged);
    } else {
      final persisted = await WindowsProcessFilter.loadManualPair();
      final merged = persisted.where((e) => e != entry).toList();
      await WindowsProcessFilter.saveManualPair(merged);
      if (!mounted) return;
      setState(() => _manualPair = merged);
    }
  }

  // ── 说明文案 / 图标 ──

  String get _modeExplanation {
    if (_blockView) {
      return 'Selected apps are blocked from the network (highest priority, '
          'applies on top of whitelist/blacklist). Others keep normal routing.';
    }
    switch (_pairMode) {
      case 'whitelist':
        return 'Only selected apps route through the proxy. Others use direct connection (bypass sing-box).';
      default:
        return 'Selected apps bypass the proxy (direct). Others route through sing-box normally.';
    }
  }

  IconData get _selectedIcon => _blockView
      ? Icons.block
      : (_pairMode == 'whitelist' ? Icons.check_circle : Icons.do_not_disturb_alt);

  Color get _selectedColor => _blockView
      ? Colors.red
      : (_pairMode == 'whitelist' ? Colors.green : Colors.orange);

  /// 某行是否属于另一份清单（跨清单锁定，置灰不可操作）。
  bool _rowLocked(String name) => _otherSelected.contains(name);

  /// 初始展开集：根层 + 含选中名的路径（让用户看到已选进程在哪）。
  Set<int> _defaultExpanded(List<ProcNode> roots, Set<String> selected) {
    final exp = <int>{};
    void walk(List<ProcNode> nodes, bool ancestorSelected) {
      for (final n in nodes) {
        final onPath = ancestorSelected || selected.contains(n.entry.name);
        if (n.children.isNotEmpty && (onPath || n.depth == 0)) {
          exp.add(n.entry.pid);
        }
        walk(n.children, onPath);
      }
    }
    walk(roots, false);
    return exp;
  }

  /// 树形可见行（深度优先展开）：
  /// - 搜索时剪掉无关子树；命中节点 / 含命中子树的节点强制展开
  /// - 同级排序：选中置顶，其余按名
  List<ProcNode> get _visibleRows {
    final query = _searchQuery.trim().toLowerCase();
    final rows = <ProcNode>[];
    bool hit(ProcNode n) =>
        query.isEmpty ||
        n.entry.name.toLowerCase().contains(query) ||
        n.entry.path.toLowerCase().contains(query);
    bool subHit(ProcNode n) => hit(n) || n.children.any(subHit);
    void walk(List<ProcNode> nodes) {
      final sorted = [...nodes]..sort((a, b) {
          final aSel = _viewSelected.contains(a.entry.name);
          final bSel = _viewSelected.contains(b.entry.name);
          if (aSel != bSel) return aSel ? -1 : 1;
          return a.entry.name
              .toLowerCase()
              .compareTo(b.entry.name.toLowerCase());
        });
      for (final n in sorted) {
        if (query.isNotEmpty && !subHit(n)) continue; // 搜索剪枝
        rows.add(n);
        final searching = query.isNotEmpty;
        final expanded =
            searching ? subHit(n) : _expanded.contains(n.entry.pid);
        if (expanded && n.children.isNotEmpty) walk(n.children);
      }
    }
    walk(_procTree);
    return rows;
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
      final aSel = _viewSelected.contains(a['packageName']);
      final bSel = _viewSelected.contains(b['packageName']);
      if (aSel && !bSel) return -1;
      if (!aSel && bSel) return 1;
      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });
    return apps;
  }

  // ── 保存 / 清除 ──

  Future<void> _save() async {
    try {
      if (Platform.isWindows) {
        // 白/黑名单：mode + 选中集；block：独立清单；手动：按视图分流
        final hasPair = _selected.isNotEmpty || _manualPair.isNotEmpty;
        final mode = hasPair ? _pairMode : 'none';
        await WindowsProcessFilter.save(mode, _selected);
        await WindowsProcessFilter.saveBlocked(_blocked.toList());
        await WindowsProcessFilter.saveManualPair(_manualPair);
        await WindowsProcessFilter.saveManualBlock(_manualBlock);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _hasAnySelection
                    ? 'Filter saved — takes effect on next engine start'
                    : 'Filter disabled — all apps go through proxy',
              ),
              backgroundColor: _hasAnySelection ? Colors.green : Colors.blue,
            ),
          );
        }
        return;
      }

      // Android
      if (_selected.isEmpty && _blocked.isEmpty) {
        // Empty selection = no restriction (filter off); clears all lists
        await _vpnCtrl.clearAppFilter();
      } else {
        // block 的应用必须在内核过滤中放行（进 VPN）才能被引擎规则阻断
        if (_pairMode == 'whitelist') {
          await _vpnCtrl
              .setAllowedPackages({..._selected, ..._blocked}.toList());
        } else {
          await _vpnCtrl.setDisallowedPackages(_selected.toList());
        }
        if (_blocked.isNotEmpty) {
          await _vpnCtrl.setBlockedPackages(_blocked.toList());
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _hasAnySelection ? Colors.green : Colors.blue,
            content: Text(
              _hasAnySelection
                  ? 'App filter applied'
                  : 'Filter disabled — all apps go through VPN',
            ),
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
    if (Platform.isWindows) {
      await WindowsProcessFilter.save('none', {});
      await WindowsProcessFilter.saveBlocked([]);
      await WindowsProcessFilter.saveManualPair([]);
      await WindowsProcessFilter.saveManualBlock([]);
      _blocked = {};
      _manualPair = [];
      _manualBlock = [];
    } else {
      await _vpnCtrl.clearAppFilter(); // clears allow/disallow/block
      _blocked = {};
    }
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

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Per-App VPN Filter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Disable filter (all apps go through VPN)',
            onPressed: _clearFilter,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(refresh: true),
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _save,
            icon: Icon(_hasAnySelection ? Icons.check : Icons.offline_bolt),
            label: Text(
              _hasAnySelection
                  ? 'Apply (${_selected.length + _blocked.length} app${_selected.length + _blocked.length == 1 ? '' : 's'})'
                  : 'Disable Filter — all apps go through VPN',
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
        // Mode chips: 白/黑名单 radio + block 独立（chip 永远可用）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: _ModeChip(
                  label: 'Whitelist',
                  selected: !_blockView && _pairMode == 'whitelist',
                  icon: Icons.checklist,
                  onTap: () => setState(() {
                    _blockView = false;
                    _pairMode = 'whitelist';
                    _expanded = _defaultExpanded(_procTree, _viewSelected);
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ModeChip(
                  label: 'Blacklist',
                  selected: !_blockView && _pairMode == 'blacklist',
                  icon: Icons.do_not_disturb_alt,
                  onTap: () => setState(() {
                    _blockView = false;
                    _pairMode = 'blacklist';
                    _expanded = _defaultExpanded(_procTree, _viewSelected);
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ModeChip(
                  label: 'Block',
                  selected: _blockView,
                  icon: Icons.block,
                  onTap: () => setState(() {
                    _blockView = true;
                    _expanded = _defaultExpanded(_procTree, _viewSelected);
                  }),
                ),
              ),
            ],
          ),
        ),

        // Mode explanation
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _modeExplanation,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ),

        // Windows: 手动输入未启动的应用（逐条添加；按当前视图分流）
        if (Platform.isWindows) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualCtrl,
                    decoration: InputDecoration(
                      hintText: _blockView
                          ? 'Add exe to block (e.g. D:\\apps\\foo.exe)'
                          : 'Add exe path/name (e.g. D:\\apps\\foo.exe)',
                      prefixIcon: const Icon(Icons.add, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onSubmitted: (_) => _addManualEntry(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle),
                  tooltip: 'Add to current list',
                  onPressed: _addManualEntry,
                ),
              ],
            ),
          ),
          if (_viewManual.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in _viewManual)
                    InputChip(
                      label: Text(e, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => _removeManualEntry(e),
                    ),
                ],
              ),
            ),
        ],

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
            Platform.isWindows
                ? '${_visibleRows.length} shown · '
                    '${_selected.length} $_pairMode · '
                    '${_blocked.length} blocked'
                    '${_viewManual.isNotEmpty ? ' · ${_viewManual.length} manual' : ''}'
                : '${_allApps.length} apps · '
                    '${_selected.length} $_pairMode · '
                    '${_blocked.length} blocked',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),

        // App list
        Expanded(
          child: _appsLoading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              : Platform.isWindows
              ? _buildWindowsTree()
              : _filteredApps.isEmpty
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
                    // 选中/锁定一律按 packageName 判断：
                    // Android 上 name=label≠包名，用 name 会导致选中不置顶、
                    // 保存时把 label 当成包名写进 VpnService（过滤失效）。
                    final locked = _rowLocked(pkg);
                    final selected = _viewSelected.contains(pkg);
                    return ListTile(
                      leading: Icon(
                        locked
                            ? Icons.lock_outline
                            : (selected ? _selectedIcon : Icons.circle_outlined),
                        color: locked
                            ? Colors.grey.shade600
                            : (selected ? _selectedColor : Colors.grey),
                      ),
                      title: Text(name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : null,
                              color: locked ? Colors.grey.shade600 : null)),
                      subtitle: Text(
                          pkg,
                          style: TextStyle(
                              fontSize: 11,
                              color: locked
                                  ? Colors.grey.shade700
                                  : Colors.grey.shade600)),
                      enabled: !locked,
                      dense: true,
                      onTap: () {
                        if (locked) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'App is in the other list (Block / Whitelist-Blacklist)'),
                              backgroundColor: Colors.orange,
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }
                        setState(() {
                          if (selected) {
                            _viewSelected.remove(pkg);
                          } else {
                            _viewSelected.add(pkg);
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

  // ── Windows 进程树列表 ──

  Widget _buildWindowsTree() {
    final rows = _visibleRows;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isNotEmpty ? 'No matching apps' : 'No apps found',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (ctx, i) => _buildProcTile(rows[i]),
    );
  }

  /// 进程树行：缩进 + 展开箭头 + 状态图标 + 名称（折叠组附实例数）+ 路径。
  /// 勾选单位仍是 exe 名（与 process_name 规则一致），同名节点联动。
  Widget _buildProcTile(ProcNode node) {
    final entry = node.entry;
    final name = entry.name;
    final selected = _viewSelected.contains(name);
    final locked = _rowLocked(name);
    final hasChildren = node.children.isNotEmpty;
    final expanded = _expanded.contains(entry.pid);
    return ListTile(
      leading: SizedBox(
        width: 20 + node.depth * 18.0,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: node.depth * 18.0),
            if (hasChildren)
              InkWell(
                onTap: () => setState(() {
                  if (!_expanded.add(entry.pid)) _expanded.remove(entry.pid);
                }),
                child: Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: Colors.grey.shade500,
                ),
              )
            else
              const SizedBox(width: 18),
            Icon(
              locked
                  ? Icons.lock_outline
                  : (selected ? _selectedIcon : Icons.circle_outlined),
              size: 18,
              color: locked
                  ? Colors.grey.shade600
                  : (selected ? _selectedColor : Colors.grey),
            ),
          ],
        ),
      ),
      title: Text(
        node.instanceCount > 1 ? '$name ($node.instanceCount)' : name,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : null,
          color: locked ? Colors.grey.shade600 : null,
        ),
      ),
      subtitle: Text(
        entry.path.isEmpty ? 'PID ${entry.pid}' : entry.path,
        style: TextStyle(
          fontSize: 11,
          color: locked ? Colors.grey.shade700 : Colors.grey.shade600,
        ),
      ),
      enabled: !locked,
      dense: true,
      onTap: () {
        if (locked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'App is in the other list (Block / Whitelist-Blacklist)'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }
        setState(() {
          if (selected) {
            _viewSelected.remove(name);
          } else {
            _viewSelected.add(name);
          }
        });
      },
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
