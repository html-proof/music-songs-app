import 'package:hive_flutter/hive_flutter.dart';

import '../models/user_preferences.dart';

class PreferencesService {
  static const String _boxName = 'music_hub_preferences';
  static const String _userKeyPrefix = 'user_preferences_';

  static Box<dynamic>? _box;

  static Future<void> init() async {
    await Hive.initFlutter();
    _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  static Future<Box<dynamic>> _ensureBox() async {
    if (_box != null) return _box!;
    await init();
    return _box!;
  }

  static String _userKey(String uid) => '$_userKeyPrefix$uid';

  static Future<UserPreferences?> getPreferences(String uid) async {
    final box = await _ensureBox();
    final raw = box.get(_userKey(uid));
    if (raw is! Map) return null;
    return UserPreferences.fromJson(Map<String, dynamic>.from(raw));
  }

  static Future<void> savePreferences(UserPreferences preferences) async {
    final box = await _ensureBox();
    await box.put(_userKey(preferences.uid), preferences.toJson());
  }

  static Future<void> clearPreferences(String uid) async {
    final box = await _ensureBox();
    await box.delete(_userKey(uid));
  }
}
