import 'package:flutter/material.dart';

import '../models/song.dart';
import '../models/user_playlist.dart';
import '../services/offline_service.dart';
import '../services/playlist_service.dart';
import '../utils/content_filter.dart';

class PlaylistProvider extends ChangeNotifier {
  List<UserPlaylist> _playlists = [];
  bool _loading = true;

  List<UserPlaylist> get playlists => _playlists;
  bool get loading => _loading;

  PlaylistProvider() {
    loadPlaylists();
  }

  Future<void> loadPlaylists() async {
    _loading = true;
    notifyListeners();

    try {
      _playlists = await PlaylistService.getPlaylists();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  UserPlaylist? getById(String id) {
    final targetId = id.trim();
    if (targetId.isEmpty) return null;
    for (final playlist in _playlists) {
      if (playlist.id == targetId) return playlist;
    }
    return null;
  }

  Future<UserPlaylist> createPlaylist(
    String name, {
    String? description,
    String? coverImageUrl,
    Song? initialSong,
    List<Song>? initialSongs,
  }) async {
    final songs = <Song>[];
    if (initialSong != null) songs.add(initialSong);
    if (initialSongs != null) songs.addAll(initialSongs);

    final playlist = await PlaylistService.createPlaylist(
      name,
      description: description,
      coverImageUrl: coverImageUrl,
      songs: songs,
    );
    _playlists = [..._playlists, playlist];
    _sortByUpdatedAtDesc();
    notifyListeners();

    for (final song in songs) {
      // Try caching immediately so this track can work offline later.
      OfflineService.autoCache(song, force: true);
    }
    return playlist;
  }

  Future<bool> addSongsToPlaylist(String playlistId, List<Song> songs) async {
    if (songs.isEmpty) return true;

    final updated = await PlaylistService.addSongs(playlistId, songs);
    if (updated == null) return false;

    for (final song in songs) {
      OfflineService.autoCache(song, force: true);
    }

    _replacePlaylist(updated);
    return true;
  }

  Future<bool> renamePlaylist(String playlistId, String name) async {
    final updated = await PlaylistService.renamePlaylist(playlistId, name);
    if (updated == null) return false;
    _replacePlaylist(updated);
    return true;
  }

  Future<bool> updatePlaylistMetadata(
    String playlistId, {
    required String name,
    String? description,
    String? coverImageUrl,
  }) async {
    final updated = await PlaylistService.updatePlaylistMetadata(
      playlistId,
      name: name,
      description: description,
      coverImageUrl: coverImageUrl,
    );
    if (updated == null) return false;
    _replacePlaylist(updated);
    return true;
  }

  Future<bool> deletePlaylist(String playlistId) async {
    final deleted = await PlaylistService.deletePlaylist(playlistId);
    if (!deleted) return false;
    _playlists = _playlists
        .where((playlist) => playlist.id != playlistId)
        .toList(growable: false);
    notifyListeners();
    return true;
  }

  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    final updated = await PlaylistService.addSong(playlistId, song);
    if (updated == null) return false;

    _replacePlaylist(updated);
    // Queue low-quality cache request so this becomes playable offline.
    await OfflineService.autoCache(song, force: true);
    return true;
  }

  Future<bool> removeSongFromPlaylist(String playlistId, String songId) async {
    final updated = await PlaylistService.removeSong(playlistId, songId);
    if (updated == null) return false;
    _replacePlaylist(updated);
    return true;
  }

  Future<bool> reorderPlaylistSongs(
    String playlistId,
    List<String> orderedSongIds,
  ) async {
    final updated = await PlaylistService.reorderSongs(
      playlistId,
      orderedSongIds,
    );
    if (updated == null) return false;
    _replacePlaylist(updated);
    return true;
  }

  void _replacePlaylist(UserPlaylist updated) {
    final next = [..._playlists];
    final index = next.indexWhere((playlist) => playlist.id == updated.id);
    if (index >= 0) {
      next[index] = updated;
    } else {
      next.add(updated);
    }
    _playlists = next;
    _sortByUpdatedAtDesc();
    notifyListeners();
  }

  void _sortByUpdatedAtDesc() {
    _playlists.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<Song> buildPlayableSongs(
    UserPlaylist playlist, {
    required bool offlineOnly,
  }) {
    final playable = <Song>[];

    for (final song in playlist.songs) {
      if (!ContentFilter.isAllowedSongTitle(song.name)) continue;

      final localPath = OfflineService.getLocalPath(song.id);
      if (localPath != null && localPath.isNotEmpty) {
        playable.add(_withStream(song, localPath));
        continue;
      }

      final remote = (song.streamUrl ?? '').trim();
      if (!offlineOnly && remote.isNotEmpty) {
        playable.add(_withStream(song, remote));
      }
    }

    return playable;
  }

  int offlinePlayableCount(UserPlaylist playlist) {
    var count = 0;
    for (final song in playlist.songs) {
      final localPath = OfflineService.getLocalPath(song.id);
      if (localPath != null && localPath.isNotEmpty) {
        count += 1;
      }
    }
    return count;
  }

  Song _withStream(Song song, String stream) {
    return song.copyWith(streamUrl: stream);
  }
}
