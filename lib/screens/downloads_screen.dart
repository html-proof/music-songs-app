import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/download_provider.dart';
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/offline_artwork.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounce;

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _searchQuery = query.trim().toLowerCase();
        });
      }
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ...
  Future<void> _confirmDelete(
    BuildContext context,
    String songId,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Delete Download'),
        content: Text(
          'Are you sure you want to delete "$name" from your device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!context.mounted) return;
      context.read<DownloadProvider>().delete(songId);
    }
  }

  void _showSongMenu(
    BuildContext context,
    Song song,
    DownloadProvider downloads,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              song.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title: const Text(
                'Delete Download',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, song.id, song.name);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadProvider>();
    final player = context.watch<PlayerProvider>();

    final allSongs = downloads.downloadedSongs;
    final filteredSongs = allSongs.where((song) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery;
      return song.name.toLowerCase().contains(query) ||
          (song.artist ?? '').toLowerCase().contains(query) ||
          (song.album ?? '').toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              // App Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Downloads',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    // Smart Download Toggle
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: AppTheme.accentPurple,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Smart',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        Switch(
                          value: downloads.smartDownloadEnabled,
                          onChanged: (_) => downloads.toggleSmartDownload(),
                          activeThumbColor: AppTheme.accentPurple,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Storage info
              FutureBuilder<int>(
                future: DownloadService.getTotalSize(),
                builder: (context, snapshot) {
                  final size = snapshot.data ?? 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.storage,
                          color: AppTheme.textMuted,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${allSongs.length} songs • ${_formatSize(size)}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        if (downloads.smartDownloadEnabled)
                          TextButton.icon(
                            icon: const Icon(Icons.download_rounded, size: 16),
                            label: const Text('Smart Download'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppTheme.accentPurple,
                            ),
                            onPressed: () => downloads.smartDownload(),
                          ),
                      ],
                    ),
                  );
                },
              ),

              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search offline songs...',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    prefixIcon: const Icon(
                      Icons.search,
                      color: AppTheme.textMuted,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              color: AppTheme.textMuted,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.surfaceDark.withValues(alpha: 0.5),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),

              // Downloaded Songs
              Expanded(
                child: allSongs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.download_done_rounded,
                              size: 64,
                              color: AppTheme.textMuted,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No downloads yet',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              downloads.smartDownloadEnabled
                                  ? 'Smart Download will auto-cache your favorites'
                                  : 'Tap the download icon on any song',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : filteredSongs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.search_off_rounded,
                              size: 64,
                              color: AppTheme.textMuted,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No results for "$_searchQuery"',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Try a different name or artist',
                              style: TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: filteredSongs.length,
                        itemBuilder: (context, index) {
                          final song = filteredSongs[index];
                          return Dismissible(
                            key: Key(song.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              color: Colors.red.withValues(alpha: 0.2),
                              child: const Icon(
                                Icons.delete_rounded,
                                color: Colors.red,
                              ),
                            ),
                            confirmDismiss: (_) async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppTheme.cardDark,
                                  title: const Text('Delete Download'),
                                  content: Text(
                                    'Are you sure you want to delete "${song.name}" from your device?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.red,
                                      ),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              return confirmed ?? false;
                            },
                            onDismissed: (_) {
                              downloads.delete(song.id);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('"${song.name}" deleted.'),
                                ),
                              );
                            },
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 4,
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: OfflineArtwork(
                                  songId: song.id,
                                  imageUrl: song.imageUrl,
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              title: Text(
                                song.name,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                song.artist ?? 'Unknown',
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.download_done,
                                    color: Colors.green,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: AppTheme.accentPurple,
                                    ),
                                    onPressed: () async {
                                      final localPath = await downloads
                                          .getLocalPath(song.id);
                                      if (!context.mounted) return;
                                      if (localPath == null ||
                                          localPath.trim().isEmpty) {
                                        DownloadService.showDownloadFailureToast(
                                          'Failed to save. Please reconnect the internet.',
                                        );
                                        await downloads.delete(song.id);
                                        return;
                                      }

                                      final offlineSong = song.copyWith(
                                        streamUrl: localPath,
                                      );
                                      player.play(
                                        offlineSong,
                                        playlist: filteredSongs,
                                        index: index,
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.more_vert_rounded,
                                      color: AppTheme.textMuted,
                                    ),
                                    onPressed: () =>
                                        _showSongMenu(context, song, downloads),
                                  ),
                                ],
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
