import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'api_service.dart';
import 'stream_resolver.dart';
import 'verification_engine.dart';

class ResolvedStreamEntry {
  final String songId;
  final Song song;
  final String streamUrl;
  final bool isValidated;
  final DateTime expiresAt;
  final String provider;
  final int bitrate;

  ResolvedStreamEntry({
    required this.songId,
    required this.song,
    required this.streamUrl,
    required this.isValidated,
    required this.expiresAt,
    required this.provider,
    required this.bitrate,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class SearchCoordinator {
  static final Map<String, List<http.Client>> _sessionClients = {};
  static final Map<String, Future<Song?>> _activeRecoveryTasks = {};

  // --- LRU Cache (max 200 entries, 10-minute TTL) ---
  static const int _maxCacheSize = 200;
  static const Duration _cacheTtl = Duration(minutes: 10);
  static final LinkedHashMap<String, ResolvedStreamEntry> _resolvedCache =
      LinkedHashMap<String, ResolvedStreamEntry>();

  // --- Failed URL Blacklist (10-minute TTL) ---
  static const Duration _blacklistTtl = Duration(minutes: 10);
  static final Map<String, DateTime> _blacklistedUrls = {};
  static final Map<String, DateTime> _recoveredAlbumsCache = {};

  static final List<String> _alternateCdns = [
    'aac.saavncdn.com',
    'jiosaavn.cdn.jio.com',
    'snoidcdnems04.cdnsrv.jio.com',
  ];

  // ─── URL Blacklist ───────────────────────────────────────────────

  /// Blacklists a URL that has been confirmed to fail (403, 404, 410, timeout, etc.).
  /// The URL will be skipped during validation for the next [_blacklistTtl].
  static void blacklistUrl(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return;
    _blacklistedUrls[normalized] = DateTime.now().add(_blacklistTtl);
    // Periodic cleanup: remove expired entries when the map grows large
    if (_blacklistedUrls.length > 500) {
      _pruneBlacklist();
    }
  }

  /// Returns true if the URL is currently blacklisted and should be skipped.
  static bool isBlacklisted(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return false;
    final expiry = _blacklistedUrls[normalized];
    if (expiry == null) return false;
    if (DateTime.now().isAfter(expiry)) {
      _blacklistedUrls.remove(normalized);
      return false;
    }
    return true;
  }

  static void _pruneBlacklist() {
    final now = DateTime.now();
    _blacklistedUrls.removeWhere((_, expiry) => now.isAfter(expiry));
  }

  // ─── Session Management ──────────────────────────────────────────

  /// Registers a client to a specific session.
  static void _registerClient(String sessionId, http.Client client) {
    _sessionClients.putIfAbsent(sessionId, () => []).add(client);
  }

  /// Cancels all ongoing fallback searches and stream validations for a specific session.
  static void cancelSession(String sessionId) {
    debugPrint('[SearchCoordinator] Canceling active fallback tasks for session: $sessionId.');
    final clients = _sessionClients.remove(sessionId);
    if (clients != null) {
      for (var client in clients) {
        try {
          client.close();
        } catch (_) {}
      }
    }
  }

  /// Cancels all ongoing fallback searches and stream validations across all sessions.
  static void cancelAll() {
    debugPrint('[SearchCoordinator] Canceling all active fallback tasks across all sessions.');
    final keys = List<String>.from(_sessionClients.keys);
    for (var key in keys) {
      cancelSession(key);
    }
    _sessionClients.clear();
    _activeRecoveryTasks.clear();
  }

  // ─── LRU Cache ──────────────────────────────────────────────────

  /// Fast memory cache lookup (<5ms target).
  /// Expired entries are still returned for instant playback but trigger a background refresh.
  /// Accessing an entry promotes it to the most-recently-used position.
  static ResolvedStreamEntry? getCacheEntry(String songId, {Song? songFallback}) {
    final entry = _resolvedCache[songId];
    if (entry != null) {
      // Promote to MRU position
      _resolvedCache.remove(songId);
      _resolvedCache[songId] = entry;

      if (entry.isExpired) {
        if (songFallback != null) {
          debugPrint('[SearchCoordinator] Cache entry expired for $songId. Triggering automatic background refresh.');
          unawaited(recoverSong(songFallback, sessionId: 'auto-refresh-$songId'));
        }
        // Return expired entry for instant playback while refresh runs
        return entry;
      }
      if (entry.isValidated) {
        return entry;
      }
    }
    return null;
  }

  /// Consolidate caching of stream entries with LRU eviction.
  static void cacheStream({
    required String songId,
    required Song song,
    required String streamUrl,
    required bool isValidated,
    required DateTime expiresAt,
    required String provider,
    required int bitrate,
  }) {
    // Remove existing entry to update its position to MRU
    _resolvedCache.remove(songId);

    // Evict LRU entries if at capacity
    while (_resolvedCache.length >= _maxCacheSize) {
      _resolvedCache.remove(_resolvedCache.keys.first);
    }

    _resolvedCache[songId] = ResolvedStreamEntry(
      songId: songId,
      song: song,
      streamUrl: streamUrl,
      isValidated: isValidated,
      expiresAt: expiresAt,
      provider: provider,
      bitrate: bitrate,
    );
  }

  /// Backward compatible helper to cache resolved streams.
  static void cacheResolvedStream(String songId, String url, int bitrate, String provider) {
    final existingEntry = _resolvedCache[songId];
    final song = existingEntry?.song ?? Song(id: songId, streamUrl: url, name: '', artist: '');
    cacheStream(
      songId: songId,
      song: song,
      streamUrl: url,
      isValidated: true,
      expiresAt: DateTime.now().add(_cacheTtl),
      provider: provider,
      bitrate: bitrate,
    );
  }

  // ─── Recovery Engine ─────────────────────────────────────────────

  /// Launch parallel search tasks for recovery.
  /// Returns the first playable stream URL, or null if all fail.
  static Future<Song?> recoverSong(Song song, {String? sessionId}) {
    final songId = song.id.trim();
    if (songId.isEmpty) return Future.value(null);

    // Check if there is already an active recovery task running for this song
    final activeTask = _activeRecoveryTasks[songId];
    if (activeTask != null) {
      debugPrint('[SearchCoordinator] Awaiting existing recovery task for $songId');
      return activeTask;
    }

    // 0. Fast Memory Cache Lookup (occur before any network search)
    final cached = getCacheEntry(song.id, songFallback: song);
    if (cached != null && !isBlacklisted(cached.streamUrl)) {
      debugPrint('[SearchCoordinator] Memory cache hit for ${song.id}');
      return Future.value(cached.song.copyWith(streamUrl: cached.streamUrl));
    }

    final sessionKey = sessionId ?? 'default_${DateTime.now().microsecondsSinceEpoch}';

    final Future<Song?> recoveryFuture = _performRecoverSong(song, sessionKey);
    _activeRecoveryTasks[songId] = recoveryFuture;

    // Clean up from the active tasks map when completed
    recoveryFuture.whenComplete(() {
      _activeRecoveryTasks.remove(songId);
    });

    return recoveryFuture;
  }

  static Future<Song?> _performRecoverSong(Song song, String sessionKey) async {
    // 1. Determine query variants based on metadata
    String artistQuery = '';
    final artist = song.artist ?? '';
    if (artist.isNotEmpty) {
      artistQuery = artist.split(',').first.trim();
    }

    String? movieQuery;
    final movieMatch = RegExp(r'(?:\([Ff]rom\s+([^)]+)\)|\[[Ff]rom\s+([^\]]+)\])').firstMatch(song.name);
    if (movieMatch != null) {
      final rawMovie = (movieMatch.group(1) ?? movieMatch.group(2))?.trim() ?? '';
      var cleanMovie = rawMovie;
      if (cleanMovie.startsWith('"') || cleanMovie.startsWith("'")) {
        cleanMovie = cleanMovie.substring(1);
      }
      if (cleanMovie.endsWith('"') || cleanMovie.endsWith("'")) {
        cleanMovie = cleanMovie.substring(0, cleanMovie.length - 1);
      }
      movieQuery = cleanMovie.trim();
    }

    final albumQuery = (song.album ?? '').trim();

    String cleanTitle = song.name.replaceAll(RegExp(r'\([Ff]rom.*?\)|\[[Ff]rom.*?\]'), '');
    cleanTitle = cleanTitle.replaceAll(RegExp(r'\([Ff]eat.*?\)|\[[Ff]eat.*?\]'), '').trim();

    // Exactly the 9 Parallel Search query variants matching system design
    final rawQueries = <String>[
      // 1. Song Title
      song.name,
      // 2. Artist
      if (artistQuery.isNotEmpty) artistQuery,
      // 3. Album
      if (albumQuery.isNotEmpty) albumQuery,
      // 4. Movie
      if (movieQuery != null && movieQuery.isNotEmpty) movieQuery,
      // 5. Title + Artist
      if (artistQuery.isNotEmpty) '${song.name} $artistQuery',
      // 6. Title + Album
      if (albumQuery.isNotEmpty) '${song.name} $albumQuery',
      // 7. Artist + Movie
      if (artistQuery.isNotEmpty && movieQuery != null && movieQuery.isNotEmpty) '$artistQuery $movieQuery',
      // 8. Artist + Song
      if (artistQuery.isNotEmpty) '$artistQuery ${song.name}',
      // 9. Clean Title
      if (cleanTitle.isNotEmpty) cleanTitle,
    ];

    final queries = rawQueries
        .map((q) => q.trim().replaceAll(RegExp(r'\s+'), ' '))
        .where((q) => q.isNotEmpty)
        .toSet()
        .toList();

    if (queries.isEmpty) return null;

    final completer = Completer<Song?>();
    int pendingTasks = queries.length;
    bool isFinished = false;

    debugPrint('[SearchCoordinator] Starting parallel search with ${queries.length} variants. Session: $sessionKey');

    void checkCompletion() {
      if (!isFinished && pendingTasks == 0) {
        isFinished = true;
        if (!completer.isCompleted) completer.complete(null);
      }
    }

    Future<void> processCandidate(Song candidateSong, http.Client taskClient) async {
      if (isFinished) return;
      if (candidateSong.id == song.id) return;

      final confidence = VerificationEngine.calculateConfidence(candidateSong, song);
      if (confidence < VerificationEngine.threshold) return;

      var resolvedCandidate = candidateSong;
      if (!StreamResolver.hasStreamUrl(resolvedCandidate.toStreamMetadata())) {
        try {
          final details = await ApiService.getSong(candidateSong.id, client: taskClient);
          dynamic songMap = details;
          if (details.containsKey('data')) {
            dynamic d = details['data'];
            if (d is List && d.isNotEmpty) {
              songMap = d.first;
            } else if (d is Map) {
              songMap = d;
            }
          }
          resolvedCandidate = Song.fromJson(Map<String, dynamic>.from(songMap));
        } catch (_) {}
      }

      if (isFinished || !StreamResolver.hasStreamUrl(resolvedCandidate.toStreamMetadata())) return;

      // Skip candidates whose stream URL is already blacklisted
      if (isBlacklisted(resolvedCandidate.streamUrl!)) {
        debugPrint('[SearchCoordinator] Skipping blacklisted URL for candidate ${resolvedCandidate.id}');
        return;
      }

      // VALIDATION WITH CDN FALLBACK
      final validatedUrl = await _validateAndFallbackCdn(resolvedCandidate.streamUrl!, taskClient);

      if (isFinished) return;

      if (validatedUrl != null) {
        isFinished = true;

        final winnerSong = song.copyWith(
          streamUrl: validatedUrl,
          duration: resolvedCandidate.duration != null && resolvedCandidate.duration! > 0
              ? resolvedCandidate.duration
              : song.duration,
        );

        // Update Memory Cache (10-minute TTL)
        cacheStream(
          songId: song.id,
          song: winnerSong,
          streamUrl: validatedUrl,
          isValidated: true,
          expiresAt: DateTime.now().add(_cacheTtl),
          provider: 'recovery_engine',
          bitrate: resolvedCandidate.duration != null ? 320 : 160,
        );

        if (!completer.isCompleted) {
          completer.complete(winnerSong);
        }
      }
    }

    // Launch all tasks concurrently
    for (final query in queries) {
      final taskClient = ApiService.createSecureHttpClient(pinCertificates: false);
      _registerClient(sessionKey, taskClient);

      ApiService.searchSongs(query, client: taskClient).then((results) async {
        if (isFinished) return;

        final candidates = results.map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
            .where((c) => c.id != song.id)
            .toList();

        candidates.sort((a, b) =>
          VerificationEngine.calculateConfidence(b, song)
          .compareTo(VerificationEngine.calculateConfidence(a, song))
        );

        for (final candidateSong in candidates) {
          if (isFinished) break;
          await processCandidate(candidateSong, taskClient);
        }
      }).catchError((_) {}).whenComplete(() {
        pendingTasks--;
        checkCompletion();
      });
    }

    if (song.albumId != null && song.albumId!.trim().isNotEmpty) {
      final taskClient = ApiService.createSecureHttpClient(pinCertificates: false);
      _registerClient(sessionKey, taskClient);
      pendingTasks++;

      ApiService.getAlbums(id: song.albumId!.trim(), client: taskClient).then((albumDetails) async {
        if (isFinished) return;
        final songs = albumDetails['data']?['songs'];
        if (songs is List) {
          final candidates = songs.whereType<Map>().map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
              .where((c) => c.id != song.id).toList();
          candidates.sort((a, b) =>
             VerificationEngine.calculateConfidence(b, song).compareTo(VerificationEngine.calculateConfidence(a, song))
          );
          for (final candidateSong in candidates) {
            if (isFinished) break;
            await processCandidate(candidateSong, taskClient);
          }
        }
      }).catchError((_) {}).whenComplete(() {
        pendingTasks--;
        checkCompletion();
      });
    }

    if (pendingTasks == 0) {
      checkCompletion();
    }

    final winner = await completer.future;

    // Explicitly cancel all tasks of this session because we have a winner!
    cancelSession(sessionKey);

    return winner;
  }

  // ─── Stream Validation ───────────────────────────────────────────

  static Future<String?> _validateAndFallbackCdn(String urlStr, http.Client client) async {
    // Skip entirely blacklisted URLs
    if (isBlacklisted(urlStr)) return null;

    Uri? originalUri = Uri.tryParse(urlStr);
    if (originalUri == null) return null;

    // 1. Try original
    if (await _validateStream(originalUri, client)) {
      return originalUri.toString();
    }
    // Blacklist the original URL that failed
    blacklistUrl(originalUri.toString());

    // 2. Try alternate CDNs
    final host = originalUri.host;
    for (final cdn in _alternateCdns) {
      if (cdn == host) continue;

      final altUri = originalUri.replace(host: cdn);
      final altUrlStr = altUri.toString();
      if (isBlacklisted(altUrlStr)) continue;

      if (await _validateStream(altUri, client)) {
        return altUrlStr;
      }
      // Blacklist the CDN variant that also failed
      blacklistUrl(altUrlStr);
    }

    return null;
  }

  static Future<bool> _validateStream(Uri uri, http.Client client) async {
    try {
      final request = http.Request('HEAD', uri);
      final response = await client.send(request).timeout(const Duration(milliseconds: 800));

      if (response.statusCode == 200) {
        final contentType = response.headers['content-type']?.toLowerCase() ?? '';
        if (contentType.contains('html')) {
          return false;
        }
        if (contentType.startsWith('audio/') ||
            contentType == 'application/mp4' ||
            contentType == 'video/mp4' ||
            contentType.contains('octet-stream') ||
            contentType.contains('mpeg') ||
            contentType.contains('application/x-mpegurl')) {
          return true;
        }
      }

      // Fallback to GET range request if HEAD fails or returns non-200
      final getRequest = http.Request('GET', uri);
      getRequest.headers['Range'] = 'bytes=0-1'; // Request first 2 bytes
      final getResponse = await client.send(getRequest).timeout(const Duration(milliseconds: 800));

      if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
        final contentType = getResponse.headers['content-type']?.toLowerCase() ?? '';
        if (contentType.isNotEmpty && !contentType.contains('html')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Recover an entire album/playlist when multiple songs in it fail.
  /// Resolves the album tracks, matches them to the queue using ISRC, title, MBID,
  /// and track/duration heuristics, validates them, and caches them for subsequent play requests.
  static Future<Map<String, String>?> recoverAlbum(
    Song triggeringSong,
    List<Song> activeQueue, {
    String? sessionId,
  }) async {
    final albumId = triggeringSong.albumId?.trim() ?? '';
    final albumName = triggeringSong.album?.trim() ?? '';
    final albumKey = albumId.isNotEmpty ? albumId : albumName;

    if (albumKey.isEmpty) return null;

    // 0. Cache check: If recently recovered (within last 10 minutes), reuse cached results
    final cachedRecovery = _recoveredAlbumsCache[albumKey];
    if (cachedRecovery != null && DateTime.now().isBefore(cachedRecovery)) {
      debugPrint('[SearchCoordinator] Album $albumKey was recently recovered. Skipping search.');
      final Map<String, String> mapping = {};
      for (final s in activeQueue) {
        final sId = s.id;
        final entry = getCacheEntry(sId);
        if (entry != null && !isBlacklisted(entry.streamUrl)) {
          mapping[sId] = entry.streamUrl;
        }
      }
      return mapping.isNotEmpty ? mapping : null;
    }

    debugPrint('[SearchCoordinator] Recovering album: $albumKey (Triggered by ${triggeringSong.name})');

    final client = ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      Map<String, dynamic>? albumPayload;
      if (albumId.isNotEmpty) {
        try {
          albumPayload = await ApiService.getAlbums(id: albumId, client: client);
        } catch (_) {}
      }

      if ((albumPayload == null ||
              albumPayload['data'] == null ||
              (albumPayload['data'] is Map &&
                  (albumPayload['data']['songs'] == null ||
                      (albumPayload['data']['songs'] as List).isEmpty))) &&
          albumName.isNotEmpty) {
        try {
          final query = '$albumName ${triggeringSong.artist ?? ""}';
          albumPayload = await ApiService.getAlbums(query: query, client: client);
        } catch (_) {}
      }

      List<dynamic> rawSongs = [];
      if (albumPayload != null) {
        final data = albumPayload['data'];
        if (data is Map && data['songs'] is List) {
          rawSongs = data['songs'];
        } else if (albumPayload['songs'] is List) {
          rawSongs = albumPayload['songs'];
        }
      }

      if (rawSongs.isEmpty) {
        debugPrint('[SearchCoordinator] No songs found in resolved album details for $albumKey');
        return null;
      }

      final resolvedSongs = rawSongs
          .whereType<Map>()
          .map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
          .toList();

      final originalAlbumTracks = activeQueue.where((s) {
        final sId = s.albumId?.trim() ?? '';
        final sName = s.album?.trim() ?? '';
        final sKey = sId.isNotEmpty ? sId : sName;
        return sKey == albumKey;
      }).toList();

      final Map<Song, Song> matchMap = {};
      for (final origTrack in originalAlbumTracks) {
        final match = _findMatchingTrack(origTrack, resolvedSongs);
        if (match != null && match.streamUrl != null && match.streamUrl!.isNotEmpty) {
          matchMap[origTrack] = match;
        }
      }

      if (matchMap.isEmpty) {
        debugPrint('[SearchCoordinator] Album recovery matching returned 0 tracks');
        return null;
      }

      // Parallel validation of matched tracks
      final Map<String, String> validMapping = {};
      final List<Future<void>> validationFutures = [];

      for (final entry in matchMap.entries) {
        final origTrack = entry.key;
        final resolvedTrack = entry.value;
        final streamUrl = resolvedTrack.streamUrl!;

        validationFutures.add(
          _validateStream(Uri.parse(streamUrl), client).then((isValid) {
            if (isValid) {
              validMapping[origTrack.id] = streamUrl;
              // Cache in memory resolver cache (10-minute TTL)
              cacheStream(
                songId: origTrack.id,
                song: origTrack.copyWith(streamUrl: streamUrl),
                streamUrl: streamUrl,
                isValidated: true,
                expiresAt: DateTime.now().add(_cacheTtl),
                provider: 'album_recovery',
                bitrate: resolvedTrack.duration != null ? 320 : 160,
              );
            } else {
              blacklistUrl(streamUrl);
            }
          }),
        );
      }

      await Future.wait(validationFutures);

      if (validMapping.isNotEmpty) {
        // Cache this album recovery for 10 minutes
        _recoveredAlbumsCache[albumKey] = DateTime.now().add(_cacheTtl);
        debugPrint('[SearchCoordinator] Recovered ${validMapping.length} tracks for album: $albumKey');
        return validMapping;
      }
    } catch (e) {
      debugPrint('[SearchCoordinator] Album recovery failed: $e');
    } finally {
      client.close();
    }
    return null;
  }

  static Song? _findMatchingTrack(Song origTrack, List<Song> resolvedTracks) {
    // 1. ISRC Match
    if (origTrack.isrc != null && origTrack.isrc!.isNotEmpty) {
      final match = resolvedTracks.cast<Song?>().firstWhere(
        (t) => t != null && t.isrc != null && t.isrc!.toLowerCase().trim() == origTrack.isrc!.toLowerCase().trim(),
        orElse: () => null,
      );
      if (match != null) return match;
    }

    // 2. MusicBrainz ID Match
    if (origTrack.musicbrainzId != null && origTrack.musicbrainzId!.isNotEmpty) {
      final match = resolvedTracks.cast<Song?>().firstWhere(
        (t) => t != null && t.musicbrainzId != null && t.musicbrainzId!.toLowerCase().trim() == origTrack.musicbrainzId!.toLowerCase().trim(),
        orElse: () => null,
      );
      if (match != null) return match;
    }

    // 3. Verification Engine (Score >= threshold)
    Song? bestMatch;
    double bestConfidence = 0.0;
    for (final t in resolvedTracks) {
      final confidence = VerificationEngine.calculateConfidence(t, origTrack);
      if (confidence >= VerificationEngine.threshold && confidence > bestConfidence) {
        bestConfidence = confidence;
        bestMatch = t;
      }
    }
    if (bestMatch != null) return bestMatch;

    // 4. Fallback: Clean Title exact match (case insensitive)
    final cleanOrigTitle = origTrack.name.toLowerCase().trim();
    final match = resolvedTracks.cast<Song?>().firstWhere(
      (t) => t != null && t.name.toLowerCase().trim() == cleanOrigTitle,
      orElse: () => null,
    );
    return match;
  }
}
