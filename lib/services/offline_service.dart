import 'dart:async';
import 'dart:io';

import 'connectivity_manager.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import '../models/user_preferences.dart';
import 'preferences_service.dart';
import 'download_service.dart';
import '../utils/album_filter.dart';

class OfflineSongRecord {
  final Song song;
  final String audioPath;
  final String? imagePath;
  final String? imageUrl;
  final String? albumId;
  final bool fullyDownloaded;
  final String quality;
  final int cachedAt;
  final int lastPlayedAt;
  final int listenedMs;
  final int? durationMs;

  const OfflineSongRecord({
    required this.song,
    required this.audioPath,
    required this.imagePath,
    required this.imageUrl,
    required this.albumId,
    required this.fullyDownloaded,
    required this.quality,
    required this.cachedAt,
    required this.lastPlayedAt,
    required this.listenedMs,
    required this.durationMs,
  });
}

class OfflineAlbumGroup {
  final String albumId;
  final String albumName;
  final String? artist;
  final String? imagePath;
  final String? imageUrl;
  final List<OfflineSongRecord> songs;
  final int latestCachedAt;

  const OfflineAlbumGroup({
    required this.albumId,
    required this.albumName,
    required this.artist,
    required this.imagePath,
    required this.imageUrl,
    required this.songs,
    required this.latestCachedAt,
  });
}

class OfflineService {
  static const String _boxName = 'offline_songs_v1';
  static const String _settingsBox = 'offline_settings_v1';

  static const String _storageLimitKey = 'storage_limit';
  static const String _smartAutoCacheKey = 'smart_auto_cache_enabled';
  static const String _wifiUpgradeKey = 'offline_wifi_upgrade_enabled';

  static const int _minValidAudioBytes = 32 * 1024;
  static const int _minValidImageBytes = 2 * 1024;
  static const int _lowQualityKbps = 96;
  static const int _defaultStorageLimitMb = -1; // Unlimited

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 2),
      sendTimeout: const Duration(seconds: 20),
      followRedirects: true,
    ),
  );

  static bool _isInitialized = false;
  static Future<void>? _initFuture;
  static final Set<String> _activeDownloads = <String>{};
  static final Map<String, CancelToken> _downloadCancelTokens =
      <String, CancelToken>{};

  static Future<void> init() {
    if (_isInitialized) return Future.value();
    _initFuture ??= _initializeInternal();
    return _initFuture!;
  }

  static Future<void> _initializeInternal() async {
    await Hive.initFlutter();
    await Hive.openBox<dynamic>(_boxName);
    await Hive.openBox<dynamic>(_settingsBox);
    await _ensureDirectories();
    _isInitialized = true;
  }

  static Future<void> _ensureReady() async {
    if (_isInitialized) return;
    await init();
  }

  static Box<dynamic> get _box => Hive.box<dynamic>(_boxName);
  static Box<dynamic> get _settings => Hive.box<dynamic>(_settingsBox);

  static bool get smartAutoCacheEnabled {
    if (!_isInitialized || !Hive.isBoxOpen(_settingsBox)) return false;
    return _settings.get(_smartAutoCacheKey, defaultValue: false) == true;
  }

  static bool get wifiUpgradeEnabled {
    if (!_isInitialized || !Hive.isBoxOpen(_settingsBox)) return true;
    return _settings.get(_wifiUpgradeKey, defaultValue: true) == true;
  }

  static Future<void> setSmartAutoCacheEnabled(bool enabled) async {
    await _ensureReady();
    await _settings.put(_smartAutoCacheKey, enabled);
  }

  static Future<void> setWifiUpgradeEnabled(bool enabled) async {
    await _ensureReady();
    await _settings.put(_wifiUpgradeKey, enabled);
  }

  static Future<Directory> get _offlineRoot async {
    final dir = await getApplicationDocumentsDirectory();
    final offline = Directory('${dir.path}/offline');
    if (!await offline.exists()) {
      await offline.create(recursive: true);
    }
    return offline;
  }

  static Future<Directory> get _songsDir async {
    final root = await getApplicationDocumentsDirectory();
    final songs = Directory('${root.path}/music_hub_downloads');
    if (!await songs.exists()) {
      await songs.create(recursive: true);
    }
    return songs;
  }

  static Future<Directory> get _imagesDir async {
    final root = await _offlineRoot;
    final images = Directory('${root.path}/images');
    if (!await images.exists()) {
      await images.create(recursive: true);
    }
    return images;
  }

  static Future<void> _ensureDirectories() async {
    await _songsDir;
    await _imagesDir;
  }

  static Future<bool> isConnected() async {
    return ConnectivityManager.isConnected;
  }

  static Future<bool> _isOnWifiLikeConnection() async {
    return ConnectivityManager.isOnWifiOrEthernet();
  }

  static bool isCached(String songId) {
    final entry = _readEntry(songId);
    if (entry == null) return false;
    if (!_isEntryFullyDownloaded(entry)) return false;
    return _isValidMediaFileSync((entry['file_path'] ?? '').toString());
  }

  static String? getLocalPath(String songId) {
    final entry = _readEntry(songId);
    if (entry == null) return null;
    if (!_isEntryFullyDownloaded(entry)) return null;

    final path = (entry['file_path'] ?? '').toString().trim();
    if (path.isEmpty) return null;
    if (_isValidMediaFileSync(path)) return path;

    _markEntryAsCorrupted(songId, entry);
    return null;
  }

  static int? getCachedBitrateKbps(String songId) {
    final entry = _readEntry(songId);
    if (entry == null) return null;
    if (!_isEntryFullyDownloaded(entry)) return null;

    final path = (entry['file_path'] ?? '').toString().trim();
    if (!_isValidMediaFileSync(path)) {
      _markEntryAsCorrupted(songId, entry);
      return null;
    }

    final bitrate = _toInt(entry['bitrate_kbps']);
    if (bitrate == null || bitrate <= 0) return null;
    return bitrate;
  }

  static Future<void> autoCache(
    Song song, {
    Duration? listenedPosition,
    Duration? totalDuration,
    bool force = false,
  }) async {
    await _ensureReady();

    final songId = song.id.trim();
    if (songId.isEmpty || (song.streamUrl ?? '').trim().isEmpty) return;

    final entry = _readEntry(songId) ?? _baseEntry(songId);
    _mergeSongMetadata(entry, song);
    _mergeProgress(
      entry,
      listenedPositionMs: listenedPosition?.inMilliseconds,
      durationMs: totalDuration?.inMilliseconds,
    );

    final isFullyDownloaded =
        _isEntryFullyDownloaded(entry) &&
        _isValidMediaFileSync((entry['file_path'] ?? '').toString());

    if (isFullyDownloaded) {
      final currentBitrate = _toInt(entry['bitrate_kbps']) ?? 0;
      final targetBitrate = await _resolveTargetBitrate(song);

      if (targetBitrate <= currentBitrate) {
        entry['status'] = 'completed';
        entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        await _persistEntry(songId, entry);
        return;
      }

      // If we can improve quality, proceed to download/upgrade.
    }

    if (!force && smartAutoCacheEnabled && !_isEngagementEligible(entry)) {
      entry['status'] = 'waiting_for_engagement';
      entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await _persistEntry(songId, entry);
      return;
    }

    if (!await isConnected()) {
      entry['status'] = 'pending_network';
      entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await _persistEntry(songId, entry);
      return;
    }

    entry['status'] = 'queued';
    entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _persistEntry(songId, entry);
    unawaited(_downloadInBackground(songId, song));
  }

  static Future<void> recordPlaybackProgress(
    Song song,
    Duration position, {
    Duration? duration,
  }) async {
    final songId = song.id.trim();
    if (songId.isEmpty) return;

    await _ensureReady();

    final entry = _readEntry(songId) ?? _baseEntry(songId);
    _mergeSongMetadata(entry, song);
    _mergeProgress(
      entry,
      listenedPositionMs: position.inMilliseconds,
      durationMs: duration?.inMilliseconds,
    );
    entry['last_played_at'] = DateTime.now().millisecondsSinceEpoch;
    entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _persistEntry(songId, entry);

    if (smartAutoCacheEnabled && _isEngagementEligible(entry)) {
      final isFullyDownloaded =
          _isEntryFullyDownloaded(entry) &&
          _isValidMediaFileSync((entry['file_path'] ?? '').toString());

      if (!isFullyDownloaded) {
        await autoCache(song, force: true);
      } else {
        // Even if downloaded, check if quality can be improved
        final currentBitrate = _toInt(entry['bitrate_kbps']) ?? 0;
        final targetBitrate = await _resolveTargetBitrate(song);
        if (targetBitrate > currentBitrate) {
          await autoCache(song, force: true);
        }
      }
    }
  }

  static Future<List<OfflineSongRecord>> getOfflineSongRecords() async {
    await _ensureReady();

    final downloadedSongs = await DownloadService.getDownloadedSongs();
    final downloadedIds = downloadedSongs.map((s) => s.id).toSet();

    final records = <OfflineSongRecord>[];
    for (final key in _box.keys) {
      final songId = key.toString().trim();
      if (songId.isEmpty || downloadedIds.contains(songId)) continue;

      final entry = _readEntry(songId);
      if (entry == null) continue;
      if (!_isEntryFullyDownloaded(entry)) continue;

      final audioPath = (entry['file_path'] ?? '').toString().trim();
      if (!_isValidMediaFileSync(audioPath)) {
        await _markEntryAsCorruptedAsync(songId, entry);
        continue;
      }

      final imagePath = (entry['image_path'] ?? '').toString().trim();
      final validImagePath = _isValidImageFileSync(imagePath)
          ? imagePath
          : null;
      final imageUrl = (entry['image_url'] ?? '').toString().trim();

      final durationMs = _toInt(entry['duration_ms']);
      final song = Song(
        id: songId,
        name: (entry['name'] ?? '').toString().trim().isEmpty
            ? 'Unknown'
            : (entry['name'] ?? '').toString(),
        artist: (entry['artist'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['artist'] ?? '').toString(),
        album: (entry['album'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['album'] ?? '').toString(),
        albumId: (entry['album_id'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['album_id'] ?? '').toString(),
        sourceAlbumId:
            (entry['source_album_id'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['source_album_id'] ?? '').toString(),
        sourceAlbumName:
            (entry['source_album_name'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['source_album_name'] ?? '').toString(),
        sourceAlbumArtist:
            (entry['source_album_artist'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['source_album_artist'] ?? '').toString(),
        sourceAlbumImageUrl:
            (entry['source_album_image_url'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['source_album_image_url'] ?? '').toString(),
        imageUrl: imageUrl.isEmpty ? null : imageUrl,
        streamUrl: audioPath,
        language: (entry['language'] ?? '').toString().trim().isEmpty
            ? null
            : (entry['language'] ?? '').toString(),
        duration: durationMs == null ? null : (durationMs ~/ 1000),
      );

      records.add(
        OfflineSongRecord(
          song: song,
          audioPath: audioPath,
          imagePath: validImagePath,
          imageUrl: imageUrl.isEmpty ? null : imageUrl,
          albumId: (entry['album_id'] ?? '').toString().trim().isEmpty
              ? null
              : (entry['album_id'] ?? '').toString(),
          fullyDownloaded: true,
          quality: (entry['quality'] ?? 'low').toString(),
          cachedAt: _toInt(entry['cached_at']) ?? 0,
          lastPlayedAt: _toInt(entry['last_played_at']) ?? 0,
          listenedMs: _toInt(entry['listened_ms']) ?? 0,
          durationMs: durationMs,
        ),
      );
    }

    records.sort((a, b) {
      final aRecency = a.lastPlayedAt > 0 ? a.lastPlayedAt : a.cachedAt;
      final bRecency = b.lastPlayedAt > 0 ? b.lastPlayedAt : b.cachedAt;
      return bRecency.compareTo(aRecency);
    });
    return records;
  }

  static Future<List<Song>> getOfflineSongs() async {
    final records = await getOfflineSongRecords();
    return records.map((record) => record.song).toList(growable: false);
  }

  static Future<void> deleteRecord(String songId) async {
    await _ensureReady();
    final id = songId.trim();
    if (id.isEmpty) return;

    final entry = _readEntry(id);
    if (entry != null) {
      await _deleteSongFiles(id, entry);
      await _box.delete(id);
    }
  }

  static Future<void> uncacheRecord(String songId) async {
    await _ensureReady();
    await _box.delete(songId.trim());
  }

  static Future<List<OfflineAlbumGroup>> getOfflineAlbums() async {
    final records = await getOfflineSongRecords();
    final groups = <String, List<OfflineSongRecord>>{};

    for (final record in records) {
      final albumName = (record.song.album ?? '').trim();
      if (albumName.isEmpty) continue;

      final key = (record.albumId ?? '').trim().isNotEmpty
          ? (record.albumId ?? '').trim()
          : _stableAlbumKey(albumName);
      groups.putIfAbsent(key, () => <OfflineSongRecord>[]).add(record);
    }

    final output = <OfflineAlbumGroup>[];
    for (final entry in groups.entries) {
      final songs = entry.value;
      songs.sort((a, b) => b.cachedAt.compareTo(a.cachedAt));

      final first = songs.first;
      var latestCachedAt = 0;
      for (final song in songs) {
        if (song.cachedAt > latestCachedAt) {
          latestCachedAt = song.cachedAt;
        }
      }

      output.add(
        OfflineAlbumGroup(
          albumId: entry.key,
          albumName: first.song.album ?? 'Unknown Album',
          artist: first.song.artist,
          imagePath: first.imagePath,
          imageUrl: first.imageUrl,
          songs: songs,
          latestCachedAt: latestCachedAt,
        ),
      );
    }

    output.sort((a, b) => b.latestCachedAt.compareTo(a.latestCachedAt));
    return output;
  }

  static Future<void> deleteSong(String songId) async {
    await _ensureReady();
    final normalizedId = songId.trim();
    if (normalizedId.isEmpty) return;

    final entry = _readEntry(normalizedId);
    if (entry != null) {
      final albumId = (entry['albumId'] ?? entry['album_id'] ?? '').toString().trim();
      if (albumId.isNotEmpty) {
        unawaited(AlbumFilter.invalidateCache(albumId));
      }
    }

    await _deleteEntriesBySongIds(<String>{normalizedId});
  }

  static Future<int> deleteAlbum(String albumId) async {
    await _ensureReady();
    final normalizedAlbumId = albumId.trim();
    if (normalizedAlbumId.isEmpty) return 0;

    final songIds = <String>{};
    for (final key in _box.keys) {
      final songId = key.toString().trim();
      if (songId.isEmpty) continue;

      final entry = _readEntry(songId);
      if (entry == null) continue;

      final entryAlbumId = (entry['album_id'] ?? '').toString().trim();
      final entryAlbumName = (entry['album'] ?? '').toString().trim();
      final derivedAlbumId = entryAlbumName.isEmpty
          ? ''
          : _stableAlbumKey(entryAlbumName);

      if (entryAlbumId == normalizedAlbumId ||
          derivedAlbumId == normalizedAlbumId) {
        songIds.add(songId);
      }
    }

    if (songIds.isEmpty) return 0;
    await _deleteEntriesBySongIds(songIds);
    return songIds.length;
  }

  static Future<void> clearCache() async {
    await _ensureReady();

    for (final token in _downloadCancelTokens.values) {
      token.cancel('clear_cache');
    }
    _downloadCancelTokens.clear();
    _activeDownloads.clear();

    final root = await _offlineRoot;
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await _box.clear();
    await _ensureDirectories();
  }

  static Future<void> setStorageLimit(int mb) async {
    await _ensureReady();
    await _settings.put(_storageLimitKey, mb);
    await _checkStorageLimit();
  }

  static Future<void> persistAndStopForLogout() async {
    await _ensureReady();
    if (_downloadCancelTokens.isEmpty) return;

    for (final token in _downloadCancelTokens.values) {
      token.cancel('logout');
    }
  }

  static int getStorageLimit() {
    if (!_isInitialized || !Hive.isBoxOpen(_settingsBox)) {
      return _defaultStorageLimitMb;
    }
    final raw = _settings.get(
      _storageLimitKey,
      defaultValue: _defaultStorageLimitMb,
    );
    return _toInt(raw) ?? _defaultStorageLimitMb;
  }

  static Future<void> _downloadInBackground(String songId, Song song) async {
    if (!_activeDownloads.add(songId)) return;
    
    // Skip auto-caching if song is already present on disk (manual download or other).
    // This prevents storing the same song twice.
    try {
      final existingPath = await DownloadService.getGlobalLocalPath(songId);
      if (existingPath != null) {
        final entry = _readEntry(songId) ?? _baseEntry(songId);
        entry['file_path'] = existingPath;
        entry['status'] = 'completed';
        entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        await _persistEntry(songId, entry);
        final albumId = (entry['album_id'] ?? song.albumId ?? '').toString().trim();
        if (albumId.isNotEmpty) {
          unawaited(AlbumFilter.invalidateCache(albumId));
        }
        
        _activeDownloads.remove(songId);
        return;
      }
    } catch (_) {}

    final cancelToken = CancelToken();
    _downloadCancelTokens[songId] = cancelToken;

    try {
      final entry = _readEntry(songId) ?? _baseEntry(songId);
      _mergeSongMetadata(entry, song);

      final songsDir = await _songsDir;
      final imagesDir = await _imagesDir;
      final audioPath = '${songsDir.path}/$songId.mp4';
      final albumId = _deriveAlbumId(entry, song);
      final imageKey = albumId.isEmpty ? songId : albumId;
      final imagePath = '${imagesDir.path}/$imageKey.jpg';

      entry['album_id'] = albumId;
      entry['file_path'] = audioPath;
      entry['image_path'] = imagePath;

      final isFullyDownloaded =
          _isEntryFullyDownloaded(entry) && _isValidMediaFileSync(audioPath);

      if (!isFullyDownloaded) {
        entry['status'] = 'downloading';
        entry['fully_downloaded'] = false;
        entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        await _persistEntry(songId, entry);

        final sourceUrl = (song.streamUrl ?? '').trim();
        final lowQualityUrl =
            Song.optimizeStreamUrlForData(
              sourceUrl,
              maxKbps: _lowQualityKbps,
            ) ??
            sourceUrl;
        final lowBitrate = _extractBitrate(lowQualityUrl);

        final lowOk = await _downloadFile(
          lowQualityUrl,
          audioPath,
          cancelToken: cancelToken,
        );
        if (!lowOk || !_isValidMediaFileSync(audioPath)) {
          entry['status'] = cancelToken.isCancelled
              ? 'paused_by_logout'
              : 'failed';
          entry['fully_downloaded'] = false;
          entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
          await _persistEntry(songId, entry);
          return;
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        entry['status'] = 'completed';
        entry['fully_downloaded'] = true;
        entry['quality'] = 'low';
        entry['bitrate_kbps'] = lowBitrate;
        entry['cached_at'] = _toInt(entry['cached_at']) ?? now;
        entry['updated_at'] = now;
        await _persistEntry(songId, entry);
        if (albumId.isNotEmpty) {
          unawaited(AlbumFilter.invalidateCache(albumId));
        }
      }

      await _downloadImage(song.imageUrl, imagePath, cancelToken: cancelToken);
      await _checkStorageLimit();

      final currentBitrate = _toInt(entry['bitrate_kbps']) ?? 0;
      final targetBitrate = await _resolveTargetBitrate(song);

      if (!cancelToken.isCancelled && targetBitrate > currentBitrate) {
        await _upgradeToHigherQuality(
          songId,
          song,
          audioPath,
          entry,
          targetBitrate: targetBitrate,
          cancelToken: cancelToken,
        );
      }
    } on DioException catch (e) {
      final entry = _readEntry(songId) ?? _baseEntry(songId);
      entry['status'] = CancelToken.isCancel(e) ? 'paused_by_logout' : 'failed';
      entry['fully_downloaded'] = false;
      entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await _persistEntry(songId, entry);
      if (!CancelToken.isCancel(e)) {
        debugPrint('Background cache error for $songId: $e');
      }
    } catch (e) {
      final entry = _readEntry(songId) ?? _baseEntry(songId);
      entry['status'] = cancelToken.isCancelled ? 'paused_by_logout' : 'failed';
      entry['fully_downloaded'] = false;
      entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await _persistEntry(songId, entry);
      debugPrint('Background cache error for $songId: $e');
    } finally {
      _activeDownloads.remove(songId);
      _downloadCancelTokens.remove(songId);
    }
  }

  static Future<void> _upgradeToHigherQuality(
    String songId,
    Song song,
    String audioPath,
    Map<String, dynamic> entry, {
    required int targetBitrate,
    required CancelToken cancelToken,
  }) async {
    final sourceUrl = (song.streamUrl ?? '').trim();
    if (sourceUrl.isEmpty) return;

    final bestUrl =
        Song.optimizeStreamUrlForData(sourceUrl, maxKbps: targetBitrate) ??
        sourceUrl;
    if (bestUrl.isEmpty) return;

    final tempPath = '$audioPath.upgrade';
    try {
      final upgraded = await _downloadFile(
        bestUrl,
        tempPath,
        cancelToken: cancelToken,
      );
      if (!upgraded || !_isValidMediaFileSync(tempPath)) {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        return;
      }

      final currentFile = File(audioPath);
      final tempFile = File(tempPath);
      final currentSize = await currentFile.length();
      final upgradedSize = await tempFile.length();

      if (upgradedSize >= currentSize) {
        if (await currentFile.exists()) {
          await currentFile.delete();
        }
        await tempFile.rename(audioPath);
        final newBitrate = _extractBitrate(bestUrl);
        entry['quality'] = newBitrate >= AudioQuality.veryHigh.kbps
            ? 'very_high'
            : newBitrate >= AudioQuality.high.kbps
            ? 'high'
            : newBitrate >= 96
            ? 'normal'
            : 'low';
        entry['bitrate_kbps'] = newBitrate;
        entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        await _persistEntry(songId, entry);
      } else {
        await tempFile.delete();
      }
    } catch (_) {
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  static Future<bool> _downloadFile(
    String url,
    String targetPath, {
    CancelToken? cancelToken,
  }) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return false;

    final tempPath = '$targetPath.part';
    final tempFile = File(tempPath);
    final targetFile = File(targetPath);

    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      await _dio.download(
        cleanUrl,
        tempPath,
        cancelToken: cancelToken,
        deleteOnError: false,
      );
      if (!await tempFile.exists()) return false;
      if (await tempFile.length() < _minValidAudioBytes) {
        await tempFile.delete();
        return false;
      }

      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetPath);
      return true;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return false;
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return false;
    } catch (_) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return false;
    }
  }

  static Future<void> _downloadImage(
    String? url,
    String path, {
    CancelToken? cancelToken,
  }) async {
    final source = (url ?? '').trim();
    if (source.isEmpty) return;

    final file = File(path);
    if (_isValidImageFileSync(path)) return;

    try {
      await _dio.download(
        source,
        path,
        cancelToken: cancelToken,
        deleteOnError: false,
      );
      if (!_isValidImageFileSync(path) && await file.exists()) {
        await file.delete();
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (await file.exists() && !_isValidImageFileSync(path)) {
        await file.delete();
      }
    } catch (_) {
      if (await file.exists() && !_isValidImageFileSync(path)) {
        await file.delete();
      }
    }
  }

  static Future<void> _checkStorageLimit() async {
    final limitMb = getStorageLimit();
    if (limitMb < 0) return;

    await _ensureReady();

    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final key in _box.keys) {
      final id = key.toString();
      final entry = _readEntry(id);
      if (entry == null || !_isEntryFullyDownloaded(entry)) continue;
      entries.add(MapEntry(id, entry));
    }
    if (entries.isEmpty) return;

    int totalBytes = 0;
    final sizeBySongId = <String, int>{};
    for (final item in entries) {
      final entry = item.value;
      final audioPath = (entry['file_path'] ?? '').toString();
      final imagePath = (entry['image_path'] ?? '').toString();
      var size = 0;

      if (_isValidMediaFileSync(audioPath)) {
        try {
          size += File(audioPath).lengthSync();
        } catch (_) {}
      }
      if (_isValidImageFileSync(imagePath)) {
        try {
          size += File(imagePath).lengthSync();
        } catch (_) {}
      }

      sizeBySongId[item.key] = size;
      totalBytes += size;
    }

    final limitBytes = limitMb * 1024 * 1024;
    if (totalBytes <= limitBytes) return;

    entries.sort((a, b) {
      final aTs =
          _toInt(a.value['cached_at']) ?? _toInt(a.value['updated_at']) ?? 0;
      final bTs =
          _toInt(b.value['cached_at']) ?? _toInt(b.value['updated_at']) ?? 0;
      return aTs.compareTo(bTs);
    });

    for (final item in entries) {
      if (totalBytes <= limitBytes) break;

      final size = sizeBySongId[item.key] ?? 0;
      await _deleteEntryFiles(item.value);
      await _box.delete(item.key);
      totalBytes -= size;
    }
  }

  static Future<void> _deleteEntriesBySongIds(Set<String> songIds) async {
    final normalizedIds = songIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (normalizedIds.isEmpty) return;

    final entriesToDelete = <String, Map<String, dynamic>>{};
    final remainingEntries = <Map<String, dynamic>>[];

    for (final key in _box.keys) {
      final songId = key.toString().trim();
      if (songId.isEmpty) continue;

      final entry = _readEntry(songId);
      if (entry == null) continue;

      if (normalizedIds.contains(songId)) {
        entriesToDelete[songId] = entry;
      } else {
        remainingEntries.add(entry);
      }
    }

    if (entriesToDelete.isEmpty) return;

    final imagePathsToDelete = <String>{};

    for (final item in entriesToDelete.entries) {
      final songId = item.key;
      final entry = item.value;

      _downloadCancelTokens[songId]?.cancel('deleted');
      _downloadCancelTokens.remove(songId);
      _activeDownloads.remove(songId);

      await _deleteSongFiles(songId, entry);

      final imagePath = (entry['image_path'] ?? '').toString().trim();
      if (imagePath.isNotEmpty) {
        imagePathsToDelete.add(imagePath);
      }
    }

    for (final songId in entriesToDelete.keys) {
      await _box.delete(songId);
    }

    for (final imagePath in imagePathsToDelete) {
      if (_isImageReferencedByEntries(imagePath, remainingEntries)) continue;
      await _deleteFileIfExists(imagePath);
    }
  }

  static Future<void> _deleteEntryFiles(Map<String, dynamic> entry) async {
    final audioPath = (entry['file_path'] ?? '').toString().trim();
    final imagePath = (entry['image_path'] ?? '').toString().trim();

    if (audioPath.isNotEmpty) {
      final audioFile = File(audioPath);
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
    }
    if (imagePath.isNotEmpty) {
      final imageFile = File(imagePath);
      if (await imageFile.exists()) {
        await imageFile.delete();
      }
    }
  }

  static Future<void> _deleteSongFiles(
    String songId,
    Map<String, dynamic> entry,
  ) async {
    final audioPath = (entry['file_path'] ?? '').toString().trim();
    final audioCandidates = <String>{};

    if (audioPath.isNotEmpty) {
      audioCandidates.add(audioPath);
      audioCandidates.add('$audioPath.part');
      audioCandidates.add('$audioPath.upgrade');
    } else {
      final songsDir = await _songsDir;
      final fallback = '${songsDir.path}/$songId.mp4';
      audioCandidates.add(fallback);
      audioCandidates.add('$fallback.part');
      audioCandidates.add('$fallback.upgrade');
    }

    for (final path in audioCandidates) {
      await _deleteFileIfExists(path);
    }
  }

  static bool _isImageReferencedByEntries(
    String imagePath,
    Iterable<Map<String, dynamic>> entries,
  ) {
    final normalized = imagePath.trim();
    if (normalized.isEmpty) return false;

    for (final entry in entries) {
      final candidate = (entry['image_path'] ?? '').toString().trim();
      if (candidate == normalized) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _deleteFileIfExists(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;

    final file = File(normalized);
    if (!await file.exists()) return;

    try {
      await file.delete();
    } catch (_) {
      // Ignore cleanup failures; metadata removal still proceeds.
    }
  }

  static Map<String, dynamic>? _readEntry(String songId) {
    if (!_isInitialized || !Hive.isBoxOpen(_boxName)) return null;
    final raw = _box.get(songId);
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  static Future<void> _persistEntry(
    String songId,
    Map<String, dynamic> entry,
  ) async {
    await _box.put(songId, entry);
  }

  static Map<String, dynamic> _baseEntry(String songId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': songId,
      'song_id': songId,
      'status': 'pending',
      'fully_downloaded': false,
      'quality': 'low',
      'bitrate_kbps': 0,
      'listened_ms': 0,
      'duration_ms': 0,
      'cached_at': now,
      'last_played_at': 0,
      'created_at': now,
      'updated_at': now,
    };
  }

  static void _mergeSongMetadata(Map<String, dynamic> entry, Song song) {
    entry['id'] = song.id;
    entry['song_id'] = song.id;
    entry['name'] = song.name;
    entry['artist'] = song.artist;
    entry['album'] = song.album;
    entry['album_id'] = _deriveAlbumId(entry, song);
    entry['source_album_id'] = song.sourceAlbumId;
    entry['source_album_name'] = song.sourceAlbumName;
    entry['source_album_artist'] = song.sourceAlbumArtist;
    entry['source_album_image_url'] = song.sourceAlbumImageUrl;
    entry['image_url'] = song.imageUrl;
    entry['language'] = song.language;
    if (song.duration != null && song.duration! > 0) {
      entry['duration_ms'] = song.duration! * 1000;
    }
    entry['source_url'] = song.streamUrl;
  }

  static void _mergeProgress(
    Map<String, dynamic> entry, {
    int? listenedPositionMs,
    int? durationMs,
  }) {
    final currentListened = _toInt(entry['listened_ms']) ?? 0;
    final nextListened = (listenedPositionMs ?? 0).clamp(0, 1 << 31);
    if (nextListened > currentListened) {
      entry['listened_ms'] = nextListened;
    } else if (!entry.containsKey('listened_ms')) {
      entry['listened_ms'] = currentListened;
    }

    final currentDuration = _toInt(entry['duration_ms']) ?? 0;
    final nextDuration = durationMs ?? currentDuration;
    if (nextDuration > 0) {
      entry['duration_ms'] = nextDuration;
    }
  }

  static bool _isEngagementEligible(Map<String, dynamic> entry) {
    final listened = _toInt(entry['listened_ms']) ?? 0;
    final duration = _toInt(entry['duration_ms']) ?? 0;
    if (duration <= 0) return false;

    return listened / duration >= 0.70;
  }

  static bool _isEntryFullyDownloaded(Map<String, dynamic> entry) {
    if (entry['fully_downloaded'] == true) return true;
    return (entry['status'] ?? '').toString().toLowerCase() == 'completed';
  }

  static int _extractBitrate(String? url) {
    if (url == null) return 0;
    final match = RegExp(r'_(\d+)\.mp4(\?|$)').firstMatch(url);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  static Future<int> _resolveTargetBitrate(Song _) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    int preferred = Song.preferredStreamingMaxKbps;

    if (uid != null && uid.isNotEmpty) {
      final prefs = await PreferencesService.getPreferences(uid);
      if (prefs != null) {
        preferred = prefs.downloadQuality.kbps;
      }
    }

    final targetKbps = preferred.clamp(_lowQualityKbps, Song.streamingMaxKbps);
    final onWifiLike = await _isOnWifiLikeConnection();
    // Smart cache stores a low-quality copy first, then upgrades it later.
    // When Wi-Fi-only upgrades are enabled, defer that upgrade until Wi-Fi.
    if (wifiUpgradeEnabled && !onWifiLike) {
      return _lowQualityKbps;
    }
    return targetKbps.toInt();
  }

  static void _markEntryAsCorrupted(String songId, Map<String, dynamic> entry) {
    entry['status'] = 'corrupted';
    entry['fully_downloaded'] = false;
    entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_box.put(songId, entry));
  }

  static Future<void> _markEntryAsCorruptedAsync(
    String songId,
    Map<String, dynamic> entry,
  ) async {
    entry['status'] = 'corrupted';
    entry['fully_downloaded'] = false;
    entry['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _persistEntry(songId, entry);
  }

  static bool _isValidMediaFileSync(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) return false;

    try {
      final file = File(normalized);
      if (!file.existsSync()) return false;
      return file.lengthSync() >= _minValidAudioBytes;
    } catch (_) {
      return false;
    }
  }

  static bool _isValidImageFileSync(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) return false;

    try {
      final file = File(normalized);
      if (!file.existsSync()) return false;
      return file.lengthSync() >= _minValidImageBytes;
    } catch (_) {
      return false;
    }
  }

  static String _deriveAlbumId(Map<String, dynamic> entry, Song song) {
    final existing = (entry['album_id'] ?? '').toString().trim();
    if (existing.isNotEmpty) return existing;

    final sourceAlbumId = (song.sourceAlbumId ?? '').trim();
    if (sourceAlbumId.isNotEmpty) return sourceAlbumId;

    final songAlbumId = (song.albumId ?? '').trim();
    if (songAlbumId.isNotEmpty) return songAlbumId;

    final album = (song.album ?? entry['album'] ?? '').toString().trim();
    if (album.isEmpty) return '';
    return _stableAlbumKey(album);
  }

  static String _stableAlbumKey(String album) {
    final normalized = album
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    var hash = 0;
    for (final code in normalized.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return 'al_${hash.toRadixString(16)}';
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }
}
