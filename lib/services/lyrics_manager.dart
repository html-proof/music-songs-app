import 'dart:async';
import '../models/song.dart';
import 'lyrics_alignment_engine.dart';
import 'lyrics_cache.dart';
import 'lyrics_service.dart';
import 'player_service.dart';
import 'connectivity_manager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'preferences_service.dart';

// ─────────────────────────────────────────────────────────────
// State enum — replaces 10+ booleans in _PlayerScreenState
// ─────────────────────────────────────────────────────────────
enum LyricsLoadState {
  idle,        // No song / nothing to do
  searching,   // Phase 1: foreground multi-provider search (≤8s)
  retrying,    // Phase 2: background retry (shows subtle "still looking" UI)
  ready,       // Lyrics found and loaded
  unavailable, // All retries exhausted — show "Lyrics aren't available"
}

// ─────────────────────────────────────────────────────────────
// Parsed synced lyric line (moved from player_screen.dart)
// ─────────────────────────────────────────────────────────────
@immutable
class TimedLyricLine {
  final Duration time;
  final String text;

  const TimedLyricLine({required this.time, required this.text});
}

// ─────────────────────────────────────────────────────────────
// Central Lyrics Manager
// ─────────────────────────────────────────────────────────────
class LyricsManager extends ChangeNotifier {
  // ── Public state ──────────────────────────────────────────
  LyricsLoadState get state => _state;
  LyricsPayload? get payload => _payload;
  List<TimedLyricLine> get originalSyncedLines => _originalSyncedLines;
  List<TimedLyricLine> get translationSyncedLines => _translationSyncedLines;
  Song? get currentSong => _currentSong;

  String get statusMessage {
    switch (_state) {
      case LyricsLoadState.searching:
      case LyricsLoadState.retrying:
      case LyricsLoadState.idle:
      case LyricsLoadState.ready:
        return '';
      case LyricsLoadState.unavailable:
        return "Lyrics not found";
    }
  }

  // ── Private state ─────────────────────────────────────────
  LyricsLoadState _state = LyricsLoadState.idle;
  LyricsPayload? _payload;
  List<TimedLyricLine> _originalSyncedLines = const [];
  List<TimedLyricLine> _translationSyncedLines = const [];
  Song? _currentSong;

  int _generation = 0; // Incremented on every song change — prevents stale async updates

  Timer? _retryTimer;
  Timer? _hardStopTimer;


  // ── Subscriptions ─────────────────────────────────────────
  StreamSubscription<Song?>? _resolvingSongSub;
  StreamSubscription<int?>? _currentIndexSub;

  StreamSubscription<ConnectivityEvent>? _connectivitySub;

  LyricsManager() {
    _listenToPlayerService();
  }

  void _listenToPlayerService() {
    // When a new song starts resolving (user tapped play), start search immediately
    _resolvingSongSub = PlayerService.resolvingSongStream.listen((song) {
      if (song != null) {
        if (_currentSong?.id == song.id) {
          return;
        }
        _onSongChanging(song);
        _scheduleFetch(song);
      }
    });

    // When the queue index changes (skip next/prev, queue navigation)
    _currentIndexSub = PlayerService.player.currentIndexStream.listen((_) {
      final song = PlayerService.currentSong;
      if (song != null) {
        if (_currentSong?.id == song.id) {
          return;
        }
        _onSongChanging(song);
        _scheduleFetch(song);
      }
    });
  }

  /// Called when a new song is starting — clears state immediately.
  void _onSongChanging(Song song) {
    _generation++; // Invalidate all in-flight requests
    _cancelTimers();
    LyricsService.cancelActiveSearches();

    _currentSong = song;
    _state = LyricsLoadState.searching;
    _payload = null;
    _originalSyncedLines = const [];
    _translationSyncedLines = const [];
    notifyListeners();
  }

  /// Called after a new song is confirmed playing — triggers fetch.
  void _scheduleFetch(Song song, {bool isManual = false}) {
    // Use a post-frame delay so we don't block the song-change UI update.
    Future.microtask(() async {
      if (_currentSong?.id == song.id) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        bool dataSaverEnabled = false;
        bool lyricsAutoFetch = true;
        if (uid != null) {
          final prefs = await PreferencesService.getPreferences(uid);
          if (prefs != null) {
            dataSaverEnabled = prefs.dataSaverEnabled;
            lyricsAutoFetch = prefs.lyricsAutoFetch;
          }
        }

        final lifecycle = WidgetsBinding.instance.lifecycleState;
        final isBackground =
            lifecycle == AppLifecycleState.paused ||
            lifecycle == AppLifecycleState.inactive;

        // If automatic fetch (not manual): check background state, data saver mode, or disabled auto fetch
        if (!isManual && (isBackground || dataSaverEnabled || !lyricsAutoFetch)) {
          // Attempt a zero-data local cache read first. If it's cached, we can load it safely!
          final cached = await LyricsCache.get(
            songId: song.id,
            title: song.name,
            artist: song.artist ?? '',
            album: song.sourceAlbumName ?? song.album ?? '',
            duration: song.duration ?? 0,
          );
          if (cached != null && !cached.isUnavailable) {
            final hasPlain = cached.plainLyrics != null && cached.plainLyrics!.trim().isNotEmpty;
            final hasSynced = cached.syncedLyrics != null && cached.syncedLyrics!.trim().isNotEmpty;
            if (hasPlain || hasSynced) {
              if (_currentSong?.id == song.id) {
                var payload = LyricsPayload(
                  plainLyrics: cached.plainLyrics,
                  syncedLyrics: cached.syncedLyrics,
                  provider: cached.providerSource,
                );
                if (!payload.hasSynced && payload.hasPlain) {
                  payload = LyricsAlignmentEngine.align(song, payload);
                }
                _applyPayload(payload, _generation);
              }
              return;
            }
          }

          // Otherwise, do not query any network. Immediately mark as unavailable.
          if (_currentSong?.id == song.id) {
            _state = LyricsLoadState.unavailable;
            notifyListeners();
          }
          return;
        }

        _fetchLyrics(song);
      }
    });
  }

  /// Public API: request lyrics for the given song.
  /// If already loaded for the same song, no-op.
  /// If forceRetry, re-fetch even if previously marked unavailable.
  void requestLyrics(Song song, {bool forceRetry = false}) {
    final isSameSong = _currentSong?.id == song.id;

    if (isSameSong && !forceRetry) {
      // Already loading, ready, or exhausted for this song — no-op
      if (_state == LyricsLoadState.ready ||
          _state == LyricsLoadState.searching ||
          _state == LyricsLoadState.retrying ||
          _state == LyricsLoadState.unavailable) {
        return;
      }
    }

    if (!isSameSong) {
      _onSongChanging(song);
    } else if (forceRetry) {
      _generation++;
      _cancelTimers();
      _state = LyricsLoadState.searching;
      _payload = null;
      _originalSyncedLines = const [];
      _translationSyncedLines = const [];
      notifyListeners();
    }

    _scheduleFetch(song, isManual: true);
  }

  /// Prefetch lyrics for a song without displaying them (e.g., next in queue).
  void prefetchLyrics(Song song) async {
    final isSameSong = _currentSong?.id == song.id;
    if (isSameSong) return; // Don't prefetch the current song

    final uid = FirebaseAuth.instance.currentUser?.uid;
    bool dataSaverEnabled = false;
    bool lyricsAutoFetch = true;
    if (uid != null) {
      final prefs = await PreferencesService.getPreferences(uid);
      if (prefs != null) {
        dataSaverEnabled = prefs.dataSaverEnabled;
        lyricsAutoFetch = prefs.lyricsAutoFetch;
      }
    }
    // Skip network queries for prefetch in data saver mode or when disabled
    if (dataSaverEnabled || !lyricsAutoFetch) return;

    // Fire-and-forget into LyricsService cache without affecting LyricsManager state
    LyricsService.prefetchLyricsForSong(song);
  }

  // ─────────────────────────────────────────────────────────
  // PHASE 1 — Foreground fetch (≤8s)
  // ─────────────────────────────────────────────────────────
  Future<void> _fetchLyrics(Song song) async {
    final myGeneration = _generation;
    final songId = song.id;
    final title = song.name.trim();
    final artist = (song.artist ?? '').trim();
    final album = (song.sourceAlbumName ?? song.album ?? '').trim();
    final duration = song.duration ?? 0;

    // 1. Check local download directory LRC first (instantly)
    final localLrc = await LyricsService.loadLocalLrc(songId);
    if (!_isMyGeneration(myGeneration)) return;
    if (localLrc != null) {
      var finalLrc = localLrc;
      if (!localLrc.hasSynced && localLrc.hasPlain) {
        finalLrc = LyricsAlignmentEngine.align(song, localLrc);
      }
      _applyPayload(finalLrc, myGeneration);
      return;
    }

    // 2. Fast path: check cache before network
    final cached = await LyricsCache.get(
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );

    if (!_isMyGeneration(myGeneration)) return;

    if (cached != null) {
      if (cached.isUnavailable) {
        // Check if the 24h TTL for unavailable entries has expired
        final age = DateTime.now().difference(cached.fetchedAt);
        if (age.inHours < 24) {
          _applyUnavailable();
          return;
        }
        // TTL expired — allow re-search
      } else {
        var payload = cached.toPayload();
        if (!payload.hasSynced && payload.hasPlain) {
          payload = LyricsAlignmentEngine.align(song, payload);
        }
        _applyPayload(payload, myGeneration);
        return;
      }
    }

    // 3. Check connectivity. If offline, fail immediately to prevent hanging
    if (ConnectivityManager.isOffline) {
      _applyUnavailable();
      return;
    }

    // 4. Run progressive search asynchronously in the background.
    // Allow up to approximately 10 seconds for the entire search to complete.
    try {
      final found = await LyricsService.progressiveLyricsSearch(song).timeout(
        const Duration(seconds: 10),
      );

      if (!_isMyGeneration(myGeneration)) return;

      _retryTimer?.cancel();
      _retryTimer = null;
      _hardStopTimer?.cancel();
      _hardStopTimer = null;

      if (found != null && found.hasAny) {
        await LyricsCache.put(
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          payload: found,
          providerSource: found.provider ?? 'lrclib',
        );
        if (_isMyGeneration(myGeneration)) {
          _applyPayload(found, myGeneration);
          // Prefetch next song lyrics in background
          _prefetchNext();
        }
      } else {
        // Cache unavailable so we don't hammer the API on subsequent plays
        await LyricsCache.put(
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          payload: null,
          providerSource: 'none',
          isUnavailable: true,
        );
        if (_isMyGeneration(myGeneration)) {
          _applyUnavailable();
        }
      }
    } catch (e) {
      debugPrint('[LyricsManager] Background progressive search timed out or failed: $e');
      if (_isMyGeneration(myGeneration)) {
        _applyUnavailable();
      }
    }
  }

  // ─────────────────────────────────────────────────────────
  // Applying results
  // ─────────────────────────────────────────────────────────
  void _applyPayload(LyricsPayload payload, int myGeneration) {
    if (!_isMyGeneration(myGeneration)) return;

    final originalLines = payload.syncedLyrics != null
        ? _parseSyncedLyrics(payload.syncedLyrics!)
        : const <TimedLyricLine>[];
    final translationLines = payload.translationSyncedLyrics != null
        ? _parseSyncedLyrics(payload.translationSyncedLyrics!)
        : const <TimedLyricLine>[];

    _payload = payload;
    _originalSyncedLines = originalLines;
    _translationSyncedLines = translationLines;
    _state = LyricsLoadState.ready;
    _cancelTimers();
    notifyListeners();
    debugPrint('[LyricsManager] Lyrics applied for "${_currentSong?.name}"');
  }

  void _applyUnavailable() {
    // Guard: don't re-notify if already in unavailable state (prevents rebuild loops)
    if (_state == LyricsLoadState.unavailable) return;

    _state = LyricsLoadState.unavailable;
    _payload = null;
    _originalSyncedLines = const [];
    _translationSyncedLines = const [];
    _cancelTimers();
    notifyListeners();
    debugPrint('[LyricsManager] Lyrics unavailable for "${_currentSong?.name}"');
  }



  // ─────────────────────────────────────────────────────────
  // Synced lyric parsing (moved from _PlayerScreenState)
  // ─────────────────────────────────────────────────────────
  static final RegExp _lrcTagRegex = RegExp(
    r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]',
    multiLine: true,
  );

  static List<TimedLyricLine> _parseSyncedLyrics(String rawSyncedLyrics) {
    final parsed = <TimedLyricLine>[];
    final seenEntries = <String>{};
    final rows = rawSyncedLyrics.split('\n');

    for (final row in rows) {
      final matches = _lrcTagRegex.allMatches(row).toList();
      if (matches.isEmpty) continue;

      final text = row.replaceAll(_lrcTagRegex, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minute = int.tryParse(match.group(1) ?? '') ?? 0;
        final second = int.tryParse(match.group(2) ?? '') ?? 0;
        if (second >= 60) continue;

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

        final timestampMs = (minute * 60 * 1000) + (second * 1000) + millisecond;
        final dedupeKey = '$timestampMs|$text';
        if (seenEntries.contains(dedupeKey)) continue;
        seenEntries.add(dedupeKey);

        parsed.add(TimedLyricLine(
          time: Duration(milliseconds: timestampMs),
          text: text,
        ));
      }
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));
    return parsed;
  }

  // ─────────────────────────────────────────────────────────
  // Active lyric index lookup (binary search + linear scan)
  // ─────────────────────────────────────────────────────────

  /// Lyrics from most LRC sources are timestamped slightly ahead of the
  /// actual vocal onset. This offset delays the highlight so the lyric
  /// appears exactly when the singer begins — matching Spotify / Apple Music
  /// behaviour. Higher value = lyrics appear later (delays highlight).
  static const int _lyricsSyncOffsetMs = 1000;

  static int activeIndexForPosition(
    List<TimedLyricLine> lines,
    Duration position, {
    int cachedIndex = -1,
  }) {
    if (lines.isEmpty) return -1;
    // Apply sync offset: subtract to delay the highlight
    final millis = position.inMilliseconds - _lyricsSyncOffsetMs;
    if (millis < lines.first.time.inMilliseconds) return -1;

    var left = 0;
    var right = lines.length - 1;
    while (left <= right) {
      final mid = (left + right) >> 1;
      if (lines[mid].time.inMilliseconds <= millis) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    final targetIndex = right.clamp(0, lines.length - 1);

    if (targetIndex == cachedIndex) return cachedIndex;
    if (cachedIndex < 0 || cachedIndex >= lines.length) return targetIndex;

    final targetTime = lines[targetIndex].time;
    final drift = (millis - targetTime.inMilliseconds).abs();

    // If drift is less than 150ms, keep the current line to avoid jitter / early transitions
    if (drift < 150) {
      return cachedIndex;
    }

    return targetIndex;
  }

  // ─────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────
  bool _isMyGeneration(int gen) => gen == _generation;

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _hardStopTimer?.cancel();
    _hardStopTimer = null;
  }

  void _prefetchNext() {
    final index = PlayerService.currentIndex;
    final queue = PlayerService.queue;
    if (index >= 0 && index + 1 < queue.length) {
      prefetchLyrics(queue[index + 1]);
    }
  }

  @override
  void dispose() {
    _resolvingSongSub?.cancel();
    _currentIndexSub?.cancel();
    _connectivitySub?.cancel();
    _cancelTimers();
    super.dispose();
  }
}
