import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/offline_service.dart';
import 'content_filter.dart';

class AlbumFilter {
  static const String _cachePrefix = 'album_validation_v2_';
  static final Map<String, bool> _memoryCache = {};
  static final Map<String, String> _rejectionReasons = {};
  static SharedPreferences? _prefs;

  static Future<void> _initPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static Future<void> invalidateCache(String albumId) async {
    final key = albumId.trim();
    if (key.isEmpty) return;
    _memoryCache.remove(key);
    _rejectionReasons.remove(key);
    await _initPrefs();
    await _prefs?.remove('$_cachePrefix$key');
  }

  static Future<void> clearCache() async {
    _memoryCache.clear();
    _rejectionReasons.clear();
    await _initPrefs();
    final keys = _prefs?.getKeys() ?? {};
    for (final k in keys) {
      if (k.startsWith(_cachePrefix)) {
        await _prefs?.remove(k);
      }
    }
  }

  static String? getRejectionReason(String albumId) {
    return _rejectionReasons[albumId.trim()];
  }

  /// Synchronous validator checking the cache only.
  /// Used for fast, non-blocking UI rendering (stale-while-revalidate).
  static bool isValidAlbumCached(Album album) {
    final albumId = album.id.trim();
    if (albumId.isEmpty) return false;

    // Check memory cache first
    if (_memoryCache.containsKey(albumId)) {
      return _memoryCache[albumId]!;
    }

    // Check SharedPreferences if initialized
    if (_prefs != null) {
      final cached = _prefs!.getBool('$_cachePrefix$albumId');
      if (cached != null) {
        _memoryCache[albumId] = cached;
        return cached;
      }
    }

    // Default to false to avoid rendering unvalidated albums (Validate Before Rendering)
    return false;
  }

  /// Centralized validator. Asynchronously fetches tracks if not provided.
  static Future<bool> isValidAlbum(Album album, {List<Song>? tracks}) async {
    final title = album.name.trim();
    final albumId = album.id.trim();

    if (title.isEmpty) {
      _rejectionReasons[albumId] = 'Empty album title';
      return false;
    }
    if (albumId.isEmpty) {
      _rejectionReasons[albumId] = 'Empty album ID';
      return false;
    }

    if (!ContentFilter.isAllowedSongTitle(title)) {
      _rejectionReasons[albumId] = 'Blocked by ContentFilter';
      return false;
    }
    if (album.artist == null || album.artist!.trim().isEmpty) {
      _rejectionReasons[albumId] = 'Missing or empty artist info';
      return false;
    }
    if (album.songCount != null && album.songCount! <= 0) {
      _rejectionReasons[albumId] = 'Song count explicitly <= 0';
      return false;
    }

    // Check memory/persistent cache
    if (_memoryCache.containsKey(albumId)) {
      final cached = _memoryCache[albumId]!;
      if (cached) return true;
      // If it was cached as invalid, verify if we can re-evaluate or return false
      if (tracks == null) return false;
    }

    await _initPrefs();
    final persisted = _prefs?.getBool('$_cachePrefix$albumId');
    if (persisted != null) {
      _memoryCache[albumId] = persisted;
      if (persisted && tracks == null) return true;
    }

    List<Song> songList = [];
    if (tracks != null) {
      songList = tracks;
    } else {
      try {
        final data = await ApiService.getAlbums(id: albumId);
        final rawSongs = data['data']?['songs'] as List? ?? const [];
        songList = rawSongs
            .whereType<Map>()
            .map((json) => Song.fromJson(Map<String, dynamic>.from(json)))
            .toList();
      } catch (e) {
        final reason = 'Failed to load track list: $e';
        _rejectionReasons[albumId] = reason;
        debugPrint('[AlbumValidator] Rejected "$title" ($albumId): $reason');
        _memoryCache[albumId] = false;
        await _prefs?.setBool('$_cachePrefix$albumId', false);
        return false;
      }
    }

    if (songList.isEmpty) {
      final reason = 'Empty track list';
      _rejectionReasons[albumId] = reason;
      debugPrint('[AlbumValidator] Rejected "$title" ($albumId): $reason');
      _memoryCache[albumId] = false;
      await _prefs?.setBool('$_cachePrefix$albumId', false);
      return false;
    }

    int verifiedPlayableCount = 0;
    for (final song in songList) {
      // 1. Basic track metadata checks
      if (song.name.trim().isEmpty) continue;
      if ((song.artist ?? '').trim().isEmpty) continue;
      if (song.duration == null || song.duration! <= 0) continue;

      // 2. Playable source checks
      final offlinePath = OfflineService.getLocalPath(song.id);
      final downloadPath = await DownloadService.getLocalPath(song.id);
      final hasLocal = (offlinePath != null && offlinePath.isNotEmpty && File(offlinePath).existsSync()) ||
                       (downloadPath != null && downloadPath.isNotEmpty && File(downloadPath).existsSync());
      final hasRemote = (song.streamUrl ?? '').trim().isNotEmpty;

      if (hasLocal || hasRemote) {
        // 3. Region blocked or preview check
        final isRegionBlocked = (song.streamUrl ?? '').contains('blocked') || (song.streamUrl ?? '').contains('restricted');
        final isPreview = (song.duration != null && song.duration! < 45) ||
                          song.name.toLowerCase().contains('preview') ||
                          song.name.toLowerCase().contains('teaser') ||
                          song.name.toLowerCase().contains('snippet');

        if (!isRegionBlocked && !isPreview) {
          verifiedPlayableCount++;
        }
      }
    }

    final isValid = verifiedPlayableCount > 0;
    _memoryCache[albumId] = isValid;
    await _prefs?.setBool('$_cachePrefix$albumId', isValid);

    if (!isValid) {
      final reason = 'No playable streams (verified 0 out of ${songList.length})';
      _rejectionReasons[albumId] = reason;
      debugPrint('[AlbumValidator] Rejected "$title" ($albumId): $reason');
    }

    return isValid;
  }

  /// Filters a list of albums asynchronously.
  static Future<List<Album>> filterValid(List<Album> albums) async {
    final List<Album> result = [];
    final futures = albums.map((album) async {
      final valid = await isValidAlbum(album);
      return MapEntry(album, valid);
    });
    final evaluated = await Future.wait(futures);
    for (final entry in evaluated) {
      if (entry.value) {
        result.add(entry.key);
      }
    }
    return result;
  }

  /// Synchronously filters albums based on cached validation status.
  static List<Album> filterValidSync(List<Album> albums) {
    return albums.where((album) => isValidAlbumCached(album)).toList();
  }

  /// Filters and deduplicates a list of albums asynchronously.
  static Future<List<Album>> filterAndDeduplicate(List<Album> albums) async {
    final uniqueAlbums = <String, Album>{};

    for (final album in albums) {
      final valid = await isValidAlbum(album);
      if (!valid) continue;

      final titleKey = album.name.toLowerCase()
          .replaceAll(RegExp(r'\(.*?\)'), '')
          .replaceAll(RegExp(r'\[.*?\]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final artistKey = (album.artist ?? '').toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final signature = '$titleKey|$artistKey';

      final existing = uniqueAlbums[signature];
      if (existing == null) {
        uniqueAlbums[signature] = album;
      } else {
        final existingCount = existing.songCount ?? 0;
        final currentCount = album.songCount ?? 0;

        if (currentCount > existingCount) {
          uniqueAlbums[signature] = album;
        } else if (currentCount == existingCount) {
          final scoreExisting = _completenessScore(existing);
          final scoreCurrent = _completenessScore(album);
          if (scoreCurrent > scoreExisting) {
            uniqueAlbums[signature] = album;
          }
        }
      }
    }

    return uniqueAlbums.values.toList(growable: false);
  }

  /// Synchronously filters and deduplicates a list of albums.
  static List<Album> filterAndDeduplicateSync(List<Album> albums) {
    final uniqueAlbums = <String, Album>{};

    for (final album in albums) {
      if (!isValidAlbumCached(album)) continue;

      final titleKey = album.name.toLowerCase()
          .replaceAll(RegExp(r'\(.*?\)'), '')
          .replaceAll(RegExp(r'\[.*?\]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final artistKey = (album.artist ?? '').toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final signature = '$titleKey|$artistKey';

      final existing = uniqueAlbums[signature];
      if (existing == null) {
        uniqueAlbums[signature] = album;
      } else {
        final existingCount = existing.songCount ?? 0;
        final currentCount = album.songCount ?? 0;

        if (currentCount > existingCount) {
          uniqueAlbums[signature] = album;
        } else if (currentCount == existingCount) {
          final scoreExisting = _completenessScore(existing);
          final scoreCurrent = _completenessScore(album);
          if (scoreCurrent > scoreExisting) {
            uniqueAlbums[signature] = album;
          }
        }
      }
    }

    return uniqueAlbums.values.toList(growable: false);
  }

  static int _completenessScore(Album album) {
    var score = 0;
    if ((album.imageUrl ?? '').trim().isNotEmpty) score += 3;
    if ((album.artist ?? '').trim().isNotEmpty) score += 2;
    if ((album.year ?? '').trim().isNotEmpty) score += 2;
    if ((album.language ?? '').trim().isNotEmpty) score += 1;
    if (album.isOfficial) score += 2;
    return score;
  }
}
