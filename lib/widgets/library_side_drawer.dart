import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'offline_artwork.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/preferences_provider.dart';
import '../screens/album_detail_screen.dart';
import '../screens/playlist_detail_screen.dart';
import '../services/api_service.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';
import '../utils/content_filter.dart';

enum _SongSortOption { az, recentlyPlayed, recentlyAdded }

class LibrarySideDrawer extends StatefulWidget {
  const LibrarySideDrawer({super.key});

  @override
  State<LibrarySideDrawer> createState() => _LibrarySideDrawerState();
}

class _LibrarySideDrawerState extends State<LibrarySideDrawer> {
  List<_SongLibraryEntry> _songs = [];
  List<Album> _albums = [];
  _SongSortOption _sortOption = _SongSortOption.recentlyPlayed;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final player = context.read<PlayerProvider>();
    final preferences = context.read<PreferencesProvider>();
    final isOffline = player.isOffline;

    final songByKey = <String, _SongLibraryEntry>{};
    final albumByKey = <String, Album>{};

    try {
      final offlineRecords = await OfflineService.getOfflineSongRecords();
      final offlineAlbums = await OfflineService.getOfflineAlbums();

      for (var index = 0; index < offlineRecords.length; index++) {
        final record = offlineRecords[index];
        final song = record.song;
        if (!ContentFilter.isAllowedSongTitle(song.name)) continue;
        final key = _songKey(song);
        final entry = _SongLibraryEntry(
          song: song,
          recentlyPlayedAt: record.lastPlayedAt,
          recentlyAddedAt: record.cachedAt,
          sourceRank: index,
        );
        _putBestSong(songByKey, key, entry);
      }

      for (final group in offlineAlbums) {
        if (!ContentFilter.hasValidSongs(
          group.songs.map((e) => e.song).toList(),
        )) {
          continue;
        }
        final album = Album(
          id: group.albumId,
          name: group.albumName,
          artist: group.artist,
          imageUrl: group.imageUrl,
          language: group.songs.isEmpty
              ? null
              : group.songs.first.song.language,
          songCount: group.songs.length,
        );
        _putBestAlbum(albumByKey, _albumKey(album), album);
      }

      if (!isOffline) {
        final languages = preferences.languages;
        final favoriteArtists = preferences.favoriteArtists;
        final onlineBatch = await Future.wait([
          ApiService.getPersonalizedRecommendations(
            languages: languages,
            favoriteArtists: favoriteArtists,
            limit: 40,
          ),
          ApiService.getTrendingSongs(languages: languages, limit: 40),
          ApiService.getRecommendedAlbums(
            languages: languages,
            favoriteArtists: favoriteArtists,
            limit: 20,
          ),
          ApiService.getTrendingAlbums(languages: languages, limit: 20),
          ApiService.getHistory(type: 'play', limit: 80),
        ]);

        final historyRows = onlineBatch[4]
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false);
        final recentlyPlayedMap = _buildPlayTimestampMap(historyRows);
        final nowMs = DateTime.now().millisecondsSinceEpoch;

        final onlineSongsRaw = [
          ...onlineBatch[0].whereType<Map>(),
          ...onlineBatch[1].whereType<Map>(),
        ].map((raw) => Map<String, dynamic>.from(raw)).toList(growable: false);

        for (var index = 0; index < onlineSongsRaw.length; index++) {
          final raw = onlineSongsRaw[index];
          final title = (raw['name'] ?? raw['title'] ?? '').toString();
          if (!ContentFilter.isAllowedSongTitle(title)) continue;
          final song = Song.fromJson(raw);
          if (song.id.trim().isEmpty || song.name.trim().isEmpty) continue;
          final key = _songKey(song);
          final songId = song.id.trim();
          final playedAt = recentlyPlayedMap[songId] ?? 0;
          final addedAt = nowMs - index;
          final entry = _SongLibraryEntry(
            song: song,
            recentlyPlayedAt: playedAt,
            recentlyAddedAt: addedAt,
            sourceRank: index + 1000,
          );
          _putBestSong(songByKey, key, entry);
        }

        final onlineAlbumsRaw = [
          ...onlineBatch[2].whereType<Map>(),
          ...onlineBatch[3].whereType<Map>(),
        ].map((raw) => Map<String, dynamic>.from(raw)).toList(growable: false);

        for (final raw in onlineAlbumsRaw) {
          final title = (raw['name'] ?? raw['title'] ?? '').toString();
          if (!ContentFilter.isAllowedSongTitle(title)) continue;
          final album = Album.fromJson(raw);
          if (album.id.trim().isEmpty || album.name.trim().isEmpty) continue;
          _putBestAlbum(albumByKey, _albumKey(album), album);
        }
      }

      if (!mounted) return;
      setState(() {
        _songs = songByKey.values.toList(growable: false);
        _albums = albumByKey.values.toList(growable: false);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load library data.';
        _loading = false;
      });
    }
  }

  Map<String, int> _buildPlayTimestampMap(List<Map<String, dynamic>> rows) {
    final output = <String, int>{};
    for (final row in rows) {
      final songId = (row['songId'] ?? row['song_id'] ?? '').toString().trim();
      if (songId.isEmpty) continue;

      final timestamp = _asTimestamp(
        row['timestamp'] ??
            row['createdAt'] ??
            row['created_at'] ??
            row['time'] ??
            row['playedAt'],
      );
      final previous = output[songId] ?? 0;
      if (timestamp > previous) {
        output[songId] = timestamp;
      }
    }
    return output;
  }

  int _asTimestamp(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final raw = value.toString().trim();
    if (raw.isEmpty) return 0;
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final parsed = DateTime.tryParse(raw);
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  String _songKey(Song song) {
    final id = song.id.trim();
    if (id.isNotEmpty) return 'id:$id';
    final signature = _normalizeText(
      '${song.name}|${song.artist ?? ''}|${song.album ?? ''}',
    );
    return 'sig:$signature';
  }

  String _albumKey(Album album) {
    final id = album.id.trim();
    if (id.isNotEmpty) return 'id:$id';
    final signature = _normalizeText('${album.name}|${album.artist ?? ''}');
    return 'sig:$signature';
  }

  String _normalizeText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<String?> _promptPlaylistName({String? initialValue}) async {
    final controller = TextEditingController(text: initialValue ?? '');
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Text(
          (initialValue ?? '').trim().isEmpty
              ? 'Create Playlist'
              : 'Rename Playlist',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            counterText: '',
          ),
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim().isEmpty ? null : value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              Navigator.pop(dialogContext, name.isEmpty ? null : name);
            },
            child: Text(
              (initialValue ?? '').trim().isEmpty ? 'Create' : 'Save',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddSongToPlaylistSheet(Song song) async {
    final provider = context.read<PlaylistProvider>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final playlists = sheetContext.watch<PlaylistProvider>().playlists;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Add to Playlist',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: AppTheme.accentPurple,
                ),
                title: const Text('Create New Playlist'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final name = await _promptPlaylistName();
                  if (name == null) return;
                  await provider.createPlaylist(name, initialSong: song);
                  if (!mounted) return;
                },
              ),
              if (playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Text(
                    'No playlists yet. Create one to save this song.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: playlists
                        .map((playlist) {
                          return ListTile(
                            leading: const Icon(Icons.queue_music_rounded),
                            title: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${playlist.songs.length} songs'),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await provider.addSongToPlaylist(
                                playlist.id,
                                song,
                              );
                              if (!mounted) return;
                            },
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  int _songQualityScore(_SongLibraryEntry entry) {
    var score = 0;
    if ((entry.song.imageUrl ?? '').trim().isNotEmpty) score += 2;
    if ((entry.song.artist ?? '').trim().isNotEmpty) score += 1;
    if ((entry.song.album ?? '').trim().isNotEmpty) score += 1;
    if ((entry.song.streamUrl ?? '').trim().isNotEmpty) score += 1;
    return score;
  }

  void _putBestSong(
    Map<String, _SongLibraryEntry> target,
    String key,
    _SongLibraryEntry incoming,
  ) {
    final existing = target[key];
    if (existing == null) {
      target[key] = incoming;
      return;
    }

    final existingScore = _songQualityScore(existing);
    final incomingScore = _songQualityScore(incoming);
    if (incomingScore > existingScore) {
      target[key] = incoming;
      return;
    }

    if (incoming.recentlyPlayedAt > existing.recentlyPlayedAt) {
      target[key] = existing.copyWith(
        recentlyPlayedAt: incoming.recentlyPlayedAt,
      );
    } else if (incoming.recentlyAddedAt > existing.recentlyAddedAt) {
      target[key] = existing.copyWith(
        recentlyAddedAt: incoming.recentlyAddedAt,
      );
    }
  }

  int _albumQualityScore(Album album) {
    var score = 0;
    if ((album.imageUrl ?? '').trim().isNotEmpty) score += 2;
    if ((album.artist ?? '').trim().isNotEmpty) score += 1;
    if ((album.language ?? '').trim().isNotEmpty) score += 1;
    if ((album.songCount ?? 0) > 0) score += 1;
    return score;
  }

  void _putBestAlbum(Map<String, Album> target, String key, Album incoming) {
    final existing = target[key];
    if (existing == null) {
      target[key] = incoming;
      return;
    }

    final existingScore = _albumQualityScore(existing);
    final incomingScore = _albumQualityScore(incoming);
    if (incomingScore > existingScore) {
      target[key] = incoming;
    }
  }

  List<_SongLibraryEntry> _sortedSongs() {
    final output = List<_SongLibraryEntry>.from(_songs);
    switch (_sortOption) {
      case _SongSortOption.az:
        output.sort(
          (a, b) =>
              a.song.name.toLowerCase().compareTo(b.song.name.toLowerCase()),
        );
        break;
      case _SongSortOption.recentlyPlayed:
        output.sort((a, b) {
          final played = b.recentlyPlayedAt.compareTo(a.recentlyPlayedAt);
          if (played != 0) return played;
          final added = b.recentlyAddedAt.compareTo(a.recentlyAddedAt);
          if (added != 0) return added;
          return a.song.name.toLowerCase().compareTo(b.song.name.toLowerCase());
        });
        break;
      case _SongSortOption.recentlyAdded:
        output.sort((a, b) {
          final added = b.recentlyAddedAt.compareTo(a.recentlyAddedAt);
          if (added != 0) return added;
          return a.song.name.toLowerCase().compareTo(b.song.name.toLowerCase());
        });
        break;
    }
    return output;
  }

  List<Album> _sortedAlbums() {
    final output = List<Album>.from(_albums);
    output.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return output;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final playlistProvider = context.watch<PlaylistProvider>();
    final sortedSongs = _sortedSongs();
    final sortedAlbums = _sortedAlbums();
    final userPlaylists = playlistProvider.playlists;

    return Drawer(
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                child: Row(
                  children: [
                    const Text(
                      'Library',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: _loadLibrary,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (player.isOffline)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Text(
                    'Offline mode: showing downloaded songs and albums only.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.accentPurple,
                        ),
                      )
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadLibrary,
                        color: AppTheme.accentPurple,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          children: [
                            _sectionHeader('Songs', Icons.music_note_rounded),
                            Row(
                              children: [
                                const Text(
                                  'Sort:',
                                  style: TextStyle(
                                    color: AppTheme.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                DropdownButton<_SongSortOption>(
                                  value: _sortOption,
                                  dropdownColor: AppTheme.cardDark,
                                  underline: const SizedBox.shrink(),
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: _SongSortOption.az,
                                      child: Text('A-Z'),
                                    ),
                                    DropdownMenuItem(
                                      value: _SongSortOption.recentlyPlayed,
                                      child: Text('Recently Played'),
                                    ),
                                    DropdownMenuItem(
                                      value: _SongSortOption.recentlyAdded,
                                      child: Text('Recently Added'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => _sortOption = value);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (sortedSongs.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No songs found.',
                                  style: TextStyle(color: AppTheme.textMuted),
                                ),
                              )
                            else
                              ...List.generate(sortedSongs.length, (index) {
                                final entry = sortedSongs[index];
                                final song = entry.song;
                                final isPlaying =
                                    player.currentSong?.id == song.id;
                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  tileColor: isPlaying
                                      ? AppTheme.accentPurple.withValues(
                                          alpha: 0.18,
                                        )
                                      : AppTheme.surfaceDark.withValues(
                                          alpha: 0.55,
                                        ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  leading: _songArtwork(song),
                                  title: Text(
                                    song.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    (song.artist ?? '').trim().isEmpty
                                        ? 'Unknown Artist'
                                        : song.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isPlaying
                                            ? Icons.equalizer_rounded
                                            : Icons.play_arrow_rounded,
                                        color: isPlaying
                                            ? AppTheme.accentPurple
                                            : AppTheme.textMuted,
                                      ),
                                      PopupMenuButton<String>(
                                        icon: const Icon(
                                          Icons.more_vert_rounded,
                                          color: AppTheme.textMuted,
                                        ),
                                        color: AppTheme.cardDark,
                                        onSelected: (value) async {
                                          if (value != 'add_to_playlist') {
                                            return;
                                          }
                                          await _showAddSongToPlaylistSheet(
                                            song,
                                          );
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'add_to_playlist',
                                            child: Text('Add to Playlist'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    final playlist = sortedSongs
                                        .map((e) => e.song)
                                        .toList(growable: false);
                                    Navigator.pop(context);
                                    await player.play(
                                      song,
                                      playlist: playlist,
                                      index: index,
                                    );
                                  },
                                );
                              }),
                            const SizedBox(height: 20),
                            _sectionHeader('Albums', Icons.album_rounded),
                            const SizedBox(height: 4),
                            if (sortedAlbums.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No albums found.',
                                  style: TextStyle(color: AppTheme.textMuted),
                                ),
                              )
                            else
                              ...sortedAlbums.map((album) {
                                final subtitle = [
                                  if ((album.artist ?? '').trim().isNotEmpty)
                                    album.artist!,
                                  if ((album.songCount ?? 0) > 0)
                                    '${album.songCount} songs',
                                ].join(' - ');

                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  tileColor: AppTheme.surfaceDark.withValues(
                                    alpha: 0.55,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  leading: _albumArtwork(album),
                                  title: Text(
                                    album.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    subtitle.isEmpty ? 'Album' : subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                    color: AppTheme.textMuted,
                                  ),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    if (!mounted) return;
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            AlbumDetailScreen(album: album),
                                      ),
                                    );
                                  },
                                );
                              }),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                _sectionHeader(
                                  'Playlists',
                                  Icons.queue_music_rounded,
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  onPressed: () async {
                                    final name = await _promptPlaylistName();
                                    if (name == null) return;
                                    await context
                                        .read<PlaylistProvider>()
                                        .createPlaylist(name);
                                  },
                                  icon: const Icon(Icons.add_rounded, size: 16),
                                  label: const Text('New'),
                                ),
                              ],
                            ),
                            if (playlistProvider.loading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: LinearProgressIndicator(
                                  minHeight: 2,
                                  color: AppTheme.accentPurple,
                                  backgroundColor: Colors.transparent,
                                ),
                              )
                            else if (userPlaylists.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No playlists yet.',
                                  style: TextStyle(color: AppTheme.textMuted),
                                ),
                              )
                            else
                              ...userPlaylists.map((playlist) {
                                final offlineCount = playlistProvider
                                    .offlinePlayableCount(playlist);
                                final subtitle = player.isOffline
                                    ? '$offlineCount/${playlist.songs.length} available offline'
                                    : '${playlist.songs.length} songs';

                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  tileColor: AppTheme.surfaceDark.withValues(
                                    alpha: 0.55,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  leading: const Icon(
                                    Icons.queue_music_rounded,
                                    color: AppTheme.textSecondary,
                                  ),
                                  title: Text(
                                    playlist.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    icon: const Icon(
                                      Icons.more_vert_rounded,
                                      color: AppTheme.textMuted,
                                    ),
                                    color: AppTheme.cardDark,
                                    onSelected: (value) async {
                                      if (value == 'rename') {
                                        final next = await _promptPlaylistName(
                                          initialValue: playlist.name,
                                        );
                                        if (next == null) return;
                                        await context
                                            .read<PlaylistProvider>()
                                            .renamePlaylist(playlist.id, next);
                                        return;
                                      }
                                      if (value == 'delete') {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (_) => AlertDialog(
                                            backgroundColor: AppTheme.cardDark,
                                            title: const Text(
                                              'Delete playlist?',
                                            ),
                                            content: Text(
                                              'Delete "${playlist.name}" from your library?',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: const Text('Cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: const Text(
                                                  'Delete',
                                                  style: TextStyle(
                                                    color: Colors.redAccent,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await context
                                              .read<PlaylistProvider>()
                                              .deletePlaylist(playlist.id);
                                        }
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: Text('Rename'),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete'),
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    if (!mounted) return;
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PlaylistDetailScreen(
                                          playlistId: playlist.id,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _songArtwork(Song song) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 36,
        child: OfflineArtwork(
          songId: song.id,
          imageUrl: song.imageUrl,
          fit: BoxFit.cover,
          placeholder: Container(
            color: AppTheme.cardDark,
            alignment: Alignment.center,
            child: const Icon(
              Icons.music_note_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
          errorWidget: Container(
            color: AppTheme.cardDark,
            alignment: Alignment.center,
            child: const Icon(
              Icons.music_note_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  Widget _albumArtwork(Album album) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 36,
        child: OfflineArtwork(
          albumId: album.id,
          imageUrl: album.imageUrl,
          fit: BoxFit.cover,
          placeholder: Container(
            color: AppTheme.cardDark,
            alignment: Alignment.center,
            child: const Icon(
              Icons.album_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
          errorWidget: Container(
            color: AppTheme.cardDark,
            alignment: Alignment.center,
            child: const Icon(
              Icons.album_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.accentPurple, size: 17),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SongLibraryEntry {
  final Song song;
  final int recentlyPlayedAt;
  final int recentlyAddedAt;
  final int sourceRank;

  const _SongLibraryEntry({
    required this.song,
    required this.recentlyPlayedAt,
    required this.recentlyAddedAt,
    required this.sourceRank,
  });

  _SongLibraryEntry copyWith({int? recentlyPlayedAt, int? recentlyAddedAt}) {
    return _SongLibraryEntry(
      song: song,
      recentlyPlayedAt: recentlyPlayedAt ?? this.recentlyPlayedAt,
      recentlyAddedAt: recentlyAddedAt ?? this.recentlyAddedAt,
      sourceRank: sourceRank,
    );
  }
}
