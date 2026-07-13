import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/offline_service.dart';

class DownloadProvider extends ChangeNotifier {
  final Map<String, double> _progress = {};
  final Set<String> _downloadedIds = {};
  List<Song> _downloadedSongs = [];
  bool _smartDownloadEnabled = OfflineService.smartAutoCacheEnabled;
  String? _activeUid;
  bool _resumingPendingDownloads = false;
  PlaylistDownloadProgress? _playlistProgress;
  StreamSubscription<PlaylistDownloadProgress>? _playlistProgressSub;
  StreamSubscription<String>? _downloadCompletedSub;

  Map<String, double> get progress => _progress;
  Set<String> get downloadedIds => _downloadedIds;
  List<Song> get downloadedSongs => _downloadedSongs;
  bool get smartDownloadEnabled => _smartDownloadEnabled;
  PlaylistDownloadProgress? get playlistProgress => _playlistProgress;

  DownloadProvider() {
    _playlistProgressSub = DownloadService.playlistProgressStream.listen((prog) {
      _playlistProgress = prog;
      if (prog.isCompleted) {
        _loadDownloaded();
      }
      notifyListeners();
    });
    _downloadCompletedSub = DownloadService.downloadCompletedStream.listen((_) {
      _loadDownloaded();
    });
  }

  void syncWithAuth(User? user) {
    final nextUid = user?.uid;
    if (_activeUid == nextUid) return;
    _activeUid = nextUid;

    _progress.clear();
    _downloadedIds.clear();
    _downloadedSongs = [];
    notifyListeners();

    if (nextUid == null || nextUid.isEmpty) return;
    unawaited(_bootstrapForUser(nextUid));
  }

  Future<void> _bootstrapForUser(String uid) async {
    _smartDownloadEnabled = OfflineService.smartAutoCacheEnabled;
    await _loadDownloaded();
    if (_activeUid != uid) return;

    final pending = await DownloadService.getPendingProgressForCurrentUser();
    if (_activeUid != uid) return;

    _progress
      ..clear()
      ..addAll(pending);
    notifyListeners();

    unawaited(_resumePendingDownloads(uid));
  }

  Future<void> _resumePendingDownloads(String uid) async {
    if (_resumingPendingDownloads) return;
    _resumingPendingDownloads = true;
    try {
      await DownloadService.resumePendingDownloadsForCurrentUser(
        onSongProgress: (songId, p) {
          if (_activeUid != uid) return;
          if (p >= 1.0) {
            _progress.remove(songId);
          } else {
            _progress[songId] = p;
          }
          notifyListeners();
        },
      );

      if (_activeUid == uid) {
        await _loadDownloaded();
        final pending =
            await DownloadService.getPendingProgressForCurrentUser();
        if (_activeUid == uid) {
          _progress
            ..clear()
            ..addAll(pending);
          notifyListeners();
        }
      }
    } finally {
      _resumingPendingDownloads = false;
    }
  }

  Future<void> _loadDownloaded() async {
    if (_activeUid == null || _activeUid!.isEmpty) {
      _downloadedSongs = [];
      _downloadedIds.clear();
      notifyListeners();
      return;
    }

    final manualDownloaded = await DownloadService.getDownloadedSongs();
    final autoCached = await OfflineService.getOfflineSongs();

    _downloadedSongs = [...manualDownloaded, ...autoCached];
    _downloadedIds.clear();
    for (final song in _downloadedSongs) {
      _downloadedIds.add(song.id);
    }
    notifyListeners();
  }

  bool isDownloaded(String songId) => _downloadedIds.contains(songId);
  bool isDownloading(String songId) => DownloadService.isDownloading(songId);

  Future<void> download(Song song) async {
    if (_activeUid == null || _activeUid!.isEmpty) return;
    _progress[song.id] = 0.0;
    notifyListeners();

    final success = await DownloadService.downloadSong(
      song,
      onProgress: (p) {
        _progress[song.id] = p;
        notifyListeners();
      },
    );

    if (success) {
      _downloadedIds.add(song.id);
      await _loadDownloaded();
      _progress.remove(song.id);
      notifyListeners();
      return;
    }

    final pending = await DownloadService.getPendingProgressForCurrentUser();
    _progress
      ..remove(song.id)
      ..addAll(pending);
    notifyListeners();
  }

  Future<void> delete(String songId) async {
    if (_activeUid == null || _activeUid!.isEmpty) return;
    
    // Clear from both sources to ensure full removal
    final success = await DownloadService.deleteSong(songId);
    if (!success) {
      // Abort UI state changes to keep it visible
      return;
    }
    await OfflineService.deleteRecord(songId);
    
    _downloadedIds.remove(songId);
    _progress.remove(songId);
    await _loadDownloaded();
    notifyListeners();
  }

  /// Get local file path for offline playback
  Future<String?> getLocalPath(String songId) =>
      DownloadService.getLocalPath(songId);

  /// Smart Download: auto-download frequently played songs
  void toggleSmartDownload() {
    _smartDownloadEnabled = !_smartDownloadEnabled;
    unawaited(OfflineService.setSmartAutoCacheEnabled(_smartDownloadEnabled));
    notifyListeners();
  }

  /// Smart download: auto-cache top played songs
  Future<void> smartDownload() async {
    if (!_smartDownloadEnabled) return;
    if (_activeUid == null || _activeUid!.isEmpty) return;

    try {
      final history = await ApiService.getHistory(type: 'play', limit: 50);

      // Count play frequency per song
      final Map<String, int> playCounts = {};
      final Map<String, dynamic> songData = {};

      for (final item in history) {
        final id = item['songId']?.toString() ?? '';
        if (id.isEmpty) continue;
        playCounts[id] = (playCounts[id] ?? 0) + 1;
        songData[id] = item;
      }

      // Sort by play count, get top 5 not already downloaded
      final topSongs = playCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      int downloaded = 0;
      for (final entry in topSongs) {
        if (downloaded >= 5) break;
        if (_downloadedIds.contains(entry.key)) continue;

        final data = songData[entry.key];
        if (data == null) continue;

        // We need stream URL - try fetching the song.
        try {
          final songResult = await ApiService.getSong(entry.key);
          final songJson = songResult['data'];
          if (songJson != null) {
            final song = Song.fromJson(
              songJson is List ? songJson.first : songJson,
            );
            if (song.streamUrl != null) {
              await download(song);
              downloaded++;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Smart download error: $e');
    }
  }
  @override
  void dispose() {
    _playlistProgressSub?.cancel();
    _downloadCompletedSub?.cancel();
    super.dispose();
  }

  Future<void> downloadPlaylist(
    String playlistId,
    String playlistName,
    List<Song> songs,
  ) async {
    unawaited(DownloadService.startPlaylistDownload(playlistId, playlistName, songs));
  }

  void cancelPlaylistDownload() {
    DownloadService.cancelPlaylistDownload();
  }

  void clearPlaylistProgress() {
    _playlistProgress = null;
    notifyListeners();
  }
}
