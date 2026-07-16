import 'dart:async';
import 'dart:math' as math;
import '../models/song.dart';
import 'lyrics_alignment_engine.dart';
import 'lyrics_cache.dart';
import 'lyrics_service.dart';
import '../models/lyrics_payload.dart';
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
class WordHighlight {
  final String word;
  final Duration startOffset; // Offset from line start time
  final Duration endOffset;   // Offset from line start time

  const WordHighlight({
    required this.word,
    required this.startOffset,
    required this.endOffset,
  });
}

@immutable
class TimedLyricLine {
  final Duration time;
  final String text;
  final List<WordHighlight>? words; // Optional word-level highlights

  const TimedLyricLine({
    required this.time,
    required this.text,
    this.words,
  });
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
      } else {
        // Resolving finished (playable song is loaded in PlayerService)
        final resolvedSong = PlayerService.currentSong;
        if (resolvedSong != null && _currentSong?.id == resolvedSong.id) {
          final wasUnresolved = _currentSong?.duration == null || _currentSong?.duration == 0;
          final isResolved = resolvedSong.duration != null && resolvedSong.duration! > 0;
          
          if (wasUnresolved && isResolved && _state != LyricsLoadState.ready) {
            debugPrint('[LyricsManager] Song resolved! Upgrading lyrics search with complete metadata.');
            _generation++; // Invalidate pending unresolved fetch tasks
            _currentSong = resolvedSong;
            _scheduleFetch(resolvedSong);
          }
        }
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
                  unawaited(LyricsCache.put(
                    songId: song.id,
                    title: song.name,
                    artist: song.artist ?? '',
                    album: song.sourceAlbumName ?? song.album ?? '',
                    duration: song.duration ?? 0,
                    payload: payload,
                    providerSource: cached.providerSource,
                  ));
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
        _prefetchNext();
      }
    });
  }

  /// Public API: request lyrics for the given song.
  /// If already loaded for the same song, no-op.
  /// If forceRetry, re-fetch even if previously marked unavailable.
  void requestLyrics(Song song, {bool forceRetry = false}) {
    final isSameSong = _currentSong?.id == song.id;

    if (isSameSong && !forceRetry) {
      final wasUnresolved = _currentSong?.duration == null || _currentSong?.duration == 0;
      final isResolved = song.duration != null && song.duration! > 0;

      // If the song is now resolved and we haven't successfully loaded lyrics, upgrade search!
      if (wasUnresolved && isResolved && _state != LyricsLoadState.ready) {
        debugPrint('[LyricsManager] requestLyrics: Upgrading lyrics search to resolved metadata.');
        _generation++; // Invalidate pending unresolved fetch tasks
        _currentSong = song;
        _scheduleFetch(song);
        return;
      }

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
    LyricsService.prefetchLyricsForSong(song.toLyricsMetadata());
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
        unawaited(LyricsService.saveLocalLrc(songId, finalLrc));
      }
      _applyPayload(finalLrc, myGeneration);
      return;
    }

    // 2. Fast path: check cache
    final cached = await LyricsCache.get(
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );

    if (!_isMyGeneration(myGeneration)) return;

    bool needsBackgroundRefresh = false;
    bool needsUpgradeToSynced = false;

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
          unawaited(LyricsCache.put(
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            payload: payload,
            providerSource: cached.providerSource,
          ));
        }

        // Show cached lyrics instantly!
        _applyPayload(payload, myGeneration);

        // Check if cached entry is older than 24 hours (refresh check)
        final age = DateTime.now().difference(cached.fetchedAt);
        if (age.inHours >= 24) {
          needsBackgroundRefresh = true;
        }

        // Check if the payload only has plain lyrics (upgrade to synced check)
        if (!payload.hasSynced) {
          needsUpgradeToSynced = true;
        }

        if (!needsBackgroundRefresh && !needsUpgradeToSynced) {
          // No need to query network since we have fresh synced lyrics!
          return;
        }
      }
    }

    // 3. Check connectivity. If offline, stop since we can't query the network
    if (ConnectivityManager.isOffline) {
      if (cached == null) {
        _applyUnavailable();
      }
      return;
    }

    // 4. Run progressive search in the background.
    // If we already showed cached lyrics, this is a silent background refresh/upgrade,
    // so we must NOT change the state to `searching` or show any loading spinner.
    if (cached == null) {
      _state = LyricsLoadState.searching;
      notifyListeners();
    }

    try {
      final found = await LyricsService.progressiveLyricsSearch(song.toLyricsMetadata()).timeout(
        const Duration(seconds: 10),
      );

      if (!_isMyGeneration(myGeneration)) return;

      if (found != null && found.hasAny) {
        // Upgrade check: if we already have plain/synced lyrics displayed, only swap/update if the new one is better
        // (e.g. if we had plain and found synced, or if it is a fresh refresh).
        bool shouldApply = true;
        if (cached != null) {
          final currentHasSynced = _payload?.hasSynced ?? false;
          final newHasSynced = found.hasSynced;
          // If we had synced lyrics, and the refreshed one is plain, do not overwrite/downgrade.
          if (currentHasSynced && !newHasSynced) {
            shouldApply = false;
          }
        }

        await LyricsCache.put(
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          payload: found,
          providerSource: found.provider ?? 'lrclib',
        );

        if (shouldApply && _isMyGeneration(myGeneration)) {
          _applyPayload(found, myGeneration);
        }
      } else if (cached == null) {
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
      if (cached == null && _isMyGeneration(myGeneration)) {
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
        ? parseSyncedLyrics(payload.syncedLyrics!)
        : const <TimedLyricLine>[];
    final translationLines = payload.translationSyncedLyrics != null
        ? parseSyncedLyrics(payload.translationSyncedLyrics!)
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

  static final RegExp _wordTagRegex = RegExp(
    r'<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>',
  );

  static List<TimedLyricLine> parseSyncedLyrics(String rawSyncedLyrics) {
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

        final words = _parseWordHighlights(text, timestampMs);
        final cleanText = text.replaceAll(_wordTagRegex, '').replaceAll(RegExp(r'\s+'), ' ').trim();

        parsed.add(TimedLyricLine(
          time: Duration(milliseconds: timestampMs),
          text: cleanText,
          words: words,
        ));
      }
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));
    return parsed;
  }

  static List<WordHighlight>? _parseWordHighlights(String lineText, int lineStartMs) {
    final matches = _wordTagRegex.allMatches(lineText).toList();
    if (matches.isEmpty) return null;

    final words = <WordHighlight>[];
    
    int getMs(Match m) {
      final minute = int.tryParse(m.group(1) ?? '') ?? 0;
      final second = int.tryParse(m.group(2) ?? '') ?? 0;
      final fractionRaw = m.group(3);
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
      return (minute * 60 * 1000) + (second * 1000) + millisecond;
    }

    // First word check before any tag
    final firstMatchStart = matches.first.start;
    if (firstMatchStart > 0) {
      final firstWordText = lineText.substring(0, firstMatchStart).trim();
      if (firstWordText.isNotEmpty) {
        final endMs = getMs(matches.first);
        words.add(WordHighlight(
          word: firstWordText,
          startOffset: Duration.zero,
          endOffset: Duration(milliseconds: math.max(0, endMs - lineStartMs)),
        ));
      }
    }

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final startMs = getMs(match);
      final endPos = (i + 1 < matches.length) ? matches[i + 1].start : lineText.length;
      final wordText = lineText.substring(match.end, endPos).trim();
      if (wordText.isEmpty) continue;

      final endMs = (i + 1 < matches.length) ? getMs(matches[i + 1]) : (startMs + 400);

      words.add(WordHighlight(
        word: wordText,
        startOffset: Duration(milliseconds: math.max(0, startMs - lineStartMs)),
        endOffset: Duration(milliseconds: math.max(0, endMs - lineStartMs)),
      ));
    }

    return words.isEmpty ? null : words;
  }

  // ─────────────────────────────────────────────────────────
  // Active lyric index lookup (binary search + linear scan)
  // ─────────────────────────────────────────────────────────

  /// Lyrics from most LRC sources are timestamped slightly ahead of the
  /// actual vocal onset. This offset delays the highlight so the lyric
  /// appears exactly when the singer begins — matching Spotify / Apple Music
  /// behaviour. Higher value = lyrics appear later (delays highlight).
  static const int _lyricsSyncOffsetMs = 1200;

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

    if (drift <= 50) {
      // ±50 ms -> No change (keep cached index to prevent jitter)
      return cachedIndex;
    } else if (drift <= 100) {
      // ±100 ms -> Smooth correction (update to target index)
      return targetIndex;
    } else if (drift > 250) {
      // >250 ms -> Recalculate/jump immediately (update to target index)
      return targetIndex;
    }

    // Default fallback (between 100ms and 250ms)
    return cachedIndex;
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
