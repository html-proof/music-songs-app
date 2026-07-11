import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/download_provider.dart';
import '../services/download_service.dart';
import '../models/song.dart';
import '../models/user_playlist.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/offline_artwork.dart';
import 'playlist_import_screen.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  bool _dialogShown = false;

  @override
  Widget build(BuildContext context) {
    final playlistId = widget.playlistId;
    final playlists = context.watch<PlaylistProvider>();
    final player = context.watch<PlayerProvider>();
    final downloadProvider = context.watch<DownloadProvider>();
    final playlist = playlists.getById(playlistId);

    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playlist')),
        body: const Center(
          child: Text(
            'Playlist not found.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      );
    }

    final progress = downloadProvider.playlistProgress;
    if (progress != null && progress.playlistId == playlist.id) {
      if (progress.isCompleted) {
        if (!_dialogShown) {
          _dialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showCompletionDialog(context, progress, downloadProvider);
          });
        }
      } else {
        _dialogShown = false;
      }
    }

    final playableSongs = playlists.buildPlayableSongs(
      playlist,
      offlineOnly: player.isOffline,
    );
    final offlineAvailable = playlists.offlinePlayableCount(playlist);
    final cover = _playlistCover(playlist);
    final isPlaylistDownloaded = playlist.songs.isNotEmpty &&
        playlist.songs.every((s) => downloadProvider.isDownloaded(s.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_rounded),
            onPressed: () => _editMetadata(context, playlist),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) async {
              if (value == 'delete') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppTheme.cardDark,
                    title: const Text('Delete playlist?'),
                    content: Text(
                      'This will remove "${playlist.name}" from your library.',
                    ),
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
                if (confirmed != true) return;
                await context.read<PlaylistProvider>().deletePlaylist(
                  playlist.id,
                );
                if (context.mounted) {
                  Navigator.pop(context);
                }
              } else if (value == 'import') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlaylistImportScreen(
                      targetPlaylistId: playlist.id,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.file_download_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Import songs'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded,
                        size: 20, color: Colors.redAccent),
                    SizedBox(width: 10),
                    Text('Delete', style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: OfflineArtwork(
                          playlistId: playlist.id,
                          imageUrl: cover,
                          fit: BoxFit.cover,
                          placeholder: Container(
                            color: AppTheme.cardDark,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.queue_music_rounded,
                              color: AppTheme.textMuted,
                              size: 28,
                            ),
                          ),
                          errorWidget: Container(
                            color: AppTheme.cardDark,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.queue_music_rounded,
                              color: AppTheme.textMuted,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playlist.name,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${playlist.songs.length} songs · ${_formatDuration(playlist.totalDurationSeconds)}',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                player.isOffline
                                    ? '$offlineAvailable available offline'
                                    : '$offlineAvailable cached for offline',
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              if (isPlaylistDownloaded) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppTheme.accentPurple,
                                  size: 13,
                                ),
                                const SizedBox(width: 4),
                                const Text(
                                  'Available Offline',
                                  style: TextStyle(
                                    color: AppTheme.accentPurple,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if ((playlist.description ?? '').trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                playlist.description!.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: playableSongs.isEmpty
                                ? null
                                : () => _playFromPlaylist(
                                    context,
                                    player: player,
                                    queue: playableSongs,
                                    startSong: playableSongs.first,
                                  ),
                            icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                            label: Text(player.isOffline ? 'Play Offline' : 'Play', style: const TextStyle(fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentPurple,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: playableSongs.isEmpty
                                ? null
                                : () async {
                                    if (!player.shuffleModeEnabled) {
                                      await player.toggleShuffleMode();
                                    }
                                    final randomIndex = Random().nextInt(playableSongs.length);
                                    final startSong = playableSongs[randomIndex];
                                    _playFromPlaylist(
                                      context,
                                      player: player,
                                      queue: playableSongs,
                                      startSong: startSong,
                                    );
                                  },
                            icon: const Icon(Icons.shuffle_rounded, color: AppTheme.accentPurple, size: 18),
                            label: const Text('Shuffle', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: AppTheme.accentPurple, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildDownloadPlaylistButton(context, playlist, downloadProvider),
                        const Spacer(),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: playlist.songs.isEmpty
                    ? const Center(
                        child: Text(
                          'No songs in this playlist yet.',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: playlist.songs.length,
                        onReorder: (oldIndex, newIndex) async {
                          final ids = playlist.songs
                              .map((song) => song.id)
                              .toList(growable: true);
                          if (oldIndex < newIndex) {
                            newIndex -= 1;
                          }
                          final moved = ids.removeAt(oldIndex);
                          ids.insert(newIndex, moved);
                          await context
                              .read<PlaylistProvider>()
                              .reorderPlaylistSongs(playlist.id, ids);
                        },
                        itemBuilder: (_, index) {
                          final song = playlist.songs[index];
                          final isPlaying = player.currentSong?.id == song.id;
                          final isPlayableNow = playlists
                              .buildPlayableSongs(
                                playlist.copyWith(songs: [song]),
                                offlineOnly: player.isOffline,
                              )
                              .isNotEmpty;

                          return Container(
                            key: ValueKey('pl-${playlist.id}-${song.id}'),
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: isPlaying
                                  ? AppTheme.accentPurple.withValues(
                                      alpha: 0.16,
                                    )
                                  : AppTheme.surfaceDark.withValues(
                                      alpha: 0.55,
                                    ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              enabled: isPlayableNow,
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      color: AppTheme.textMuted.withValues(
                                        alpha: 0.9,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: OfflineArtwork(
                                      songId: song.id,
                                      imageUrl: song.imageUrl,
                                      width: 36,
                                      height: 36,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ],
                              ),
                              title: Text(
                                song.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isPlaying
                                      ? AppTheme.accentPurple
                                      : AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Row(
                                children: [
                                  if (downloadProvider.isDownloaded(song.id))
                                    const Padding(
                                      padding: EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Icons.check_circle_rounded,
                                        color: AppTheme.accentPurple,
                                        size: 13,
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      _subtitle(
                                        song: song,
                                        isPlayableNow: isPlayableNow,
                                        offlineMode: player.isOffline,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isPlayableNow
                                        ? Icons.play_arrow_rounded
                                        : Icons.cloud_off_rounded,
                                    color: isPlayableNow
                                        ? AppTheme.textMuted
                                        : Colors.orangeAccent,
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.remove_circle_outline_rounded,
                                      color: Colors.redAccent,
                                    ),
                                    tooltip: 'Remove from playlist',
                                    onPressed: () {
                                      context
                                          .read<PlaylistProvider>()
                                          .removeSongFromPlaylist(
                                            playlist.id,
                                            song.id,
                                          );
                                    },
                                  ),
                                ],
                              ),
                              onTap: () {
                                final queue = playlists.buildPlayableSongs(
                                  playlist,
                                  offlineOnly: player.isOffline,
                                );
                                if (queue.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        player.isOffline
                                            ? 'No offline songs available in this playlist.'
                                            : 'No playable songs available in this playlist.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                _playFromPlaylist(
                                  context,
                                  player: player,
                                  queue: queue,
                                  startSong: song,
                                );
                              },
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

  Future<void> _editMetadata(
    BuildContext context,
    UserPlaylist playlist,
  ) async {
    final form = await _showEditDialog(context, playlist);
    if (form == null) return;

    final provider = context.read<PlaylistProvider>();
    await provider.updatePlaylistMetadata(
      playlist.id,
      name: form.name,
      description: form.description,
      coverImageUrl: form.coverImageUrl,
    );
  }

  Future<_PlaylistFormValue?> _showEditDialog(
    BuildContext context,
    UserPlaylist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    final descriptionController = TextEditingController(
      text: playlist.description ?? '',
    );
    final coverController = TextEditingController(
      text: playlist.coverImageUrl ?? '',
    );

    return showDialog<_PlaylistFormValue>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Edit Playlist'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                maxLength: 40,
                decoration: const InputDecoration(
                  hintText: 'Playlist name',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descriptionController,
                maxLength: 120,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Description (optional)',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: coverController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'Cover image URL (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                Navigator.pop(dialogContext);
                return;
              }
              Navigator.pop(
                dialogContext,
                _PlaylistFormValue(
                  name: name,
                  description: descriptionController.text.trim(),
                  coverImageUrl: coverController.text.trim(),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String? _playlistCover(UserPlaylist playlist) {
    final custom = (playlist.coverImageUrl ?? '').trim();
    if (custom.isNotEmpty) return custom;
    for (final song in playlist.songs) {
      final image = (song.imageUrl ?? '').trim();
      if (image.isNotEmpty) return image;
    }
    return null;
  }

  String _subtitle({
    required Song song,
    required bool isPlayableNow,
    required bool offlineMode,
  }) {
    final artist = (song.artist ?? '').trim().isEmpty
        ? 'Unknown Artist'
        : song.artist!.trim();
    if (!offlineMode) return artist;
    if (isPlayableNow) return '$artist - Offline ready';
    return '$artist - Not downloaded';
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0m';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    return '${seconds}s';
  }

  Future<void> _playFromPlaylist(
    BuildContext context, {
    required PlayerProvider player,
    required List<Song> queue,
    required Song startSong,
  }) async {
    if (queue.isEmpty) return;
    final index = queue.indexWhere((song) => song.id == startSong.id);
    final start = index < 0 ? 0 : index;
    await player.play(queue[start], playlist: queue, index: start);
  }

  void _showCompletionDialog(
    BuildContext context,
    PlaylistDownloadProgress progress,
    DownloadProvider downloadProvider,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: AppTheme.accentPurple),
            SizedBox(width: 10),
            Text(
              'Download Complete',
              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '"${progress.playlistName}" playlist download finished.',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 16),
            _summaryRow(Icons.file_download_outlined, 'Downloaded', progress.downloadedCount),
            _summaryRow(Icons.youtube_searched_for_rounded, 'Recovered by Search', progress.recoveredCount),
            _summaryRow(Icons.check_rounded, 'Already Downloaded', progress.alreadyDownloadedCount),
            _summaryRow(Icons.error_outline_rounded, 'Failed', progress.failedCount, isError: progress.failedCount > 0),
          ],
        ),
        actions: [
          if (progress.failedCount > 0)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                downloadProvider.clearPlaylistProgress();
                downloadProvider.downloadPlaylist(
                  progress.playlistId,
                  progress.playlistName,
                  progress.failedSongs,
                );
              },
              child: const Text('Retry Failed Songs', style: TextStyle(color: AppTheme.accentPurple)),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              downloadProvider.clearPlaylistProgress();
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, int count, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: isError ? Colors.redAccent : AppTheme.textMuted),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13.5)),
          const Spacer(),
          Text(
            '$count',
            style: TextStyle(
              color: isError ? Colors.redAccent : AppTheme.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadPlaylistButton(
    BuildContext context,
    UserPlaylist playlist,
    DownloadProvider downloadProvider,
  ) {
    if (playlist.songs.isEmpty) return const SizedBox.shrink();

    final isPlaylistDownloaded = playlist.songs.isNotEmpty &&
        playlist.songs.every((s) => downloadProvider.isDownloaded(s.id));
    final progress = downloadProvider.playlistProgress;
    final isPlaylistDownloading = progress != null &&
        progress.playlistId == playlist.id &&
        !progress.isCompleted &&
        !progress.isCancelled;

    if (isPlaylistDownloaded) {
      return TextButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check_circle_rounded, color: AppTheme.accentPurple, size: 20),
        label: const Text(
          'Downloaded',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      );
    }

    if (isPlaylistDownloading) {
      final progressPct = (progress.progress * 100).toInt();
      return TextButton.icon(
        onPressed: () {
          downloadProvider.cancelPlaylistDownload();
        },
        icon: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.accentPurple,
          ),
        ),
        label: Text(
          'Downloading... $progressPct%',
          style: const TextStyle(
            color: AppTheme.accentPurple,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      );
    }

    final failedCount = playlist.songs.where((s) => !downloadProvider.isDownloaded(s.id)).length;
    final labelText = failedCount < playlist.songs.length && failedCount > 0
        ? 'Download Missing ($failedCount)'
        : 'Download Playlist';

    return TextButton.icon(
      onPressed: () {
        downloadProvider.downloadPlaylist(
          playlist.id,
          playlist.name,
          playlist.songs,
        );
      },
      icon: const Icon(Icons.arrow_circle_down_rounded, color: AppTheme.textSecondary, size: 20),
      label: Text(
        labelText,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontWeight: FontWeight.bold,
          fontSize: 13.5,
        ),
      ),
    );
  }
}

class _PlaylistFormValue {
  final String name;
  final String description;
  final String coverImageUrl;

  const _PlaylistFormValue({
    required this.name,
    required this.description,
    required this.coverImageUrl,
  });
}
