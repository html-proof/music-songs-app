import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:http/http.dart' as raw_http;
import 'package:http/io_client.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'stability_logger.dart';
import 'connectivity_manager.dart';
import '../utils/content_filter.dart';
import '../utils/language_utils.dart';

class ApiService {
  static const String baseUrl =
      'https://fows.onrender.com'; // Production backend
  static const String _fallbackSearchBaseUrl =
      'https://jiosaavn-api-murex.vercel.app';
  static const Duration _homeCacheTtl = Duration(minutes: 15);
  static const Duration _albumCacheTtl = Duration(hours: 24);
  static const Duration _songCacheTtl = Duration(days: 7);
  static const Duration _searchRequestTimeout = Duration(seconds: 3);
  static const Duration _fallbackSearchTimeout = Duration(seconds: 3);
  static const Duration _artistRequestTimeout = Duration(seconds: 10);
  static const Duration _albumRequestTimeout = Duration(seconds: 12);
  static const int _maxPersistedCacheChars = 220000;
  static const int _maxInlineStringCharsForCache = 100000;
  static const int _maxListItemsForDiskCache = 250;
  static const int _maxListItemsForMemoryCache = 400;
  static const int _maxMemoryCacheEntries = 160;
  static final Map<String, Map<String, dynamic>> _memoryCache = {};
  static final Map<String, List<Map<String, dynamic>>>
  _artistAlbumSessionCache = {};
  static final Set<String> _artistAlbumSessionExhausted = {};
  static const Duration _searchCacheTtl = Duration(minutes: 5);
  static final Map<String, Future<dynamic>> _inFlightRequests = {};

  static Future<T> _deduplicateRequest<T>(String key, Future<T> Function() fetch) {
    final active = _inFlightRequests[key];
    if (active != null) {
      StabilityLogger.info('Network', 'DEDUPLICATED: Reusing in-flight request for: $key');
      return active as Future<T>;
    }
    final future = fetch().whenComplete(() {
      _inFlightRequests.remove(key);
    });
    _inFlightRequests[key] = future;
    return future;
  }

  static String _sessionSeed = (DateTime.now().millisecondsSinceEpoch ^ 42)
      .toRadixString(16);

  /// Rotates the session seed to force fresh randomized content on next load.
  static void rotateSessionSeed() {
    _sessionSeed = (DateTime.now().millisecondsSinceEpoch ^ 0xFEED)
        .toRadixString(16);
    debugPrint('[ApiService] Session seed rotated: $_sessionSeed');
  }

  /// Whether the backend has responded to at least one request.
  static bool _backendAwake = false;
  static bool get isBackendAwake => _backendAwake;

  static bool _isPrimaryApiHealthy = true;
  static DateTime? _lastPrimaryApiCheck;

  static bool get _shouldUsePrimaryApi {
    if (!_isPrimaryApiHealthy) {
      if (_lastPrimaryApiCheck != null &&
          DateTime.now().difference(_lastPrimaryApiCheck!) > const Duration(minutes: 5)) {
        _isPrimaryApiHealthy = true;
        debugPrint('[ApiService] Cooldown expired. Retrying primary API...');
      }
    }
    return _isPrimaryApiHealthy;
  }

  static void _markPrimaryApiUnhealthy() {
    if (_isPrimaryApiHealthy) {
      _isPrimaryApiHealthy = false;
      _lastPrimaryApiCheck = DateTime.now();
      debugPrint('[ApiService] Primary API marked unhealthy. Direct fallback active.');
    }
  }

  static raw_http.Client createSecureHttpClient({bool pinCertificates = true}) {
    if (kDebugMode) {
      return raw_http.Client();
    }

    try {
      final context = pinCertificates
          ? SecurityContext(withTrustedRoots: false)
          : SecurityContext.defaultContext;

      if (pinCertificates) {
        context.setTrustedCertificatesBytes(utf8.encode(_isrgRootX1Pem));
        context.setTrustedCertificatesBytes(utf8.encode(_isrgRootX2Pem));
        context.setTrustedCertificatesBytes(utf8.encode(_amazonRootCA1Pem));
      }

      final httpClient = HttpClient(context: context);
      httpClient.badCertificateCallback = (cert, host, port) {
        return false;
      };

      return IOClient(httpClient);
    } catch (e) {
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => false;
      return IOClient(httpClient);
    }
  }

  /// Fire-and-forget: ping the backend health endpoint to wake it up from
  /// Render's free-tier sleep. Call this as early as possible in app startup
  /// so the cold-start completes while the user sees cached/local content.
  ///
  /// Set [forcePing] to true for periodic keep-alive pings even after the
  /// backend has already been marked awake.
  static Future<void> warmUpBackend({bool forcePing = false}) async {
    if (_backendAwake && !forcePing) return;
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/healthz'))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final wasAwake = _backendAwake;
        _backendAwake = true;
        if (!wasAwake) {
          debugPrint('[ApiService] Backend is awake');
        }
      }
    } catch (e) {
      if (!forcePing) {
        debugPrint('[ApiService] Warm-up ping failed: $e');
      }
    }
  }

  static Future<void> preFetchHomeData({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
  }) async {
    // This populates both SharedPreferences AND _memoryCache in the background.
    unawaited(
      getPersonalizedRecommendations(
        languages: languages,
        favoriteArtists: favoriteArtists,
      ),
    );
    unawaited(
      getRecommendedAlbums(
        languages: languages,
        favoriteArtists: favoriteArtists,
      ),
    );
    unawaited(getTrendingSongs(languages: languages));
    unawaited(getPlaylists(languages: languages));
    unawaited(
      getSuggestedArtists(
        languages: languages,
        favoriteArtists: favoriteArtists,
      ),
    );
    unawaited(getHistory(type: 'play', limit: 6));
  }

  static Map<String, dynamic>? getCachedHomeData({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
  }) {
    final normalizedLanguages = _normalizeList(languages);
    final normalizedArtists = _normalizeArtists(favoriteArtists);

    final recsKey = _cacheKey('home_song_recs', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedArtists,
      'limit': 20,
      'session': _sessionSeed,
    });
    final recsRaw = _readMemoryCacheSync(recsKey, _homeCacheTtl);
    if (recsRaw == null) return null;

    final albumsKey = _cacheKey('home_album_recs', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedArtists,
      'limit': 8,
      'session': _sessionSeed,
    });
    final albumsRaw = _readMemoryCacheSync(albumsKey, _homeCacheTtl);

    final trendingKey = _cacheKey('home_trending_songs', {
      'languages': normalizedLanguages,
      'limit': 12,
      'session': _sessionSeed,
    });
    final trendingRaw = _readMemoryCacheSync(trendingKey, _homeCacheTtl);

    final playlistsKey = _cacheKey('home_playlists', {
      'languages': normalizedLanguages,
      'limit': 8,
      'session': _sessionSeed,
    });
    final playlistsRaw = _readMemoryCacheSync(playlistsKey, _homeCacheTtl);

    final artistsKey = _cacheKey('home_suggested_artists', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedArtists,
      'limit': 8,
      'session': _sessionSeed,
    });
    final artistsRaw = _readMemoryCacheSync(artistsKey, _homeCacheTtl);

    final historyKey = _cacheKey('user_activity_history', {
      'type': 'play',
      'limit': 6,
    });
    final historyRaw = _readMemoryCacheSync(historyKey, _homeCacheTtl);

    return {
      'recommendations': recsRaw,
      'recommendedAlbums': albumsRaw,
      'trendingSongs': trendingRaw,
      'playlists': playlistsRaw,
      'suggestedArtists': artistsRaw,
      'recentlyPlayed': historyRaw,
    };
  }

  static Map<String, List<dynamic>> _emptySearchResult() => {
    'songs': const [],
    'albums': const [],
    'artists': const [],
  };

  static Map<String, dynamic> _emptyAlbumResult() => {
    'success': false,
    'data': {'results': const [], 'songs': const []},
  };

  static Future<Map<String, String>> _authHeaders() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {'Content-Type': 'application/json'};

    String? token;
    try {
      // Try to get refreshed token but with a timeout
      token = await user.getIdToken(true).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Token refresh failed (network?), using cached: $e');
      try {
        // Fallback to cached token if refresh fails
        token = await user.getIdToken(false);
      } catch (_) {
        token = null;
      }
    }

    if (token == null) return {'Content-Type': 'application/json'};

    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static String _cacheKey(String namespace, Object identity) {
    return 'cache_${namespace}_${_stableHash(identity)}';
  }

  static String _stableHash(Object value) {
    final raw = jsonEncode(value);
    var hash = 0;
    for (final unit in raw.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  static bool _isFresh(int timestampMs, Duration ttl) {
    if (timestampMs <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - timestampMs <= ttl.inMilliseconds;
  }

  static Future<bool> _isOffline() async {
    return ConnectivityManager.isOffline;
  }

  static Future<dynamic> _readCache(String key, Duration ttl, {bool ignoreTtlIfOffline = true}) async {
    final memory = _memoryCache[key];
    final offline = ignoreTtlIfOffline && await _isOffline();

    if (memory != null) {
      final ts = memory['ts'] as int? ?? 0;
      if (offline || _isFresh(ts, ttl)) {
        return memory['data'];
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      if (raw.length > _maxPersistedCacheChars) {
        await prefs.remove(key);
        return null;
      }

      final parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      final payload = Map<String, dynamic>.from(parsed);
      final ts = payload['ts'] as int? ?? 0;
      if (!offline && !_isFresh(ts, ttl)) {
        await prefs.remove(key);
        return null;
      }
      _memoryCache[key] = payload;
      _pruneMemoryCache();
      return payload['data'];
    } catch (_) {
      return null;
    }
  }

  static dynamic _readMemoryCacheSync(String key, Duration ttl) {
    _pruneMemoryCache();
    final memory = _memoryCache[key];
    if (memory != null) {
      final ts = memory['ts'] as int? ?? 0;
      if (_isFresh(ts, ttl)) {
        return memory['data'];
      }
    }
    return null;
  }

  static Future<void> _writeCache(String key, dynamic data) async {
    final payload = {'ts': DateTime.now().millisecondsSinceEpoch, 'data': data};
    if (_shouldStoreInMemoryCache(data)) {
      _memoryCache[key] = Map<String, dynamic>.from(payload);
      _pruneMemoryCache();
    } else {
      _memoryCache.remove(key);
    }
    if (!_shouldPersistCacheEntry(key, data)) {
      await _removePersistedCacheEntryIfPresent(key);
      return;
    }

    try {
      final encoded = jsonEncode(payload);
      if (encoded.length > _maxPersistedCacheChars) {
        await _removePersistedCacheEntryIfPresent(key);
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, encoded);
    } catch (_) {}
  }

  static Future<void> _deleteCache(String key) async {
    _memoryCache.remove(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }

  static List<Map<String, dynamic>> _asMapList(dynamic input) {
    if (input is! List) return const [];
    return input
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  static Map<String, dynamic> _sanitizeAlbumPayload(
    Map<String, dynamic> payload,
  ) {
    final sanitized = Map<String, dynamic>.from(payload);
    final data = sanitized['data'];

    if (data is Map) {
      sanitized['data'] = _sanitizeAlbumDataMap(
        Map<String, dynamic>.from(data),
      );
    } else if (data is List) {
      sanitized['data'] = _sanitizeAlbumList(data);
    } else if (sanitized.containsKey('songs') ||
        sanitized.containsKey('results') ||
        sanitized.containsKey('albums')) {
      return _sanitizeAlbumDataMap(sanitized);
    }

    return sanitized;
  }

  static Map<String, dynamic> _sanitizeAlbumDataMap(Map<String, dynamic> data) {
    final sanitized = Map<String, dynamic>.from(data);

    final songsInfo = sanitized['songs'];
    if (songsInfo is List) {
      final filteredSongs = _sanitizeSongList(songsInfo);
      sanitized['songs'] = filteredSongs;
      _updateSongCountFields(sanitized, filteredSongs.length);
    }

    final resultsInfo = sanitized['results'];
    if (resultsInfo is List) {
      sanitized['results'] = _sanitizeAlbumList(resultsInfo);
    }

    final albumsInfo = sanitized['albums'];
    if (albumsInfo is List) {
      sanitized['albums'] = _sanitizeAlbumList(albumsInfo);
    }

    if (_looksLikeAlbumEntity(sanitized)) {
      return _sanitizeAlbumEntity(sanitized) ?? <String, dynamic>{};
    }

    return sanitized;
  }

  static List<Map<String, dynamic>> _sanitizeAlbumList(List<dynamic> albums) {
    return albums
        .whereType<Map>()
        .map((entry) => _sanitizeAlbumEntity(Map<String, dynamic>.from(entry)))
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> _sanitizeSongList(List<dynamic> songs) {
    return songs
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .where(_isValidSong)
        .toList(growable: false);
  }

  static Map<String, dynamic>? _sanitizeAlbumEntity(
    Map<String, dynamic> album,
  ) {
    final sanitized = Map<String, dynamic>.from(album);

    final songsInfo = sanitized['songs'];
    if (songsInfo is List) {
      final filteredSongs = _sanitizeSongList(songsInfo);
      sanitized['songs'] = filteredSongs;
      _updateSongCountFields(sanitized, filteredSongs.length);
      if (songsInfo.isNotEmpty && filteredSongs.isEmpty) {
        return null;
      }
    }

    if (!_isValidAlbum(sanitized)) return null;
    return sanitized;
  }

  static bool _looksLikeAlbumEntity(Map<String, dynamic> value) {
    final id = (value['id'] ?? '').toString().trim();
    final name = (value['name'] ?? value['title'] ?? '').toString().trim();
    return id.isNotEmpty && name.isNotEmpty;
  }

  static void _updateSongCountFields(
    Map<String, dynamic> album,
    int filteredSongCount,
  ) {
    if (album.containsKey('songCount')) album['songCount'] = filteredSongCount;
    if (album.containsKey('song_count')) {
      album['song_count'] = filteredSongCount;
    }
    if (album.containsKey('songsCount')) {
      album['songsCount'] = filteredSongCount;
    }
    if (album.containsKey('totalSongs')) {
      album['totalSongs'] = filteredSongCount;
    }
  }

  static bool _shouldPersistCacheEntry(String key, dynamic data) {
    if (_isLargeByKeyNamespace(key)) return false;
    if (_containsOversizedInlineString(data)) return false;
    if (data is List && data.length > _maxListItemsForDiskCache) return false;
    return true;
  }

  static bool _shouldStoreInMemoryCache(dynamic data) {
    if (_containsOversizedInlineString(data)) return false;
    if (data is List && data.length > _maxListItemsForMemoryCache) return false;
    return true;
  }

  static bool _isLargeByKeyNamespace(String key) {
    return key.startsWith('cache_song_') ||
        key.startsWith('cache_album_detail_');
  }

  static bool _containsOversizedInlineString(dynamic value, {int depth = 0}) {
    if (depth > 6 || value == null) return false;
    if (value is String) {
      return value.length > _maxInlineStringCharsForCache;
    }
    if (value is List) {
      final sampleCount = value.length > 40 ? 40 : value.length;
      for (var i = 0; i < sampleCount; i++) {
        if (_containsOversizedInlineString(value[i], depth: depth + 1)) {
          return true;
        }
      }
      return false;
    }
    if (value is Map) {
      var inspected = 0;
      for (final entry in value.entries) {
        if (_containsOversizedInlineString(entry.value, depth: depth + 1)) {
          return true;
        }
        inspected += 1;
        if (inspected >= 60) break;
      }
    }
    return false;
  }

  static Future<void> _removePersistedCacheEntryIfPresent(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  static void _pruneMemoryCache() {
    if (_memoryCache.length <= _maxMemoryCacheEntries) return;

    final sortedEntries = _memoryCache.entries.toList(growable: false)
      ..sort((a, b) {
        final aTs = a.value['ts'] as int? ?? 0;
        final bTs = b.value['ts'] as int? ?? 0;
        return aTs.compareTo(bTs);
      });

    final removeCount = _memoryCache.length - _maxMemoryCacheEntries;
    for (var i = 0; i < removeCount; i++) {
      _memoryCache.remove(sortedEntries[i].key);
    }
  }

  // ─── Public Endpoints ────────────────────────────────────

  static Future<Map<String, List<dynamic>>> globalSearch(
    String query, {
    List<String> preferredLanguages = const [],
    int limit = 20,
  }) async {
    final normalizedQuery = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedQuery.isEmpty) {
      return _emptySearchResult();
    }

    final normalizedLanguages = _normalizeList(preferredLanguages);
    final safeLimit = limit.clamp(10, 20);

    final cacheKey = _cacheKey('global_search', {
      'query': normalizedQuery,
      'languages': normalizedLanguages,
      'limit': safeLimit,
    });

    final cached = await _readCache(cacheKey, _searchCacheTtl);
    if (cached is Map) {
      final cachedMap = Map<String, dynamic>.from(cached);
      return {
        'songs': cachedMap['songs'] ?? const [],
        'albums': cachedMap['albums'] ?? const [],
        'artists': cachedMap['artists'] ?? const [],
      };
    }

    final requestKey = 'global_search_${normalizedQuery}_${normalizedLanguages.join(",")}';
    return _deduplicateRequest<Map<String, List<dynamic>>>(requestKey, () async {
      final result = await _globalSearchInternal(
        normalizedQuery,
        normalizedLanguages: normalizedLanguages,
        safeLimit: safeLimit,
      );
      if (result['songs']!.isNotEmpty || result['albums']!.isNotEmpty || result['artists']!.isNotEmpty) {
        await _writeCache(cacheKey, result);
      }
      return result;
    });
  }

  static Future<Map<String, List<dynamic>>> _globalSearchInternal(
    String normalizedQuery, {
    required List<String> normalizedLanguages,
    required int safeLimit,
  }) async {
    final queryParams = <String, String>{
      'query': normalizedQuery,
      'limit': safeLimit.toString(),
    };
    if (normalizedLanguages.isNotEmpty) {
      queryParams['languages'] = normalizedLanguages.join(',');
    }

    dynamic responseData;
    if (_shouldUsePrimaryApi) {
      try {
        final res = await http
            .get(
              Uri.parse(
                '$baseUrl/api/search',
              ).replace(queryParameters: queryParams),
            )
            .timeout(_searchRequestTimeout);
        if (res.statusCode != 200) throw Exception('Search failed');
        responseData = jsonDecode(res.body);
      } catch (e) {
        debugPrint('Primary global search failed: $e');
        _markPrimaryApiUnhealthy();
      }
    }

    // Primary search failed or returned nothing, try retry OR fallback.
    // If strict language is requested, we should be careful about retrying without languages,
    // but the original code had it. I'll keep it but ensure filtering happens afterwards.
    if (responseData == null && normalizedLanguages.isNotEmpty && _shouldUsePrimaryApi) {
      try {
        final retryParams = <String, String>{
          'query': normalizedQuery,
          'limit': safeLimit.toString(),
        };
        final retryRes = await http
            .get(
              Uri.parse(
                '$baseUrl/api/search',
              ).replace(queryParameters: retryParams),
            )
            .timeout(_searchRequestTimeout);
        if (retryRes.statusCode == 200) {
          responseData = jsonDecode(retryRes.body);
        } else {
          _markPrimaryApiUnhealthy();
        }
      } catch (e) {
        debugPrint('Search retry without language failed: $e');
        _markPrimaryApiUnhealthy();
      }
    }

    if (responseData == null) {
      try {
        final fallbackSongs = await _searchSongsFallback(normalizedQuery);
        // Apply strict filtering to fallback results
        final filteredFallback = fallbackSongs.where((s) {
          if (s is! Map) return false;
          final song = Map<String, dynamic>.from(s);
          return _isValidSong(song) &&
              _matchesPreferredLanguage(song, normalizedLanguages);
        }).toList();

        if (filteredFallback.isNotEmpty) {
          final scored =
              filteredFallback.map((s) {
                final song = Map<String, dynamic>.from(s);
                return {
                  'song': song,
                  'score': _scoreResultItem(song, normalizedQuery),
                };
              }).toList()..sort(
                (a, b) => (b['score'] as int).compareTo(a['score'] as int),
              );

          final finalSongs = scored
              .map((e) => e['song'])
              .take(safeLimit)
              .toList();

          return {
            'songs': finalSongs,
            'albums': _mergeAlbumLists(
              [],
              _deriveAlbumsFromSongs(finalSongs),
              languages: normalizedLanguages,
            ),
            'artists': _deriveArtistsFromSongs(finalSongs),
          };
        }
      } catch (e) {
        debugPrint('Fallback global search failed: $e');
      }
      return _emptySearchResult();
    }

    if (responseData is! Map) return _emptySearchResult();
    final d = responseData['data'] ?? responseData;
    if (d is! Map) return _emptySearchResult();

    List<dynamic> extractResults(dynamic category) {
      if (category == null) return [];
      if (category is List) return category;
      if (category is Map && category['results'] != null) {
        return category['results'] as List;
      }
      return [];
    }

    final rawSongs = extractResults(d['songs']);
    final songs =
        rawSongs
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .where(
              (s) =>
                  _isValidSong(s) &&
                  _matchesPreferredLanguage(s, normalizedLanguages),
            )
            .map(
              (s) => {'song': s, 'score': _scoreResultItem(s, normalizedQuery)},
            )
            .toList()
          ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

    final finalSongs = songs.map((e) => e['song']).take(safeLimit).toList();

    final rawAlbums = extractResults(d['albums']);
    final mergedAlbums = _mergeAlbumLists(
      rawAlbums,
      _deriveAlbumsFromSongs(rawSongs),
      languages: normalizedLanguages,
    );

    // Score and sort albums
    final scoredAlbums =
        mergedAlbums
            .map(
              (a) => {
                'album': a,
                'score': _scoreResultItem(a, normalizedQuery, isSong: false),
              },
            )
            .toList()
          ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

    final finalAlbums = scoredAlbums
        .map((e) => e['album'])
        .take(safeLimit)
        .toList();

    final artists = extractResults(
      d['artists'],
    ).whereType<Map>().take(safeLimit).toList();

    return {'songs': finalSongs, 'albums': finalAlbums, 'artists': artists};
  }

  static Future<List<dynamic>> searchSongs(
    String query, {
    int page = 1,
    List<String> preferredLanguages = const [],
    int limit = 20,
  }) async {
    final normalizedQuery = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedQuery.isEmpty) return const [];

    final normalizedLanguages = _normalizeList(preferredLanguages);
    final safeLimit = limit.clamp(10, 20);
    final queryParams = <String, String>{
      'query': normalizedQuery,
      'page': page.toString(),
      'limit': safeLimit.toString(),
    };
    if (normalizedLanguages.isNotEmpty) {
      queryParams['languages'] = normalizedLanguages.join(',');
    }

    dynamic responseData;
    if (_shouldUsePrimaryApi) {
      try {
        final res = await http
            .get(
              Uri.parse(
                '$baseUrl/api/search',
              ).replace(queryParameters: queryParams),
            )
            .timeout(_searchRequestTimeout);
        if (res.statusCode != 200) throw Exception('Search failed');
        responseData = jsonDecode(res.body);
      } catch (e) {
        debugPrint('searchSongs primary failed: $e');
        _markPrimaryApiUnhealthy();
      }
    }

    if (responseData == null) {
      try {
        final fallback = await globalSearch(
          normalizedQuery,
          preferredLanguages: normalizedLanguages,
          limit: safeLimit,
        );
        return (fallback['songs'] ?? const [])
            .take(safeLimit)
            .toList(growable: false);
      } catch (fallbackError) {
        debugPrint('searchSongs fallback failed: $fallbackError');
      }
      return const [];
    }

    if (responseData is! Map) return const [];
    final d = responseData['data'] ?? responseData;
    if (d is! Map) return const [];

    List<dynamic> rawSongs = [];

    // Try to find songs list in various common structures
    if (d['songs'] != null) {
      if (d['songs'] is List) {
        rawSongs = d['songs'] as List;
      } else if (d['songs'] is Map && d['songs']['results'] != null) {
        rawSongs = d['songs']['results'] as List;
      }
    } else if (d['results'] != null) {
      rawSongs = d['results'] as List;
    }

    final songs =
        rawSongs
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .where(
              (s) =>
                  _isValidSong(s) &&
                  _matchesPreferredLanguage(s, normalizedLanguages),
            )
            .map(
              (s) => {'song': s, 'score': _scoreResultItem(s, normalizedQuery)},
            )
            .toList()
          ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

    return songs.map((e) => e['song']).take(safeLimit).toList(growable: false);
  }

  static Future<Map<String, dynamic>> getSong(String id, {bool forceRefresh = false}) async {
    final songCacheKey = _cacheKey('song', {'id': id});
    if (!forceRefresh) {
      final cached = await _readCache(songCacheKey, _songCacheTtl);
      if (cached is Map) {
        return Map<String, dynamic>.from(cached);
      }
    }

    if (_shouldUsePrimaryApi) {
      try {
        final res = await http
            .get(Uri.parse('$baseUrl/api/songs/$id'))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final parsed = jsonDecode(res.body);
          await _writeCache(songCacheKey, parsed);
          return Map<String, dynamic>.from(parsed);
        } else {
          _markPrimaryApiUnhealthy();
        }
      } catch (e) {
        debugPrint('Primary getSong failed: $e');
        _markPrimaryApiUnhealthy();
      }
    }

    // Fallback to Vercel API
    debugPrint('Using Vercel fallback for getSong...');
    try {
      final res = await http
          .get(Uri.parse('$_fallbackSearchBaseUrl/api/songs?ids=$id'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final parsed = jsonDecode(res.body);
        dynamic songData = parsed;
        if (parsed is Map) {
          final d = parsed['data'];
          if (d is List && d.isNotEmpty) {
            songData = d.first;
          } else if (d is Map) {
            songData = d;
          }
        } else if (parsed is List && parsed.isNotEmpty) {
          songData = parsed.first;
        }

        if (songData is Map) {
          final normalized = Map<String, dynamic>.from(songData);
          await _writeCache(songCacheKey, normalized);
          return normalized;
        }
      }
    } catch (e) {
      debugPrint('Vercel fallback getSong failed: $e');
    }

    throw Exception('Song fetch failed');
  }

  static Future<Map<String, dynamic>> getAlbums({
    String? id,
    String? query,
    List<String> preferredLanguages = const [],
  }) async {
    final normalizedId = (id ?? '').trim();
    final normalizedQuery = (query ?? '').trim();
    final hasId = normalizedId.isNotEmpty;
    final hasQuery = normalizedQuery.isNotEmpty;

    if (!hasId && !hasQuery) {
      return _emptyAlbumResult();
    }

    final normalizedLanguages = _normalizeList(preferredLanguages);

    final useAlbumCache = hasId && !hasQuery;
    String? albumCacheKey;
    if (useAlbumCache) {
      albumCacheKey = _cacheKey('album_detail', {'id': normalizedId});
      final cached = await _readCache(albumCacheKey, _albumCacheTtl);
      if (cached is Map) {
        return _sanitizeAlbumPayload(Map<String, dynamic>.from(cached));
      }
    }

    final queryParams = <String, String>{};
    if (hasId) queryParams['id'] = normalizedId;
    if (hasQuery) queryParams['query'] = normalizedQuery;
    if (normalizedLanguages.isNotEmpty) {
      queryParams['languages'] = normalizedLanguages.join(',');
    }

    final requestKey = 'get_albums_${normalizedId}_${normalizedQuery}_${normalizedLanguages.join(",")}';
    return _deduplicateRequest<Map<String, dynamic>>(requestKey, () async {
      try {
        final res = await http
            .get(
              Uri.parse(
                '$baseUrl/api/albums',
              ).replace(queryParameters: queryParams),
            )
            .timeout(_albumRequestTimeout);

        if (res.statusCode == 200) {
          final parsed = jsonDecode(res.body);
          if (parsed is Map<String, dynamic>) {
            final sanitized = _sanitizeAlbumPayload(parsed);
            if (albumCacheKey != null) {
              await _writeCache(albumCacheKey, sanitized);
            }
            return sanitized;
          }
        } else {
          debugPrint('Album fetch failed: ${res.statusCode} ($queryParams)');
        }
      } catch (e) {
        debugPrint('Album request error ($queryParams): $e');
      }

      // Fallback: recover album lists from search payload.
      try {
        final seed = hasQuery ? normalizedQuery : normalizedId;
        if (seed.isNotEmpty) {
          final fallback = await globalSearch(
            seed,
            preferredLanguages: normalizedLanguages,
            limit: 20,
          );
          var albums = _asMapList(fallback['albums']);
          if (hasId) {
            albums = albums
                .where((album) => (album['id'] ?? '').toString() == normalizedId)
                .toList(growable: false);
          }

          if (albums.isEmpty && hasQuery) {
            albums = _deriveAlbumsFromSongs(fallback['songs'] ?? const [])
                .whereType<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList(growable: false);
          }

          if (albums.isNotEmpty) {
            final fallbackPayload = <String, dynamic>{
              'success': true,
              'data': {'results': albums, 'songs': const []},
            };
            return _sanitizeAlbumPayload(fallbackPayload);
          }
        }
      } catch (e) {
        debugPrint('Album fallback failed: $e');
      }

      return _emptyAlbumResult();
    });
  }

  static Future<List<dynamic>> getArtistsByLanguage(String language) async {
    final normalizedLanguage = LanguageUtils.normalizeLanguage(language);
    if (normalizedLanguage.isEmpty) return const [];

    try {
      final res = await http
          .get(
            Uri.parse(
              '$baseUrl/api/artists/by-language?language=${Uri.encodeComponent(normalizedLanguage)}',
            ),
          )
          .timeout(_artistRequestTimeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final artists = data['data'];
        if (artists is List) return artists;
      } else {
        debugPrint(
          'Artists by language failed: ${res.statusCode} ($normalizedLanguage)',
        );
      }
    } catch (e) {
      debugPrint('Artists by language request error ($normalizedLanguage): $e');
    }

    // Fallback to global search so onboarding doesn't fail hard.
    try {
      final fallback = await globalSearch(
        'Top $normalizedLanguage artists',
        preferredLanguages: [normalizedLanguage],
        limit: 20,
      );
      final artists = fallback['artists'];
      if (artists is List && artists.isNotEmpty) return artists;
    } catch (e) {
      debugPrint(
        'Artists by language fallback failed ($normalizedLanguage): $e',
      );
    }

    return const [];
  }

  static Future<Map<String, dynamic>?> getArtistById(String id) async {
    if (id.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/artists/$id'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['data'];
      }
    } catch (_) {}
    return null;
  }

  static Future<List<dynamic>> getArtistSongs(String id) async {
    if (id.isEmpty) return const [];
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/artists/$id/songs'))
          .timeout(_artistRequestTimeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['data']?['songs'] ?? data['data'] ?? [];
      }
    } catch (_) {}
    return const [];
  }

  static Future<List<dynamic>> getArtistAlbums(
    String artistId, {
    String? artistName,
    int limit = 20,
    int page = 1,
  }) async {
    final safeLimit = limit < 1 ? 20 : limit;
    final safePage = page < 1 ? 1 : page;
    final cacheKey = _artistAlbumCacheKey(artistId, artistName);
    final rangeStart = (safePage - 1) * safeLimit;
    final rangeEnd = rangeStart + safeLimit;

    final cached = _artistAlbumSessionCache[cacheKey];
    final isExhausted = _artistAlbumSessionExhausted.contains(cacheKey);
    if (cached != null &&
        (cached.length >= rangeEnd || isExhausted || safePage == 1)) {
      return cached.skip(rangeStart).take(safeLimit).toList(growable: false);
    }

    try {
      // Primary: Try direct artist albums endpoint
      final url = artistId.isNotEmpty
          ? '$baseUrl/api/artists/$artistId/albums?limit=$safeLimit&page=$safePage'
          : '$baseUrl/api/search?query=${Uri.encodeComponent('$artistName albums')}&type=album';

      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final normalized = _extractArtistAlbums(data);
        if (normalized.isNotEmpty) {
          _mergeArtistAlbumSessionCache(
            cacheKey: cacheKey,
            incoming: normalized,
          );
          if (normalized.length < safeLimit) {
            _artistAlbumSessionExhausted.add(cacheKey);
          }
          final merged = _artistAlbumSessionCache[cacheKey] ?? normalized;
          return merged
              .skip(rangeStart)
              .take(safeLimit)
              .toList(growable: false);
        }
      }
    } catch (_) {}

    // Fallback: Search by artist name if ID fetch fails
    if (artistName != null && artistName.isNotEmpty) {
      try {
        final searchResults = await globalSearch('$artistName albums');
        final fallbackAlbums = (searchResults['albums'] ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((a) => _isValidAlbum(a))
            .toList(growable: false);
        if (fallbackAlbums.isNotEmpty) {
          _mergeArtistAlbumSessionCache(
            cacheKey: cacheKey,
            incoming: fallbackAlbums,
          );
          _artistAlbumSessionExhausted.add(cacheKey);
          return fallbackAlbums
              .skip(rangeStart)
              .take(safeLimit)
              .toList(growable: false);
        }
      } catch (_) {}
    }

    return const [];
  }

  static List<Map<String, dynamic>> _extractArtistAlbums(dynamic payload) {
    final candidates = <Map<String, dynamic>>[];

    void collect(dynamic value, {int depth = 0}) {
      if (value == null || depth > 4) return;

      if (value is List) {
        for (final item in value) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          if (_isValidAlbum(map)) candidates.add(map);
        }
        return;
      }

      if (value is Map) {
        collect(value['results'], depth: depth + 1);
        collect(value['albums'], depth: depth + 1);
        collect(value['data'], depth: depth + 1);
      }
    }

    collect(payload);

    final deduped = <String, Map<String, dynamic>>{};
    for (final album in candidates) {
      final id = (album['id'] ?? '').toString().trim().toLowerCase();
      final name = (album['name'] ?? album['title'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final key = id.isNotEmpty ? id : 'name:$name';
      if (key == 'name:' || deduped.containsKey(key)) continue;
      deduped[key] = album;
    }

    return deduped.values.toList(growable: false);
  }

  static String _artistAlbumCacheKey(String artistId, String? artistName) {
    final id = artistId.trim().toLowerCase();
    if (id.isNotEmpty) return 'id:$id';
    final name = (artistName ?? '').trim().toLowerCase();
    return 'name:$name';
  }

  static void _mergeArtistAlbumSessionCache({
    required String cacheKey,
    required List<Map<String, dynamic>> incoming,
  }) {
    final existing = _artistAlbumSessionCache[cacheKey] ?? const [];
    final mergedByKey = <String, Map<String, dynamic>>{};

    void append(Iterable<Map<String, dynamic>> source) {
      for (final item in source) {
        final id = (item['id'] ?? '').toString().trim().toLowerCase();
        final name = (item['name'] ?? item['title'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final key = id.isNotEmpty ? id : name;
        if (key.isEmpty || mergedByKey.containsKey(key)) continue;
        mergedByKey[key] = item;
      }
    }

    append(existing);
    append(incoming);

    _artistAlbumSessionCache[cacheKey] = mergedByKey.values.toList(
      growable: false,
    );
  }

  static Future<List<dynamic>> getTrendingAlbums({
    required List<String> languages,
    int limit = 10,
  }) async {
    try {
      final res = await getRecommendedAlbums(
        languages: languages,
        favoriteArtists: const [],
        limit: limit,
      );
      return res;
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getPersonalizedRecommendations({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
    int limit = 20,
  }) async {
    final normalizedLanguages = _normalizeList(languages);
    final normalizedFavoriteArtists = _normalizeArtists(favoriteArtists);

    final cacheKey = _cacheKey('home_song_recs', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedFavoriteArtists,
      'limit': limit,
      'session': _sessionSeed,
    });
    final cached = await _readCache(cacheKey, _homeCacheTtl);
    if (cached is List && cached.isNotEmpty) {
      return _asMapList(cached);
    }

    // Dynamic randomization of seeds based on ALL user preferences
    final random = Random();
    final shuffledArtists = favoriteArtists.toList()..shuffle(random);
    final shuffledLanguages = normalizedLanguages.toList()..shuffle(random);

    // Large pool of seed templates for artist-based queries
    const artistSeedTemplates = [
      '{name}',
      'Top songs by {name}',
      'Best of {name}',
      '{name} hits',
      '{name} popular songs',
      '{name} latest',
      'Songs like {name}',
      '{name} greatest hits',
      '{name} top tracks',
      'New songs {name}',
      '{name} essentials',
      '{name} playlist',
    ];

    // Large pool of seed templates for language-based queries
    const languageSeedTemplates = [
      'Top {lang} songs',
      'Trending {lang} music',
      'Best {lang} songs',
      'New {lang} hits',
      'Popular {lang} music',
      '{lang} latest releases',
      '{lang} romantic songs',
      '{lang} party songs',
      '{lang} chill music',
      'Top {lang} hits today',
      '{lang} chartbusters',
      '{lang} evergreen songs',
    ];

    final seeds = <String>{};
    for (final artist in shuffledArtists.take(3)) {
      final name = artist['name'] ?? '';
      if (name.isNotEmpty) {
        // Pick 2 random templates per artist from the pool
        final templates = (artistSeedTemplates.toList()..shuffle(random)).take(2);
        for (final tmpl in templates) {
          seeds.add(tmpl.replaceAll('{name}', name));
        }
      }
    }
    for (final language in shuffledLanguages.take(3)) {
      // Pick 2 random templates per language from the pool
      final templates = (languageSeedTemplates.toList()..shuffle(random)).take(2);
      for (final tmpl in templates) {
        seeds.add(tmpl.replaceAll('{lang}', language));
      }
    }
    if (seeds.isEmpty) {
      const fallbackSeeds = [
        'Top songs',
        'Popular music',
        'Trending global',
        'Best songs of all time',
        'Viral hits',
        'New releases today',
        'Party anthems',
        'Chill vibes music',
      ];
      final picked = (fallbackSeeds.toList()..shuffle(random)).take(3);
      seeds.addAll(picked);
    }

    final seedsList = seeds.toList()..shuffle();
    final searchResults = await Future.wait(
      seedsList.take(6).map((seed) async {
        try {
          return await globalSearch(
            seed,
            preferredLanguages: normalizedLanguages,
            limit: limit,
          );
        } catch (_) {
          return <String, List<dynamic>>{
            'songs': const [],
            'albums': const [],
            'artists': const [],
          };
        }
      }),
    );

    final scoredSongs = <String, Map<String, dynamic>>{};
    for (final result in searchResults) {
      final songs = result['songs'] ?? const [];
      for (final song in songs) {
        if (song is! Map) continue;
        final songMap = Map<String, dynamic>.from(song);
        final songId = songMap['id']?.toString() ?? '';
        if (songId.isEmpty) continue;
        if (!_matchesPreferredLanguage(songMap, normalizedLanguages)) continue;

        final favoriteArtistScore = _favoriteArtistBoost(
          songMap,
          normalizedFavoriteArtists,
        );
        final score = 10 + favoriteArtistScore;

        final existing = scoredSongs[songId];
        if (existing == null || (existing['score'] as int? ?? 0) < score) {
          scoredSongs[songId] = {'song': songMap, 'score': score};
        }
      }
    }

    final ranked = scoredSongs.values.toList()
      ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

    final output = ranked
        .take(limit)
        .map((entry) => entry['song'])
        .whereType<Map<String, dynamic>>()
        .toList();

    // Jitter shuffle: move top items slightly around to feel dynamic
    if (output.length > 5) {
      final head = output.take(3).toList()..shuffle();
      final mid = output.skip(3).take(7).toList()..shuffle();
      final tail = output.skip(10).toList();
      final shuffledOutput = [...head, ...mid, ...tail];

      await _writeCache(cacheKey, shuffledOutput);
      return shuffledOutput;
    }

    if (output.isNotEmpty) {
      await _writeCache(cacheKey, output);
      return output;
    }

    // Avoid sticky empty cache and provide a resilient default feed.
    await _deleteCache(cacheKey);
    try {
      final fallbackQuery = normalizedLanguages.isNotEmpty
          ? 'Top ${normalizedLanguages.first} songs'
          : 'Top songs';
      final fallback = await globalSearch(
        fallbackQuery,
        preferredLanguages: normalizedLanguages,
        limit: limit,
      );
      final fallbackSongs = _asMapList(fallback['songs']).take(limit).toList();
      if (fallbackSongs.isNotEmpty) {
        await _writeCache(cacheKey, fallbackSongs);
        return fallbackSongs;
      }
    } catch (_) {}

    return const [];
  }

  static Future<List<dynamic>> getRecommendedAlbums({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
    int limit = 12,
  }) async {
    final normalizedLanguages = _normalizeList(languages);
    final normalizedFavoriteArtists = _normalizeArtists(favoriteArtists);

    final cacheKey = _cacheKey('home_album_recs', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedFavoriteArtists,
      'limit': limit,
      'session': _sessionSeed,
    });
    final cached = await _readCache(cacheKey, _homeCacheTtl);
    if (cached is List && cached.isNotEmpty) {
      return _asMapList(cached);
    }

    final random = Random();
    final shuffledArtists = normalizedFavoriteArtists.toList()..shuffle(random);
    final shuffledLanguages = normalizedLanguages.toList()..shuffle(random);

    // Pool of album-specific seed templates
    const artistAlbumTemplates = [
      '{name} albums',
      'Best of {name}',
      '{name} discography',
      '{name} greatest albums',
      '{name} top albums',
      'New album {name}',
      '{name} collection',
    ];
    const languageAlbumTemplates = [
      'Top {lang} albums',
      'New {lang} music',
      'Best {lang} albums',
      '{lang} latest albums',
      '{lang} album releases',
      'Popular {lang} albums',
      '{lang} new releases',
      '{lang} classic albums',
    ];

    final seeds = <String>{};
    for (final artist in shuffledArtists.take(3)) {
      final name = artist['name'] ?? '';
      if (name.isNotEmpty) {
        final templates = (artistAlbumTemplates.toList()..shuffle(random)).take(2);
        for (final tmpl in templates) {
          seeds.add(tmpl.replaceAll('{name}', name));
        }
      }
    }
    for (final language in shuffledLanguages.take(3)) {
      final templates = (languageAlbumTemplates.toList()..shuffle(random)).take(2);
      for (final tmpl in templates) {
        seeds.add(tmpl.replaceAll('{lang}', language));
      }
    }
    if (seeds.isEmpty) {
      const fallback = ['Top albums', 'Classic albums', 'New album releases', 'Best albums'];
      seeds.addAll((fallback.toList()..shuffle(random)).take(2));
    }

    final seedsList = seeds.toList()..shuffle();
    final albumCandidates = <Map<String, dynamic>>[];
    for (final query in seedsList.take(6)) {
      try {
        final response = await getAlbums(
          query: query,
          preferredLanguages: normalizedLanguages,
        );
        final albums = _extractAlbumResults(response);
        albumCandidates.addAll(albums);
      } catch (_) {}
    }

    // Use professional merging and deduplication logic
    var finalAlbums = _mergeAlbumLists(
      albumCandidates,
      [],
      languages: normalizedLanguages,
    ).map((entry) => Map<String, dynamic>.from(entry as Map)).toList();

    // Fallback: If seeds didn't yield anything valid, try language-based Top Albums search
    if (finalAlbums.isEmpty) {
      try {
        final fallbackQuery = normalizedLanguages.isNotEmpty
            ? 'Top ${normalizedLanguages.first} albums'
            : 'Top albums';
        final fallback = await globalSearch(
          fallbackQuery,
          preferredLanguages: normalizedLanguages,
          limit: limit,
        );
        final fallbackAlbums = _asMapList(fallback['albums']);
        if (fallbackAlbums.isNotEmpty) {
          finalAlbums = _mergeAlbumLists(
            fallbackAlbums,
            [],
            languages: normalizedLanguages,
          ).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
    }

    if (normalizedLanguages.isNotEmpty) {
      finalAlbums = finalAlbums
          .where(
            (album) => _matchesPreferredLanguage(album, normalizedLanguages),
          )
          .toList(growable: false);
    }

    if (finalAlbums.isEmpty) {
      await _deleteCache(cacheKey);
      return const [];
    }

    // Scoring to prioritize user favorites and language matches
    final scored =
        finalAlbums.map((album) {
            final favoriteArtistScore = _favoriteArtistAlbumBoost(
              album,
              normalizedFavoriteArtists,
            );
            return {'album': album, 'score': 10 + favoriteArtistScore};
          }).toList()
          ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

    final output = scored
        .take(limit)
        .map((entry) => entry['album'])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (output.length > 4) {
      final head = output.take(2).toList()..shuffle();
      final rest = output.skip(2).toList()..shuffle();
      final shuffledOutput = [...head, ...rest];
      await _writeCache(cacheKey, shuffledOutput);
      return shuffledOutput;
    }

    if (output.isNotEmpty) {
      await _writeCache(cacheKey, output);
      return output;
    }

    return const [];
  }

  static Future<List<dynamic>> getTrendingSongs({
    required List<String> languages,
    int limit = 20,
  }) async {
    final normalizedLanguages = _normalizeList(languages);
    final cacheKey = _cacheKey('home_trending_songs', {
      'languages': normalizedLanguages,
      'limit': limit,
      'session': _sessionSeed,
    });
    final cached = await _readCache(cacheKey, _homeCacheTtl);
    if (cached is List) {
      return cached
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    // Pool of trending seed templates for variety
    const trendingTemplates = [
      'Top {lang} songs',
      '{lang} trending now',
      '{lang} hits today',
      'Popular {lang} songs',
      '{lang} chart toppers',
      'Viral {lang} songs',
      '{lang} most played',
      'Hot {lang} tracks',
    ];
    final random = Random();

    final queries = normalizedLanguages.expand((language) {
      final templates = (trendingTemplates.toList()..shuffle(random)).take(2);
      return templates.map((t) => t.replaceAll('{lang}', language));
    }).toList()..shuffle(random);
    if (queries.isEmpty) {
      const fallback = [
        'Top songs',
        'Billboard hot 100',
        'Viral hits global',
        'Most streamed songs',
        'Chart toppers today',
      ];
      queries.addAll((fallback.toList()..shuffle(random)).take(2));
    }

    final allSongs = <Map<String, dynamic>>[];
    for (final query in queries.take(4)) {
      try {
        final result = await globalSearch(
          query,
          preferredLanguages: normalizedLanguages,
          limit: limit,
        );
        final songs = result['songs'] ?? const [];
        for (final song in songs) {
          if (song is Map) {
            allSongs.add(Map<String, dynamic>.from(song));
          }
        }
      } catch (_) {}
    }

    final deduped = _dedupeById(allSongs);
    if (normalizedLanguages.isEmpty) {
      final output = deduped.take(limit).toList();
      await _writeCache(cacheKey, output);
      return output;
    }

    final matching = deduped
        .where((song) => _matchesPreferredLanguage(song, normalizedLanguages))
        .toList();
    final output = matching.take(limit).toList();
    await _writeCache(cacheKey, output);
    return output;
  }

  static Future<List<dynamic>> getPlaylists({
    required List<String> languages,
    int limit = 10,
  }) async {
    final normalizedLanguages = _normalizeList(languages);
    final cacheKey = _cacheKey('home_playlists', {
      'languages': normalizedLanguages,
      'limit': limit,
      'session': _sessionSeed,
    });
    final cached = await _readCache(cacheKey, _homeCacheTtl);
    if (cached is List) {
      return cached
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    // Pool of playlist seed templates
    const playlistTemplates = [
      'Top {lang} playlists',
      'Best {lang} playlist',
      '{lang} mood playlist',
      '{lang} workout playlist',
      '{lang} party playlist',
      '{lang} romantic playlist',
      '{lang} chill playlist',
      '{lang} drive playlist',
    ];
    final random = Random();

    final queries = normalizedLanguages.expand((language) {
      final templates = (playlistTemplates.toList()..shuffle(random)).take(1);
      return templates.map((t) => t.replaceAll('{lang}', language));
    }).toSet();
    if (queries.isEmpty) {
      const fallback = ['Top playlists', 'Best playlists', 'Popular playlists'];
      queries.add((fallback.toList()..shuffle(random)).first);
    }

    final albums = <Map<String, dynamic>>[];
    for (final query in queries.take(2)) {
      try {
        final response = await getAlbums(
          query: query,
          preferredLanguages: normalizedLanguages,
        );
        final extracted = _extractAlbumResults(response);
        for (final album in extracted) {
          if (_isValidAlbum(album)) {
            albums.add(album);
          }
        }
      } catch (_) {}
    }

    final deduped = _mergeAlbumLists(
      albums,
      [],
      languages: normalizedLanguages,
    ).map((e) => Map<String, dynamic>.from(e as Map)).toList();

    if (normalizedLanguages.isEmpty) {
      final output = deduped.take(limit).toList();
      await _writeCache(cacheKey, output);
      return output;
    }

    final output = deduped.take(limit).toList();
    await _writeCache(cacheKey, output);
    return output;
  }

  static Future<List<dynamic>> getSuggestedArtists({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
    int limit = 12,
  }) async {
    final normalizedLanguages = _normalizeList(languages);
    final normalizedFavorites = _normalizeArtists(favoriteArtists);

    final cacheKey = _cacheKey('home_suggested_artists', {
      'languages': normalizedLanguages,
      'favoriteArtists': normalizedFavorites,
      'limit': limit,
      'session': _sessionSeed,
    });
    final cached = await _readCache(cacheKey, _homeCacheTtl);
    if (cached is List) {
      return cached
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    final artistCandidates = <Map<String, dynamic>>[];
    for (final language in normalizedLanguages.take(2)) {
      try {
        final artists = await getArtistsByLanguage(language);
        for (final artist in artists) {
          if (artist is Map) {
            artistCandidates.add(Map<String, dynamic>.from(artist));
          }
        }
      } catch (_) {}
    }

    if (artistCandidates.isEmpty) return const [];

    final deduped = _dedupeById(artistCandidates);
    final scored =
        deduped.map((artist) {
          var score = 0;
          final artistId = artist['id']?.toString() ?? '';
          final artistName = (artist['name'] ?? '').toString().toLowerCase();

          for (final favorite in normalizedFavorites) {
            final favoriteId = favorite['id']?.toLowerCase() ?? '';
            final favoriteName = favorite['name']?.toLowerCase() ?? '';
            if (favoriteId.isNotEmpty && artistId.toLowerCase() == favoriteId) {
              score += 40;
            }
            if (favoriteName.isNotEmpty && artistName.contains(favoriteName)) {
              score += 20;
            }
          }

          return {'artist': artist, 'score': score};
        }).toList()..sort(
          (a, b) => (b['score'] as int).compareTo(a['score'] as int),
        );

    final output = scored
        .take(limit)
        .map((entry) => entry['artist'])
        .whereType<Map<String, dynamic>>()
        .toList();
    await _writeCache(cacheKey, output);
    return output;
  }

  static List<Map<String, String>> _normalizeArtists(
    List<Map<String, String>> artists,
  ) {
    return artists
        .map(
          (artist) => {
            'id': (artist['id'] ?? '').trim(),
            'name': (artist['name'] ?? '').trim(),
          },
        )
        .where(
          (artist) => artist['id']!.isNotEmpty || artist['name']!.isNotEmpty,
        )
        .toList();
  }

  static List<String> _normalizeList(List<String> list) {
    return LanguageUtils.normalizeLanguageList(list);
  }

  static String _normalizeString(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static int _scoreResultItem(
    Map<String, dynamic> item,
    String query, {
    bool isSong = true,
  }) {
    final title = (item['name'] ?? item['title'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    final normalizedTitle = _normalizeString(title);
    final normalizedQuery = _normalizeString(query);
    final q = query.toLowerCase().trim();

    if (q.isEmpty) return 0;

    // --- Exact / prefix / substring on title ---
    if (title == q || normalizedTitle == normalizedQuery) return 200;
    if (title.startsWith(q) || normalizedTitle.startsWith(normalizedQuery)) {
      return 180;
    }
    if (title.contains(q) || normalizedTitle.contains(normalizedQuery)) {
      return 150;
    }

    // --- Token-level matching (handles multi-word queries) ---
    final queryTokens = q
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final titleTokens = title
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final artistText =
        (isSong ? _extractSongArtists(item) : _extractAlbumArtists(item))
            .toLowerCase()
            .trim();
    final artistTokens = artistText
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();



    int nameHits = 0;
    int artistHits = 0;
    int albumHits = 0;

    String? albumName;
    List<String> albumTokens = const [];
    if (isSong) {
      albumName =
          (item['album'] is Map ? item['album']['name'] : item['album'] ?? '')
              .toString()
              .toLowerCase()
              .trim();
      albumTokens = albumName
          .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
    }

    for (final qt in queryTokens) {
      if (_tokenContainedIn(qt, titleTokens)) {
        nameHits++;
      } else if (_tokenContainedIn(qt, artistTokens)) {
        artistHits++;
      } else if (isSong && _tokenContainedIn(qt, albumTokens)) {
        albumHits++;
      }
    }

    final totalHits = nameHits + artistHits + albumHits;

    if (queryTokens.isNotEmpty && totalHits == queryTokens.length) {
      // All query tokens found somewhere
      final nameRatio = nameHits / queryTokens.length;
      return (120 + (nameRatio * 40)).round().clamp(0, 170);
    }

    if (queryTokens.length >= 2 && totalHits >= queryTokens.length - 1) {
      // All but one token matched
      final nameRatio = nameHits / queryTokens.length;
      return (90 + (nameRatio * 30)).round().clamp(0, 130);
    }

    // Artist-level full match
    if (artistText.contains(q)) return 70;

    // Album-level full match
    if (isSong && albumName != null && albumName.contains(q)) return 55;

    // Partial coverage via bigrams for typo tolerance
    if (normalizedQuery.length >= 4 && normalizedTitle.length >= 4) {
      final overlap = _bigramOverlap(normalizedQuery, normalizedTitle);
      if (overlap >= 0.5) return (40 + (overlap * 40)).round().clamp(0, 80);
    }

    // Some tokens matched but not enough for higher tiers
    if (totalHits > 0) {
      return (20 + (totalHits / queryTokens.length * 30)).round().clamp(0, 60);
    }

    return 5;
  }

  static bool _tokenContainedIn(String query, List<String> tokens) {
    for (final t in tokens) {
      if (t.contains(query) || (query.length >= 5 && query.contains(t))) {
        return true;
      }
    }
    return false;
  }

  static double _bigramOverlap(String a, String b) {
    if (a.length < 2 || b.length < 2) return 0.0;
    final bigramsA = <String>{};
    for (int i = 0; i < a.length - 1; i++) {
      bigramsA.add(a.substring(i, i + 2));
    }
    int matches = 0;
    int total = 0;
    for (int i = 0; i < b.length - 1; i++) {
      total++;
      if (bigramsA.contains(b.substring(i, i + 2))) matches++;
    }
    if (total == 0) return 0.0;
    final denominator =
        bigramsA.length > total ? bigramsA.length : total;
    return matches / denominator;
  }

  static List<Map<String, dynamic>> _dedupeById(
    List<Map<String, dynamic>> items,
  ) {
    final deduped = <String, Map<String, dynamic>>{};
    for (final item in items) {
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      deduped[id] = item;
    }
    return deduped.values.toList();
  }

  static bool _matchesPreferredLanguage(
    Map<String, dynamic> json,
    List<String> languages,
  ) {
    if (languages.isEmpty) return true;
    return LanguageUtils.matchesPreferredLanguages(
      json['language'],
      languages.toSet(),
    );
  }

  static int _favoriteArtistBoost(
    Map<String, dynamic> song,
    List<Map<String, String>> favoriteArtists,
  ) {
    if (favoriteArtists.isEmpty) return 0;
    final artistsText = _extractSongArtists(song).toLowerCase();
    var score = 0;
    for (final favorite in favoriteArtists) {
      final name = (favorite['name'] ?? '').toLowerCase();
      if (name.isNotEmpty && artistsText.contains(name)) {
        score += 35;
      }
    }
    return score;
  }

  static String _extractSongArtists(Map<String, dynamic> song) {
    if (song['primaryArtists'] is String) {
      return song['primaryArtists'] as String;
    }
    if (song['primaryArtists'] is List) {
      final list = song['primaryArtists'] as List;
      return list
          .map((item) => item is String ? item : item['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .join(', ');
    }
    if (song['artists'] is Map) {
      final artists = song['artists'] as Map;
      final primary = artists['primary'];
      if (primary is List) {
        return primary
            .map((item) => item['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .join(', ');
      }
    }
    return '';
  }

  static int _favoriteArtistAlbumBoost(
    Map<String, dynamic> album,
    List<Map<String, String>> favoriteArtists,
  ) {
    if (favoriteArtists.isEmpty) return 0;

    final albumArtistText = _extractAlbumArtists(album).toLowerCase();
    var score = 0;
    for (final favorite in favoriteArtists) {
      final favoriteName = (favorite['name'] ?? '').toLowerCase();
      if (favoriteName.isNotEmpty && albumArtistText.contains(favoriteName)) {
        score += 35;
      }
    }
    return score;
  }

  static String _extractAlbumArtists(Map<String, dynamic> album) {
    if (album['primaryArtists'] is String) {
      return album['primaryArtists'] as String;
    }

    final artists = album['artists'];
    if (artists is Map) {
      final allArtists = artists['all'];
      if (allArtists is List) {
        return allArtists
            .map((item) => item['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .join(', ');
      }
    }

    return (album['artist'] ?? '').toString();
  }

  static List<Map<String, dynamic>> _extractAlbumResults(
    Map<String, dynamic> response,
  ) {
    final data = response['data'] ?? response;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    if (data is Map) {
      if (data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      }
      if (data['albums'] is List) {
        return (data['albums'] as List)
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      }
    }
    return const [];
  }

  static List<dynamic> _deriveAlbumsFromSongs(List<dynamic> songs) {
    final albumsByKey = <String, Map<String, dynamic>>{};

    for (final entry in songs) {
      if (entry is! Map) continue;
      final song = Map<String, dynamic>.from(entry);
      final albumRaw = song['album'];

      String albumId = '';
      String albumName = '';
      String albumUrl = '';

      if (albumRaw is Map) {
        final albumMap = Map<String, dynamic>.from(albumRaw);
        albumId = (albumMap['id'] ?? '').toString().trim();
        albumName = (albumMap['name'] ?? '').toString().trim();
        albumUrl = (albumMap['url'] ?? '').toString().trim();
      } else {
        albumName = (albumRaw ?? '').toString().trim();
      }

      if (albumName.isEmpty) continue;
      final key = albumId.isNotEmpty ? albumId : albumName.toLowerCase();
      if (albumsByKey.containsKey(key)) continue;

      final image = song['image'] is List
          ? List<dynamic>.from(song['image'] as List)
          : const [];
      final artistText = (song['primaryArtists'] ?? '').toString().trim();

      albumsByKey[key] = {
        'id': albumId.isNotEmpty ? albumId : key,
        'name': albumName,
        'url': albumUrl,
        'primaryArtists': artistText,
        'image': image,
        'language': song['language'],
      };
    }

    return albumsByKey.values.toList(growable: false);
  }

  /// Derive unique artist entries from a list of raw song JSON maps.
  static List<dynamic> _deriveArtistsFromSongs(List<dynamic> songs) {
    final artistsByKey = <String, Map<String, dynamic>>{};

    for (final entry in songs) {
      if (entry is! Map) continue;
      final song = Map<String, dynamic>.from(entry);

      // Try structured artists map first, then fall back to primaryArtists string.
      final artistsMap = song['artists'];
      if (artistsMap is Map) {
        final primary = artistsMap['primary'];
        if (primary is List) {
          for (final a in primary) {
            if (a is! Map) continue;
            final id = (a['id'] ?? '').toString().trim();
            final name = (a['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final key = id.isNotEmpty ? id : name.toLowerCase();
            if (artistsByKey.containsKey(key)) continue;
            artistsByKey[key] = {
              'id': id.isNotEmpty ? id : key,
              'name': name,
              'image': a['image'],
              'role': (a['role'] ?? a['type'] ?? '').toString(),
            };
          }
          continue;
        }
      }

      // Fallback: split comma-separated primaryArtists string.
      final primaryArtists = (song['primaryArtists'] ?? song['primary_artists'] ?? '').toString().trim();
      if (primaryArtists.isEmpty) continue;
      final parts = primaryArtists.split(RegExp(r',\s*'));
      for (final part in parts) {
        final name = part.trim();
        if (name.isEmpty) continue;
        final key = name.toLowerCase();
        if (artistsByKey.containsKey(key)) continue;
        artistsByKey[key] = {
          'id': key,
          'name': name,
          'image': song['image'],
        };
      }
    }

    return artistsByKey.values.toList(growable: false);
  }

  static List<dynamic> _mergeAlbumLists(
    List<dynamic> primary,
    List<dynamic> fallback, {
    List<String> languages = const [],
  }) {
    if (primary.isEmpty && fallback.isEmpty) return [];

    final candidates = <Map<String, dynamic>>[];

    void appendAll(List<dynamic> source) {
      for (final item in source) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (!_isValidAlbum(map)) continue;
        if (!_matchesPreferredLanguage(map, languages)) continue;
        candidates.add(map);
      }
    }

    appendAll(primary);
    appendAll(fallback);

    // Grouping by deduplication key (normalized name + primary artist + language)
    final groupedAlbums = <String, List<Map<String, dynamic>>>{};
    for (final album in candidates) {
      final name = (album['name'] ?? album['title'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final artistText = _extractAlbumArtists(album).toLowerCase();
      final language = (album['language'] ?? '').toString().toLowerCase();

      final dedupKey = _normalizeString('${name}_${artistText}_$language');

      groupedAlbums.putIfAbsent(dedupKey, () => []).add(album);
    }

    final merged = <Map<String, dynamic>>[];

    for (final group in groupedAlbums.values) {
      if (group.isEmpty) continue;

      final scoredAlbums = group.map((album) {
        int validCount = 0;
        final songs = album['songs'];
        if (songs is List) {
          validCount = songs
              .where(
                (s) => s is Map && _isValidSong(Map<String, dynamic>.from(s)),
              )
              .length;
        } else {
          validCount =
              int.tryParse(
                album['songCount']?.toString() ??
                    album['song_count']?.toString() ??
                    '0',
              ) ??
              0;
        }

        final isOfficial =
            album['is_official'] == true || album['isOfficial'] == true;

        return {
          'album': album,
          'validCount': validCount,
          'isOfficial': isOfficial,
          'year': int.tryParse(album['year']?.toString() ?? '0') ?? 0,
        };
      }).toList();

      scoredAlbums.sort((a, b) {
        if (a['isOfficial'] != b['isOfficial']) {
          return (b['isOfficial'] as bool) ? 1 : -1;
        }

        final countA = a['validCount'] as int;
        final countB = b['validCount'] as int;
        if (countA != countB) return countB.compareTo(countA);

        return (b['year'] as int).compareTo(a['year'] as int);
      });

      merged.add(scoredAlbums.first['album'] as Map<String, dynamic>);
    }

    return merged;
  }

  static Future<List<dynamic>> _searchSongsFallback(String query) async {
    try {
      final res = await http
          .get(
            Uri.parse(
              '$_fallbackSearchBaseUrl/api/search/songs?query=${Uri.encodeComponent(query)}',
            ),
          )
          .timeout(_fallbackSearchTimeout);
      if (res.statusCode != 200) return const [];

      final payload = jsonDecode(res.body);
      final data = payload['data'];
      if (data == null || data['results'] == null) return const [];
      
      final results = data['results'] as List;
      return results;
    } catch (_) {
      return const [];
    }
}


  // ─── Protected Endpoints ─────────────────────────────────

  static Future<void> savePreferences({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
  }) async {
    final headers = await _authHeaders();
    final res = await http.post(
      Uri.parse('$baseUrl/api/user/preferences'),
      headers: headers,
      body: jsonEncode({
        'languages': languages,
        'favoriteArtists': favoriteArtists,
      }),
    );
    if (res.statusCode != 200) throw Exception('Save preferences failed');
  }

  static Future<Map<String, dynamic>?> getPreferences() async {
    try {
      final headers = await _authHeaders();
      final res = await http
          .get(Uri.parse('$baseUrl/api/user/preferences'), headers: headers)
          .timeout(const Duration(seconds: 10)); // 10s safety timeout

      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) throw Exception('Get preferences failed');
      final data = jsonDecode(res.body);
      return data['data'];
    } catch (e) {
      debugPrint('Get Preferences Error: $e');
      return null; // Fallback to no preferences on error/timeout
    }
  }

  static Future<void> logActivity(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final headers = await _authHeaders();
    await http.post(
      Uri.parse('$baseUrl/api/activity/$type'),
      headers: headers,
      body: jsonEncode(payload),
    );
  }

  static Future<List<dynamic>> getHistory({
    String? type,
    int limit = 20,
  }) async {
    final headers = await _authHeaders();
    String url = '$baseUrl/api/activity/history?limit=$limit';
    if (type != null) url += '&type=$type';
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body);
    return data['data'] ?? [];
  }

  static Future<List<dynamic>> getRecommendations({int limit = 20}) async {
    final headers = await _authHeaders();
    final res = await http.get(
      Uri.parse('$baseUrl/api/recommendations?limit=$limit'),
      headers: headers,
    );
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body);
    return data['data'] ?? [];
  }

  static bool _isValidSong(Map<String, dynamic> song) {
    if (song.isEmpty) return false;

    final title = (song['name'] ?? song['title'] ?? '').toString();
    if (!ContentFilter.isAllowedSongTitle(title)) return false;

    // 2. Status/Official checks
    if (song.containsKey('is_official') && song['is_official'] == false) {
      return false;
    }
    if (song.containsKey('isOfficial') && song['isOfficial'] == false) {
      return false;
    }

    if (song['status'] != null) {
      final status = song['status'].toString().toLowerCase().trim();
      if (status.isNotEmpty && status != 'published') return false;
    }

    return true;
  }

  static bool _isValidAlbum(Map<String, dynamic> album) {
    if (album.isEmpty) return false;

    final title = (album['name'] ?? album['title'] ?? '').toString();
    if (!ContentFilter.isAllowedSongTitle(title)) return false;
    final id = (album['id'] ?? '').toString().trim();
    if (id.isEmpty) return false;

    // 2. Status & Test flags
    if (album['is_test'] == true || album['isTest'] == true) return false;

    // Validate status if present
    final status = (album['status'] ?? '').toString().toLowerCase().trim();
    if (status.isNotEmpty && status != 'published') return false;

    // Reject explicitly unofficial albums
    if (album['is_official'] == false || album['isOfficial'] == false) {
      return false;
    }

    // 3. Valid Song Count Logic (Deep Check)
    final songsInfo = album['songs'];
    if (songsInfo is List) {
      final validSongs = songsInfo.where(
        (s) => s is Map && _isValidSong(Map<String, dynamic>.from(s)),
      );
      if (validSongs.isEmpty) return false;
    } else {
      final hasExplicitTrackCount =
          album.containsKey('songCount') ||
          album.containsKey('song_count') ||
          album.containsKey('songsCount') ||
          album.containsKey('totalSongs');

      final trackCount =
          int.tryParse(
            album['songCount']?.toString() ??
                album['song_count']?.toString() ??
                '0',
          ) ??
          0;

      if (hasExplicitTrackCount && trackCount < 1) {
        return false;
      }

      if (!hasExplicitTrackCount && trackCount < 1) {
        final type = (album['type'] ?? '').toString().trim().toLowerCase();
        if (type.isNotEmpty &&
            type != 'album' &&
            type != 'ep' &&
            type != 'single') {
          return false;
        }
      }
    }

    return true;
  }
}

// Let's Encrypt ISRG Root X1 (Valid until 2035)
const String _isrgRootX1Pem = """
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
""";

// Let's Encrypt ISRG Root X2 (Valid until 2040)
const String _isrgRootX2Pem = """
-----BEGIN CERTIFICATE-----
MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQsw
CQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2gg
R3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00
MDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBT
ZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYw
EAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW
+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9
ItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0T
AQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZI
zj0EAwMDaAAwZQIwe3lORlCEwkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdW
tL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtCnwr1
/q4AaOeMSQ+2b1tbFfLn
-----END CERTIFICATE-----
""";

// Amazon Root CA 1 (Valid until 2038 - for Vercel and AWS API services)
const String _amazonRootCA1Pem = """
-----BEGIN CERTIFICATE-----
MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF
ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL
MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggIPADCCAQoCggEBALJ4gHHKeNXj
ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM
9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw
IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6
VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L
93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm
jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA
A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI
U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs
N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv
o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU
5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy
rqXRfboQnoZsG4q5WTP468SQvvG5
-----END CERTIFICATE-----
""";

class _HttpLogWrapper {
  final raw_http.Client _client;

  _HttpLogWrapper() : _client = ApiService.createSecureHttpClient(pinCertificates: true);

  Future<raw_http.Response> get(Uri url, {Map<String, String>? headers}) async {
    if (url.scheme != 'https') {
      throw UnsupportedError('Insecure HTTP connections are prohibited in production: $url');
    }
    StabilityLogger.debug('API', 'GET request: $url');
    try {
      final response = await _client.get(url, headers: headers);
      StabilityLogger.debug('API', 'GET response: ${response.statusCode} for $url');
      return response;
    } catch (e) {
      StabilityLogger.error('API', 'GET error for $url', e);
      rethrow;
    }
  }

  Future<raw_http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    if (url.scheme != 'https') {
      throw UnsupportedError('Insecure HTTP connections are prohibited in production: $url');
    }
    StabilityLogger.debug('API', 'POST request: $url');
    try {
      final response = await _client.post(url, headers: headers, body: body, encoding: encoding);
      StabilityLogger.debug('API', 'POST response: ${response.statusCode} for $url');
      return response;
    } catch (e) {
      StabilityLogger.error('API', 'POST error for $url', e);
      rethrow;
    }
  }
}

final http = _HttpLogWrapper();
