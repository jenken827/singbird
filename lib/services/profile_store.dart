// lib/services/profile_store.dart
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:singbird/services/dir.dart';
import '../models/profile.dart';

/// 跨平台 Profile 持久化存储，支持 sing-box 和 netbird 两类配置
class ProfileStore {
  static final ProfileStore _instance = ProfileStore._();
  factory ProfileStore() => _instance;
  ProfileStore._();

  List<Profile> _profiles = [];

  List<Profile> get profiles => List.unmodifiable(_profiles);

  /// 获取指定类型的配置文件列表
  List<Profile> getByType(ProfileType type) =>
      _profiles.where((p) => p.type == type).toList();

  /// 获取指定类型的活跃配置
  Profile? getActive(ProfileType type) {
    final list = _profiles.where((p) => p.type == type).toList();
    if (list.isEmpty) return null;
    try {
      return list.firstWhere((p) => p.active);
    } catch (_) {
      return list.first;
    }
  }

  Profile? get activeSingBox => getActive(ProfileType.singBox);
  Profile? get activeNetbird => getActive(ProfileType.netbird);

  Future<void> load() async {
    try {
      final file = File('$dataDir/profiles.json');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as List;
        _profiles = json.map((e) => Profile.fromJson(e)).toList();
      }
    } catch (_) {
      _profiles = [];
    }
  }

  Future<void> _save() async {
    final file = File('$dataDir/profiles.json');
    await file.writeAsString(
      jsonEncode(_profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> add(Profile profile) async {
    _profiles.add(profile);
    await _save();
  }

  Future<void> update(Profile profile) async {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
      await _save();
    }
  }

  Future<void> remove(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    // Ensure at least one active per type if any remain
    for (final type in ProfileType.values) {
      final list = _profiles.where((p) => p.type == type).toList();
      if (list.isNotEmpty && list.every((p) => !p.active)) {
        list.first.active = true;
      }
    }
    await _save();
  }

  /// 设置指定类型的活跃配置
  Future<void> setActive(String id) async {
    for (var p in _profiles) {
      p.active = p.id == id;
    }
    await _save();
  }

  String newId() => DateTime.now().millisecondsSinceEpoch.toRadixString(36);
}
