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
import '../services/lyrics_service.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_artwork.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  LyricsPayload? _lyricsPayload;
  List<_TimedLyricLine> _syncedLyrics = const <_TimedLyricLine>[];
  List<_TimedLyricLine> _originalSyncedLyrics = const <_TimedLyricLine>[];
  List<_TimedLyricLine> _translationSyncedLyrics = const <_TimedLyricLine>[];
  _LyricsDisplayMode _lyricsDisplayMode = _LyricsDisplayMode.original;
  bool _loadingLyrics = false;
  bool _lyricsSearchFailed = false;
  bool _isSearchingInBackground = false;
  bool _initialSearchFailed = false;
  bool _lyricsPermanentlyUnavailable = false;
  int _currentStatusIndex = 0;
  Timer? _statusTimer;
  Timer? _backgroundRetryTimer;
  Timer? _hardStopTimer;
  bool _showLyrics = false;
  String? _lastLyricsRequestKey;
  DateTime? _lastLyricsFetchAt;
  String? _currentSongId;
  final ValueNotifier<double?> _scrubNotifier = ValueNotifier<double?>(null);
  final ScrollController _lyricsScrollController = ScrollController();
  int _lastScrolledLyricIndex = -1;
  int _activeLyricIndexCache = -1;
  bool _lyricsAutoScrollPausedByUser = false;
  bool _isProgrammaticLyricScroll = false;
  Timer? _programmaticLyricScrollResetTimer;

  static const double _lyricLineExtent = 46.0;

  static const List<String> _loadingStatusSteps = [
    '🎵 Searching lyrics...',
    'Trying another source...',
    'Matching song...',
    '✓ Almost there...',
  ];

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _programmaticLyricScrollResetTimer?.cancel();
    _statusTimer?.cancel();
    _backgroundRetryTimer?.cancel();
    _hardStopTimer?.cancel();
    _lyricsScrollController.dispose();
    _scrubNotifier.dispose();
    super.dispose();
  }

  String? _lyricsLookupKeyForSong(Song song) {
    final artist = (song.artist ?? '').trim();
    final title = song.name.trim();
    final songId = song.id.trim().toLowerCase();
    final lookupKey = songId.isNotEmpty
        ? songId
        : '${artist.toLowerCase()}::${title.toLowerCase()}';
    if (title.isEmpty || lookupKey.isEmpty) {
      return null;
    }
    return lookupKey;
  }

  void _startStatusAnimation() {
    _statusTimer?.cancel();
    _hardStopTimer?.cancel();
    _currentStatusIndex = 0;

    // Advance status label every 2 seconds through the 4 steps
    _statusTimer = Timer.periodic(const Duration(milliseconds: 2000), (timer) {
      if (!mounted || !_loadingLyrics) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_currentStatusIndex < _loadingStatusSteps.length - 1) {
          _currentStatusIndex++;
        }
      });
    });

    // Hard deadline: if still in foreground-loading after 10s, transition to
    // background-searching state so the UI never stays stuck on a spinner.
    _hardStopTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_loadingLyrics) return;
      _statusTimer?.cancel();
      setState(() {
        _loadingLyrics = false;
        _isSearchingInBackground = true;
        _initialSearchFailed = true;
      });
    });
  }

  void _applyLyrics(LyricsPayload payload, String lookupKey, DateTime now) {
    final originalSyncedLines = payload.syncedLyrics != null
        ? _parseSyncedLyrics(payload.syncedLyrics!)
        : const <_TimedLyricLine>[];
    final translationSyncedLines = payload.translationSyncedLyrics != null
        ? _parseSyncedLyrics(payload.translationSyncedLyrics!)
        : const <_TimedLyricLine>[];

    _lastLyricsRequestKey = lookupKey;
    _lastLyricsFetchAt = now;
    setState(() {
      _lyricsPayload = payload;
      _originalSyncedLyrics = originalSyncedLines;
      _translationSyncedLyrics = translationSyncedLines;
      _syncedLyrics = originalSyncedLines;
      _lyricsDisplayMode = _LyricsDisplayMode.original;
      _activeLyricIndexCache = -1;
      _lastScrolledLyricIndex = -1;
      _loadingLyrics = false;
      _lyricsSearchFailed = false;
      _isSearchingInBackground = false;
      _initialSearchFailed = false;
      _lyricsPermanentlyUnavailable = false;
    });
  }

  Future<void> _fetchLyrics(Song song, {bool forceRetry = false}) async {
    final artist = (song.artist ?? '').trim();
    final title = song.name.trim();
    final lookupKey = _lyricsLookupKeyForSong(song);
    if (lookupKey == null) return;

    final isSameLookup = _lastLyricsRequestKey == lookupKey;
    final now = DateTime.now();

    // Guard: don't restart if already loading this exact song
    if (_loadingLyrics && isSameLookup && !forceRetry) return;
    // Guard: already have lyrics for this song
    if (isSameLookup && _lyricsPayload != null && !forceRetry) return;
    // Guard: searched recently and found nothing — wait at least 15s before
    // allowing a non-forced retry so we don't hammer the API
    if (!forceRetry &&
        isSameLookup &&
        _lyricsPayload == null &&
        _lastLyricsFetchAt != null &&
        now.difference(_lastLyricsFetchAt!) < const Duration(seconds: 15)) {
      return;
    }

    // --- Fast path: serve from cache immediately ---
    if (!forceRetry) {
      final cachedPayload = LyricsService.getCachedLyricsForSong(song);
      if (cachedPayload != null) {
        _applyLyrics(cachedPayload, lookupKey, now);
        return;
      }
    }

    // Cancel any pending background-retry timer from a previous search
    _backgroundRetryTimer?.cancel();
    _backgroundRetryTimer = null;

    _lastLyricsRequestKey = lookupKey;
    _lastLyricsFetchAt = now;

    // Start the UI status animation with a built-in 10s hard stop
    _startStatusAnimation();

    setState(() {
      _loadingLyrics = true;
      _lyricsSearchFailed = false;
      _isSearchingInBackground = false;
      _initialSearchFailed = false;
      _lyricsPermanentlyUnavailable = false;
      _lyricsPayload = null;
      _syncedLyrics = const <_TimedLyricLine>[];
      _originalSyncedLyrics = const <_TimedLyricLine>[];
      _translationSyncedLyrics = const <_TimedLyricLine>[];
      _lyricsDisplayMode = _LyricsDisplayMode.original;
      _lastScrolledLyricIndex = -1;
      _activeLyricIndexCache = -1;
      _lyricsAutoScrollPausedByUser = false;
      _isProgrammaticLyricScroll = false;
    });

    bool isCurrentSong() {
      if (!mounted) return false;
      final currentActive = context.read<PlayerProvider>().activeSong;
      if (currentActive == null) return false;
      return _lyricsLookupKeyForSong(currentActive) == lookupKey;
    }

    // ─────────────────────────────────────────────────────────────
    // PHASE 1 — Foreground search (≤ 8 seconds total)
    // Three quick attempts run concurrently to maximise hit rate.
    // If any one resolves with lyrics we are done immediately.
    // ─────────────────────────────────────────────────────────────
    LyricsPayload? found;

    try {
      final results = await Future.wait(<Future<LyricsPayload?>>[
        // Attempt 1: full song-aware lookup (Saavn + LRC exact + search)
        LyricsService.getLyricsPayloadForSong(song),
        // Attempt 2: plain title search
        LyricsService.getLyricsByQuery(title, song),
        // Attempt 3: title + artist
        LyricsService.getLyricsByQuery('$title $artist'.trim(), song),
      ]).timeout(
        const Duration(seconds: 8),
        onTimeout: () => const <LyricsPayload?>[null, null, null],
      );

      for (final res in results) {
        if (res != null && res.hasAny) {
          found = res;
          break;
        }
      }
    } catch (e) {
      debugPrint('[Lyrics] Phase 1 search error: $e');
    }

    if (!isCurrentSong()) return;

    // Phase 1 succeeded — show lyrics right away
    if (found != null && found.hasAny) {
      _statusTimer?.cancel();
      _hardStopTimer?.cancel();
      _applyLyrics(found, lookupKey, now);
      return;
    }

    // ─────────────────────────────────────────────────────────────
    // PHASE 1 FAILED — Transition to background-searching state.
    // The UI immediately shows "We're still looking..." instead of
    // a stuck spinner. Phase 2 retries fire asynchronously via
    // Timer so they never block the UI or playback.
    // ─────────────────────────────────────────────────────────────
    _statusTimer?.cancel();
    _hardStopTimer?.cancel();

    if (!isCurrentSong()) return;

    setState(() {
      _loadingLyrics = false;
      _isSearchingInBackground = true;
      _initialSearchFailed = true;
      _lyricsPermanentlyUnavailable = false;
    });

    // ─────────────────────────────────────────────────────────────
    // PHASE 2 — Background retries: 20 s / 40 s / 60 s
    // Each retry fires independently via a chained Timer so there
    // is no blocking await in the UI. If the user changes songs,
    // _backgroundRetryTimer is cancelled immediately.
    // ─────────────────────────────────────────────────────────────
    var bgAttempt = 1;
    const bgDelays = [20, 40, 60]; // seconds between each retry
    const bgMaxAttempts = 3;

    void scheduleNextBgRetry() {
      if (bgAttempt > bgMaxAttempts) {
        // All background attempts exhausted — mark permanently unavailable
        if (mounted && isCurrentSong()) {
          setState(() {
            _isSearchingInBackground = false;
            _lyricsPermanentlyUnavailable = true;
            _lyricsSearchFailed = true;
          });
        }
        return;
      }

      final delaySeconds = bgAttempt <= bgDelays.length
          ? bgDelays[bgAttempt - 1]
          : bgDelays.last;

      _backgroundRetryTimer?.cancel();
      _backgroundRetryTimer = Timer(Duration(seconds: delaySeconds), () async {
        if (!isCurrentSong()) return;

        LyricsPayload? bgResult;
        try {
          final albumName = song.album ?? song.sourceAlbumName ?? '';
          final queries = <String>[
            '$title $artist'.trim(),
            if (albumName.isNotEmpty) '$title $artist $albumName'.trim(),
            title,
          ];
          final queryToUse = queries[((bgAttempt - 1) % queries.length).clamp(0, queries.length - 1)];
          bgResult = await LyricsService.getLyricsByQuery(queryToUse, song)
              .timeout(const Duration(seconds: 8), onTimeout: () => null);
        } catch (e) {
          debugPrint('[Lyrics] Background retry $bgAttempt failed: $e');
        }

        if (!isCurrentSong()) return;

        if (bgResult != null && bgResult.hasAny) {
          // Found it in the background — update the screen automatically
          _applyLyrics(bgResult, lookupKey, DateTime.now());
          return;
        }

        bgAttempt++;
        scheduleNextBgRetry();
      });
    }

    scheduleNextBgRetry();
  }

  List<_TimedLyricLine> _parseSyncedLyrics(String rawSyncedLyrics) {
    final lineRegex = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final parsed = <_TimedLyricLine>[];
    final seenEntries = <String>{};
    final rows = rawSyncedLyrics.split('\n');

    for (final row in rows) {
      final matches = lineRegex.allMatches(row).toList(growable: false);
      if (matches.isEmpty) continue;

      final text = row.replaceAll(lineRegex, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minute = int.tryParse(match.group(1) ?? '') ?? 0;
        final second = int.tryParse(match.group(2) ?? '') ?? 0;
        if (minute < 0 || second < 0 || second >= 60) continue;

        final fractionRaw = match.group(3);
        var millisecond = 0;
        if (fractionRaw != null && fractionRaw.isNotEmpty) {
          if (fractionRaw.length == 3) {
            millisecond = int.tryParse(fractionRaw) ?? 0;
          } else if (fractionRaw.length == 2) {
            millisecond = (int.tryParse(fractionRaw) ?? 0) * 10;
          } else {
            millisecond = (int.tryParse(fractionRaw) ?? 0) * 100;
          }
        }

        final timestampMs =
            (minute * 60 * 1000) + (second * 1000) + millisecond;
        final dedupeKey = '$timestampMs|$text';
        if (seenEntries.contains(dedupeKey)) {
          continue;
        }
        seenEntries.add(dedupeKey);

        parsed.add(
          _TimedLyricLine(
            time: Duration(milliseconds: timestampMs),
            text: text,
          ),
        );
      }
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));
    return parsed;
  }

  int _activeIndexForPosition(Duration position) {
    final index = _activeIndexForPositionIn(
      _syncedLyrics,
      position,
      cachedIndex: _activeLyricIndexCache,
    );
    _activeLyricIndexCache = index;
    return index;
  }

  int _activeIndexForPositionIn(
    List<_TimedLyricLine> syncedLyrics,
    Duration position, {
    int cachedIndex = -1,
  }) {
    if (syncedLyrics.isEmpty) return -1;
    final millis = position.inMilliseconds;
    final firstMillis = syncedLyrics.first.time.inMilliseconds;
    if (millis < firstMillis) return -1;

    int binarySearch() {
      var left = 0;
      var right = syncedLyrics.length - 1;
      while (left <= right) {
        final mid = (left + right) >> 1;
        final midMillis = syncedLyrics[mid].time.inMilliseconds;
        if (midMillis <= millis) {
          left = mid + 1;
        } else {
          right = mid - 1;
        }
      }
      return right.clamp(0, syncedLyrics.length - 1);
    }

    if (cachedIndex < 0 || cachedIndex >= syncedLyrics.length) {
      return binarySearch();
    }

    var index = cachedIndex;
    final cachedMillis = syncedLyrics[index].time.inMilliseconds;

    // Large seek jumps are handled better with binary search.
    if ((millis - cachedMillis).abs() > 10000) {
      return binarySearch();
    }

    while (index + 1 < syncedLyrics.length &&
        millis >= syncedLyrics[index + 1].time.inMilliseconds) {
      index += 1;
    }
    while (index > 0 && millis < syncedLyrics[index].time.inMilliseconds) {
      index -= 1;
    }

    return index.clamp(0, syncedLyrics.length - 1);
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
          duration: const Duration(milliseconds: 260),
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
    if (_syncedLyrics.isEmpty || _isProgrammaticLyricScroll) {
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

  void _resumeLiveLyrics(Duration visualPosition) {
    setState(() {
      _lyricsAutoScrollPausedByUser = false;
    });
    final targetIndex = _activeIndexForPosition(visualPosition);
    if (targetIndex >= 0) {
      _activeLyricIndexCache = targetIndex;
      _lastScrolledLyricIndex = targetIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollLyricsToIndex(targetIndex);
      });
    }
  }

  bool get _hasOriginalLyrics {
    final plain = _lyricsPayload?.plainLyrics?.trim() ?? '';
    return plain.isNotEmpty || _originalSyncedLyrics.isNotEmpty;
  }

  bool get _hasTranslationLyrics {
    final plain = _lyricsPayload?.translationPlainLyrics?.trim() ?? '';
    return plain.isNotEmpty || _translationSyncedLyrics.isNotEmpty;
  }

  String? _plainLyricsForCurrentMode() {
    if (_lyricsDisplayMode == _LyricsDisplayMode.translation) {
      final translation = _lyricsPayload?.translationPlainLyrics?.trim();
      return (translation == null || translation.isEmpty) ? null : translation;
    }

    final original = _lyricsPayload?.plainLyrics?.trim();
    return (original == null || original.isEmpty) ? null : original;
  }

  void _setLyricsDisplayMode(_LyricsDisplayMode mode, Duration visualPosition) {
    if (mode == _lyricsDisplayMode) return;

    final nextSyncedLyrics = mode == _LyricsDisplayMode.original
        ? _originalSyncedLyrics
        : _translationSyncedLyrics;
    final nextActiveIndex = _activeIndexForPositionIn(
      nextSyncedLyrics,
      visualPosition,
      cachedIndex: -1,
    );

    setState(() {
      _lyricsDisplayMode = mode;
      _syncedLyrics = nextSyncedLyrics;
      _activeLyricIndexCache = nextActiveIndex;
      _lastScrolledLyricIndex = nextActiveIndex;
      _lyricsAutoScrollPausedByUser = false;
    });

    if (nextActiveIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollLyricsToIndex(nextActiveIndex);
      });
    }
  }

  Widget _buildLyricsModeToggle(Duration visualPosition) {
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
            onTap: () => _setLyricsDisplayMode(
              _LyricsDisplayMode.original,
              visualPosition,
            ),
          ),
          modeButton(
            label: 'Translation',
            selected: isTranslationSelected,
            onTap: () => _setLyricsDisplayMode(
              _LyricsDisplayMode.translation,
              visualPosition,
            ),
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

        if (song.id != _currentSongId) {
          _currentSongId = song.id;
          // Clear old lyrics synchronously so they don't display for the previous song
          _lyricsPayload = null;
          _syncedLyrics = const <_TimedLyricLine>[];
          _originalSyncedLyrics = const <_TimedLyricLine>[];
          _translationSyncedLyrics = const <_TimedLyricLine>[];
          _lyricsSearchFailed = false;
          _lyricsPermanentlyUnavailable = false;
          _initialSearchFailed = false;
          _isSearchingInBackground = false;
          _loadingLyrics = true;
          _currentStatusIndex = 0;
          _statusTimer?.cancel();
          _backgroundRetryTimer?.cancel();
          _hardStopTimer?.cancel();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_fetchLyrics(song));
          });
        }

        final downloads = context.watch<DownloadProvider>();
        final isDownloaded = downloads.isDownloaded(song.id);
        final isDownloading = downloads.progress.containsKey(song.id);

        return ValueListenableBuilder<double?>(
          valueListenable: _scrubNotifier,
          builder: (context, scrubValue, _) {
            final visualPosition = scrubValue != null
                ? Duration(milliseconds: (scrubValue * 1000).round())
                : player.position;

            Widget mainPlayerView = Column(
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
                        child: (player.isBuffering && !player.isOffline)
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

                // Progress Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      SliderTheme(
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
                                  ? player.position.inSeconds
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
                          onChangeStart: player.isBuffering
                              ? null
                              : (val) {
                                  _scrubNotifier.value = val;
                                  player.setSeeking(true);
                                },
                          onChanged: (player.isBuffering ||
                                  player.duration ==
                                      Duration.zero)
                              ? null
                              : (val) {
                                  _scrubNotifier.value = val;
                                },
                          onChangeEnd: player.isBuffering
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
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(visualPosition),
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
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
                        icon: player.isBuffering
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
                        onPressed: player.isBuffering
                            ? null
                            : () => player.togglePlayPause(),
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
                _buildLyricsPreviewCard(song, visualPosition),
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
                          ? _buildFullScreenLyrics(song, visualPosition)
                          : SafeArea(child: mainPlayerView),
                    ),
                  ),
                ),
              ),
            );
          },
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

  Widget _buildLyricsPreviewCard(Song song, Duration visualPosition) {
    if (_loadingLyrics && !_initialSearchFailed) {
      final statusText = _loadingStatusSteps[_currentStatusIndex.clamp(0, _loadingStatusSteps.length - 1)];
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.accentPurple.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                color: AppTheme.accentPurple,
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  statusText,
                  key: ValueKey<String>(statusText),
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_lyricsPayload == null) {
      if (_lyricsPermanentlyUnavailable) {
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
                "Lyrics aren't available for this song.",
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      } else if (_initialSearchFailed) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppTheme.accentPurple.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.15)),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  color: AppTheme.accentPurple,
                  strokeWidth: 2,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  "We're still looking... Lyrics will appear automatically if found.",
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }

    if (_lyricsSearchFailed || _syncedLyrics.isEmpty) {
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
              'Lyrics unavailable for this track',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final activeIndex = _activeIndexForPosition(visualPosition);
    final activeText = activeIndex >= 0 ? _syncedLyrics[activeIndex].text : "...";

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < -100) {
          setState(() {
            _showLyrics = true;
            _lyricsAutoScrollPausedByUser = false;
          });
        }
      },
      onTap: () {
        setState(() {
          _showLyrics = true;
          _lyricsAutoScrollPausedByUser = false;
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
            Text(
              activeText,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullScreenLyrics(Song song, Duration visualPosition) {
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
                          onPressed: () {
                            setState(() {
                              _lyricsDisplayMode = _lyricsDisplayMode == _LyricsDisplayMode.original
                                  ? _LyricsDisplayMode.translation
                                  : _LyricsDisplayMode.original;
                              _syncedLyrics = _lyricsDisplayMode == _LyricsDisplayMode.original
                                  ? _originalSyncedLyrics
                                  : _translationSyncedLyrics;
                              _activeLyricIndexCache = -1;
                              _lastScrolledLyricIndex = -1;
                            });
                          },
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _buildLyricsView(song, visualPosition),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsView(Song song, Duration visualPosition) {
    if (_loadingLyrics && !_initialSearchFailed) {
      final statusText = _loadingStatusSteps[_currentStatusIndex.clamp(0, _loadingStatusSteps.length - 1)];
      final progress = (_currentStatusIndex + 1) / _loadingStatusSteps.length;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.music_note_rounded,
                size: 48,
                color: AppTheme.accentPurple,
              ),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  statusText,
                  key: ValueKey<String>(statusText),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 180,
                  height: 6,
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accentPurple),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_lyricsPayload == null) {
      if (_lyricsPermanentlyUnavailable) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lyrics_outlined,
                  size: 48,
                  color: AppTheme.textMuted,
                ),
                const SizedBox(height: 16),
                const Text(
                  "Lyrics aren't available for this song.",
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    _fetchLyrics(song, forceRetry: true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  child: const Text('Retry Search Now'),
                ),
              ],
            ),
          ),
        );
      } else if (_initialSearchFailed) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    color: AppTheme.accentPurple,
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "We're still looking...",
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  _isSearchingInBackground
                      ? "Lyrics will appear automatically if found. We'll keep searching in the background while your music plays."
                      : "Lyrics will appear automatically if found. We'll keep searching in the background.",
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }
    }

    if (_lyricsSearchFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lyrics_outlined,
                size: 48,
                color: AppTheme.textMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                "Lyrics aren't available for this song right now.",
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      _fetchLyrics(song, forceRetry: true);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentPurple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Retry Now', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(
                    onPressed: () {
                      Fluttertoast.showToast(
                        msg: 'Thank you! Missing lyrics reported.',
                        gravity: ToastGravity.BOTTOM,
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                      foregroundColor: AppTheme.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Report Missing Lyrics', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final plainLyrics = _plainLyricsForCurrentMode();
    late final Widget content;

    if (_syncedLyrics.isNotEmpty) {
      final activeIndex = _activeIndexForPosition(visualPosition);

      if (activeIndex != _lastScrolledLyricIndex) {
        _lastScrolledLyricIndex = activeIndex;
        if (!_lyricsAutoScrollPausedByUser && activeIndex >= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollLyricsToIndex(activeIndex);
          });
        }
      }

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
                itemCount: _syncedLyrics.length,
                itemExtent: _lyricLineExtent,
                itemBuilder: (context, index) {
                  final line = _syncedLyrics[index];
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
              ),
            ),
            if (_lyricsAutoScrollPausedByUser)
              Positioned(
                right: 14,
                bottom: 14,
                child: ElevatedButton.icon(
                  onPressed: () => _resumeLiveLyrics(visualPosition),
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
        _buildLyricsModeToggle(visualPosition),
        const SizedBox(height: 10),
        Expanded(child: content),
      ],
    );
  }
}

enum _LyricsDisplayMode { original, translation }

@immutable
class _TimedLyricLine {
  final Duration time;
  final String text;

  const _TimedLyricLine({required this.time, required this.text});
}

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
