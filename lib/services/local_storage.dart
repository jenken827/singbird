import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

class LocalStorage {
  LocalStorage._();

  static Future<LocalStorage> instance() async {
    final inst = LocalStorage._();
    await inst._init();
    return inst;
  }

  static const String _boxname = 'sing-bird.db';
  static const String _settingsBoxname = 'settings';

  static const String _localEncryptionKeyKey = "localEncryptionKeyKey";
  static const String _netbirdEnableKey = "netbirdEnable";
  static const String _autoStartKey = "autoStart";

  late final Box _box;
  late final Box _settingsBox;

  String _currentThemeName = '';

  String get currentThemeName => _currentThemeName;

  Box get settingsBox => _settingsBox;

  Future<void> _init() async {
    const secureStorage = FlutterSecureStorage();
    final localEncryptionKey = await secureStorage.read(
      key: _localEncryptionKeyKey,
    );

    if (localEncryptionKey == null) {
      final key = Hive.generateSecureKey();
      await secureStorage.write(
        key: _localEncryptionKeyKey,
        value: base64UrlEncode(key),
      );
    }
    final key = await secureStorage.read(key: _localEncryptionKeyKey);

    final encryptionKeyUint8List = base64Url.decode(key!);

    await Hive.initFlutter();

    _box = await Hive.openBox(
      _boxname,
      encryptionCipher: HiveAesCipher(encryptionKeyUint8List),
    );
    _settingsBox = await Hive.openBox(_settingsBoxname);
  }

  // ThemeLanguage get themeLanguage {
  //   final tl = _settingsBox.get(_themeLanguageKey);
  //   if (tl != null) {
  //     if (_currentThemeName.isNotEmpty) {
  //       return tl;
  //     }
  //     if (tl.themeName == 'random') {
  //       _currentThemeName =
  //           FlexScheme.values[Random().nextInt(FlexScheme.values.length)].name;
  //     } else {
  //       _currentThemeName = tl.themeName;
  //     }

  //     return tl;
  //   }
  //   //没有记录配置，初始化
  //   if (_currentThemeName.isEmpty) {
  //     _currentThemeName = FlexScheme.values[0].name;
  //   }
  //   return ThemeLanguage(
  //     themeMode: ThemeMode.light,
  //     themeName: _currentThemeName,
  //     locale: 'zh',
  //   );
  // }

  // Future<void> saveThemeLanguage(ThemeLanguage tl) async {
  //   if (tl.themeName != 'random') {
  //     _currentThemeName = tl.themeName;
  //   }
  //   await _settingsBox.put(_themeLanguageKey, tl);
  // }

  bool getNetbirdEnable() {
    final bool? a = _settingsBox.get(_netbirdEnableKey);
    return a ?? false;
  }

  Future<void> saveNetbirdEnable(bool? enable) async {
    if (enable == null) {
      await _settingsBox.delete(_netbirdEnableKey);
      return;
    }
    await _settingsBox.put(_netbirdEnableKey, enable);
  }

  bool getAutoStart() {
    final bool? a = _settingsBox.get(_autoStartKey);
    return a ?? false;
  }

  Future<void> saveAutoStart(bool? enable) async {
    if (enable == null) {
      await _settingsBox.delete(_autoStartKey);
      return;
    }
    await _settingsBox.put(_autoStartKey, enable);
  }
}
