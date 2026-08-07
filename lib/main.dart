// lib/main.dart
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:singbird/providers/theme_provider.dart';
import 'package:singbird/services/dir.dart';
import 'package:singbird/services/local_storage.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'pages/dashboard_page.dart';
import 'pages/monitor_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';
import 'services/log_writer.dart';
import 'services/singbox_controller.dart';

/// Global talker instance for debug logging.
final talker = TalkerFlutter.init();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init file logging
  await LogWriter().init();

  await initDataDir();

  final ls = await LocalStorage.instance();
  GetIt.I.registerSingleton(ls);

  // Pre-load persisted theme mode so the app starts with the saved theme
  // (no dark→light flash).
  try {
    final prefs = await SharedPreferences.getInstance();
    initialThemeMode = prefs.getString('theme_mode');
  } catch (_) {}

  if (Platform.isWindows) {
    AppLogger().init();
    await windowManager.ensureInitialized();
    windowManager.setPreventClose(true);
    windowManager.addListener(_AppWindowListener());

    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('SingBird');
    trayManager.addListener(_AppTrayListener());
    await _setTrayMenu();
  }

  talker.info('App started', 'Lifecycle');

  // Capture Flutter errors
  FlutterError.onError = (details) {
    talker.error(
      'FlutterError: ${details.exception}',
      'Flutter',
      details.stack,
    );
    LogWriter().error(
      'Flutter',
      '${details.exception}',
      details.exception,
      details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    talker.error('PlatformDispatcher: $error', 'Platform', stack);
    LogWriter().error('Platform', '$error', error, stack);
    return true;
  };

  runApp(const ProviderScope(child: SingBirdApp()));
}

Future<void> _setTrayMenu() async {
  await trayManager.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'show', label: 'Show'),
        MenuItem(key: 'exit', label: 'Exit'),
      ],
    ),
  );
}

class _AppWindowListener extends WindowListener {
  @override
  void onWindowClose() => windowManager.hide();
}

class _AppTrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit') {
      _exit();
    }
  }

  Future<void> _exit() async {
    await SingBoxController.instance().stop();
    await trayManager.destroy();
    await windowManager.destroy();
  }
}

class SingBirdApp extends ConsumerWidget {
  const SingBirdApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'SingBird',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      themeMode: themeMode,
      home: const MainShell(),
      navigatorObservers: [TalkerRouteObserver(talker)],
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final _pages = const [DashboardPage(), MonitorPage(), SettingsPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // Refresh controller config from store when switching back to
          // Dashboard — profiles may have been added/edited on Settings tab.
          if (i == 0) {
            SingBoxController.instance().reloadFromStore();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart),
            label: 'Monitor',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
