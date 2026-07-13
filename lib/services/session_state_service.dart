import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionStateService {
  static const String _boxName = 'secure_session_state_v1';
  static const String _encryptionKeyPref = 'secure_session_state_key_v1';

  static const String _playbackPrefix = 'playback_state_';
  static const String _logoutPlaybackPrefix = 'logout_playback_state_';
  static const String _downloadPrefix = 'download_state_';

  static bool _initialized = false;
  static Future<void>? _initFuture;
  static Box<dynamic>? _box;

  static Future<void> init() {
    if (_initialized) return Future.value();
    _initFuture ??= _initializeInternal();
    return _initFuture!;
  }

  static Future<void> _initializeInternal() async {
    await Hive.initFlutter();

    final prefs = await SharedPreferences.getInstance();
    final key = await _loadOrCreateEncryptionKey(prefs);

    _box = await Hive.openBox<dynamic>(
      _boxName,
      encryptionCipher: HiveAesCipher(key),
    );

    _initialized = true;
  }

  static Future<Uint8List> _loadOrCreateEncryptionKey(
    SharedPreferences prefs,
  ) async {
    final existing = prefs.getString(_encryptionKeyPref);
    if (existing != null && existing.isNotEmpty) {
      try {
        final obfuscatedBytes = base64Decode(existing);
        final deobfuscatedBytes = _deobfuscateKey(obfuscatedBytes);
        if (deobfuscatedBytes.length == 32) {
          return deobfuscatedBytes;
        }
      } catch (_) {}
    }

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = Uint8List.fromList(bytes);
    final obfuscatedBytes = _obfuscateKey(key);
    await prefs.setString(_encryptionKeyPref, base64Encode(obfuscatedBytes));
    return key;
  }

  static final List<int> _xorKey = [0x5A, 0xA5, 0x1F, 0xF1, 0x3C, 0xC3, 0x4B, 0xB4];

  static Uint8List _obfuscateKey(Uint8List key) {
    final result = Uint8List(key.length);
    for (int i = 0; i < key.length; i++) {
      result[i] = key[i] ^ _xorKey[i % _xorKey.length];
    }
    return result;
  }

  static Uint8List _deobfuscateKey(Uint8List obfuscatedKey) {
    return _obfuscateKey(obfuscatedKey);
  }

  static Box<dynamic> get _secureBox {
    final box = _box;
    if (box == null) {
      throw StateError('SessionStateService.init() must be called first.');
    }
    return box;
  }

  static String _playbackKey(String uid) => '$_playbackPrefix$uid';
  static String _logoutPlaybackKey(String uid) => '$_logoutPlaybackPrefix$uid';
  static String _downloadStateKey(String uid, String songId) =>
      '$_downloadPrefix${uid}_$songId';

  static Future<void> savePlaybackState({
    required String uid,
    required Map<String, dynamic> state,
  }) async {
    await init();
    await _secureBox.put(_playbackKey(uid), jsonEncode(state));
  }

  static Future<Map<String, dynamic>?> readPlaybackState(String uid) async {
    await init();
    return _readJsonMap(_playbackKey(uid));
  }

  static Future<void> clearPlaybackState(String uid) async {
    await init();
    await _secureBox.delete(_playbackKey(uid));
  }

  static Future<void> saveLogoutPlaybackState({
    required String uid,
    required Map<String, dynamic> state,
  }) async {
    await init();
    await _secureBox.put(_logoutPlaybackKey(uid), jsonEncode(state));
  }

  static Future<Map<String, dynamic>?> readLogoutPlaybackState(
    String uid,
  ) async {
    await init();
    return _readJsonMap(_logoutPlaybackKey(uid));
  }

  static Future<void> clearLogoutPlaybackState(String uid) async {
    await init();
    await _secureBox.delete(_logoutPlaybackKey(uid));
  }

  static Future<void> saveDownloadState({
    required String uid,
    required String songId,
    required Map<String, dynamic> state,
  }) async {
    await init();
    await _secureBox.put(_downloadStateKey(uid, songId), jsonEncode(state));
  }

  static Future<Map<String, dynamic>?> readDownloadState({
    required String uid,
    required String songId,
  }) async {
    await init();
    return _readJsonMap(_downloadStateKey(uid, songId));
  }

  static Future<List<Map<String, dynamic>>> readAllDownloadStatesForUser(
    String uid,
  ) async {
    await init();
    final prefix = '$_downloadPrefix${uid}_';
    final output = <Map<String, dynamic>>[];

    for (final key in _secureBox.keys) {
      final stringKey = key.toString();
      if (!stringKey.startsWith(prefix)) continue;
      final parsed = _readJsonMap(stringKey);
      if (parsed != null) {
        output.add(parsed);
      }
    }
    return output;
  }

  static Future<void> clearDownloadState({
    required String uid,
    required String songId,
  }) async {
    await init();
    await _secureBox.delete(_downloadStateKey(uid, songId));
  }

  static Future<void> clearAllDownloadStatesForUser(String uid) async {
    await init();
    final prefix = '$_downloadPrefix${uid}_';
    final keys = _secureBox.keys
        .map((key) => key.toString())
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    if (keys.isEmpty) return;
    await _secureBox.deleteAll(keys);
  }

  static Map<String, dynamic>? _readJsonMap(String key) {
    final raw = _secureBox.get(key);
    if (raw == null) return null;

    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is! String || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }
}
