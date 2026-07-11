import 'package:hive_flutter/hive_flutter.dart';

import '../models/song.dart';
import '../models/user_playlist.dart';

class PlaylistService {
  static const String _boxName = 'music_hub_user_playlists_v1';
  static const String _allPlaylistsKey = 'playlists';

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

  static Future<List<UserPlaylist>> getPlaylists() async {
    final box = await _ensureBox();
    final raw = box.get(_allPlaylistsKey);
    if (raw is! List) return const [];

    final playlists = raw
        .whereType<Map>()
        .map((item) => UserPlaylist.fromJson(Map<String, dynamic>.from(item)))
        .where((playlist) => playlist.id.trim().isNotEmpty)
        .toList(growable: false);

    playlists.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return playlists;
  }

  static Future<UserPlaylist> createPlaylist(
    String name, {
    String? description,
    String? coverImageUrl,
    List<Song> songs = const [],
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Playlist name cannot be empty.');
    }

    final existing = await getPlaylists();
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = UserPlaylist(
      id: 'pl_$now',
      name: trimmedName,
      description: _normalizeOptionalText(description),
      coverImageUrl: _normalizeOptionalText(coverImageUrl),
      songs: _dedupeSongs(songs),
      createdAt: now,
      updatedAt: now,
    );

    final updated = [...existing, playlist];
    await _savePlaylists(updated);
    return playlist;
  }

  static Future<UserPlaylist?> renamePlaylist(
    String playlistId,
    String nextName,
  ) async {
    final trimmedName = nextName.trim();
    if (trimmedName.isEmpty) return null;

    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final updatedPlaylist = existing[index].copyWith(
      name: trimmedName,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    existing[index] = updatedPlaylist;
    await _savePlaylists(existing);
    return updatedPlaylist;
  }

  static Future<UserPlaylist?> updatePlaylistMetadata(
    String playlistId, {
    String? name,
    String? description,
    String? coverImageUrl,
  }) async {
    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final current = existing[index];
    final nextName = (name ?? current.name).trim();
    if (nextName.isEmpty) return null;

    final updated = current.copyWith(
      name: nextName,
      description: _normalizeOptionalText(description),
      coverImageUrl: _normalizeOptionalText(coverImageUrl),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    existing[index] = updated;
    await _savePlaylists(existing);
    return updated;
  }

  static Future<bool> deletePlaylist(String playlistId) async {
    final existing = List<UserPlaylist>.from(
      await getPlaylists(),
      growable: true,
    );
    final before = existing.length;
    existing.removeWhere((playlist) => playlist.id == playlistId);
    if (existing.length == before) return false;
    await _savePlaylists(existing);
    return true;
  }

  static Future<UserPlaylist?> addSong(String playlistId, Song song) async {
    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final target = existing[index];
    final deduped = _dedupeSongs([...target.songs, song]);
    final updatedPlaylist = target.copyWith(
      songs: deduped,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    existing[index] = updatedPlaylist;
    await _savePlaylists(existing);
    return updatedPlaylist;
  }

  static Future<UserPlaylist?> addSongs(
    String playlistId,
    List<Song> songs,
  ) async {
    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final target = existing[index];
    final deduped = _dedupeSongs([...target.songs, ...songs]);
    final updatedPlaylist = target.copyWith(
      songs: deduped,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    existing[index] = updatedPlaylist;
    await _savePlaylists(existing);
    return updatedPlaylist;
  }

  static Future<UserPlaylist?> removeSong(
    String playlistId,
    String songId,
  ) async {
    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final target = existing[index];
    final before = target.songs.length;
    final keptSongs = target.songs
        .where((song) => song.id.trim() != songId.trim())
        .toList(growable: false);
    if (keptSongs.length == before) return target;

    final updatedPlaylist = target.copyWith(
      songs: keptSongs,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    existing[index] = updatedPlaylist;
    await _savePlaylists(existing);
    return updatedPlaylist;
  }

  static Future<UserPlaylist?> reorderSongs(
    String playlistId,
    List<String> orderedSongIds,
  ) async {
    final existing = await getPlaylists();
    final index = existing.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return null;

    final current = existing[index];
    if (current.songs.isEmpty || orderedSongIds.isEmpty) return current;

    final byId = <String, Song>{};
    for (final song in current.songs) {
      final id = song.id.trim();
      if (id.isNotEmpty) {
        byId[id] = song;
      }
    }

    final reordered = <Song>[];
    final seen = <String>{};
    for (final id in orderedSongIds) {
      final key = id.trim();
      if (key.isEmpty || seen.contains(key)) continue;
      final song = byId[key];
      if (song == null) continue;
      seen.add(key);
      reordered.add(song);
    }

    for (final song in current.songs) {
      final id = song.id.trim();
      if (id.isEmpty || seen.contains(id)) continue;
      reordered.add(song);
    }

    final updated = current.copyWith(
      songs: reordered,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    existing[index] = updated;
    await _savePlaylists(existing);
    return updated;
  }

  static List<Song> _dedupeSongs(List<Song> songs) {
    final uniqueById = <String, Song>{};
    for (final song in songs) {
      final id = song.id.trim();
      if (id.isEmpty) continue;
      uniqueById[id] = song;
    }
    return uniqueById.values.toList(growable: false);
  }

  static Future<void> _savePlaylists(List<UserPlaylist> playlists) async {
    final box = await _ensureBox();
    final payload = playlists.map((playlist) => playlist.toJson()).toList();
    await box.put(_allPlaylistsKey, payload);
  }

  static String? _normalizeOptionalText(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
