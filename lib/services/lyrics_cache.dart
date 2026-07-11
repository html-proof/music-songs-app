import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'lyrics_service.dart';

class LyricsCacheEntry {
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? language;
  final String? syncedLyrics;
  final String? plainLyrics;
  final String? translationSyncedLyrics;
  final String? translationPlainLyrics;
  final String providerSource; // 'lrclib' | 'saavn' | 'local' | 'none'
  final DateTime fetchedAt;
  final bool isUnavailable;

  LyricsCacheEntry({
    required this.songId,
    required this.title,
    required this.artist,
    required this.album,
    this.language,
    this.syncedLyrics,
    this.plainLyrics,
    this.translationSyncedLyrics,
    this.translationPlainLyrics,
    required this.providerSource,
    required this.fetchedAt,
    required this.isUnavailable,
  });

  Map<String, dynamic> toMap() {
    return {
      'songId': songId,
      'title': title,
      'artist': artist,
      'album': album,
      'language': language,
      'syncedLyrics': syncedLyrics,
      'plainLyrics': plainLyrics,
      'translationSyncedLyrics': translationSyncedLyrics,
      'translationPlainLyrics': translationPlainLyrics,
      'providerSource': providerSource,
      'fetchedAt': fetchedAt.toIso8601String(),
      'isUnavailable': isUnavailable,
    };
  }

  factory LyricsCacheEntry.fromMap(Map<dynamic, dynamic> map) {
    return LyricsCacheEntry(
      songId: map['songId']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      album: map['album']?.toString() ?? '',
      language: map['language']?.toString(),
      syncedLyrics: map['syncedLyrics']?.toString(),
      plainLyrics: map['plainLyrics']?.toString(),
      translationSyncedLyrics: map['translationSyncedLyrics']?.toString(),
      translationPlainLyrics: map['translationPlainLyrics']?.toString(),
      providerSource: map['providerSource']?.toString() ?? '',
      fetchedAt: map['fetchedAt'] != null
          ? DateTime.parse(map['fetchedAt'].toString())
          : DateTime.now(),
      isUnavailable: map['isUnavailable'] == true,
    );
  }

  LyricsPayload toPayload() {
    return LyricsPayload(
      plainLyrics: plainLyrics,
      syncedLyrics: syncedLyrics,
      translationPlainLyrics: translationPlainLyrics,
      translationSyncedLyrics: translationSyncedLyrics,
    );
  }
}

class LyricsCache {
  static const String _boxName = 'lyrics_cache_v5';
  static Box<dynamic>? _box;
  static final Map<String, LyricsCacheEntry> _memCache = {};

  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<dynamic>(_boxName);
    debugPrint('[LyricsCache] Initialized Hive box: $_boxName');
  }

  static String _normalizedKey(String title, String artist, String album, int duration) {
    final t = title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final a = artist.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final al = album.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    return 'norm::$t::$a::$al::$duration';
  }

  static Future<LyricsCacheEntry?> get({
    required String songId,
    required String title,
    required String artist,
    required String album,
    required int duration,
  }) async {
    final sId = songId.trim();
    final normKey = _normalizedKey(title, artist, album, duration);

    // 1. Check memory cache
    if (sId.isNotEmpty && _memCache.containsKey(sId)) {
      return _memCache[sId];
    }
    if (_memCache.containsKey(normKey)) {
      return _memCache[normKey];
    }

    // 2. Check local `.lrc` file (primary for offline downloads)
    if (sId.isNotEmpty) {
      try {
        final localLrc = await LyricsService.loadLocalLrc(sId);
        if (localLrc != null && localLrc.hasAny) {
          final entry = LyricsCacheEntry(
            songId: sId,
            title: title,
            artist: artist,
            album: album,
            syncedLyrics: localLrc.syncedLyrics,
            plainLyrics: localLrc.plainLyrics,
            translationSyncedLyrics: localLrc.translationSyncedLyrics,
            translationPlainLyrics: localLrc.translationPlainLyrics,
            providerSource: 'local',
            fetchedAt: DateTime.now(),
            isUnavailable: false,
          );
          _memCache[sId] = entry;
          _memCache[normKey] = entry;
          return entry;
        }
      } catch (e) {
        debugPrint('[LyricsCache] Failed loading local LRC: $e');
      }
    }

    // 3. Check Hive box
    if (_box != null) {
      if (sId.isNotEmpty && _box!.containsKey(sId)) {
        final data = _box!.get(sId);
        if (data is Map) {
          final entry = LyricsCacheEntry.fromMap(data);
          _memCache[sId] = entry;
          _memCache[normKey] = entry;
          return entry;
        }
      }

      if (_box!.containsKey(normKey)) {
        final data = _box!.get(normKey);
        if (data is Map) {
          final entry = LyricsCacheEntry.fromMap(data);
          _memCache[normKey] = entry;
          if (sId.isNotEmpty) {
            _memCache[sId] = entry;
          }
          return entry;
        }
      }
    }

    return null;
  }

  static Future<void> put({
    required String songId,
    required String title,
    required String artist,
    required String album,
    required int duration,
    LyricsPayload? payload,
    required String providerSource,
    bool isUnavailable = false,
  }) async {
    final sId = songId.trim();
    final normKey = _normalizedKey(title, artist, album, duration);

    final entry = LyricsCacheEntry(
      songId: sId,
      title: title,
      artist: artist,
      album: album,
      syncedLyrics: payload?.syncedLyrics,
      plainLyrics: payload?.plainLyrics,
      translationSyncedLyrics: payload?.translationSyncedLyrics,
      translationPlainLyrics: payload?.translationPlainLyrics,
      providerSource: providerSource,
      fetchedAt: DateTime.now(),
      isUnavailable: isUnavailable,
    );

    // Save in memory
    if (sId.isNotEmpty) {
      _memCache[sId] = entry;
    }
    _memCache[normKey] = entry;

    // Save in Hive
    if (_box != null) {
      final mapData = entry.toMap();
      if (sId.isNotEmpty) {
        await _box!.put(sId, mapData);
      }
      await _box!.put(normKey, mapData);
    }
  }

  static void clear() {
    _memCache.clear();
    _box?.clear();
  }
}
