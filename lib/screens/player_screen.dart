import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../screens/album_detail_screen.dart';
import '../services/api_service.dart';
import '../services/listening_safety_service.dart';
import '../services/lyrics_manager.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_artwork.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Lyrics display state — everything else is in LyricsManager
  _LyricsDisplayMode _lyricsDisplayMode = _LyricsDisplayMode.original;
  bool _showLyrics = false;
  final ValueNotifier<double?> _scrubNotifier = ValueNotifier<double?>(null);
  final ScrollController _lyricsScrollController = ScrollController();
  int _lastScrolledLyricIndex = -1;
  int _activeLyricIndexCache = -1;
  bool _lyricsAutoScrollPausedByUser = false;
  bool _isProgrammaticLyricScroll = false;
  Timer? _programmaticLyricScrollResetTimer;
  String? _lastRequestedLyricsSongId;

  // New Notifiers for optimized rebuilds
  StreamSubscription<Duration>? _positionSubscription;
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<int> _activeLyricIndexNotifier = ValueNotifier<int>(-1);

  static const double _lyricLineExtent = 46.0;

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void initState() {
    super.initState();
    _subscribeToPosition();
    _activeLyricIndexNotifier.addListener(_onActiveLyricIndexChanged);
    _scrubNotifier.addListener(_onScrubChanged);
  }

  void _subscribeToPosition() {
    _positionSubscription = PlayerService.positionStream.listen((pos) {
      if (!mounted) return;
      _positionNotifier.value = pos;
      
      // Update active lyric index if not scrubbing
      if (_scrubNotifier.value == null) {
        final index = _activeIndexForPosition(pos);
        if (index != _activeLyricIndexNotifier.value) {
          _activeLyricIndexNotifier.value = index;
        }
      }
    });
  }

  void _onScrubChanged() {
    final scrubVal = _scrubNotifier.value;
    if (scrubVal != null) {
      final pos = Duration(milliseconds: (scrubVal * 1000).round());
      final index = _activeIndexForPosition(pos);
      if (index != _activeLyricIndexNotifier.value) {
        _activeLyricIndexNotifier.value = index;
      }
    } else {
      // Scrubbing ended, revert to current position
      final index = _activeIndexForPosition(_positionNotifier.value);
      if (index != _activeLyricIndexNotifier.value) {
        _activeLyricIndexNotifier.value = index;
      }
    }
  }

  void _onActiveLyricIndexChanged() {
    final index = _activeLyricIndexNotifier.value;
    if (index != _lastScrolledLyricIndex) {
      _lastScrolledLyricIndex = index;
      if (!_lyricsAutoScrollPausedByUser && index >= 0) {
        _scrollLyricsToIndex(index);
      }
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _positionNotifier.dispose();
    _activeLyricIndexNotifier.removeListener(_onActiveLyricIndexChanged);
    _activeLyricIndexNotifier.dispose();
    _scrubNotifier.removeListener(_onScrubChanged);
    _programmaticLyricScrollResetTimer?.cancel();
    _lyricsScrollController.dispose();
    _scrubNotifier.dispose();
    super.dispose();
  }

  List<TimedLyricLine> get _currentSyncedLyrics {
    final manager = context.read<LyricsManager>();
    return _lyricsDisplayMode == _LyricsDisplayMode.original
        ? manager.originalSyncedLines
        : manager.translationSyncedLines;
  }

  int _activeIndexForPosition(Duration position) {
    final index = LyricsManager.activeIndexForPosition(
      _currentSyncedLyrics,
      position,
      cachedIndex: _activeLyricIndexCache,
    );
    _activeLyricIndexCache = index;
    return index;
  }

  void _scrollLyricsToIndex(int index) {
    if (!_lyricsScrollController.hasClients) return;
    final position = _lyricsScrollController.position;
    final viewport = position.viewportDimension;
    final targetOffset =
        (index * _lyricLineExtent) - ((viewport / 2) - (_lyricLineExtent / 2));
    final clamped = targetOffset.clamp(0.0, position.maxScrollExtent);

    _isProgrammaticLyricScroll = true;
    _programmaticLyricScrollResetTimer?.cancel();
    _lyricsScrollController
        .animateTo(
            clamped,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          _programmaticLyricScrollResetTimer = Timer(
            const Duration(milliseconds: 120),
            () {
              _isProgrammaticLyricScroll = false;
            },
          );
        });
  }

  bool _onLyricsScrollNotification(ScrollNotification notification) {
    if (_currentSyncedLyrics.isEmpty || _isProgrammaticLyricScroll) {
      return false;
    }

    final isManualScroll =
        (notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null);
    if (isManualScroll && !_lyricsAutoScrollPausedByUser) {
      setState(() {
        _lyricsAutoScrollPausedByUser = true;
      });
    }
    return false;
  }

  void _resumeLiveLyrics() {
    setState(() {
      _lyricsAutoScrollPausedByUser = false;
    });
    final targetIndex = _activeLyricIndexNotifier.value;
    if (targetIndex >= 0) {
      _scrollLyricsToIndex(targetIndex);
    }
  }

  bool get _hasOriginalLyrics {
    final manager = context.read<LyricsManager>();
    final plain = manager.payload?.plainLyrics?.trim() ?? '';
    return plain.isNotEmpty || manager.originalSyncedLines.isNotEmpty;
  }

  bool get _hasTranslationLyrics {
    final manager = context.read<LyricsManager>();
    final plain = manager.payload?.translationPlainLyrics?.trim() ?? '';
    return plain.isNotEmpty || manager.translationSyncedLines.isNotEmpty;
  }

  String? _plainLyricsForCurrentMode() {
    final manager = context.read<LyricsManager>();
    if (_lyricsDisplayMode == _LyricsDisplayMode.translation) {
      final translation = manager.payload?.translationPlainLyrics?.trim();
      return (translation == null || translation.isEmpty) ? null : translation;
    }

    final original = manager.payload?.plainLyrics?.trim();
    return (original == null || original.isEmpty) ? null : original;
  }

  void _setLyricsDisplayMode(_LyricsDisplayMode mode) {
    if (mode == _lyricsDisplayMode) return;

    final manager = context.read<LyricsManager>();
    final nextSyncedLyrics = mode == _LyricsDisplayMode.original
        ? manager.originalSyncedLines
        : manager.translationSyncedLines;
    
    final currentPos = _scrubNotifier.value != null
        ? Duration(milliseconds: (_scrubNotifier.value! * 1000).round())
        : _positionNotifier.value;

    final nextActiveIndex = LyricsManager.activeIndexForPosition(
      nextSyncedLyrics,
      currentPos,
      cachedIndex: -1,
    );

    setState(() {
      _lyricsDisplayMode = mode;
      _lyricsAutoScrollPausedByUser = false;
      _activeLyricIndexNotifier.value = nextActiveIndex;
    });

    if (nextActiveIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollLyricsToIndex(nextActiveIndex);
      });
    }
  }

  Widget _buildLyricsModeToggle() {
    if (!_hasTranslationLyrics) return const SizedBox.shrink();

    final isOriginalSelected =
        _lyricsDisplayMode == _LyricsDisplayMode.original;
    final isTranslationSelected =
        _lyricsDisplayMode == _LyricsDisplayMode.translation;

    Widget modeButton({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.accentPurple.withValues(alpha: 0.22)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          modeButton(
            label: 'Original',
            selected: isOriginalSelected,
            onTap: () => _setLyricsDisplayMode(_LyricsDisplayMode.original),
          ),
          modeButton(
            label: 'Translation',
            selected: isTranslationSelected,
            onTap: () => _setLyricsDisplayMode(_LyricsDisplayMode.translation),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddToPlaylistSheet(Song song) async {
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
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
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
                  if (name == null || name.trim().isEmpty) return;

                  await provider.createPlaylist(name.trim(), initialSong: song);
                  if (!mounted) return;
                },
              ),
              if (playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Text(
                    'No playlists yet. Create one to save songs.',
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

  Future<String?> _promptPlaylistName() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Create Playlist'),
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
              final value = controller.text.trim();
              Navigator.pop(dialogContext, value.isEmpty ? null : value);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAlbum(BuildContext context, Song song) async {
    final albumId = (song.sourceAlbumId ?? song.albumId ?? '').trim();

    if (albumId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Album not found')));
      return;
    }

    try {
      final payload = await ApiService.getAlbums(id: albumId);
      final data = payload['data'] ?? payload;

      Map<String, dynamic>? albumMap;
      if (data is Map) {
        albumMap = Map<String, dynamic>.from(data);
      } else if (data is List && data.isNotEmpty && data.first is Map) {
        albumMap = Map<String, dynamic>.from(data.first);
      } else if (data is Map &&
          data['results'] != null &&
          data['results'] is List &&
          (data['results'] as List).isNotEmpty) {
        albumMap = Map<String, dynamic>.from((data['results'] as List).first);
      }

      if (albumMap != null) {
        final parsed = Album.fromJson(albumMap);
        final album = parsed.id.trim().isNotEmpty
            ? parsed
            : Album(
                id: albumId,
                name: parsed.name,
                artist: parsed.artist,
                imageUrl: parsed.imageUrl,
                language: parsed.language,
                songCount: parsed.songCount,
                year: parsed.year,
              );

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
        );
        return;
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Album not found')));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.activeSong;
        if (song == null) {
          return const Scaffold(body: Center(child: Text('No song playing')));
        }

        final isLoadingNew = player.isLoadingNewSong;

        // Automatically trigger lyrics request for active song if needed
        // Only fire once per song to avoid rebuild loops
        if (_lastRequestedLyricsSongId != song.id) {
          _lastRequestedLyricsSongId = song.id;
          _activeLyricIndexCache = -1;
          _lastScrolledLyricIndex = -1;
          _lyricsAutoScrollPausedByUser = false;
          _activeLyricIndexNotifier.value = -1;
          
          // Seed the initial position from the player provider
          _positionNotifier.value = player.position;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              context.read<LyricsManager>().requestLyrics(song);
            }
          });
        }

        final downloads = context.watch<DownloadProvider>();
        final isDownloaded = downloads.isDownloaded(song.id);
        final isDownloading = downloads.progress.containsKey(song.id);

        final mainPlayerView = Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppTheme.textSecondary,
                      size: 32,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Expanded(
                    child: Text(
                      'NOW PLAYING',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  // Conversation Mode Toggle
                  _ConversationToggleChip(
                    active: player.isConversationModeActive,
                    onTap: () => player.toggleConversationMode(),
                    isVisible: player.isConversationContextEligible,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),

            // Main content — Album Art
            Expanded(
              flex: 3,
              child: _buildAlbumArt(song),
            ),

            // Song Info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                children: [
                  Text(
                    song.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _OutputDeviceIcon(
                        device: player.outputDeviceState,
                      ),
                      const SizedBox(width: 6),
                      if (player.isOffline) ...[
                        const Icon(
                          Icons.wifi_off_rounded,
                          color: AppTheme.textMuted,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Offline',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else if (player.isWeakConnection) ...[
                        const Icon(
                          Icons.signal_cellular_connected_no_internet_4_bar_rounded,
                          color: Colors.orangeAccent,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Weak',
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (isDownloaded) ...[
                        const Icon(
                          Icons.check_circle_rounded,
                          color: AppTheme.accentPurple,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          song.artist ?? 'Unknown Artist',
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: (isLoadingNew && !player.isOffline)
                        ? const Padding(
                            key: ValueKey('player-buffering'),
                            padding: EdgeInsets.only(top: 8),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.accentPurple,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Loading...',
                                  style: TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox(
                            key: ValueKey('player-status-idle'),
                          ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Progress Bar (using localized ValueListenableBuilder for progress updates)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  ValueListenableBuilder<double?>(
                    valueListenable: _scrubNotifier,
                    builder: (context, scrubValue, _) {
                      return ValueListenableBuilder<Duration>(
                        valueListenable: _positionNotifier,
                        builder: (context, currentPosition, _) {
                          final visualPosition = scrubValue != null
                              ? Duration(milliseconds: (scrubValue * 1000).round())
                              : currentPosition;

                          return SliderTheme(
                            data: SliderThemeData(
                              activeTrackColor: AppTheme.accentPurple,
                              inactiveTrackColor: AppTheme.textMuted
                                  .withValues(alpha: 0.3),
                              thumbColor: AppTheme.accentPurple,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              trackHeight: 3,
                              overlayShape:
                                  const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value:
                                  scrubValue ??
                                  (player.duration.inSeconds > 0
                                      ? visualPosition.inSeconds
                                            .toDouble()
                                            .clamp(
                                              0,
                                              player
                                                  .duration
                                                  .inSeconds
                                                  .toDouble(),
                                            )
                                      : 0),
                              max: player.duration.inSeconds > 0
                                  ? player.duration.inSeconds
                                        .toDouble()
                                  : 1,
                              onChangeStart: isLoadingNew
                                  ? null
                                  : (val) {
                                      _scrubNotifier.value = val;
                                      player.setSeeking(true);
                                    },
                              onChanged: (isLoadingNew ||
                                      player.duration ==
                                          Duration.zero)
                                  ? null
                                  : (val) {
                                      _scrubNotifier.value = val;
                                    },
                              onChangeEnd: isLoadingNew
                                  ? null
                                  : (val) async {
                                      await player.seek(
                                        Duration(
                                          milliseconds: (val * 1000)
                                              .round(),
                                        ),
                                        immediate: true,
                                      );
                                      _scrubNotifier.value = null;
                                      player.setSeeking(false);
                                    },
                            ),
                          );
                        },
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        ValueListenableBuilder<double?>(
                          valueListenable: _scrubNotifier,
                          builder: (context, scrubValue, _) {
                            return ValueListenableBuilder<Duration>(
                              valueListenable: _positionNotifier,
                              builder: (context, currentPosition, _) {
                                final visualPosition = scrubValue != null
                                    ? Duration(milliseconds: (scrubValue * 1000).round())
                                    : currentPosition;
                                return Text(
                                  _formatDuration(visualPosition),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textMuted,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        Text(
                          (isLoadingNew && player.duration == Duration.zero)
                              ? '--:--'
                              : _formatDuration(player.duration),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Shuffle button
                IconButton(
                  icon: Icon(
                    Icons.shuffle_rounded,
                    color: player.shuffleModeEnabled
                        ? AppTheme.accentPurple
                        : Colors.white54,
                  ),
                  onPressed: () => player.toggleShuffleMode(),
                ),
                const SizedBox(width: 4),
                IconButton(
                  iconSize: 40,
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    color: AppTheme.textPrimary,
                  ),
                  onPressed: () => player.skipPrevious(),
                ),
                const SizedBox(width: 4),
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentPurple.withValues(
                          alpha: 0.4,
                        ),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: IconButton(
                    iconSize: 36,
                    icon: (player.isBuffering || isLoadingNew)
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            player.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                    onPressed: () => player.togglePlayPause(),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  iconSize: 40,
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: AppTheme.textPrimary,
                  ),
                  onPressed: player.canSkipNext
                      ? () => player.skipNext()
                      : null,
                ),
                const SizedBox(width: 4),
                // Download button
                IconButton(
                  icon: isDownloading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            value: downloads.progress[song.id],
                            strokeWidth: 2,
                            color: AppTheme.accentPurple,
                          ),
                        )
                      : Icon(
                          isDownloaded
                              ? Icons.download_done
                              : Icons.download_rounded,
                          color: isDownloaded
                              ? Colors.green
                              : AppTheme.textSecondary,
                        ),
                  onPressed: isDownloaded || isDownloading
                      ? null
                      : () => downloads.download(song),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(
                    Icons.playlist_add_rounded,
                    color: AppTheme.textSecondary,
                  ),
                  onPressed: () => _showAddToPlaylistSheet(song),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Preview Lyrics Card
            _buildLyricsPreviewCard(song),
          ],
        );

        return PopScope(
          canPop: true,
          child: Scaffold(
            body: RepaintBoundary(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: AppTheme.backgroundGradient,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: _showLyrics
                      ? _buildFullScreenLyrics(song)
                      : SafeArea(child: mainPlayerView),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlbumArt(Song song) {
    final artworkUrl = song.imageUrl?.trim();

    return Center(
      child: GestureDetector(
        onTap: () => _openAlbum(context, song),
        child: Container(
          width: 280,
          height: 280,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppTheme.accentPurple.withValues(alpha: 0.3),
                blurRadius: 40,
                spreadRadius: 10,
              ),
            ],
          ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
            child: OfflineArtwork(
              key: ValueKey('player-art-${song.id}-$artworkUrl'),
              songId: song.id,
              imageUrl: artworkUrl,
              fit: BoxFit.cover,
              placeholder: Container(
                color: AppTheme.cardDark,
                child: const Icon(
                  Icons.music_note,
                  size: 80,
                  color: AppTheme.textMuted,
                ),
              ),
              errorWidget: Container(
                color: AppTheme.cardDark,
                child: const Icon(
                  Icons.music_note,
                  size: 80,
                  color: AppTheme.textMuted,
                ),
              ),
            ),
        ),
      ),
    ),
  );
}

  Widget _buildLyricsPreviewCard(Song song) {
    final lyricsManager = context.watch<LyricsManager>();

    if (lyricsManager.state == LyricsLoadState.searching ||
        lyricsManager.state == LyricsLoadState.retrying ||
        lyricsManager.state == LyricsLoadState.idle) {
      return const SizedBox.shrink();
    }

    if (lyricsManager.state == LyricsLoadState.unavailable || lyricsManager.payload == null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: const Row(
          children: [
            Icon(Icons.lyrics_rounded, color: AppTheme.textMuted, size: 20),
            SizedBox(width: 8),
            Text(
              "Lyrics not found",
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final syncedLyrics = _currentSyncedLyrics;
    if (syncedLyrics.isEmpty) {
      final plain = _plainLyricsForCurrentMode();
      if (plain == null || plain.trim().isEmpty) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: const Row(
            children: [
              Icon(Icons.lyrics_rounded, color: AppTheme.textMuted, size: 20),
              SizedBox(width: 8),
              Text(
                "Lyrics not found",
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      }

      // Teaser for plain lyrics
      return GestureDetector(
        onTap: () {
          setState(() {
            _showLyrics = true;
            _lyricsAutoScrollPausedByUser = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _activeLyricIndexNotifier.value >= 0) {
              _scrollLyricsToIndex(_activeLyricIndexNotifier.value);
            }
          });
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: const Row(
            children: [
              Icon(Icons.lyrics_rounded, color: AppTheme.accentPurple, size: 20),
              SizedBox(width: 8),
              Text(
                'Lyrics (Plain Text) — Tap to view',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < -100) {
          setState(() {
            _showLyrics = true;
            _lyricsAutoScrollPausedByUser = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _activeLyricIndexNotifier.value >= 0) {
              _scrollLyricsToIndex(_activeLyricIndexNotifier.value);
            }
          });
        }
      },
      onTap: () {
        setState(() {
          _showLyrics = true;
          _lyricsAutoScrollPausedByUser = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _activeLyricIndexNotifier.value >= 0) {
            _scrollLyricsToIndex(_activeLyricIndexNotifier.value);
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppTheme.accentPurple.withValues(alpha: 0.28),
              AppTheme.accentPurple.withValues(alpha: 0.12),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.accentPurple.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lyrics_rounded, color: AppTheme.accentPurple, size: 20),
                SizedBox(width: 8),
                Text(
                  'LYRICS',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.5,
                  ),
                ),
                Spacer(),
                Icon(Icons.keyboard_arrow_up_rounded, color: AppTheme.textMuted, size: 22),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
              valueListenable: _activeLyricIndexNotifier,
              builder: (context, activeIndex, _) {
                final activeText = activeIndex >= 0 ? syncedLyrics[activeIndex].text : "...";
                return Text(
                  activeText,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullScreenLyrics(Song song) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! > 100) {
          setState(() {
            _showLyrics = false;
          });
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: OfflineArtwork(
              songId: song.id,
              imageUrl: song.imageUrl,
              fit: BoxFit.cover,
              placeholder: Container(color: AppTheme.primaryDark),
              errorWidget: Container(color: AppTheme.primaryDark),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
              child: Container(
                color: Colors.black.withValues(alpha: 0.65),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: AppTheme.textPrimary,
                          size: 32,
                        ),
                        onPressed: () {
                          setState(() {
                            _showLyrics = false;
                          });
                        },
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              song.name,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist ?? 'Unknown Artist',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      if (_hasTranslationLyrics)
                        IconButton(
                          icon: const Icon(Icons.translate_rounded, color: AppTheme.accentPurple),
                          onPressed: () => _setLyricsDisplayMode(
                            _lyricsDisplayMode == _LyricsDisplayMode.original
                                ? _LyricsDisplayMode.translation
                                : _LyricsDisplayMode.original,
                          ),
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _buildLyricsView(song),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsView(Song song) {
    final lyricsManager = context.watch<LyricsManager>();

    if (lyricsManager.state == LyricsLoadState.searching ||
        lyricsManager.state == LyricsLoadState.retrying ||
        lyricsManager.state == LyricsLoadState.idle) {
      return const SizedBox.shrink();
    }

    if (lyricsManager.state == LyricsLoadState.unavailable || lyricsManager.payload == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 48,
                color: AppTheme.textMuted,
              ),
              SizedBox(height: 16),
              Text(
                "Lyrics not found",
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final plainLyrics = _plainLyricsForCurrentMode();
    late final Widget content;

    final syncedLyrics = _currentSyncedLyrics;

    if (syncedLyrics.isNotEmpty) {
      content = Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: _onLyricsScrollNotification,
              child: ListView.builder(
                controller: _lyricsScrollController,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 120),
                itemCount: syncedLyrics.length,
                itemExtent: _lyricLineExtent,
                itemBuilder: (context, index) {
                  final line = syncedLyrics[index];

                  return ValueListenableBuilder<int>(
                    valueListenable: _activeLyricIndexNotifier,
                    builder: (context, activeIndex, _) {
                      final isActive = index == activeIndex;
                      final isPast = index < activeIndex;
                      final distance = (index - activeIndex).abs();
                      final opacity = isActive
                          ? 1.0
                          : isPast
                          ? 0.38
                          : distance == 1
                          ? 0.88
                          : distance == 2
                          ? 0.74
                          : 0.58;

                      return GestureDetector(
                        onTap: () {
                          context.read<PlayerProvider>().seek(line.time);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOut,
                          opacity: opacity,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeOut,
                                style: TextStyle(
                                  color: isActive
                                      ? AppTheme.textPrimary
                                      : isPast
                                      ? AppTheme.textMuted.withValues(alpha: 0.95)
                                      : Colors.white.withValues(alpha: 0.82),
                                  fontWeight: isActive
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  fontSize: isActive ? 19 : 15,
                                  height: 1.2,
                                ),
                                textAlign: TextAlign.center,
                                child: Text(
                                  line.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _activeLyricIndexNotifier,
              builder: (context, activeIndex, _) {
                if (_lyricsAutoScrollPausedByUser) {
                  return Positioned(
                    right: 14,
                    bottom: 14,
                    child: ElevatedButton.icon(
                      onPressed: _resumeLiveLyrics,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentPurple,
                        foregroundColor: Colors.white,
                        elevation: 3,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                      icon: const Icon(Icons.music_note_rounded, size: 18),
                      label: const Text(
                        'Back to Live Lyrics',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      );
    } else if (_lyricsDisplayMode == _LyricsDisplayMode.original &&
        !_hasOriginalLyrics &&
        _hasTranslationLyrics) {
      content = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_rounded, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text(
              'Original lyrics unavailable for this track.',
              style: TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 6),
            Text(
              'Switch to Translation to view synced lines.',
              style: TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    } else if (_lyricsDisplayMode == _LyricsDisplayMode.translation &&
        !_hasTranslationLyrics) {
      content = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_rounded, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text(
              'Translation not available for this track.',
              style: TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    } else if (plainLyrics == null || plainLyrics.isEmpty) {
      content = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_rounded, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text(
              'Lyrics not available for this track.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    } else {
      content = Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          child: Text(
            plainLyrics,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              height: 1.8,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (!_hasTranslationLyrics) {
      return content;
    }

    return Column(
      children: [
        _buildLyricsModeToggle(),
        const SizedBox(height: 10),
        Expanded(child: content),
      ],
    );
  }
}

enum _LyricsDisplayMode { original, translation }


class _ConversationToggleChip extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  final bool isVisible;

  const _ConversationToggleChip({
    required this.active,
    required this.onTap,
    required this.isVisible,
  });

  @override
  Widget build(BuildContext context) {
    if (!isVisible && !active) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.accentPurple.withValues(alpha: 0.35)
              : AppTheme.surfaceDark.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: active
                ? AppTheme.accentPurple.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.record_voice_over_rounded : Icons.headset_rounded,
              color: active ? AppTheme.accentPurple : AppTheme.textMuted,
              size: 14,
            ),
            const SizedBox(width: 5),
            Text(
              active ? 'Conversation' : 'Normal',
              style: TextStyle(
                color: active ? AppTheme.textPrimary : AppTheme.textMuted,
                fontSize: 10,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputDeviceIcon extends StatelessWidget {
  final AudioOutputRouteState device;

  const _OutputDeviceIcon({required this.device});

  @override
  Widget build(BuildContext context) {
    final icon = _iconFor(device.type);
    final color = device.isExternal
        ? const Color(0xFF44D79D)
        : AppTheme.textMuted;

    return Tooltip(
      message: device.name,
      preferBelow: false,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Icon(
          icon,
          key: ValueKey(device.type.name),
          size: 16,
          color: color,
        ),
      ),
    );
  }

  IconData _iconFor(AudioOutputRouteType type) {
    switch (type) {
      case AudioOutputRouteType.wiredHeadphones:
      case AudioOutputRouteType.bluetoothHeadphones:
        return Icons.headphones_rounded;
      case AudioOutputRouteType.carAudio:
        return Icons.directions_car_filled_rounded;
      case AudioOutputRouteType.bluetoothSpeaker:
      case AudioOutputRouteType.externalSpeaker:
        return Icons.speaker_rounded;
      case AudioOutputRouteType.phoneSpeaker:
        return Icons.smartphone_rounded;
      case AudioOutputRouteType.unknown:
        return Icons.graphic_eq_rounded;
    }
  }
}
