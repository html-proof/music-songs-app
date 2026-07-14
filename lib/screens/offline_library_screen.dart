import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../widgets/offline_artwork.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../models/user_playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/download_provider.dart';
import '../services/offline_service.dart';
import '../services/player_service.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../utils/content_filter.dart';
import 'playlist_detail_screen.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key});

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<OfflineSongRecord> _allOfflineSongs = [];
  bool _isLoading = true;
  bool? _lastOfflineState;
  String? _resumeHandledUid;
  bool _resumeCheckInProgress = false;
  Timer? _searchDebounce;
  String _searchQuery = '';

  List<OfflineSongRecord> get _visibleOfflineSongs {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _allOfflineSongs;
    return _allOfflineSongs
        .where((record) => _matchesSongQuery(record.song, query))
        .toList(growable: false);
  }

  List<Song> _playlistFor(List<OfflineSongRecord> records) =>
      records.map((record) => record.song).toList(growable: false);

  Map<String, List<OfflineSongRecord>> get _groupedByArtist {
    final Map<String, List<OfflineSongRecord>> map = {};
    for (final record in _visibleOfflineSongs) {
      final artist = record.song.artist?.trim() ?? 'Unknown Artist';
      final name = artist.isEmpty ? 'Unknown Artist' : artist;
      map.putIfAbsent(name, () => []).add(record);
    }
    return map;
  }

  Map<String, List<OfflineSongRecord>> get _groupedByAlbum {
    final Map<String, List<OfflineSongRecord>> map = {};
    for (final record in _visibleOfflineSongs) {
      final album = record.song.album?.trim() ?? 'Single';
      final name = album.isEmpty ? 'Single' : album;
      map.putIfAbsent(name, () => []).add(record);
    }
    return map;
  }

  @override
  void initState() {
    super.initState();
    _loadOfflineData();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadOfflineData() async {
    final cached = await OfflineService.getOfflineSongRecords();
    final manualSongs = await DownloadService.getDownloadedSongs();

    final manualRecords = manualSongs.map((song) {
      return OfflineSongRecord(
        song: song,
        audioPath: song.streamUrl ?? '',
        imagePath: null,
        imageUrl: song.imageUrl,
        albumId: song.albumId,
        fullyDownloaded: true,
        quality: 'high',
        cachedAt: DateTime.now().millisecondsSinceEpoch,
        lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
        listenedMs: 0,
        durationMs: (song.duration ?? 0) * 1000,
      );
    }).toList();

    final seenIds = <String>{};
    final allRecords = <OfflineSongRecord>[];

    for (final record in [...manualRecords, ...cached]) {
      final id = record.song.id.trim();
      if (id.isNotEmpty && !seenIds.contains(id)) {
        seenIds.add(id);
        allRecords.add(record);
      }
    }

    final filteredSongs = allRecords
        .where((record) => ContentFilter.isAllowedSongTitle(record.song.name))
        .toList(growable: false);

    if (mounted) {
      setState(() {
        _allOfflineSongs = filteredSongs;
        _isLoading = false;
      });
    }
  }

  void _onSearchChanged(String query) {
    if (mounted) {
      setState(() {});
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = query.trim();
      });
    });
  }

  bool _matchesSongQuery(Song song, String query) {
    final normalized = query.toLowerCase();
    return song.name.toLowerCase().contains(normalized) ||
        (song.artist ?? '').toLowerCase().contains(normalized) ||
        (song.album ?? '').toLowerCase().contains(normalized);
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _showToast(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }

  Future<void> _stopPlaybackIfDeletingSongs(Set<String> songIds) async {
    final currentSongId = (context.read<PlayerProvider>().currentSong?.id ?? '')
        .trim();
    if (currentSongId.isEmpty || !songIds.contains(currentSongId)) return;
    await PlayerService.stop();
  }

  Future<void> _stopPlaybackIfClearingOfflineLibrary() async {
    final currentSong = context.read<PlayerProvider>().currentSong;
    final currentPath = (currentSong?.streamUrl ?? '').trim();
    if (currentSong == null || currentPath.isEmpty) return;
    if (!currentPath.startsWith('/') &&
        !currentPath.startsWith('file://') &&
        !RegExp(r'^[A-Za-z]:\\').hasMatch(currentPath)) {
      return;
    }
    await PlayerService.stop();
  }

  void _removeSongFromLocalState(String songId) {
    final normalizedId = songId.trim();
    _allOfflineSongs = _allOfflineSongs
        .where((record) => record.song.id != normalizedId)
        .toList(growable: false);
  }

  Future<void> _deleteOfflineSong(OfflineSongRecord record) async {
    final confirmed = await _confirmDelete(
      title: 'Delete Song',
      message: 'Remove "${record.song.name}" from offline storage?',
    );
    if (!confirmed) return;

    await _stopPlaybackIfDeletingSongs(<String>{record.song.id.trim()});
    await OfflineService.deleteSong(record.song.id);
    if (!mounted) return;

    setState(() {
      _removeSongFromLocalState(record.song.id);
    });
    _showToast('Song deleted');
  }

  void _maybeHandlePlaybackResume(AuthProvider auth) {
    final uid = auth.user?.uid;
    if (uid == null || uid.isEmpty) {
      _resumeHandledUid = null;
      _resumeCheckInProgress = false;
      return;
    }
    if (_resumeHandledUid == uid || _resumeCheckInProgress) return;

    _resumeHandledUid = uid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handlePendingPlaybackResume(uid);
    });
  }

  Future<void> _handlePendingPlaybackResume(String uid) async {
    if (_resumeCheckInProgress) return;
    _resumeCheckInProgress = true;
    try {
      // Silently restore — the song loads paused at the saved position.
      final result = await PlayerService.resumePendingPlaybackAfterLogin();
      if (!mounted || _resumeHandledUid != uid) return;

      if (result == PlaybackResumeResult.offlineSongUnavailable) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'This song is not downloaded. Connect to internet to resume it.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      _resumeCheckInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final player = context.read<PlayerProvider>();
    final isOffline = context.select<PlayerProvider, bool>((p) => p.isOffline);
    final playlistsProvider = context.watch<PlaylistProvider>();
    
    final visibleSongs = _visibleOfflineSongs;
    final visiblePlaylist = _playlistFor(visibleSongs);
    _maybeHandlePlaybackResume(auth);

    if (_lastOfflineState != isOffline) {
      _lastOfflineState = isOffline;
    }

    final allPlaylists = playlistsProvider.playlists;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Offline Library'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: () async {
                final confirm = await _confirmDelete(
                  title: 'Clear Cache?',
                  message: 'This will delete all offline songs.',
                );
                if (confirm == true) {
                  await _stopPlaybackIfClearingOfflineLibrary();
                  await OfflineService.clearCache();
                  if (!mounted) return;
                  setState(() {
                    _allOfflineSongs = [];
                  });
                  _showToast('Offline library cleared');
                }
              },
            ),
          ],
          bottom: const TabBar(
            isScrollable: false,
            indicatorColor: AppTheme.accentPurple,
            labelColor: AppTheme.accentPurple,
            unselectedLabelColor: AppTheme.textMuted,
            tabs: [
              Tab(text: 'Songs'),
              Tab(text: 'Artists'),
              Tab(text: 'Albums'),
              Tab(text: 'Playlists'),
            ],
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
          child: SafeArea(
            child: Column(
              children: [
                if (isOffline)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    color: Colors.orangeAccent.withValues(alpha: 0.8),
                    child: const Text(
                      "You're offline. Playing downloaded music.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Search offline library...',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppTheme.textMuted,
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear_rounded,
                                color: AppTheme.textMuted,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('');
                                setState(() {});
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: AppTheme.surfaceDark.withValues(alpha: 0.55),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.accentPurple,
                          ),
                        )
                      : TabBarView(
                          children: [
                            _buildSongsTab(player, visibleSongs, visiblePlaylist),
                            _buildArtistsTab(),
                            _buildAlbumsTab(),
                            _buildPlaylistsTab(context, allPlaylists),
                          ],
                        ),
                ),
                const MiniPlayer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSongsTab(
    PlayerProvider player,
    List<OfflineSongRecord> visibleSongs,
    List<Song> visiblePlaylist,
  ) {
    if (_allOfflineSongs.isEmpty) {
      return _buildEmptyState();
    }
    if (visibleSongs.isEmpty) {
      return _buildNoResultsState();
    }
    return RefreshIndicator(
      onRefresh: _loadOfflineData,
      color: AppTheme.accentPurple,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        itemCount: visibleSongs.length + 1, // +1 for summary
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildSummaryCard(
              songCount: visibleSongs.length,
            );
          }
          final songIndex = index - 1;
          final record = visibleSongs[songIndex];
          return _buildOfflineSongTile(
            player: player,
            record: record,
            playlistIndex: songIndex,
            playlist: visiblePlaylist,
          );
        },
      ),
    );
  }

  Widget _buildArtistsTab() {
    final artists = _groupedByArtist;
    if (_allOfflineSongs.isEmpty) {
      return _buildEmptyState();
    }
    if (artists.isEmpty) {
      return _buildNoResultsState();
    }
    final artistNames = artists.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: artistNames.length,
      itemBuilder: (context, index) {
        final artistName = artistNames[index];
        final records = artists[artistName]!;
        final songCount = records.length;
        final firstRecord = records.first;

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: CircleAvatar(
            backgroundColor: AppTheme.cardDark,
            radius: 24,
            child: ClipOval(
              child: _OfflineArtwork(
                songId: firstRecord.song.id,
                imagePath: firstRecord.imagePath,
                imageUrl: firstRecord.imageUrl,
                size: 48,
              ),
            ),
          ),
          title: Text(
            artistName,
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            '$songCount ${songCount == 1 ? 'song' : 'songs'} offline',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OfflineDrillDownScreen(
                  title: artistName,
                  songs: records,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAlbumsTab() {
    final albums = _groupedByAlbum;
    if (_allOfflineSongs.isEmpty) {
      return _buildEmptyState();
    }
    if (albums.isEmpty) {
      return _buildNoResultsState();
    }
    final albumNames = albums.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: albumNames.length,
      itemBuilder: (context, index) {
        final albumName = albumNames[index];
        final records = albums[albumName]!;
        final songCount = records.length;
        final firstRecord = records.first;
        final artistName = firstRecord.song.artist ?? 'Unknown Artist';

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _OfflineArtwork(
              songId: firstRecord.song.id,
              imagePath: firstRecord.imagePath,
              imageUrl: firstRecord.imageUrl,
              size: 48,
            ),
          ),
          title: Text(
            albumName,
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            '$artistName • $songCount ${songCount == 1 ? 'song' : 'songs'}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OfflineDrillDownScreen(
                  title: albumName,
                  songs: records,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlaylistsTab(BuildContext context, List<UserPlaylist> playlists) {
    final playlistsProvider = context.read<PlaylistProvider>();
    final downloadProvider = context.read<DownloadProvider>();
    final player = context.read<PlayerProvider>();

    if (playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.playlist_play_rounded, size: 64, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text(
              'No playlists found',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Playlists you create or import will appear here.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        final songCount = playlist.songs.length;
        final offlineCount = playlistsProvider.offlinePlayableCount(playlist);

        String? coverUrl;
        if ((playlist.coverImageUrl ?? '').trim().isNotEmpty) {
          coverUrl = playlist.coverImageUrl!.trim();
        } else {
          for (final song in playlist.songs) {
            if ((song.imageUrl ?? '').trim().isNotEmpty) {
              coverUrl = song.imageUrl!.trim();
              break;
            }
          }
        }

        final subtitleText = offlineCount == songCount
            ? '$songCount ${songCount == 1 ? 'song' : 'songs'} offline'
            : '$offlineCount of $songCount songs offline';

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: OfflineArtwork(
              playlistId: playlist.id,
              imageUrl: coverUrl,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              placeholder: Container(
                color: AppTheme.cardDark,
                child: const Icon(Icons.music_note, color: AppTheme.textMuted),
              ),
              errorWidget: Container(
                color: AppTheme.cardDark,
                child: const Icon(Icons.music_note, color: AppTheme.textMuted),
              ),
            ),
          ),
          title: Text(
            playlist.name,
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            subtitleText,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
            color: AppTheme.cardDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) async {
              switch (value) {
                case 'play':
                  if (playlist.songs.isNotEmpty) {
                    player.play(playlist.songs.first, playlist: playlist.songs, index: 0);
                  }
                  break;
                case 'shuffle':
                  if (playlist.songs.isNotEmpty) {
                    if (!player.shuffleModeEnabled) {
                      await player.toggleShuffleMode();
                    }
                    final randomIndex = Random().nextInt(playlist.songs.length);
                    player.play(playlist.songs[randomIndex], playlist: playlist.songs, index: randomIndex);
                  }
                  break;
                case 'download':
                  if (playlist.songs.isNotEmpty) {
                    downloadProvider.downloadPlaylist(
                      playlist.id,
                      playlist.name,
                      playlist.songs,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Downloading "${playlist.name}"...'),
                        backgroundColor: AppTheme.accentPurple,
                      ),
                    );
                  }
                  break;
                case 'delete':
                  final confirmed = await _confirmDelete(
                    title: 'Delete Playlist',
                    message: 'Remove "${playlist.name}" from library?',
                  );
                  if (confirmed == true) {
                    await playlistsProvider.deletePlaylist(playlist.id);
                    _showToast('Playlist deleted');
                  }
                  break;
              }
            },
            itemBuilder: (context) {
              final hasSongs = playlist.songs.isNotEmpty;
              final isPlaylistDownloaded = hasSongs &&
                  playlist.songs.every((s) => downloadProvider.isDownloaded(s.id));
              
              return [
                PopupMenuItem(
                  value: 'play',
                  enabled: hasSongs,
                  child: const Row(
                    children: [
                      Icon(Icons.play_arrow_rounded, color: AppTheme.textPrimary, size: 20),
                      SizedBox(width: 8),
                      Text('Play'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'shuffle',
                  enabled: hasSongs,
                  child: const Row(
                    children: [
                      Icon(Icons.shuffle_rounded, color: AppTheme.textPrimary, size: 20),
                      SizedBox(width: 8),
                      Text('Shuffle'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'download',
                  enabled: hasSongs && !isPlaylistDownloaded,
                  child: Row(
                    children: [
                      Icon(
                        isPlaylistDownloaded ? Icons.check_circle_rounded : Icons.arrow_circle_down_rounded,
                        color: isPlaylistDownloaded ? AppTheme.accentPurple : AppTheme.textPrimary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(isPlaylistDownloaded ? 'Downloaded' : 'Download All'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                      SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ];
            },
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSummaryCard({required int songCount}) {
    final showingFiltered = _searchQuery.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.accentPurple.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_done_rounded, color: AppTheme.accentPurple),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              showingFiltered
                  ? '$songCount songs match your search'
                  : '$songCount songs available offline',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineSongTile({
    required PlayerProvider player,
    required OfflineSongRecord record,
    required int playlistIndex,
    required List<Song> playlist,
  }) {
    final song = record.song;
    final isCurrentSong = context.select<PlayerProvider, bool>((p) => p.currentSong?.id == song.id);
    final isPlaying = isCurrentSong && context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final subtitleParts = <String>[];
    final artist = (song.artist ?? '').trim();
    final album = (song.album ?? '').trim();

    if (artist.isNotEmpty) subtitleParts.add(artist);
    if (album.isNotEmpty) subtitleParts.add(album);
    if (subtitleParts.isEmpty) subtitleParts.add('Unknown Artist');

    return Dismissible(
      key: Key('offline_${song.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.redAccent),
      ),
      confirmDismiss: (_) async {
        return await _confirmDelete(
          title: 'Delete Song',
          message: 'Remove "${song.name}" from offline storage?',
        );
      },
      onDismissed: (_) async {
        await _stopPlaybackIfDeletingSongs(<String>{song.id.trim()});
        await OfflineService.deleteSong(song.id);
        if (!mounted) return;
        setState(() {
          _removeSongFromLocalState(song.id);
        });
        _showToast('Song deleted');
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 3, 16, 3),
        decoration: BoxDecoration(
          color: isCurrentSong
              ? AppTheme.accentPurple.withValues(alpha: 0.18)
              : AppTheme.surfaceDark.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _OfflineArtwork(
              songId: song.id,
              imagePath: record.imagePath,
              imageUrl: record.imageUrl,
              size: 46,
            ),
          ),
          title: Text(
            song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  isCurrentSong ? AppTheme.accentPurple : AppTheme.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          subtitle: Text(
            subtitleParts.join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
          ),
          onTap: () async {
            if (isCurrentSong) {
              await player.togglePlayPause();
              return;
            }
            await player.play(song, playlist: playlist, index: playlistIndex);
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isCurrentSong
                    ? (isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded)
                    : Icons.play_arrow_rounded,
                color:
                    isCurrentSong ? AppTheme.accentPurple : AppTheme.textMuted,
              ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: AppTheme.textMuted,
                ),
                color: AppTheme.cardDark,
                onSelected: (value) async {
                  if (value == 'delete_song') {
                    await _deleteOfflineSong(record);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(
                    value: 'delete_song',
                    child: Text('Delete Song'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoResultsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 72,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 16),
          Text(
            'No offline songs found for "$_searchQuery"',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Try a different song, artist, or album name.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 80,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 24),
          const Text(
            'No cached songs yet',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Play songs online and they will be saved here automatically for offline playback.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentPurple,
              shape: RoundedRectanglePlatform.borderRadius(20),
            ),
            child: const Text('Go Home'),
          ),
        ],
      ),
    );
  }
}

class _OfflineArtwork extends StatelessWidget {
  final String? songId;
  final String? imagePath;
  final String? imageUrl;
  final double size;

  const _OfflineArtwork({
    this.songId,
    this.imagePath,
    required this.imageUrl,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return OfflineArtwork(
      songId: songId,
      imageUrl: imageUrl,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: _placeholder(),
      errorWidget: _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: AppTheme.cardDark,
      child: const Icon(Icons.music_note, color: AppTheme.textMuted),
    );
  }
}

class RoundedRectanglePlatform {
  static RoundedRectangleBorder borderRadius(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
}

class OfflineDrillDownScreen extends StatelessWidget {
  final String title;
  final List<OfflineSongRecord> songs;

  const OfflineDrillDownScreen({
    super.key,
    required this.title,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final currentSongId = context.select<PlayerProvider, String?>((p) => p.currentSong?.id);
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final playlist = songs.map((record) => record.song).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final record = songs[index];
                    final song = record.song;
                    final isCurrentSong = currentSongId == song.id;
                    final isPlayingSong = isCurrentSong && isPlaying;

                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: isCurrentSong
                            ? AppTheme.accentPurple.withValues(alpha: 0.18)
                            : AppTheme.surfaceDark.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _OfflineArtwork(
                            songId: song.id,
                            imagePath: record.imagePath,
                            imageUrl: record.imageUrl,
                            size: 46,
                          ),
                        ),
                        title: Text(
                          song.name,
                          style: TextStyle(
                            color: isCurrentSong ? AppTheme.accentPurple : AppTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          song.artist ?? 'Unknown Artist',
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5),
                        ),
                        onTap: () async {
                          if (isCurrentSong) {
                            await player.togglePlayPause();
                            return;
                          }
                          await player.play(song, playlist: playlist, index: index);
                        },
                        trailing: Icon(
                          isCurrentSong
                              ? (isPlayingSong ? Icons.pause_rounded : Icons.play_arrow_rounded)
                              : Icons.play_arrow_rounded,
                          color: isCurrentSong ? AppTheme.accentPurple : AppTheme.textMuted,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        ),
      ),
    );
  }
}
