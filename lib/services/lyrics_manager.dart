import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'lyrics_cache.dart';
import 'lyrics_service.dart';
import 'player_service.dart';

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
        return _searchStatusMessages[_searchStatusIndex.clamp(0, _searchStatusMessages.length - 1)];
      case LyricsLoadState.retrying:
        return '🔍 Still searching for lyrics…';
      case LyricsLoadState.ready:
        return '';
      case LyricsLoadState.unavailable:
        return "Lyrics aren't available for this song.";
      case LyricsLoadState.idle:
        return '';
    }
  }

  static const List<String> _searchStatusMessages = [
    '🎵 Searching lyrics...',
    'Trying another source...',
    'Matching song...',
    '✓ Almost there...',
  ];

  // ── Private state ─────────────────────────────────────────
  LyricsLoadState _state = LyricsLoadState.idle;
  LyricsPayload? _payload;
  List<TimedLyricLine> _originalSyncedLines = const [];
  List<TimedLyricLine> _translationSyncedLines = const [];
  Song? _currentSong;

  int _generation = 0; // Incremented on every song change — prevents stale async updates
  int _searchStatusIndex = 0;

  Timer? _statusTimer;
  Timer? _retryTimer;
  Timer? _hardStopTimer;


  // ── Subscriptions ─────────────────────────────────────────
  StreamSubscription<Song?>? _resolvingSongSub;
  StreamSubscription<int?>? _currentIndexSub;

  LyricsManager() {
    _listenToPlayerService();
  }

  void _listenToPlayerService() {
    // When a new song starts resolving (user tapped play), clear lyrics immediately
    _resolvingSongSub = PlayerService.resolvingSongStream.listen((song) {
      if (song != null) {
        _onSongChanging(song);
      }
    });

    // When the queue index changes (skip next/prev, queue navigation)
    _currentIndexSub = PlayerService.player.currentIndexStream.listen((_) {
      final song = PlayerService.currentSong;
      if (song != null) {
        if (_currentSong?.id == song.id &&
            _state != LyricsLoadState.searching &&
            _state != LyricsLoadState.idle) {
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

    _currentSong = song;
    _state = LyricsLoadState.searching;
    _searchStatusIndex = 0;
    _payload = null;
    _originalSyncedLines = const [];
    _translationSyncedLines = const [];
    notifyListeners();
  }

  /// Called after a new song is confirmed playing — triggers fetch.
  void _scheduleFetch(Song song) {
    // Use a post-frame delay so we don't block the song-change UI update.
    Future.microtask(() {
      if (_currentSong?.id == song.id) {
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
      _searchStatusIndex = 0;
      _payload = null;
      _originalSyncedLines = const [];
      _translationSyncedLines = const [];
      notifyListeners();
    }

    _fetchLyrics(song);
  }

  /// Prefetch lyrics for a song without displaying them (e.g., next in queue).
  void prefetchLyrics(Song song) {
    final isSameSong = _currentSong?.id == song.id;
    if (isSameSong) return; // Don't prefetch the current song
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

    // ── Fast path: check cache before network ──
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
        _applyPayload(cached.toPayload(), myGeneration);
        return;
      }
    }

    // ── Start status animation ──
    _startStatusAnimation(myGeneration);

    // ── Phase 1: Run concurrent searches ──
    LyricsPayload? found;
    String providerSource = '';

    try {
      final results = await Future.wait<LyricsPayload?>([
        // Attempt 1: full song-aware lookup (Saavn + LRCLIB exact + search)
        LyricsService.getLyricsPayloadForSong(song),
        // Attempt 2: plain title search
        LyricsService.getLyricsByQuery(title, song),
        // Attempt 3: title + artist
        if (artist.isNotEmpty)
          LyricsService.getLyricsByQuery('$title $artist'.trim(), song),
      ]).timeout(
        const Duration(seconds: 8),
        onTimeout: () => const <LyricsPayload?>[null, null, null],
      );

      for (final res in results) {
        if (res != null && res.hasAny) {
          found = res;
          providerSource = res.provider ?? 'lrclib';
          break;
        }
      }
    } catch (e) {
      debugPrint('[LyricsManager] Phase 1 error: $e');
    }

    if (!_isMyGeneration(myGeneration)) return;

    _cancelStatusTimer();
    _hardStopTimer?.cancel();

    if (found != null && found.hasAny) {
      // Cache and apply
      await LyricsCache.put(
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        payload: found,
        providerSource: providerSource,
      );
      if (_isMyGeneration(myGeneration)) {
        _applyPayload(found, myGeneration);
        // Prefetch next song lyrics in background
        _prefetchNext();
      }
      return;
    }

    // ── Phase 1 failed — transition to background retrying ──
    if (!_isMyGeneration(myGeneration)) return;
    _state = LyricsLoadState.retrying;
    notifyListeners();

    _schedulePhase2(song, myGeneration, songId, title, artist, album, duration);
  }

  // ─────────────────────────────────────────────────────────
  // PHASE 2 — Background retries (15s / 30s / 60s)
  // ─────────────────────────────────────────────────────────
  void _schedulePhase2(
    Song song,
    int myGeneration,
    String songId,
    String title,
    String artist,
    String album,
    int duration,
  ) {
    var attempt = 1;
    const maxAttempts = 3;
    const delays = [15, 30, 60]; // seconds

    void scheduleNext() {
      if (attempt > maxAttempts) {
        if (_isMyGeneration(myGeneration)) {
          // Cache unavailable to prevent hammering
          unawaited(LyricsCache.put(
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            payload: null,
            providerSource: 'none',
            isUnavailable: true,
          ));
          _applyUnavailable();
        }
        return;
      }

      final delaySecs = attempt <= delays.length ? delays[attempt - 1] : delays.last;
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(seconds: delaySecs), () async {
        if (!_isMyGeneration(myGeneration)) return;

        final albumName = song.album ?? song.sourceAlbumName ?? '';
        final queries = <String>[
          '$title $artist'.trim(),
          if (albumName.isNotEmpty) '$title $albumName'.trim(),
          title,
          if (artist.isNotEmpty) artist,
        ];
        final query = queries[(attempt - 1).clamp(0, queries.length - 1)];

        LyricsPayload? result;
        try {
          result = await LyricsService.getLyricsByQuery(query, song)
              .timeout(const Duration(seconds: 8), onTimeout: () => null);
        } catch (e) {
          debugPrint('[LyricsManager] Phase 2 attempt $attempt failed: $e');
        }

        if (!_isMyGeneration(myGeneration)) return;

        if (result != null && result.hasAny) {
          await LyricsCache.put(
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            payload: result,
            providerSource: 'lrclib',
          );
          if (_isMyGeneration(myGeneration)) {
            _applyPayload(result, myGeneration);
          }
          return;
        }

        attempt++;
        scheduleNext();
      });
    }

    scheduleNext();
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
  // Status animation
  // ─────────────────────────────────────────────────────────
  void _startStatusAnimation(int myGeneration) {
    _cancelStatusTimer();
    _searchStatusIndex = 0;

    _statusTimer = Timer.periodic(const Duration(milliseconds: 2000), (timer) {
      if (!_isMyGeneration(myGeneration) || _state != LyricsLoadState.searching) {
        timer.cancel();
        return;
      }
      if (_searchStatusIndex < _searchStatusMessages.length - 1) {
        _searchStatusIndex++;
        notifyListeners();
      }
    });

    // Hard stop: after 10s, transition to retrying so UI never stays stuck
    _hardStopTimer = Timer(const Duration(seconds: 10), () {
      if (!_isMyGeneration(myGeneration)) return;
      if (_state == LyricsLoadState.searching) {
        _cancelStatusTimer();
        _state = LyricsLoadState.retrying;
        notifyListeners();
      }
    });
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
  static int activeIndexForPosition(
    List<TimedLyricLine> lines,
    Duration position, {
    int cachedIndex = -1,
  }) {
    if (lines.isEmpty) return -1;
    final millis = position.inMilliseconds;
    if (millis < lines.first.time.inMilliseconds) return -1;

    int binarySearch() {
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
      return right.clamp(0, lines.length - 1);
    }

    if (cachedIndex < 0 || cachedIndex >= lines.length) {
      return binarySearch();
    }

    // Large seek: use binary search
    if ((millis - lines[cachedIndex].time.inMilliseconds).abs() > 10000) {
      return binarySearch();
    }

    var index = cachedIndex;
    while (index + 1 < lines.length && millis >= lines[index + 1].time.inMilliseconds) {
      index++;
    }
    while (index > 0 && millis < lines[index].time.inMilliseconds) {
      index--;
    }
    return index.clamp(0, lines.length - 1);
  }

  // ─────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────
  bool _isMyGeneration(int gen) => gen == _generation;

  void _cancelTimers() {
    _cancelStatusTimer();
    _retryTimer?.cancel();
    _retryTimer = null;
    _hardStopTimer?.cancel();
    _hardStopTimer = null;
  }

  void _cancelStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
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
    _cancelTimers();
    super.dispose();
  }
}
