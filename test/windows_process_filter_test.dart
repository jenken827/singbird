// test/windows_process_filter_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:singbird/services/windows_process_filter.dart';

void main() {
  group('expandNames', () {
    test('BFS 收集子进程与孙进程', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'singbird.exe', path: r'C:\app\singbird.exe'),
        const WinProcessEntry(
            pid: 2, parentPid: 1, name: 'sing-box.exe', path: r'C:\app\sing-box.exe'),
        const WinProcessEntry(
            pid: 3, parentPid: 2, name: 'helper.exe', path: r'C:\app\helper.exe'),
        const WinProcessEntry(
            pid: 4, parentPid: 0, name: 'unrelated.exe', path: r'C:\x\unrelated.exe'),
      ];
      final names = WindowsProcessFilter.expandNames({'singbird.exe'}, procs);
      expect(names, containsAll(['singbird.exe', 'sing-box.exe', 'helper.exe']));
      expect(names, isNot(contains('unrelated.exe')));
    });

    test('未运行的选中进程名保留（之后启动即命中规则）', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'chrome.exe', path: r'C:\x\chrome.exe'),
      ];
      final names = WindowsProcessFilter.expandNames({'notepad.exe'}, procs);
      expect(names, contains('notepad.exe'));
      expect(names, isNot(contains('chrome.exe')));
    });

    test('大小写不敏感匹配', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'SingBird.EXE', path: r'C:\x\SingBird.EXE'),
      ];
      final names = WindowsProcessFilter.expandNames({'singbird.exe'}, procs);
      expect(names, contains('SingBird.EXE'));
    });

    test('异常父子环不死循环', () {
      final procs = [
        const WinProcessEntry(pid: 1, parentPid: 2, name: 'a.exe', path: ''),
        const WinProcessEntry(pid: 2, parentPid: 1, name: 'b.exe', path: ''),
      ];
      final names = WindowsProcessFilter.expandNames({'a.exe'}, procs);
      expect(names, containsAll(['a.exe', 'b.exe']));
    });
  });

  group('groupByName', () {
    test('同名多实例合并为一行并附实例数', () {
      final procs = [
        for (var i = 0; i < 5; i++)
          WinProcessEntry(
              pid: 100 + i,
              parentPid: 1,
              name: 'Weixin.exe',
              path: r'C:\WeChat\Weixin.exe'),
        for (var i = 0; i < 8; i++)
          WinProcessEntry(
              pid: 200 + i,
              parentPid: 100,
              name: 'WeChatExApp.exe',
              path: r'C:\WeChat\WeChatExApp.exe'),
        const WinProcessEntry(
            pid: 300, parentPid: 0, name: 'chrome.exe', path: r'C:\x\chrome.exe'),
      ];
      final groups = WindowsProcessFilter.groupByName(procs);
      expect(groups, hasLength(3));
      final weixin = groups.firstWhere((g) => g['name'] == 'Weixin.exe');
      expect(weixin['count'], 5);
      final exapp = groups.firstWhere((g) => g['name'] == 'WeChatExApp.exe');
      expect(exapp['count'], 8);
    });

    test('大小写不同视为同一进程', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'weixin.exe', path: r'C:\a\weixin.exe'),
        const WinProcessEntry(
            pid: 2, parentPid: 0, name: 'WeiXin.EXE', path: r'C:\a\WeiXin.EXE'),
      ];
      final groups = WindowsProcessFilter.groupByName(procs);
      expect(groups, hasLength(1));
      expect(groups.first['name'], 'weixin.exe'); // 保留首个实际大小写
      expect(groups.first['count'], 2);
    });
  });

  group('nameFromEntry', () {
    test('完整路径取末段', () {
      expect(WindowsProcessFilter.nameFromEntry(r'C:\Program Files\Foo\foo.exe'),
          'foo.exe');
      expect(WindowsProcessFilter.nameFromEntry('C:/Program Files/Foo/foo.exe'),
          'foo.exe');
    });

    test('纯 exe 名原样返回', () {
      expect(WindowsProcessFilter.nameFromEntry('foo.exe'), 'foo.exe');
    });

    test('去引号与首尾空白', () {
      expect(WindowsProcessFilter.nameFromEntry(' "D:\\a\\b.exe" '), 'b.exe');
      expect(WindowsProcessFilter.nameFromEntry("  'foo.exe'  "), 'foo.exe');
    });

    test('空输入返回空串', () {
      expect(WindowsProcessFilter.nameFromEntry('   '), '');
      expect(WindowsProcessFilter.nameFromEntry(''), '');
    });
  });

  group('mergeManualNames', () {
    test('手动条目与选中项合并，路径提取为 exe 名', () {
      final merged = WindowsProcessFilter.mergeManualNames(
        {'chrome.exe'},
        [r'D:\apps\foo.exe', 'bar.exe', ''],
      );
      expect(merged, containsAll(['chrome.exe', 'foo.exe', 'bar.exe']));
      expect(merged, hasLength(3));
    });

    test('重复条目去重', () {
      final merged = WindowsProcessFilter.mergeManualNames(
        {'foo.exe'},
        [r'C:\x\foo.exe', r'C:\y\foo.exe'],
      );
      expect(merged, hasLength(1));
    });
  });

  group('composeRules', () {
    test('block 规则在最前（最高优先级），其后是白名单规则', () {
      final rules = WindowsProcessFilter.composeRules(
        pairMode: 'whitelist',
        pairNames: {'chrome.exe'},
        blockedNames: {'weixin.exe'},
        proxyTag: 'proxy',
      );
      expect(rules, hasLength(3)); // 1 block + 2 whitelist
      expect(rules[0]['outbound'], 'block');
      expect((rules[0]['rules'] as List), [
        {'process_name': 'weixin.exe'},
      ]);
      expect(rules[1]['outbound'], 'proxy');
      expect(rules[2]['outbound'], 'direct');
    });

    test('仅 block（白名单空/关闭）', () {
      final rules = WindowsProcessFilter.composeRules(
        pairMode: 'none',
        pairNames: {},
        blockedNames: {'weixin.exe'},
      );
      expect(rules, hasLength(1));
      expect(rules.first['outbound'], 'block');
    });

    test('仅白名单（无 block）', () {
      final rules = WindowsProcessFilter.composeRules(
        pairMode: 'blacklist',
        pairNames: {'weixin.exe'},
        blockedNames: {},
      );
      expect(rules, hasLength(1));
      expect(rules.first['outbound'], 'direct');
    });

    test('全空 → 空规则', () {
      expect(
        WindowsProcessFilter.composeRules(
            pairMode: 'none', pairNames: {}, blockedNames: {}),
        isEmpty,
      );
    });
  });

  group('resolveProxyTag', () {
    test('default_outbound 优先', () {
      final cfg = {
        'route': {'default_outbound': 'proxy'},
        'outbounds': [
          {'tag': 'direct'},
          {'tag': 'proxy'},
        ],
      };
      expect(WindowsProcessFilter.resolveProxyTag(cfg), 'proxy');
    });

    test('回退到第一个 outbound 的 tag', () {
      final cfg = {
        'outbounds': [
          {'tag': 'my-proxy'},
        ],
      };
      expect(WindowsProcessFilter.resolveProxyTag(cfg), 'my-proxy');
    });

    test('无法解析时返回 null', () {
      expect(WindowsProcessFilter.resolveProxyTag({}), isNull);
      expect(WindowsProcessFilter.resolveProxyTag({'outbounds': []}), isNull);
      expect(WindowsProcessFilter.resolveProxyTag({'route': {}}), isNull);
    });
  });

  group('buildRules', () {
    test('blacklist → 单条 direct 规则', () {
      final rules =
          WindowsProcessFilter.buildRules(mode: 'blacklist', names: {'a.exe'});
      expect(rules, hasLength(1));
      expect(rules.first['outbound'], 'direct');
      expect(rules.first['rules'], [
        {'process_name': 'a.exe'},
      ]);
    });

    test('block → 单条 block 规则（断网）', () {
      final rules =
          WindowsProcessFilter.buildRules(mode: 'block', names: {'a.exe'});
      expect(rules, hasLength(1));
      expect(rules.first['outbound'], 'block');
      expect(rules.first['rules'], [
        {'process_name': 'a.exe'},
      ]);
    });

    test('whitelist → 代理规则 + invert direct 规则', () {
      final rules = WindowsProcessFilter.buildRules(
          mode: 'whitelist', names: {'a.exe', 'b.exe'}, proxyTag: 'proxy');
      expect(rules, hasLength(2));
      expect(rules[0]['outbound'], 'proxy');
      expect(rules[1]['invert'], isTrue);
      expect(rules[1]['outbound'], 'direct');
      expect(rules[1]['rules'], [
        {'process_name': 'a.exe'},
        {'process_name': 'b.exe'},
      ]);
    });
  });

  group('injectRules', () {
    test('配置无 route 段时自动创建', () {
      final out = WindowsProcessFilter.injectRules('{"outbounds":[]}', [
        {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {'process_name': 'a.exe'},
          ],
          'outbound': 'direct',
        },
      ]);
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      expect((cfg['route'] as Map)['rules'], hasLength(1));
    });

    test('过滤规则插到用户规则之前', () {
      final out = WindowsProcessFilter.injectRules(
        '{"route":{"rules":[{"protocol":"http"}]}}',
        [
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'process_name': 'a.exe'},
            ],
            'outbound': 'direct',
          },
        ],
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final rules = (cfg['route'] as Map)['rules'] as List;
      expect(rules, hasLength(2));
      expect((rules[0] as Map)['rules'], [
        {'process_name': 'a.exe'},
      ]);
      expect((rules[1] as Map)['protocol'], 'http');
    });
  });

  group('buildProcessTree', () {
    void collectNames(List<ProcNode> nodes, List<String> out) {
      for (final n in nodes) {
        out.add(n.entry.name);
        collectNames(n.children, out);
      }
    }

    test('父子链构建 + 孤儿挂根', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'singbird.exe', path: r'C:\app\singbird.exe'),
        const WinProcessEntry(
            pid: 2, parentPid: 1, name: 'sing-box.exe', path: r'C:\app\sing-box.exe'),
        const WinProcessEntry(
            pid: 3, parentPid: 2, name: 'helper.exe', path: r'C:\app\helper.exe'),
        const WinProcessEntry(
            pid: 9, parentPid: 999, name: 'orphan.exe', path: r'C:\x\orphan.exe'),
      ];
      final tree = buildProcessTree(procs);
      expect(tree, hasLength(2)); // singbird 树 + orphan 根
      final root = tree.firstWhere((n) => n.entry.name == 'singbird.exe');
      expect(root.depth, 0);
      expect(root.instanceCount, 1);
      expect(root.children.single.entry.name, 'sing-box.exe');
      expect(root.children.single.depth, 1);
      expect(root.children.single.children.single.entry.name, 'helper.exe');
      expect(root.children.single.children.single.depth, 2);
      final orphan = tree.firstWhere((n) => n.entry.name == 'orphan.exe');
      expect(orphan.depth, 0);
      expect(orphan.children, isEmpty);
    });

    test('同名子进程折叠计数，不同名后代仍挂其下', () {
      final procs = [
        const WinProcessEntry(
            pid: 1, parentPid: 0, name: 'chrome.exe', path: r'C:\x\chrome.exe'),
        const WinProcessEntry(
            pid: 2, parentPid: 1, name: 'chrome.exe', path: r'C:\x\chrome.exe'),
        const WinProcessEntry(
            pid: 3, parentPid: 2, name: 'chrome.exe', path: r'C:\x\chrome.exe'),
        const WinProcessEntry(
            pid: 4, parentPid: 2, name: 'crashpad_handler.exe', path: r'C:\x\crashpad.exe'),
      ];
      final tree = buildProcessTree(procs);
      expect(tree, hasLength(1));
      final chrome = tree.single;
      expect(chrome.entry.name, 'chrome.exe');
      expect(chrome.instanceCount, 3);
      expect(chrome.children.single.entry.name, 'crashpad_handler.exe');
      expect(chrome.children.single.depth, 1);
    });

    test('大小写不同的同名进程折叠', () {
      final procs = [
        const WinProcessEntry(pid: 1, parentPid: 0, name: 'Weixin.exe', path: ''),
        const WinProcessEntry(
            pid: 2, parentPid: 1, name: 'weixin.EXE', path: ''),
      ];
      final tree = buildProcessTree(procs);
      expect(tree, hasLength(1));
      expect(tree.single.instanceCount, 2);
    });

    test('父子环不死循环，全部进程入树', () {
      final procs = [
        const WinProcessEntry(pid: 1, parentPid: 2, name: 'a.exe', path: ''),
        const WinProcessEntry(pid: 2, parentPid: 1, name: 'b.exe', path: ''),
      ];
      final tree = buildProcessTree(procs);
      final names = <String>[];
      collectNames(tree, names);
      expect(names.toSet(), {'a.exe', 'b.exe'});
    });

    test('空快照 → 空树', () {
      expect(buildProcessTree([]), isEmpty);
    });
  });
}
