import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluttertoast/fluttertoast.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import '../models/user_preferences.dart';
import 'preferences_service.dart';
import 'session_state_service.dart';
import 'offline_service.dart';
import 'player_service.dart';
import 'lyrics_service.dart';
import 'artwork_service.dart';
import 'playlist_service.dart';

class PlaylistDownloadProgress {
  final String playlistId;
  final String playlistName;
  final int totalSongs;
  final int completedSongs; // downloaded + recovered + alreadyDownloaded + failed
  final int downloadedCount;
  final int recoveredCount;
  final int alreadyDownloadedCount;
  final int failedCount;
  final bool isCompleted;
  final bool isCancelled;
  final List<Song> failedSongs;

  PlaylistDownloadProgress({
    required this.playlistId,
    required this.playlistName,
    required this.totalSongs,
    required this.completedSongs,
    required this.downloadedCount,
    required this.recoveredCount,
    required this.alreadyDownloadedCount,
    required this.failedCount,
    this.isCompleted = false,
    this.isCancelled = false,
    required this.failedSongs,
  });

  double get progress => totalSongs > 0 ? completedSongs / totalSongs : 0.0;
}

class PlaylistDownloadSession {
  final String playlistId;
  final String playlistName;
  final List<Song> songs;
  final String uid;
  final CancelToken cancelToken = CancelToken();

  int totalSongs = 0;
  int downloadedCount = 0;
  int recoveredCount = 0;
  int alreadyDownloadedCount = 0;
  int failedCount = 0;
  final List<Song> failedSongs = [];

  PlaylistDownloadSession({
    required this.playlistId,
    required this.playlistName,
    required this.songs,
    required this.uid,
  });
}

class DownloadService {
  static PlaylistDownloadSession? _activePlaylistSession;
  static PlaylistDownloadSession? get activePlaylistSession => _activePlaylistSession;

  static final StreamController<PlaylistDownloadProgress> _playlistProgressController =
      StreamController<PlaylistDownloadProgress>.broadcast();
  static Stream<PlaylistDownloadProgress> get playlistProgressStream =>
      _playlistProgressController.stream;

  static final StreamController<String> _downloadCompletedController =
      StreamController<String>.broadcast();
  static Stream<String> get downloadCompletedStream =>
      _downloadCompletedController.stream;

  static Future<void> startPlaylistDownload(
    String playlistId,
    String playlistName,
    List<Song> songs,
  ) async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return;

    if (_activePlaylistSession != null) {
      if (_activePlaylistSession!.playlistId == playlistId) {
        return;
      }
      _activePlaylistSession!.cancelToken.cancel('new_session_started');
    }

    final session = PlaylistDownloadSession(
      playlistId: playlistId,
      playlistName: playlistName,
      songs: List<Song>.from(songs),
      uid: uid,
    );
    _activePlaylistSession = session;
    session.totalSongs = songs.length;

    // Try to find the playlist cover and download it, fallback to album cover
    try {
      final playlists = await PlaylistService.getPlaylists();
      final matchingPlaylist = playlists.firstWhere((p) => p.id == playlistId);
      final coverUrl = matchingPlaylist.coverImageUrl?.trim();
      if (coverUrl != null && coverUrl.isNotEmpty) {
        final dir = await _downloadsDir;
        final playlistDir = Directory('${dir.path}/playlists');
        if (!await playlistDir.exists()) await playlistDir.create(recursive: true);
        final coverFile = File('${playlistDir.path}/$playlistId.jpg');
        await _dio.download(
          coverUrl,
          coverFile.path,
          cancelToken: session.cancelToken,
        );
        debugPrint('[DownloadService] Downloaded playlist cover for $playlistId');
      }
    } catch (_) {
      try {
        if (songs.isNotEmpty) {
          final firstSong = songs.first;
          final albumId = firstSong.albumId;
          if (albumId != null && albumId.isNotEmpty) {
            final albumCoverUrl = ArtworkService.resolveArtworkUrl(firstSong);
            if (albumCoverUrl.isNotEmpty) {
              final dir = await _downloadsDir;
              final albumDir = Directory('${dir.path}/albums');
              if (!await albumDir.exists()) await albumDir.create(recursive: true);
              final coverFile = File('${albumDir.path}/$albumId.jpg');
              await _dio.download(
                albumCoverUrl,
                coverFile.path,
                cancelToken: session.cancelToken,
              );
              debugPrint('[DownloadService] Downloaded album cover for $albumId');
            }
          }
        }
      } catch (err) {
        debugPrint('[DownloadService] Failed to download album cover fallback: $err');
      }
    }

    _notifyPlaylistProgress(session);

    final int workerCount = 3.clamp(1, 5);
    int nextSongIndex = 0;
    final List<Future<void>> workers = [];

    Future<void> runWorker() async {
      while (true) {
        if (session.cancelToken.isCancelled) break;

        Song? song;
        if (nextSongIndex < session.songs.length) {
          song = session.songs[nextSongIndex];
          nextSongIndex++;
        }

        if (song == null) break;

        await _downloadPlaylistSong(session, song);
      }
    }

    for (int i = 0; i < workerCount; i++) {
      workers.add(runWorker());
    }

    await Future.wait(workers);

    if (session.cancelToken.isCancelled) {
      _playlistProgressController.add(PlaylistDownloadProgress(
        playlistId: session.playlistId,
        playlistName: session.playlistName,
        totalSongs: session.totalSongs,
        completedSongs: session.downloadedCount +
            session.recoveredCount +
            session.alreadyDownloadedCount +
            session.failedCount,
        downloadedCount: session.downloadedCount,
        recoveredCount: session.recoveredCount,
        alreadyDownloadedCount: session.alreadyDownloadedCount,
        failedCount: session.failedCount,
        isCancelled: true,
        failedSongs: session.failedSongs,
      ));
    } else {
      _playlistProgressController.add(PlaylistDownloadProgress(
        playlistId: session.playlistId,
        playlistName: session.playlistName,
        totalSongs: session.totalSongs,
        completedSongs: session.totalSongs,
        downloadedCount: session.downloadedCount,
        recoveredCount: session.recoveredCount,
        alreadyDownloadedCount: session.alreadyDownloadedCount,
        failedCount: session.failedCount,
        isCompleted: true,
        failedSongs: session.failedSongs,
      ));
    }

    if (_activePlaylistSession == session) {
      _activePlaylistSession = null;
    }
  }

  static void cancelPlaylistDownload() {
    _activePlaylistSession?.cancelToken.cancel('user_cancelled');
    _activePlaylistSession = null;
  }

  static void _notifyPlaylistProgress(PlaylistDownloadSession session) {
    _playlistProgressController.add(PlaylistDownloadProgress(
      playlistId: session.playlistId,
      playlistName: session.playlistName,
      totalSongs: session.totalSongs,
      completedSongs: session.downloadedCount +
          session.recoveredCount +
          session.alreadyDownloadedCount +
          session.failedCount,
      downloadedCount: session.downloadedCount,
      recoveredCount: session.recoveredCount,
      alreadyDownloadedCount: session.alreadyDownloadedCount,
      failedCount: session.failedCount,
      failedSongs: session.failedSongs,
    ));
  }

  static Future<bool> _shouldPauseForWifiSettings(String uid) async {
    final prefs = await PreferencesService.getPreferences(uid);
    final wifiOnly = prefs?.downloadWifiOnly ?? false;
    if (!wifiOnly) return false;

    final connectivityResult = await Connectivity().checkConnectivity();
    final onMobile = connectivityResult.contains(ConnectivityResult.mobile);
    final onWifi = connectivityResult.contains(ConnectivityResult.wifi) ||
        connectivityResult.contains(ConnectivityResult.ethernet) ||
        connectivityResult.contains(ConnectivityResult.vpn);

    return onMobile && !onWifi;
  }

  static Future<bool> _isNetworkConnected() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.any((result) => result != ConnectivityResult.none);
  }

  static Future<void> _downloadPlaylistSong(
    PlaylistDownloadSession session,
    Song song,
  ) async {
    final songId = song.id.trim();

    while (await _shouldPauseForWifiSettings(session.uid)) {
      if (session.cancelToken.isCancelled) return;
      await Future.delayed(const Duration(seconds: 1));
    }

    final isDownloaded = await DownloadService.isDownloaded(songId);
    if (isDownloaded) {
      session.alreadyDownloadedCount++;
      _notifyPlaylistProgress(session);
      return;
    }

    if (_downloading[songId] == true) {
      _cancelTokens[songId]?.cancel('duplicate_playlist_download');
    }

    bool success = await _downloadSongInternal(
      song,
      uid: session.uid,
      externalCancelToken: session.cancelToken,
    );

    if (success) {
      session.downloadedCount++;
      _notifyPlaylistProgress(session);
      return;
    }

    if (session.cancelToken.isCancelled) return;

    final hasNetwork = await _isNetworkConnected();
    if (hasNetwork) {
      debugPrint('Original URL failed for playlist song ${song.name}. Attempting search recovery...');
      final fallbackSong = await PlayerService.searchFallbackForSong(song);

      if (fallbackSong != null && fallbackSong.streamUrl != null) {
        debugPrint('Found fallback search match for ${song.name}: ${fallbackSong.streamUrl}');
        final updatedSong = song.copyWith(streamUrl: fallbackSong.streamUrl);

        bool fallbackSuccess = await _downloadSongInternal(
          updatedSong,
          uid: session.uid,
          externalCancelToken: session.cancelToken,
        );

        if (fallbackSuccess) {
          session.recoveredCount++;
          _notifyPlaylistProgress(session);
          return;
        }
      }
    }

    session.failedCount++;
    session.failedSongs.add(song);
    _notifyPlaylistProgress(session);
  }

  static final Dio _dio = Dio();
  static final Map<String, double> _progress = {};
  static final Map<String, bool> _downloading = {};
  static final Map<String, CancelToken> _cancelTokens = {};
  static final Map<String, String> _downloadOwnerBySong = {};
  static final Map<String, DateTime> _lastStatePersistBySong = {};

  static const Duration _statePersistThrottle = Duration(milliseconds: 700);
  static const int _minValidDownloadedBytes = 1024;

  static String? _resolvedDownloadsDirPath;

  static String? get resolvedDownloadsDirPath => _resolvedDownloadsDirPath;

  static Future<String> getDownloadsDirPath() async {
    if (_resolvedDownloadsDirPath != null) return _resolvedDownloadsDirPath!;
    final dir = await _downloadsDir;
    _resolvedDownloadsDirPath = dir.path;
    return _resolvedDownloadsDirPath!;
  }

  /// Get the local downloads directory
  static Future<Directory> get _downloadsDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/music_hub_downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    _resolvedDownloadsDirPath = dir.path;
    return dir;
  }

  /// Get the metadata file path
  static Future<File> get _metadataFile async {
    final dir = await _downloadsDir;
    return File('${dir.path}/metadata.json');
  }

  /// Check if a song is downloaded for current user.
  static Future<bool> isDownloaded(String songId) async {
    final localPath = await getLocalPath(songId);
    return localPath != null && localPath.trim().isNotEmpty;
  }

  /// Get download progress for a song (0.0 to 1.0)
  static double getProgress(String songId) => _progress[songId] ?? 0.0;

  /// Check if currently downloading
  static bool isDownloading(String songId) => _downloading[songId] ?? false;

  static void _showToast(String msg) {
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.redAccent,
      textColor: Colors.white,
      fontSize: 14.0,
    );
  }

  static void showDownloadFailureToast([
    String msg = "Failed to save. Please reconnect the internet.",
  ]) {
    _showToast(msg);
  }

  /// Download a song (resumable when partial file exists).
  static Future<bool> downloadSong(
    Song song, {
    Function(double)? onProgress,
  }) async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return false;
    return _downloadSongInternal(song, uid: uid, onProgress: onProgress);
  }

  /// Cancel session downloads safely on logout and persist partial progress.
  static Future<void> persistAndStopForLogout({String? uid}) async {
    final ownerUid = uid ?? _currentUserUid();
    if (ownerUid == null || ownerUid.isEmpty) return;

    final songIds = _downloadOwnerBySong.entries
        .where((entry) => entry.value == ownerUid)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (songIds.isEmpty) return;

    for (final songId in songIds) {
      _cancelTokens[songId]?.cancel('logout');
    }
  }

  static Future<Map<String, double>> getPendingProgressForCurrentUser() async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return const {};

    final states = await SessionStateService.readAllDownloadStatesForUser(uid);
    final map = <String, double>{};
    for (final state in states) {
      final songId = (state['songId'] ?? '').toString().trim();
      if (songId.isEmpty) continue;
      final progress = _resolveProgress(
        state['progress'],
        receivedBytes: state['receivedBytes'],
        totalBytes: state['totalBytes'],
      );
      if (progress > 0.0 && progress < 1.0) {
        map[songId] = progress;
      }
    }
    return map;
  }

  /// Resume paused downloads for current user.
  static Future<void> resumePendingDownloadsForCurrentUser({
    void Function(String songId, double progress)? onSongProgress,
  }) async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return;

    final connectivityResult = await Connectivity().checkConnectivity();
    final hasConnectivity = connectivityResult.any(
      (result) => result != ConnectivityResult.none,
    );
    if (!hasConnectivity) {
      return;
    }

    final pending = await SessionStateService.readAllDownloadStatesForUser(uid);
    if (pending.isEmpty) return;

    pending.sort((a, b) {
      final aTs = _toInt(a['updatedAt']);
      final bTs = _toInt(b['updatedAt']);
      return aTs.compareTo(bTs);
    });

    for (final state in pending) {
      final status = (state['status'] ?? '').toString().toLowerCase();
      if (status == 'completed') {
        final songId = (state['songId'] ?? '').toString().trim();
        if (songId.isNotEmpty) {
          await SessionStateService.clearDownloadState(
            uid: uid,
            songId: songId,
          );
        }
        continue;
      }

      final song = _songFromStateMap(state);
      if (song == null || song.id.trim().isEmpty) continue;

      await _downloadSongInternal(
        song,
        uid: uid,
        onProgress: (progress) => onSongProgress?.call(song.id, progress),
        resumeState: state,
      );
    }
  }

  /// Delete a downloaded song for current user.
  static Future<void> deleteSong(String songId) async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return;

    final metadata = await _readMetadataEntries();
    metadata.removeWhere(
      (entry) => _entrySongId(entry) == songId && _entryUid(entry) == uid,
    );
    await _writeMetadataEntries(metadata);
    await SessionStateService.clearDownloadState(uid: uid, songId: songId);

    // Remove file only if no other account still references this song.
    final hasOtherOwner = metadata.any(
      (entry) => _entrySongId(entry) == songId,
    );
    if (!hasOtherOwner) {
      final dir = await _downloadsDir;
      final songDir = Directory('${dir.path}/songs/$songId');
      if (await songDir.exists()) {
        await songDir.delete(recursive: true);
      }
      // Also clean up legacy flat files if they exist
      final legacyFile = File('${dir.path}/$songId.mp4');
      final legacyPart = File('${dir.path}/$songId.mp4.part');
      final legacyArt = File('${dir.path}/$songId.jpg');
      final legacyLrc = File('${dir.path}/$songId.lrc');
      if (await legacyFile.exists()) await legacyFile.delete();
      if (await legacyPart.exists()) await legacyPart.delete();
      if (await legacyArt.exists()) await legacyArt.delete();
      if (await legacyLrc.exists()) await legacyLrc.delete();
    }
  }

  /// Get the local file path for a downloaded song for current user.
  static Future<String?> getLocalPath(String songId) async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return null;

    final metadata = await _readMetadataEntries();
    final entry = metadata.cast<Map<String, dynamic>?>().firstWhere(
      (item) =>
          item != null &&
          _entrySongId(item) == songId &&
          _entryUid(item) == uid,
      orElse: () => null,
    );
    if (entry == null) return null;

    final resolvedPath = await _resolveValidDownloadedPathForEntry(entry);
    if (resolvedPath != null) {
      if ((entry['filePath'] ?? '').toString().trim() != resolvedPath) {
        entry['filePath'] = resolvedPath;
        await _writeMetadataEntries(metadata);
      }
      return resolvedPath;
    }

    // Trigger background re-download if the file was deleted or corrupted
    final song = _songFromStateMap(entry) ?? Song.fromJson(entry);
    _triggerBackgroundReDownload(song);

    metadata.removeWhere(
      (item) => _entrySongId(item) == songId && _entryUid(item) == uid,
    );
    await _writeMetadataEntries(metadata);
    await SessionStateService.clearDownloadState(uid: uid, songId: songId);
    return null;
  }

  static void _triggerBackgroundReDownload(Song song) {
    _isNetworkConnected().then((hasNetwork) {
      if (hasNetwork) {
        debugPrint('Downloaded file for ${song.name} is missing/corrupted. Triggering background re-download...');
        unawaited(downloadSong(song));
      }
    });
  }

  /// Get the local file path for a downloaded song if it exists on disk,
  /// regardless of which user account originally downloaded it.
  static Future<String?> getGlobalLocalPath(String songId) async {
    final root = await getApplicationDocumentsDirectory();
    final file = File('${root.path}/music_hub_downloads/$songId.mp4');
    if (await file.exists() && (await file.length()) > _minValidDownloadedBytes) {
      return file.path;
    }
    return null;
  }

  /// Get all downloaded songs metadata for current user.
  static Future<List<Song>> getDownloadedSongs() async {
    final uid = _currentUserUid();
    if (uid == null || uid.isEmpty) return [];

    final file = await _metadataFile;
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final dynamic decoded = jsonDecode(content);
      if (decoded is! List) return [];

      final entries = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      var mutated = false;

      for (final entry in entries) {
        final owner = _entryUid(entry);
        if (owner.isEmpty) {
          // One-time migration for pre-account metadata.
          entry['uid'] = uid;
          mutated = true;
        }
      }
      if (mutated) {
        await _writeMetadataEntries(entries);
      }

      final cleanedEntries = <Map<String, dynamic>>[];
      final songs = <Song>[];

      for (final entry in entries) {
        final owner = _entryUid(entry);
        if (owner != uid) {
          cleanedEntries.add(entry);
          continue;
        }

        final resolvedPath = await _resolveValidDownloadedPathForEntry(entry);
        if (resolvedPath == null) {
          mutated = true;
          await SessionStateService.clearDownloadState(
            uid: uid,
            songId: _entrySongId(entry),
          );
          continue;
        }

        if ((entry['filePath'] ?? '').toString().trim() != resolvedPath) {
          entry['filePath'] = resolvedPath;
          mutated = true;
        }

        cleanedEntries.add(entry);
        songs.add(Song.fromJson(entry));
      }

      if (mutated) {
        await _writeMetadataEntries(cleanedEntries);
      }

      return songs;
    } catch (_) {
      return [];
    }
  }

  /// Get total download size in bytes (all local files on device).
  static Future<int> getTotalSize() async {
    final dir = await _downloadsDir;
    if (!await dir.exists()) return 0;

    int totalSize = 0;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.mp4')) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }

  static Future<bool> _downloadSongInternal(
    Song song, {
    required String uid,
    Function(double)? onProgress,
    Map<String, dynamic>? resumeState,
    bool allowRangeResume = true,
    CancelToken? externalCancelToken,
  }) async {
    final songId = song.id.trim();
    if (songId.isEmpty) return false;
    if (_downloading[songId] == true) return false;

    final prefs = await PreferencesService.getPreferences(uid);
    final quality = prefs?.downloadQuality ?? AudioQuality.high;

    final sourceUrl = _resolveSourceUrl(song, quality);
    if (sourceUrl.isEmpty) return false;

    _downloading[songId] = true;
    _downloadOwnerBySong[songId] = uid;
    _progress[songId] = _resolveProgress(
      resumeState?['progress'],
      receivedBytes: resumeState?['receivedBytes'],
      totalBytes: resumeState?['totalBytes'],
    );
    onProgress?.call(_progress[songId]!);

    final cancelToken = externalCancelToken ?? CancelToken();
    _cancelTokens[songId] = cancelToken;

    try {
      final dir = await _downloadsDir;
      final songDir = Directory('${dir.path}/songs/$songId');
      if (!await songDir.exists()) await songDir.create(recursive: true);

      final finalPath = '${songDir.path}/audio.mp4';
      final partPath = '$finalPath.part';
      final partFile = File(partPath);
      final finalFile = File(finalPath);

      // If a valid file already exists (potentially from auto-cache), 
      // just register it and skip download.
      if (await finalFile.exists() && (await finalFile.length()) > _minValidDownloadedBytes) {
        await _saveMetadata(song, uid: uid, filePath: finalPath);

        // Ensure artwork is present locally
        try {
          final artworkDir = Directory('${dir.path}/songs/$songId');
          final artworkFile = File('${artworkDir.path}/artwork.jpg');
          if (!await artworkFile.exists()) {
            final artworkUrl = ArtworkService.resolveArtworkUrl(song);
            if (artworkUrl.isNotEmpty) {
              if (!await artworkDir.exists()) {
                await artworkDir.create(recursive: true);
              }
              await _dio.download(
                artworkUrl,
                artworkFile.path,
                cancelToken: cancelToken,
              );
              debugPrint('[DownloadService] Saved missing local artwork for existing song $songId');
            }
          }
        } catch (e) {
          debugPrint('[DownloadService] Failed to save local artwork for existing song $songId: $e');
        }

        await SessionStateService.clearDownloadState(uid: uid, songId: songId);
        
        // Found local copy (auto-cached). Transition to manual and uncache.
        unawaited(OfflineService.uncacheRecord(songId));
        
        _progress[songId] = 1.0;
        onProgress?.call(1.0);
        return true;
      }

      var existingBytes = 0;
      if (await partFile.exists()) {
        existingBytes = await partFile.length();
      }

      if (existingBytes > 0 && !allowRangeResume) {
        await partFile.delete();
        existingBytes = 0;
      }

      var expectedTotalBytes = _toInt(resumeState?['totalBytes']);
      if (expectedTotalBytes > 0 && expectedTotalBytes < existingBytes) {
        expectedTotalBytes = 0;
      }

      await _persistDownloadState(
        uid: uid,
        song: song,
        sourceUrl: sourceUrl,
        status: 'downloading',
        progress: _progress[songId] ?? 0.0,
        receivedBytes: existingBytes,
        totalBytes: expectedTotalBytes,
      );

      final headers = <String, dynamic>{};
      final fileMode = existingBytes > 0
          ? FileAccessMode.append
          : FileAccessMode.write;
      if (existingBytes > 0) {
        headers['range'] = 'bytes=$existingBytes-';
      }

      final response = await _dio.download(
        sourceUrl,
        partPath,
        cancelToken: cancelToken,
        deleteOnError: false,
        options: Options(headers: headers.isEmpty ? null : headers),
        fileAccessMode: fileMode,
        onReceiveProgress: (received, total) {
          final mergedReceived = existingBytes + received;
          final mergedTotal = total > 0
              ? existingBytes + total
              : expectedTotalBytes;
          final progress = _resolveProgress(
            null,
            receivedBytes: mergedReceived,
            totalBytes: mergedTotal,
          );
          _progress[songId] = progress;
          onProgress?.call(progress);

          final now = DateTime.now();
          final last = _lastStatePersistBySong[songId];
          if (last != null && now.difference(last) < _statePersistThrottle) {
            return;
          }
          _lastStatePersistBySong[songId] = now;
          unawaited(
            _persistDownloadState(
              uid: uid,
              song: song,
              sourceUrl: sourceUrl,
              status: 'downloading',
              progress: progress,
              receivedBytes: mergedReceived,
              totalBytes: mergedTotal,
            ),
          );
        },
      );

      // Server ignored range header. Restart cleanly once to avoid corruption.
      if (existingBytes > 0 &&
          allowRangeResume &&
          (response.statusCode ?? 200) == 200) {
        if (await partFile.exists()) {
          await partFile.delete();
        }
        _progress[songId] = 0.0;
        onProgress?.call(0.0);
        return _downloadSongInternal(
          song,
          uid: uid,
          onProgress: onProgress,
          resumeState: resumeState,
          allowRangeResume: false,
          externalCancelToken: externalCancelToken,
        );
      }

      if (!await partFile.exists() || await partFile.length() == 0) {
        await _cleanupFailedDownload(songId, uid: uid, onProgress: onProgress);
        showDownloadFailureToast();
        return false;
      }

      if (await partFile.length() < 1000) {
        await _cleanupFailedDownload(songId, uid: uid, onProgress: onProgress);
        _showToast("Failed to save. File is incomplete.");
        return false;
      }
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partFile.rename(finalPath);

      await _saveMetadata(song, uid: uid, filePath: finalPath);

      // Fetch and save artwork locally
      try {
        final artworkUrl = ArtworkService.resolveArtworkUrl(song);
        if (artworkUrl.isNotEmpty) {
          final artworkDir = Directory('${dir.path}/songs/$songId');
          if (!await artworkDir.exists()) {
            await artworkDir.create(recursive: true);
          }
          final artworkPath = '${artworkDir.path}/artwork.jpg';
          await _dio.download(
            artworkUrl,
            artworkPath,
            cancelToken: cancelToken,
          );
          debugPrint('[DownloadService] Successfully saved local artwork for song $songId');
        }
      } catch (e) {
        debugPrint('[DownloadService] Failed to save local artwork for song $songId: $e');
      }

      // Fetch and cache lyrics for offline usage, and save .lrc locally
      try {
        final payload = await LyricsService.getLyricsPayloadForSong(song);
        if (payload != null) {
          await LyricsService.saveLocalLrc(song.id, payload);
          debugPrint('[DownloadService] Successfully saved local lyrics for song $songId');
        }
      } catch (e) {
        debugPrint('Error caching lyrics for downloaded song: $e');
      }

      await SessionStateService.clearDownloadState(uid: uid, songId: songId);
      
      // Successfully downloaded. Remove from auto-cache tracker (metadata only)
      // to avoid duplicate management of the same file.
      unawaited(OfflineService.uncacheRecord(songId));
      _downloadCompletedController.add(songId);
      
      _progress[songId] = 1.0;
      onProgress?.call(1.0);
      return true;
    } on DioException catch (e) {
      final cancelled = CancelToken.isCancel(e);
      final cancelledByLogout =
          cancelled && (e.message ?? '').toLowerCase().contains('logout');
      final status = cancelled
          ? (cancelledByLogout ? 'paused_by_logout' : 'paused')
          : 'failed';
      final received = await _currentPartialBytes(songId);
      final total = _toInt(resumeState?['totalBytes']);
      final progress = _resolveProgress(
        _progress[songId],
        receivedBytes: received,
        totalBytes: total,
      );
      _progress[songId] = progress;

      await _persistDownloadState(
        uid: uid,
        song: song,
        sourceUrl: sourceUrl,
        status: status,
        progress: progress,
        receivedBytes: received,
        totalBytes: total,
      );
      if (!cancelled) {
        await _cleanupFailedDownload(songId, uid: uid, onProgress: onProgress);
        showDownloadFailureToast();
        debugPrint('Download error for $songId: $e');
      }
      return false;
    } catch (e) {
      final received = await _currentPartialBytes(songId);
      final total = _toInt(resumeState?['totalBytes']);
      final progress = _resolveProgress(
        _progress[songId],
        receivedBytes: received,
        totalBytes: total,
      );
      _progress[songId] = progress;
      await _cleanupFailedDownload(songId, uid: uid, onProgress: onProgress);
      showDownloadFailureToast();
      debugPrint('Download error for $songId: $e');
      return false;
    } finally {
      _downloading[songId] = false;
      _cancelTokens.remove(songId);
      _downloadOwnerBySong.remove(songId);
      _lastStatePersistBySong.remove(songId);
    }
  }

  static Future<void> _persistDownloadState({
    required String uid,
    required Song song,
    required String sourceUrl,
    required String status,
    required double progress,
    required int receivedBytes,
    required int totalBytes,
  }) async {
    await SessionStateService.saveDownloadState(
      uid: uid,
      songId: song.id,
      state: {
        'uid': uid,
        'songId': song.id,
        'song': {
          'id': song.id,
          'name': song.name,
          'artist': song.artist,
          'album': song.album,
          'albumId': song.albumId,
          'sourceAlbumId': song.sourceAlbumId,
          'sourceAlbumName': song.sourceAlbumName,
          'sourceAlbumArtist': song.sourceAlbumArtist,
          'sourceAlbumImageUrl': song.sourceAlbumImageUrl,
          'imageUrl': song.imageUrl,
          'streamUrl': song.streamUrl,
          'language': song.language,
          'duration': song.duration,
        },
        'url': sourceUrl,
        'status': status,
        'progress': progress,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  static Song? _songFromStateMap(Map<String, dynamic> state) {
    final rawSong = state['song'];
    if (rawSong is Map) {
      final map = Map<String, dynamic>.from(rawSong);
      final id = (map['id'] ?? '').toString().trim();
      if (id.isEmpty) return null;
      return Song(
        id: id,
        name: (map['name'] ?? '').toString(),
        artist: map['artist']?.toString(),
        album: map['album']?.toString(),
        albumId: map['albumId']?.toString(),
        sourceAlbumId: map['sourceAlbumId']?.toString(),
        sourceAlbumName: map['sourceAlbumName']?.toString(),
        sourceAlbumArtist: map['sourceAlbumArtist']?.toString(),
        sourceAlbumImageUrl: map['sourceAlbumImageUrl']?.toString(),
        imageUrl: map['imageUrl']?.toString(),
        streamUrl: map['streamUrl']?.toString(),
        language: map['language']?.toString(),
        duration: _nullableToInt(map['duration']),
      );
    }

    final songId = (state['songId'] ?? '').toString().trim();
    if (songId.isEmpty) return null;
    return Song(
      id: songId,
      name: (state['songName'] ?? 'Unknown').toString(),
      artist: state['artist']?.toString(),
      album: state['album']?.toString(),
      albumId: state['albumId']?.toString(),
      sourceAlbumId: state['sourceAlbumId']?.toString(),
      sourceAlbumName: state['sourceAlbumName']?.toString(),
      sourceAlbumArtist: state['sourceAlbumArtist']?.toString(),
      sourceAlbumImageUrl: state['sourceAlbumImageUrl']?.toString(),
      imageUrl: state['imageUrl']?.toString(),
      streamUrl: state['url']?.toString(),
      duration: _nullableToInt(state['duration']),
    );
  }

  static double _resolveProgress(
    dynamic rawProgress, {
    dynamic receivedBytes,
    dynamic totalBytes,
  }) {
    if (rawProgress is num) {
      return rawProgress.toDouble().clamp(0.0, 1.0);
    }

    final received = _toInt(receivedBytes);
    final total = _toInt(totalBytes);
    if (received <= 0 || total <= 0) return 0.0;
    return (received / total).clamp(0.0, 1.0);
  }

  static int _toInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int? _nullableToInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static String _resolveSourceUrl(Song song, AudioQuality quality) {
    final maxKbps = quality.kbps <= 0 ? Song.streamingMaxKbps : quality.kbps;
    final maxMb = quality.maxMb <= 0 ? -1.0 : quality.maxMb;

    final optimized =
        Song.optimizeStreamUrlForData(
          song.streamUrl,
          maxKbps: maxKbps,
          durationSeconds: song.duration,
          maxMegabytes: maxMb,
        ) ??
        song.streamUrl;
    return (optimized ?? '').trim();
  }

  static String? _currentUserUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  static Future<int> _currentPartialBytes(String songId) async {
    final dir = await _downloadsDir;
    final part = File('${dir.path}/$songId.mp4.part');
    if (!await part.exists()) return 0;
    return part.length();
  }

  static Future<void> _cleanupFailedDownload(
    String songId, {
    required String uid,
    Function(double)? onProgress,
  }) async {
    final dir = await _downloadsDir;
    final partFile = File('${dir.path}/$songId.mp4.part');
    final finalFile = File('${dir.path}/$songId.mp4');

    if (await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {
        // Ignore cleanup failures.
      }
    }

    if (await finalFile.exists() && !await _isUsableDownloadedFile(finalFile)) {
      try {
        await finalFile.delete();
      } catch (_) {
        // Ignore cleanup failures.
      }
    }

    _progress.remove(songId);
    onProgress?.call(0.0);
    await SessionStateService.clearDownloadState(uid: uid, songId: songId);
  }

  static Future<String?> _resolveValidDownloadedPathForEntry(
    Map<String, dynamic> entry,
  ) async {
    final songId = _entrySongId(entry);
    if (songId.isEmpty) return null;

    final dir = await _downloadsDir;
    final explicitPath = (entry['filePath'] ?? '').toString().trim();
    final fallbackPath = '${dir.path}/$songId.mp4';
    final candidates = <String>{
      if (explicitPath.isNotEmpty) explicitPath,
      fallbackPath,
    };

    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      if (await _isUsableDownloadedFile(file)) {
        return file.path;
      }

      try {
        await file.delete();
      } catch (_) {
        // Ignore cleanup failures; we still treat the entry as invalid.
      }
    }

    return null;
  }

  static Future<bool> _isUsableDownloadedFile(File file) async {
    try {
      if (!await file.exists()) return false;
      return await file.length() >= _minValidDownloadedBytes;
    } catch (_) {
      return false;
    }
  }

  static String _entrySongId(Map<String, dynamic> entry) =>
      (entry['id'] ?? '').toString().trim();

  static String _entryUid(Map<String, dynamic> entry) =>
      (entry['uid'] ?? '').toString().trim();

  static Future<List<Map<String, dynamic>>> _readMetadataEntries() async {
    final file = await _metadataFile;
    if (!await file.exists()) return <Map<String, dynamic>>[];

    try {
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _writeMetadataEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    final file = await _metadataFile;
    await file.writeAsString(jsonEncode(entries));
  }

  static Future<void> _saveMetadata(
    Song song, {
    required String uid,
    required String filePath,
  }) async {
    final entries = await _readMetadataEntries();
    entries.removeWhere(
      (entry) => _entrySongId(entry) == song.id && _entryUid(entry) == uid,
    );

    entries.add({
      'uid': uid,
      'id': song.id,
      'name': song.name,
      'artist': song.artist,
      'album': song.album,
      'albumId': song.albumId,
      'sourceAlbumId': song.sourceAlbumId,
      'sourceAlbumName': song.sourceAlbumName,
      'sourceAlbumArtist': song.sourceAlbumArtist,
      'sourceAlbumImageUrl': song.sourceAlbumImageUrl,
      'imageUrl': song.imageUrl,
      'streamUrl': song.streamUrl,
      'filePath': filePath,
      'downloadedAt': DateTime.now().millisecondsSinceEpoch,
    });

    await _writeMetadataEntries(entries);
  }
}
