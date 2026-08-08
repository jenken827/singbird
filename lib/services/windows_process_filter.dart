// lib/services/windows_process_filter.dart
// Windows 按应用过滤：sing-box 引擎不支持内核级过滤（Android VpnService
// 才有 addAllowedApplication），改为在启动时把 `process_name` 路由规则
// 注入生效配置的 `route.rules` 最前面。
//
// 语义对齐 Android：
// - whitelist: 仅选中进程走代理，其余 direct
// - blacklist: 选中进程 direct 绕过代理，其余走代理
//
// 子进程覆盖：选中的进程会按 PID→ParentPID 递归展开全部运行中子进程，
// 一并进规则；选中本应用(singbird.exe)时自动附带引擎(sing-box.exe)——
// 引擎由本应用拉起，规则烘焙时它尚未运行，树里找不到。
//
// 纯 JSON/集合逻辑与 I/O（PowerShell CIM、SharedPreferences）分离，
// 纯函数可直接单测。
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行中进程快照条目（PowerShell CIM 查询结果）。
class WinProcessEntry {
  final int pid;
  final int parentPid;
  final String name;
  final String path;

  const WinProcessEntry({
    required this.pid,
    required this.parentPid,
    required this.name,
    required this.path,
  });

  factory WinProcessEntry.fromJson(Map<String, dynamic> json) =>
      WinProcessEntry(
        pid: (json['ProcessId'] as num?)?.toInt() ?? 0,
        parentPid: (json['ParentProcessId'] as num?)?.toInt() ?? 0,
        name: (json['Name'] as String?) ?? '',
        path: (json['ExecutablePath'] as String?) ?? '',
      );
}

class WindowsProcessFilter {
  static const _modeKey = 'win_filter_mode'; // none|whitelist|blacklist
  static const _listKey = 'win_filter_processes';
  static const _blockedKey = 'win_filter_blocked'; // block 独立清单
  static const _manualPairKey = 'win_filter_manual_pair'; // 手动(白/黑名单)
  static const _manualBlockKey = 'win_filter_manual_block'; // 手动(block)

  // ---- 持久化 ----

  static Future<String> loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modeKey) ?? 'none';
  }

  static Future<Set<String>> loadSelected() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_listKey) ?? []).toSet();
  }

  /// 手动输入清单（按视图分流：白/黑名单 vs block）。
  static Future<List<String>> loadManualPair() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_manualPairKey) ?? [];
  }

  static Future<void> saveManualPair(List<String> entries) async {
    final prefs = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await prefs.remove(_manualPairKey);
    } else {
      await prefs.setStringList(_manualPairKey, entries);
    }
  }

  static Future<List<String>> loadManualBlock() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_manualBlockKey) ?? [];
  }

  static Future<void> saveManualBlock(List<String> entries) async {
    final prefs = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await prefs.remove(_manualBlockKey);
    } else {
      await prefs.setStringList(_manualBlockKey, entries);
    }
  }

  /// block 独立清单（最高优先级；与白/黑名单互斥于具体应用）。
  static Future<List<String>> loadBlocked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_blockedKey) ?? [];
  }

  static Future<void> saveBlocked(List<String> entries) async {
    final prefs = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await prefs.remove(_blockedKey);
    } else {
      await prefs.setStringList(_blockedKey, entries);
    }
  }

  static Future<void> save(String mode, Set<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode);
    if (names.isEmpty) {
      await prefs.remove(_listKey);
    } else {
      await prefs.setStringList(_listKey, names.toList());
    }
  }

  /// 从手动输入（完整路径或纯 exe 名）提取匹配用的 exe 名：
  /// 去首尾空白/引号，取路径末段。纯函数，可单测。
  static String nameFromEntry(String input) {
    var s = input.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1).trim();
    }
    final slash = s.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) s = s.substring(slash + 1);
    return s.trim();
  }

  /// 合并运行列表选中项与手动输入项（手动项提取 exe 名）。纯函数。
  static Set<String> mergeManualNames(
      Set<String> selected, List<String> manual) {
    final result = <String>{...selected};
    for (final m in manual) {
      final n = nameFromEntry(m);
      if (n.isNotEmpty) result.add(n);
    }
    return result;
  }

  // ---- 进程枚举（PowerShell CIM，无新原生依赖）----

  // 进程快照缓存（15s TTL）：过滤页打开/引擎启动复用快照，
  // 避免每次都在 CIM（1-2s）上干等。refresh=true 强制重取。
  static List<WinProcessEntry>? _procCache;
  static DateTime? _procCacheAt;
  static const _procCacheTtl = Duration(seconds: 15);

  static Future<List<WinProcessEntry>> listProcesses(
      {bool refresh = false}) async {
    final cached = _procCache;
    if (!refresh &&
        cached != null &&
        _procCacheAt != null &&
        DateTime.now().difference(_procCacheAt!) < _procCacheTtl) {
      return cached;
    }
    const script = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
        'Get-CimInstance Win32_Process | '
        'Select-Object ProcessId,ParentProcessId,Name,ExecutablePath | '
        'ConvertTo-Json -Compress';
    final res = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 15));
    if (res.exitCode != 0) {
      throw Exception('process enum failed(${res.exitCode}): ${res.stderr}');
    }
    final decoded = jsonDecode(res.stdout);
    final list = decoded is List ? decoded : [decoded];
    final result = list
        .map((e) => WinProcessEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    _procCache = result;
    _procCacheAt = DateTime.now();
    return result;
  }

  // ---- 纯逻辑（可单测）----

  /// 选中进程名 → 连同全部运行中子进程的 exe 名集合。
  /// 未运行的选中进程也保留（规则按名匹配，之后启动即命中）。
  static Set<String> expandNames(
    Set<String> selected,
    List<WinProcessEntry> procs,
  ) {
    final result = <String>{...selected};
    final lowerSel = selected.map((s) => s.toLowerCase()).toSet();
    // PID → 条目 / PID → 子 PID 列表
    final byPid = <int, WinProcessEntry>{for (final p in procs) p.pid: p};
    final children = <int, List<int>>{};
    for (final p in procs) {
      children.putIfAbsent(p.parentPid, () => []).add(p.pid);
    }
    // BFS：从每个选中的运行中进程出发，收集全部后代 exe 名
    final visited = <int>{};
    final queue = <int>[];
    for (final p in procs) {
      if (lowerSel.contains(p.name.toLowerCase())) {
        // 用进程的实际名（保持原大小写），否则规则与引擎匹配不上
        result.add(p.name);
        queue.add(p.pid);
      }
    }
    while (queue.isNotEmpty) {
      final pid = queue.removeLast();
      if (!visited.add(pid)) continue;
      for (final childPid in children[pid] ?? const <int>[]) {
        final child = byPid[childPid];
        if (child != null) {
          result.add(child.name);
          queue.add(childPid);
        }
      }
    }
    return result;
  }

  /// 白名单需要代理 outbound 标签：`route.default_outbound` 优先，
  /// 否则取第一个 outbound 的 tag。入参 Map 可能来自 jsonDecode 或
  /// 字面量，值类型不一，全部用防御式读取。
  static String? resolveProxyTag(Map<String, dynamic> cfg) {
    final route = cfg['route'];
    if (route is Map) {
      final def = route['default_outbound'];
      if (def is String && def.isNotEmpty) return def;
    }
    final outbounds = cfg['outbounds'];
    if (outbounds is List && outbounds.isNotEmpty) {
      final first = outbounds.first;
      if (first is Map) {
        final tag = first['tag'];
        if (tag is String && tag.isNotEmpty) return tag;
      }
    }
    return null;
  }

  /// 生成过滤规则列表（blacklist/block 各 1 条，whitelist 2 条）。
  static List<Map<String, dynamic>> buildRules({
    required String mode,
    required Set<String> names,
    String? proxyTag,
  }) {
    final procRules = names.map((n) => {'process_name': n}).toList();
    if (mode == 'blacklist') {
      return [
        {
          'type': 'logical',
          'mode': 'or',
          'rules': procRules,
          'outbound': 'direct',
        },
      ];
    }
    if (mode == 'block') {
      // 选中进程断网（引擎内置 block outbound 直接丢包）
      return [
        {
          'type': 'logical',
          'mode': 'or',
          'rules': procRules,
          'outbound': 'block',
        },
      ];
    }
    // whitelist: 选中 → 代理；未选中 → direct
    return [
      {
        'type': 'logical',
        'mode': 'or',
        'rules': procRules,
        'outbound': proxyTag,
      },
      {
        'type': 'logical',
        'mode': 'or',
        'rules': procRules,
        'invert': true,
        'outbound': 'direct',
      },
    ];
  }

  /// 把过滤规则注入配置的 `route.rules` 最前面（用户规则之后仍生效，
  /// 过滤优先）。返回新配置 JSON。
  static String injectRules(
    String configJson,
    List<Map<String, dynamic>> rules,
  ) {
    final cfg = jsonDecode(configJson) as Map<String, dynamic>;
    final route = Map<String, dynamic>.from(cfg['route'] as Map? ?? {});
    final existing = List<dynamic>.from(route['rules'] as List? ?? []);
    route['rules'] = [...rules, ...existing];
    cfg['route'] = route;
    return jsonEncode(cfg);
  }

  /// 按 exe 名（大小写不敏感）分组：过滤按进程名匹配，同名的多实例
  /// （如微信的 Weixin.exe / WeChatExApp.exe）只展示一行，附实例数。
  static List<Map<String, Object>> groupByName(
      List<WinProcessEntry> procs) {
    final byName = <String, List<WinProcessEntry>>{};
    for (final p in procs) {
      byName.putIfAbsent(p.name.toLowerCase(), () => []).add(p);
    }
    return byName.values.map((list) {
      final first = list.first;
      return {'name': first.name, 'path': first.path, 'count': list.length};
    }).toList();
  }
  // ---- 组合入口（启动时调用）----

  /// 本应用 exe 名（如 singbird.exe）；选中它时自动附带引擎名。
  static String _appExeName() {
    try {
      final p = Platform.resolvedExecutable;
      final seg = p.split(Platform.pathSeparator).last;
      return seg.isNotEmpty ? seg : '';
    } catch (_) {
      return '';
    }
  }

  /// 组合最终规则：block 规则最前（最高优先级），其后是白/黑名单规则。
  /// 纯函数，可单测。返回空表 = 无过滤。
  static List<Map<String, dynamic>> composeRules({
    required String pairMode, // none|whitelist|blacklist
    required Set<String> pairNames,
    required Set<String> blockedNames,
    String? proxyTag,
  }) {
    final rules = <Map<String, dynamic>>[];
    if (blockedNames.isNotEmpty) {
      rules.addAll(buildRules(mode: 'block', names: blockedNames));
    }
    if (pairMode != 'none' && pairNames.isNotEmpty) {
      rules.addAll(
          buildRules(mode: pairMode, names: pairNames, proxyTag: proxyTag));
    }
    return rules;
  }

  /// 读取持久化过滤设置，解析进程树，把规则注入配置。
  /// 未启用/无任何选中时返回 null（不注入）。
  /// 结构：白/黑名单互斥共享一份选中集（win_filter_processes），
  /// block 独立（win_filter_blocked）且优先级最高（规则在最前）。
  static Future<String?> injectFilter(String configJson) async {
    if (!Platform.isWindows) return null;
    final pairMode = await loadMode(); // none|whitelist|blacklist
    final selected = await loadSelected(); // 白/黑名单条目
    final manualPair = await loadManualPair(); // 手动(白/黑名单)
    final blockedRaw = await loadBlocked(); // block 条目
    final manualBlock = await loadManualBlock(); // 手动(block)
    var pairNames = mergeManualNames(selected, manualPair);
    var blockedNames = <String>{
      for (final b in blockedRaw)
        if (nameFromEntry(b).isNotEmpty) nameFromEntry(b),
    };
    blockedNames = mergeManualNames(blockedNames, manualBlock);
    // 选中本应用时附带引擎（引擎由本应用拉起，烘焙规则时尚未运行）
    final appExe = _appExeName();
    if (appExe.isNotEmpty && pairNames.contains(appExe)) {
      pairNames = {...pairNames, 'sing-box.exe'};
    }
    if (appExe.isNotEmpty && blockedNames.contains(appExe)) {
      blockedNames = {...blockedNames, 'sing-box.exe'};
    }
    if (pairNames.isEmpty && blockedNames.isEmpty) return null;
    final procs = await listProcesses();
    pairNames = expandNames(pairNames, procs);
    blockedNames = expandNames(blockedNames, procs);
    // block 最高优先级：白/黑名单中与 block 冲突的剔除（UI 已锁定，此处兜底）
    pairNames = pairNames.difference(blockedNames);
    final cfg = jsonDecode(configJson) as Map<String, dynamic>;
    final proxyTag = resolveProxyTag(cfg);
    // 白名单需要代理 outbound；解析不到时降级为仅 block 规则
    final effectivePairMode =
        (pairMode == 'whitelist' && proxyTag == null) ? 'none' : pairMode;
    final rules = composeRules(
      pairMode: effectivePairMode,
      pairNames: pairNames,
      blockedNames: blockedNames,
      proxyTag: proxyTag,
    );
    if (rules.isEmpty) return null;
    return injectRules(configJson, rules);
  }
}

// ---- 进程树构建（纯函数，可单测）----

/// 进程树节点（过滤页树形展示用）。
/// 同名子进程被折叠进父节点（如 chrome.exe 的 chrome.exe 子进程），
/// [instanceCount] 为该折叠组的总实例数；[children] 为不同名子进程。
class ProcNode {
  final WinProcessEntry entry; // 组内代表实例（首个）
  final List<ProcNode> children; // 不同名子进程（同级已按名排序）
  final int instanceCount; // 折叠后的实例总数（>=1）
  final int depth; // 树深度（顶层为 0）

  const ProcNode({
    required this.entry,
    required this.children,
    required this.instanceCount,
    required this.depth,
  });
}

// ---- 进程树构建（纯函数，可单测）----

/// 构建进程树：
/// - 同名子进程折叠进父节点（instanceCount 累加），避免 chrome.exe 式
///   同名链退化成深而无信息的 "a→a→a"；折叠组的后代仍挂在折叠节点下
/// - 孤儿进程（父不在快照 / 父为自身）挂为顶层节点
/// - 同级按 exe 名排序（大小写不敏感），UI 展示稳定
/// 返回顶层节点列表；空快照返回 []。
List<ProcNode> buildProcessTree(List<WinProcessEntry> procs) {
  if (procs.isEmpty) return [];
  final byPid = <int, WinProcessEntry>{for (final p in procs) p.pid: p};
  final children = <int, List<int>>{};
  for (final p in procs) {
    children.putIfAbsent(p.parentPid, () => []).add(p.pid);
  }
  final inSnap = byPid.keys.toSet();
  final visited = <int>{};

  ProcNode build(int pid, int depth) {
    final entry = byPid[pid]!;
    visited.add(pid);
    var instanceCount = 1;
    final kids = <ProcNode>[];
    // 折叠队列：自身 + 全部同名后代；不同名子进程递归成子节点
    final sameName = <int>[pid];
    while (sameName.isNotEmpty) {
      final cur = sameName.removeLast();
      for (final k in children[cur] ?? const <int>[]) {
        if (!visited.add(k)) continue; // 防环 / 防重复并入
        final kEntry = byPid[k]!;
        if (kEntry.name.toLowerCase() == entry.name.toLowerCase()) {
          instanceCount += 1;
          sameName.add(k);
        } else {
          kids.add(build(k, depth + 1));
        }
      }
    }
    kids.sort((a, b) =>
        a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase()));
    return ProcNode(
        entry: entry, children: kids, instanceCount: instanceCount, depth: depth);
  }

  final result = <ProcNode>[];
  for (final p in procs) {
    // 顶层：父不在快照（孤儿）或父为自身（防御）
    if (!inSnap.contains(p.parentPid) || p.parentPid == p.pid) {
      if (!visited.contains(p.pid)) result.add(build(p.pid, 0));
    }
  }
  // 防御：异常父子环等情况下补建未访问进程
  for (final p in procs) {
    if (!visited.contains(p.pid)) result.add(build(p.pid, 0));
  }
  result.sort((a, b) =>
      a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase()));
  return result;
}
