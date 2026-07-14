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
import '../services/offline_service.dart';
import '../services/listening_safety_service.dart';
import '../services/lyrics_manager.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_artwork.dart';
import '../widgets/spotify_progress_bar.dart';
import '../widgets/mini_player.dart';

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
    final isOffline = Provider.of<PlayerProvider>(context, listen: false).isOffline;
    final preferredAlbumId = ((song.sourceAlbumId ?? '').trim().isNotEmpty
        ? song.sourceAlbumId
        : song.albumId)?.trim() ?? '';

    if (isOffline) {
      final bundle = await _buildLocalFallbackBundle(song, preferredAlbumId);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LocalAlbumFallbackScreen(
            bundle: bundle,
            currentSongId: song.id,
          ),
        ),
      );
      return;
    }

    var albumId = preferredAlbumId;

    // If no album ID on the song, try fetching song details from API to discover it
    if (albumId.isEmpty) {
      try {
        final songPayload = await ApiService.getSong(song.id);
        final songData = songPayload['data'] ?? songPayload;

        Map<String, dynamic>? songMap;
        if (songData is Map) {
          if (songData['songs'] is List && (songData['songs'] as List).isNotEmpty) {
            songMap = Map<String, dynamic>.from((songData['songs'] as List).first as Map);
          } else if (songData['results'] is List && (songData['results'] as List).isNotEmpty) {
            songMap = Map<String, dynamic>.from((songData['results'] as List).first as Map);
          } else {
            songMap = Map<String, dynamic>.from(songData);
          }
        } else if (songData is List && songData.isNotEmpty && songData.first is Map) {
          songMap = Map<String, dynamic>.from(songData.first as Map);
        }

        if (songMap != null) {
          albumId = (songMap['sourceAlbumId'] ??
                  songMap['source_album_id'] ??
                  songMap['albumId'] ??
                  songMap['album_id'] ??
                  '')
              .toString()
              .trim();

          // Try nested album object
          if (albumId.isEmpty && songMap['album'] is Map) {
            final albumObj = songMap['album'] as Map;
            albumId = (albumObj['id'] ?? albumObj['albumId'] ?? '').toString().trim();
          }
        }
      } catch (_) {}
    }

    // If we found an album ID, fetch and navigate
    if (albumId.isNotEmpty) {
      try {
        final payload = await ApiService.getAlbums(id: albumId);
        final data = payload['data'] ?? payload;

        Map<String, dynamic>? albumMap;
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          if (map['results'] is List && (map['results'] as List).isNotEmpty) {
            albumMap = Map<String, dynamic>.from((map['results'] as List).first);
          } else {
            albumMap = map;
          }
        } else if (data is List && data.isNotEmpty && data.first is Map) {
          albumMap = Map<String, dynamic>.from(data.first);
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
    }

    // Last resort: search by album name
    final albumName = (song.sourceAlbumName ?? song.album ?? '').trim();
    if (albumName.isNotEmpty) {
      try {
        final payload = await ApiService.getAlbums(query: albumName);
        final data = payload['data'] ?? payload;

        List<dynamic>? results;
        if (data is Map) {
          results = (data['results'] ?? data['albums']) as List?;
        } else if (data is List) {
          results = data;
        }

        if (results != null && results.isNotEmpty) {
          // Try to find a matching album by name
          Map<String, dynamic>? bestMatch;
          final lowerAlbumName = albumName.toLowerCase();
          for (final item in results) {
            if (item is! Map) continue;
            final map = Map<String, dynamic>.from(item);
            final name = (map['name'] ?? map['title'] ?? '').toString().trim().toLowerCase();
            if (name == lowerAlbumName) {
              bestMatch = map;
              break;
            }
            bestMatch ??= map;
          }

          if (bestMatch != null) {
            final parsed = Album.fromJson(bestMatch);
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: parsed)),
            );
            return;
          }
        }
      } catch (_) {}
    }

    // Try to locate a matching offline/cached album if online searches failed
    if (albumId.isNotEmpty || albumName.isNotEmpty) {
      try {
        final bundle = await _buildLocalFallbackBundle(song, albumId);
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LocalAlbumFallbackScreen(
              bundle: bundle,
              currentSongId: song.id,
            ),
          ),
        );
        return;
      } catch (_) {}
    }

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Album not found')));
  }

  Future<LocalAlbumBundle> _buildLocalFallbackBundle(
    Song song,
    String preferredAlbumId,
  ) async {
    final offlineMatch = await _findOfflineAlbumGroup(
      song,
      preferredAlbumId: preferredAlbumId,
    );
    if (offlineMatch != null) {
      return LocalAlbumBundle(
        albumId: offlineMatch.albumId,
        albumName: offlineMatch.albumName,
        artist: offlineMatch.artist,
        imageUrl: offlineMatch.imageUrl,
        songs: offlineMatch.songs
            .map((record) => record.song)
            .toList(growable: false),
      );
    }

    final queue = context.read<PlayerProvider>().queue;
    final fallbackAlbumName =
        (song.sourceAlbumName ?? song.album ?? 'Unknown Album').trim();
    final fallbackArtist = (song.sourceAlbumArtist ?? song.artist)?.trim();
    final fallbackImage =
        (song.sourceAlbumImageUrl ?? song.imageUrl)?.trim().isNotEmpty == true
        ? (song.sourceAlbumImageUrl ?? song.imageUrl)!.trim()
        : null;

    final albumSongs = queue
        .where(
          (queuedSong) => _songBelongsToAlbum(
            queuedSong,
            preferredAlbumId: preferredAlbumId,
            fallbackAlbumName: fallbackAlbumName,
          ),
        )
        .toList(growable: false);

    return LocalAlbumBundle(
      albumId: preferredAlbumId.isNotEmpty
          ? preferredAlbumId
          : (song.albumId ?? '').trim(),
      albumName: fallbackAlbumName.isEmpty
          ? 'Unknown Album'
          : fallbackAlbumName,
      artist: fallbackArtist,
      imageUrl: fallbackImage,
      songs: albumSongs.isEmpty ? <Song>[song] : albumSongs,
    );
  }

  Future<OfflineAlbumGroup?> _findOfflineAlbumGroup(
    Song song, {
    required String preferredAlbumId,
  }) async {
    try {
      final offlineAlbums = await OfflineService.getOfflineAlbums();
      final wantedId = preferredAlbumId.trim();
      if (wantedId.isNotEmpty) {
        for (final group in offlineAlbums) {
          if (group.albumId.trim() == wantedId) {
            return group;
          }
        }
      }

      final wantedName = _normalizeLookup(
        song.sourceAlbumName ?? song.album ?? '',
      );
      if (wantedName.isEmpty) return null;

      for (final group in offlineAlbums) {
        final groupName = _normalizeLookup(group.albumName);
        if (groupName == wantedName) {
          return group;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _songBelongsToAlbum(
    Song song, {
    required String preferredAlbumId,
    required String fallbackAlbumName,
  }) {
    final expectedId = preferredAlbumId.trim();
    if (expectedId.isNotEmpty) {
      final songAlbumIds = <String>{
        (song.sourceAlbumId ?? '').trim(),
        (song.albumId ?? '').trim(),
      };
      if (songAlbumIds.contains(expectedId)) {
        return true;
      }
    }

    final expectedName = _normalizeLookup(fallbackAlbumName);
    if (expectedName.isEmpty) return false;
    final songAlbumName = _normalizeLookup(
      song.sourceAlbumName ?? song.album ?? '',
    );
    return songAlbumName == expectedName;
  }

  String _normalizeLookup(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
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
        context.watch<LyricsManager>();

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

        // Sync active lyric index immediately when rebuild occurs (e.g. lyrics loaded or song changed)
        if (_scrubNotifier.value == null) {
          final index = _activeIndexForPosition(_positionNotifier.value);
          if (index != _activeLyricIndexNotifier.value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scrubNotifier.value == null) {
                _activeLyricIndexNotifier.value = index;
              }
            });
          }
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

            const SizedBox(height: 32),

            // Song Info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
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
                  const SizedBox(height: 8),
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
                ],
              ),
            ),

            const SizedBox(height: 28),

            // Progress Bar (using localized ValueListenableBuilder for progress updates)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
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

                          return SpotifyProgressBar(
                            position: visualPosition,
                            duration: player.duration,
                            bufferedPosition: player.bufferedPosition,
                            isLoading: player.isLoadingNewSong,
                            isBuffering: player.isBuffering,
                            onChanged: (dragPos) {
                              _scrubNotifier.value = dragPos.inMilliseconds / 1000.0;
                              player.setSeeking(true);
                            },
                            onChangeEnd: (seekPos) async {
                              await player.seek(seekPos, immediate: true);
                              _scrubNotifier.value = null;
                              player.setSeeking(false);
                            },
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                      if (player.isLoadingNewSong)
                        const Text(
                          'Loading...',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.accentPurple,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (player.isBuffering)
                        const Text(
                          'Buffering...',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.accentPurple,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        const SizedBox(),
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
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Playback Controls Row (centered: Previous, Play/Pause, Next)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 28,
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: AppTheme.textPrimary,
                    ),
                    onPressed: () => player.skipPrevious(),
                  ),
                  const SizedBox(width: 32),
                  // Play/Pause button — large gradient circle
                  Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accentPurple.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: IconButton(
                      iconSize: 36,
                      icon: Icon(
                        player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => player.togglePlayPause(),
                    ),
                  ),
                  const SizedBox(width: 32),
                  IconButton(
                    iconSize: 28,
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: AppTheme.textPrimary,
                    ),
                    onPressed: player.canSkipNext
                        ? () => player.skipNext()
                        : null,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Secondary Actions Row (Shuffle, Queue/Playlist Add, Download)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Shuffle button
                  IconButton(
                    iconSize: 28,
                    icon: Icon(
                      Icons.shuffle_rounded,
                      color: player.shuffleModeEnabled
                          ? AppTheme.accentPurple
                          : Colors.white54,
                    ),
                    onPressed: () => player.toggleShuffleMode(),
                  ),
                  // Playlist Add (centered)
                  IconButton(
                    iconSize: 28,
                    icon: const Icon(
                      Icons.playlist_add_rounded,
                      color: AppTheme.textSecondary,
                    ),
                    onPressed: () => _showAddToPlaylistSheet(song),
                  ),
                  // Download button
                  IconButton(
                    iconSize: 28,
                    icon: isDownloading
                        ? SizedBox(
                            width: 22,
                            height: 22,
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
                ],
              ),
            ),

            const SizedBox(height: 24),

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
        margin: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
          margin: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
          margin: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
        margin: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
        lyricsManager.state == LyricsLoadState.retrying) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.accentPurple,
              ),
            ),
            SizedBox(height: 16),
            Text(
              "Searching for lyrics...",
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (lyricsManager.state == LyricsLoadState.idle) {
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

                      return LyricLineWidget(
                        line: line,
                        isActive: isActive,
                        isPast: isPast,
                        distance: distance,
                        positionNotifier: _positionNotifier,
                        onTap: () {
                          context.read<PlayerProvider>().seek(line.time);
                        },
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

class LyricLineWidget extends StatelessWidget {
  final TimedLyricLine line;
  final bool isActive;
  final bool isPast;
  final int distance;
  final VoidCallback onTap;
  final ValueNotifier<Duration> positionNotifier;

  const LyricLineWidget({
    super.key,
    required this.line,
    required this.isActive,
    required this.isPast,
    required this.distance,
    required this.onTap,
    required this.positionNotifier,
  });

  TextStyle _lineStyle(bool active, bool past, int dist) {
    return TextStyle(
      color: active
          ? AppTheme.textPrimary
          : past
              ? AppTheme.textMuted.withValues(alpha: 0.95)
              : Colors.white.withValues(alpha: 0.82),
      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
      fontSize: active ? 18 : 15,
      height: 1.2,
    );
  }

  Widget _buildWordHighlightText(Duration position) {
    final words = line.words;
    if (words == null || words.isEmpty) {
      return Text(
        line.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: _lineStyle(true, false, 0),
      );
    }

    final elapsed = position - line.time;
    final spans = <TextSpan>[];

    for (var i = 0; i < words.length; i++) {
      final wordHighlight = words[i];
      final start = wordHighlight.startOffset;
      final end = wordHighlight.endOffset;

      Color color;
      FontWeight fontWeight;
      
      if (elapsed >= start && elapsed <= end) {
        color = AppTheme.textPrimary;
        fontWeight = FontWeight.w900;
      } else if (elapsed > end) {
        color = AppTheme.textPrimary.withValues(alpha: 0.85);
        fontWeight = FontWeight.w700;
      } else {
        color = Colors.white.withValues(alpha: 0.5);
        fontWeight = FontWeight.w500;
      }

      spans.add(TextSpan(
        text: wordHighlight.word + (i == words.length - 1 ? '' : ' '),
        style: TextStyle(
          color: color,
          fontWeight: fontWeight,
          fontSize: 18,
        ),
      ));
    }

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      text: TextSpan(children: spans),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double targetOpacity = isActive
        ? 1.0
        : isPast
            ? 0.38
            : distance == 1
                ? 0.88
                : distance == 2
                    ? 0.74
                    : 0.58;

    final double targetScale = isActive ? 1.12 : 1.0;
    final Offset targetOffset = isActive ? const Offset(0, -0.05) : Offset.zero;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedSlide(
        offset: targetOffset,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          opacity: targetOpacity,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: AnimatedScale(
                scale: targetScale,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                child: isActive && line.words != null && line.words!.isNotEmpty
                    ? ValueListenableBuilder<Duration>(
                        valueListenable: positionNotifier,
                        builder: (context, pos, _) => _buildWordHighlightText(pos),
                      )
                    : Text(
                        line.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: _lineStyle(isActive, isPast, distance),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
