import 'package:flutter/foundation.dart';
import 'package:fuzzy/fuzzy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../services/api_service.dart';
import '../services/offline_service.dart';
import '../services/playlist_import_service.dart';
import '../utils/content_filter.dart';
import '../utils/language_utils.dart';
import '../utils/album_filter.dart';
import '../models/user_playlist.dart';
import '../services/playlist_service.dart';
import '../services/download_service.dart';
import '../services/background_learning_service.dart';

class SearchProvider extends ChangeNotifier {
  static const String _recentSearchesKey = 'recent_searches_v1';
  static const int _maxRecentSearches = 12;
  static const int _maxSearchResults = 20;
  static const int _minSongsPerSearch = 7;
  static const int _minAlbumsPerSearch = 7;
  static const int _minSongDurationSeconds = 60;
  static const int _maxSongDurationSeconds = 600;
  static const int _idealSongDurationMinSeconds = 120;
  static const int _idealSongDurationMaxSeconds = 420;
  static const int _maxQueryCacheEntries = 24;
  static const Duration _queryCacheTtl = Duration(minutes: 8);
  static const List<String> _searchNoiseWords = <String>[
    'song',
    'songs',
    'music',
    'video',
    'official',
    'audio',
    'lyrics',
    'full',
    'hd',
    'movie',
    'film',
    'album',
    'theme',
    'bgm',
    'ost',
  ];
  static const List<String> _blockedSearchKeywords = <String>[
    'full movie',
    'full-movie',
    'movie',
    'cartoon',
    'episode',
    'season',
    'trailer',
    'sample',
    'testing',
    'test song',
    'demo',
    'dialogue',
    'scene',
    'clip',
    'reaction',
    'review',
  ];
  static const List<String> _singleSongAlbumBlockedKeywords = <String>[
    'sample',
    'testing',
    'trailer',
    'test',
    'demo',
  ];
  static const List<String> _blockedTypeTokens = <String>[
    'VIDEO',
    'MOVIE',
    'EPISODE',
    'TRAILER',
    'CLIP',
    'REACTION',
    'REVIEW',
    'DIALOGUE',
    'SCENE',
    'CARTOON',
    'FILM',
    'SHOW',
  ];

  /// Keywords that indicate a song/album is a derivative (not the original).
  static const List<String> _derivativeKeywords = <String>[
    'cover',
    'remix',
    'remixed',
    'karaoke',
    'instrumental',
    'reprise',
    'unplugged',
    'acoustic version',
    'live version',
    'live performance',
    'lofi',
    'lo-fi',
    'lo fi',
    'slowed',
    'reverb',
    'slowed and reverb',
    'slowed reverb',
    'mashup',
    'mash-up',
    'mash up',
    'rendition',
    'recreation',
    'reimagined',
    'rearranged',
    '8d audio',
    '8d song',
    'female version',
    'male version',
    'duet version',
    'stripped',
  ];

  List<Song> _songs = [];
  List<Album> _albums = [];
  List<Artist> _artists = [];
  List<UserPlaylist> _playlists = [];
  List<String> _recentSearches = [];
  List<String> _searchRecommendations = [];
  bool _loading = false;
  String _query = '';
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;
  int _activeRequestId = 0;
  bool _offlineMode = false;

  // Local searchable index for "Spotify-like" speed
  final List<Song> _localSongIndex = [];
  final List<Album> _localAlbumIndex = [];
  final List<Artist> _localArtistIndex = [];
  final Set<String> _offlineSongIds = <String>{};
  final Set<String> _offlineAlbumIds = <String>{};
  final Map<String, _CachedSearchSnapshot> _queryCache = {};

  List<String> _preferredLanguages = [];
  Set<String> _preferredLanguageSet = <String>{};

  List<Song> get songs => _songs;
  List<Album> get albums => _albums;
  List<Artist> get artists => _artists;
  List<UserPlaylist> get playlists => _playlists;
  List<String> get recentSearches => _recentSearches;
  List<String> get searchRecommendations => _searchRecommendations;
  // Backward compatibility getter
  List<Song> get results => _songs;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  String get query => _query;
  bool get offlineMode => _offlineMode;

  SearchProvider() {
    _loadRecentSearches();
  }

  void updatePreferredLanguages(List<String> langs) {
    final normalized = LanguageUtils.normalizeLanguageList(langs)..sort();

    if (listEquals(normalized, _preferredLanguages)) return;
    _preferredLanguages = normalized;
    _preferredLanguageSet = _preferredLanguages.toSet();
    _queryCache.clear();
    _prefetchTopresults();
  }

  Future<void> setOfflineMode(bool enabled) async {
    if (_offlineMode == enabled) return;
    _offlineMode = enabled;
    if (_offlineMode) {
      await _refreshOfflineIndexes();
      if (_query.trim().isNotEmpty) {
        await search(_query);
        return;
      }
    } else {
      // Exit Offline Mode: Re-run search in Online Mode if there's a query
      if (_query.trim().isNotEmpty) {
        await search(_query);
        return;
      }
    }
    notifyListeners();
  }

  Future<void> _prefetchTopresults() async {
    if (_preferredLanguages.isEmpty) return;
    try {
      final top = await ApiService.getTrendingSongs(
        languages: _preferredLanguages,
        limit: 15,
      );
      final songs = _parseList<Song>(top, Song.fromJson);
      _addToLocalIndex(songs: songs);
    } catch (_) {}
  }

  Future<void> _refreshOfflineIndexes() async {
    try {
      final cachedSongs = await OfflineService.getOfflineSongs();
      final downloadedSongs = await DownloadService.getDownloadedSongs();

      final Map<String, Song> uniqueSongs = {};
      for (final s in cachedSongs) {
        uniqueSongs[s.id] = s;
      }
      for (final s in downloadedSongs) {
        uniqueSongs[s.id] = s;
      }
      final songs = uniqueSongs.values.toList();

      final albumGroups = await OfflineService.getOfflineAlbums();
      _offlineSongIds
        ..clear()
        ..addAll(songs.map((song) => song.id));
      _offlineAlbumIds
        ..clear()
        ..addAll(albumGroups.map((group) => group.albumId));

      final albums = albumGroups
          .map(
            (group) => Album(
              id: group.albumId,
              name: group.albumName,
              artist: group.artist,
              imageUrl: group.imageUrl,
              language: group.songs.isEmpty
                  ? null
                  : group.songs.first.song.language,
              songCount: group.songs.length,
            ),
          )
          .toList(growable: true);

      for (final song in downloadedSongs) {
        final albumId = song.albumId ?? '';
        final albumName = song.album ?? '';
        if (albumId.isNotEmpty && albumName.isNotEmpty && !_offlineAlbumIds.contains(albumId)) {
          _offlineAlbumIds.add(albumId);
          albums.add(Album(
            id: albumId,
            name: albumName,
            artist: song.artist,
            imageUrl: song.imageUrl,
            language: song.language,
            songCount: 1,
          ));
        }
      }

      final List<Artist> artists = [];
      final Map<String, int> artistSongCounts = {};
      final Map<String, String?> artistImages = {};
      for (final song in songs) {
        final artistName = song.artist ?? '';
        if (artistName.isNotEmpty) {
          final key = artistName.toLowerCase().trim();
          artistSongCounts[key] = (artistSongCounts[key] ?? 0) + 1;
          if (artistImages[key] == null && song.imageUrl != null) {
            artistImages[key] = song.imageUrl;
          }
        }
      }
      artistSongCounts.forEach((name, count) {
        final cleanName = name.replaceAll(RegExp(r'\s+'), ' ');
        final originalName = songs.firstWhere((s) => s.artist?.toLowerCase().trim() == name).artist ?? cleanName;
        artists.add(Artist(
          id: 'art_${name.replaceAll(RegExp(r'\s+'), '_')}',
          name: originalName,
          imageUrl: artistImages[name],
          role: '$count downloaded ${count == 1 ? "song" : "songs"}',
        ));
      });

      _addToLocalIndex(songs: songs, albums: albums, artists: artists);
    } catch (e) {
      debugPrint('Offline index refresh failed: $e');
    }
  }

  void _addToLocalIndex({
    List<Song>? songs,
    List<Album>? albums,
    List<Artist>? artists,
  }) {
    if (songs != null) {
      for (final s in songs) {
        if (!_localSongIndex.any((existing) => existing.id == s.id)) {
          _localSongIndex.add(s);
        }
      }
    }
    if (albums != null) {
      for (final a in albums) {
        if (!_localAlbumIndex.any((existing) => existing.id == a.id)) {
          _localAlbumIndex.add(a);
        }
      }
    }
    if (artists != null) {
      for (final art in artists) {
        if (!_localArtistIndex.any((existing) => existing.id == art.id)) {
          _localArtistIndex.add(art);
        }
      }
    }
    // Trim local index to keep it fast
    if (_localSongIndex.length > 200) _localSongIndex.removeRange(0, 50);
    if (_localAlbumIndex.length > 100) _localAlbumIndex.removeRange(0, 20);
    if (_localArtistIndex.length > 50) _localArtistIndex.removeRange(0, 10);
  }

  String _normalize(String s) {
    return s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _compact(String value) {
    return _normalize(
      value,
    ).replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  }

  String _normalizeLanguage(String language) {
    return LanguageUtils.normalizeLanguage(language);
  }

  bool _matchesPreferredLanguage(String? rawLanguage) {
    if (_preferredLanguageSet.isEmpty) return true;
    return LanguageUtils.matchesPreferredLanguages(
      rawLanguage,
      _preferredLanguageSet,
    );
  }

  List<String> _tokenize(String value) {
    return _normalize(value)
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  String _searchCacheKey(String normalizedQuery) {
    final langs = List<String>.from(_preferredLanguages)..sort();
    return '$normalizedQuery|${langs.join(',')}';
  }

  _CachedSearchSnapshot? _readQueryCache(String key) {
    final cached = _queryCache[key];
    if (cached == null) return null;
    final age = DateTime.now().difference(cached.storedAt);
    if (age > _queryCacheTtl) {
      _queryCache.remove(key);
      return null;
    }
    return cached;
  }

  void _writeQueryCache(
    String key, {
    required List<Song> songs,
    required List<Album> albums,
    required List<Artist> artists,
    required List<UserPlaylist> playlists,
  }) {
    _queryCache[key] = _CachedSearchSnapshot(
      songs: List<Song>.from(songs),
      albums: List<Album>.from(albums),
      artists: List<Artist>.from(artists),
      playlists: List<UserPlaylist>.from(playlists),
      storedAt: DateTime.now(),
    );

    if (_queryCache.length <= _maxQueryCacheEntries) return;

    String? oldestKey;
    DateTime? oldestTime;
    _queryCache.forEach((cacheKey, value) {
      if (oldestTime == null || value.storedAt.isBefore(oldestTime!)) {
        oldestKey = cacheKey;
        oldestTime = value.storedAt;
      }
    });
    if (oldestKey != null) {
      _queryCache.remove(oldestKey);
    }
  }

  String _buildRelaxedQuery(String query) {
    final tokens = _tokenize(query);
    if (tokens.length <= 1) return query;
    if (tokens.length == 2) return tokens.first;

    final relaxedTokens = List<String>.from(tokens)..removeLast();
    return relaxedTokens.join(' ');
  }

  Future<void> search(String query) async {
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) {
      clear();
      return;
    }

    _query = query.trim();
    _loading = true;
    _page = 1;
    _hasMore = true;
    final requestId = ++_activeRequestId;
    notifyListeners();

    if (_offlineMode) {
      await _refreshOfflineIndexes();
      if (requestId != _activeRequestId) return;

      final offlineSongs = _sanitizeSongs(
        _localSongIndex
            .where((song) => _offlineSongIds.contains(song.id))
            .toList(growable: false),
      );
      final offlineAlbums = await _sanitizeAlbums(
        _localAlbumIndex
            .where((album) => _offlineAlbumIds.contains(album.id))
            .toList(growable: false),
      );
      final offlineArtists = _localArtistIndex;

      final localPlaylists = await PlaylistService.getPlaylists();
      final matchingLocalPlaylists = localPlaylists.where((p) {
        final nameMatch = p.name.toLowerCase().contains(normalizedQuery);
        final descMatch = p.description?.toLowerCase().contains(normalizedQuery) ?? false;
        return nameMatch || descMatch;
      }).toList();

      _songs = _rankAndMerge<Song>(
        local: offlineSongs,
        network: const <Song>[],
        query: normalizedQuery,
        getName: (s) => s.name,
        getArtist: (s) => s.artist ?? '',
        getLanguage: (s) => s.language ?? '',
        getQualityScore: (s) => _computeSongQuality(s),
        getId: (s) => s.id,
      );
      _albums = _rankAndMerge<Album>(
        local: offlineAlbums,
        network: const <Album>[],
        query: normalizedQuery,
        getName: (a) => a.name,
        getArtist: (a) => a.artist ?? '',
        getLanguage: (a) => a.language ?? '',
        getQualityScore: (a) => _computeAlbumQuality(a),
        getId: (a) => a.id,
      );
      _artists = _rankAndMerge<Artist>(
        local: offlineArtists,
        network: const <Artist>[],
        query: normalizedQuery,
        getName: (art) => art.name,
        getArtist: (art) => '',
        getLanguage: (art) => '',
        getQualityScore: (art) => art.isVerified ? 10.0 : 1.0,
        getId: (art) => art.id,
        getDedupeKey: (art) => art.name.toLowerCase().trim(),
        merge: _mergeArtists,
      );
      _playlists = _rankAndMerge<UserPlaylist>(
        local: matchingLocalPlaylists,
        network: const <UserPlaylist>[],
        query: normalizedQuery,
        getName: (p) => p.name,
        getArtist: (p) => p.description ?? '',
        getLanguage: (p) => '',
        getQualityScore: (p) => p.songs.length.toDouble(),
        getId: (p) => p.id,
      );
      _searchRecommendations = _buildRecommendations(normalizedQuery);
      _hasMore = false;
      _loading = false;
      notifyListeners();
      return;
    }

    final cacheKey = _searchCacheKey(normalizedQuery);
    final cached = _readQueryCache(cacheKey);
    if (cached != null) {
      _songs = List<Song>.from(cached.songs);
      _albums = List<Album>.from(cached.albums);
      _artists = List<Artist>.from(cached.artists);
      _playlists = List<UserPlaylist>.from(cached.playlists);
      _searchRecommendations = _buildRecommendations(normalizedQuery);
      _loading = false;
      notifyListeners();
      return;
    }

    final isUrl =
        RegExp(r'^https?://').hasMatch(normalizedQuery) ||
        normalizedQuery.contains('spotify.com') ||
        normalizedQuery.contains('spotify.link') ||
        normalizedQuery.contains('youtube.com') ||
        normalizedQuery.contains('youtu.be') ||
        normalizedQuery.contains('music.apple.com');

    if (isUrl && !_offlineMode) {
      try {
        final result = await PlaylistImportService.importPlaylist(
          type: 'url',
          content: query.trim(),
          preferredLanguages: _preferredLanguages,
        );
        if (requestId != _activeRequestId) return;

        if (result.matched.isNotEmpty) {
          _songs = result.matched.map((m) => m.song).toList();
          _albums = [];
          _artists = [];
          _searchRecommendations = [];
          _hasMore = false;

          _writeQueryCache(
            cacheKey,
            songs: _songs,
            albums: _albums,
            artists: _artists,
            playlists: _playlists,
          );
          _saveRecentSearch(query.trim()).catchError((_) {});

          _loading = false;
          notifyListeners();
          return;
        } else if (result.unmatched.isNotEmpty || result.hasError) {
          // If URL was parsed but no matches found, or server returned error
          _songs = [];
          _albums = [];
          _artists = [];
          _searchRecommendations = [];
          _hasMore = false;
          _loading = false;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('URL import failed in search: $e');
        // Let it fall through to normal search if URL import crashed
      }
    }

    // 1. First, try local search for instant feedback
    final localSongs = _searchLocalSongs(normalizedQuery);
    final localAlbums = _searchLocalAlbums(normalizedQuery);
    final localArtists = _searchLocalArtists(normalizedQuery);

    if (localSongs.isNotEmpty || localAlbums.isNotEmpty || localArtists.isNotEmpty) {
      _songs = localSongs;
      _albums = localAlbums;
      _artists = localArtists;
      _loading = false;
      notifyListeners();
      // We still proceed to network search to get fresh/more results
    }

    try {
      // 2. Fetch from Network
      var data = await ApiService.globalSearch(
        normalizedQuery,
        preferredLanguages: _preferredLanguages,
        limit: _maxSearchResults,
      );
      if (requestId != _activeRequestId) return;

      var networkSongs = _sanitizeSongs(
        _parseList<Song>(data['songs'] ?? const [], Song.fromJson),
      );
      var networkAlbums = await _sanitizeAlbums(
        _parseList<Album>(data['albums'] ?? const [], Album.fromJson),
      );
      var networkArtists = _parseList<Artist>(
        data['artists'] ?? const [],
        Artist.fromJson,
      );

      // Relax query once when nothing is found, so users don't hit "no results" too early.
      if (networkSongs.isEmpty) {
        final relaxedQuery = _buildRelaxedQuery(normalizedQuery);
        if (relaxedQuery.isNotEmpty && relaxedQuery != normalizedQuery) {
          data = await ApiService.globalSearch(
            relaxedQuery,
            preferredLanguages: _preferredLanguages,
            limit: _maxSearchResults,
          );
          if (requestId != _activeRequestId) return;

          final relaxedSongs = _sanitizeSongs(
            _parseList<Song>(data['songs'] ?? const [], Song.fromJson),
          );
          if (relaxedSongs.isNotEmpty) {
            networkSongs = relaxedSongs;
            networkAlbums = await _sanitizeAlbums(
              _parseList<Album>(data['albums'] ?? const [], Album.fromJson),
            );
            networkArtists = _parseList<Artist>(
              data['artists'] ?? const [],
              Artist.fromJson,
            );
          }
        }
      }

      if (networkSongs.length < _minSongsPerSearch) {
        try {
          final pageTwoSongsRaw = await ApiService.searchSongs(
            normalizedQuery,
            page: 2,
            preferredLanguages: _preferredLanguages,
            limit: _maxSearchResults,
          );
          final pageTwoSongs = _parseList<Song>(pageTwoSongsRaw, Song.fromJson);
          networkSongs = _sanitizeSongs(
            _mergeUniqueItems<Song>(
              existing: networkSongs,
              incoming: pageTwoSongs,
              getId: (song) => song.id,
            ),
          );
        } catch (e) {
          debugPrint('Supplemental song fetch failed: $e');
        }
      }

      if (networkAlbums.length < _minAlbumsPerSearch) {
        try {
          final albumPayload = await ApiService.getAlbums(
            query: normalizedQuery,
            preferredLanguages: _preferredLanguages,
          );
          final albumRaw = _extractAlbumItems(albumPayload);
          final supplementalAlbums = _parseList<Album>(
            albumRaw,
            Album.fromJson,
          );
          networkAlbums = await _sanitizeAlbums(
            _mergeUniqueItems<Album>(
              existing: networkAlbums,
              incoming: supplementalAlbums,
              getId: (album) => album.id,
            ),
          );
        } catch (e) {
          debugPrint('Supplemental album fetch failed: $e');
        }
      }

      if (networkAlbums.length < _minAlbumsPerSearch &&
          networkSongs.isNotEmpty) {
        final derivedAlbums = _deriveAlbumsFromSongs(networkSongs);
        networkAlbums = await _sanitizeAlbums(
          _mergeUniqueItems<Album>(
            existing: networkAlbums,
            incoming: derivedAlbums,
            getId: (album) => album.id,
          ),
        );
      }

      _addToLocalIndex(
        songs: networkSongs,
        albums: networkAlbums,
        artists: networkArtists,
      );

      // 3. Smart Ranking & Merging
      _songs = _rankAndMerge<Song>(
        local: localSongs,
        network: _sanitizeSongs(networkSongs),
        query: normalizedQuery,
        getName: (s) => s.name,
        getArtist: (s) => s.artist ?? '',
        getLanguage: (s) => s.language ?? '',
        getQualityScore: (s) => _computeSongQuality(s),
        getId: (s) => s.id,
        minCount: _minSongsPerSearch,
      );

      _albums = _rankAndMerge<Album>(
        local: localAlbums,
        network: await _sanitizeAlbums(networkAlbums),
        query: normalizedQuery,
        getName: (a) => a.name,
        getArtist: (a) => a.artist ?? '',
        getLanguage: (a) => a.language ?? '',
        getQualityScore: (a) => _computeAlbumQuality(a),
        getId: (a) => a.id,
        minCount: _minAlbumsPerSearch,
      );

      _artists = _rankAndMerge<Artist>(
        local: localArtists,
        network: networkArtists,
        query: normalizedQuery,
        getName: (art) => art.name,
        getArtist: (art) => '',
        getLanguage: (art) => '',
        getQualityScore: (art) => art.isVerified ? 10.0 : 1.0,
        getId: (art) => art.id,
        getDedupeKey: (art) => art.name.toLowerCase().trim(),
        merge: _mergeArtists,
      );

      final localPlaylists = await PlaylistService.getPlaylists();
      final matchingLocalPlaylists = localPlaylists.where((p) {
        final nameMatch = p.name.toLowerCase().contains(normalizedQuery);
        final descMatch = p.description?.toLowerCase().contains(normalizedQuery) ?? false;
        return nameMatch || descMatch;
      }).toList();

      _playlists = _rankAndMerge<UserPlaylist>(
        local: matchingLocalPlaylists,
        network: const <UserPlaylist>[],
        query: normalizedQuery,
        getName: (p) => p.name,
        getArtist: (p) => p.description ?? '',
        getLanguage: (p) => '',
        getQualityScore: (p) => p.songs.length.toDouble(),
        getId: (p) => p.id,
      );

      _searchRecommendations = _buildRecommendations(normalizedQuery);

      if (_songs.length < 10) _hasMore = false;
      _writeQueryCache(
        cacheKey,
        songs: _songs,
        albums: _albums,
        artists: _artists,
        playlists: _playlists,
      );
      _saveRecentSearch(query.trim()).catchError((_) {});

      ApiService.logActivity('search', {
        'query': normalizedQuery,
      }).catchError((_) {});
    } catch (e) {
      if (requestId != _activeRequestId) return;
      debugPrint('Search error: $e');
      if (_songs.isEmpty) {
        _songs = [];
        _albums = [];
        _artists = [];
      }
    } finally {
      if (requestId == _activeRequestId) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  List<T> _rankAndMerge<T>({
    required List<T> local,
    required List<T> network,
    required String query,
    required String Function(T) getName,
    required String Function(T) getArtist,
    required String Function(T) getLanguage,
    required double Function(T) getQualityScore,
    required String Function(T) getId,
    String Function(T)? getDedupeKey,
    T Function(T, T)? merge,
    int minCount = 0,
  }) {
    final networkRankById = <String, int>{};
    for (var index = 0; index < network.length; index++) {
      final id = getId(network[index]).trim();
      if (id.isEmpty || networkRankById.containsKey(id)) continue;
      networkRankById[id] = index;
    }

    final localRankById = <String, int>{};
    for (var index = 0; index < local.length; index++) {
      final id = getId(local[index]).trim();
      if (id.isEmpty || localRankById.containsKey(id)) continue;
      localRankById[id] = index;
    }

    final list = <T>[];
    final mergedMap = <String, T>{};
    for (final item in network) {
      final key = getDedupeKey != null ? getDedupeKey(item) : getId(item).trim();
      if (key.isEmpty) continue;
      mergedMap[key] = item;
    }
    for (final item in local) {
      final key = getDedupeKey != null ? getDedupeKey(item) : getId(item).trim();
      if (key.isEmpty) continue;
      final existing = mergedMap[key];
      if (existing != null && merge != null) {
        mergedMap[key] = merge(existing, item);
      } else if (existing == null) {
        mergedMap[key] = item;
      }
    }
    list.addAll(mergedMap.values);

    if (list.isEmpty) return <T>[];
    final fuzzyScores = _buildFuzzyScores<T>(
      list: list,
      query: query,
      getName: getName,
      getArtist: getArtist,
      getId: getId,
    );

    final compactQuery = _compact(query);
    final rawQueryTokens = _tokenize(query);
    final queryTokens = rawQueryTokens
        .where((token) => !_searchNoiseWords.contains(token))
        .toList(growable: false);
    final effectiveQueryTokens = queryTokens.isNotEmpty
        ? queryTokens
        : rawQueryTokens;
    final queryWantsDerivative = _containsDerivativeKeyword(query);
    final ranked = <_RankedCandidate<T>>[];
    final fallback = <_RankedCandidate<T>>[];

    for (final item in list) {
      final id = getId(item);
      final name = _normalize(getName(item));
      final artist = _normalize(getArtist(item));
      final language = getLanguage(item);
      if (!_matchesPreferredLanguage(language)) continue;

      final targetTokens = _tokenize('$name $artist');
      final fuzzyBoost = (fuzzyScores[id] ?? 0.0).clamp(0.0, 1.0);

      // Support for isOfficial in both Song and Album models.
      bool isOfficial = true;
      try {
        isOfficial = (item as dynamic).isOfficial ?? true;
      } catch (_) {}

      final match = _scoreMatch(
        query: query,
        compactQuery: compactQuery,
        queryTokens: effectiveQueryTokens,
        name: name,
        artist: artist,
        targetTokens: targetTokens,
        fuzzyBoost: fuzzyBoost,
        queryWantsDerivative: queryWantsDerivative,
      );

      final sourceRank =
          networkRankById[id] ?? (1000 + (localRankById[id] ?? 0));

      double biasBoost = 0.0;
      if (item is Song) {
        biasBoost = BackgroundLearningService.getBiasBoost(id, query: query);
      }

      final candidate = _RankedCandidate<T>(
        item: item,
        languageBucket: 0,
        matchTier: match.tier,
        score:
            match.score +
            (isOfficial ? 14.0 : -4.0) +
            _computeSearchPriorityBoost(item) +
            _computeSourceOrderBoost(sourceRank) +
            biasBoost,
        qualityScore: getQualityScore(item),
        sourceRank: sourceRank,
        tieBreaker: name,
        isOfficial: isOfficial,
      );
      if (match.tier > 4) {
        fallback.add(candidate);
      } else {
        ranked.add(candidate);
      }
    }

    ranked.sort((a, b) {
      final tierCmp = a.matchTier.compareTo(b.matchTier);
      if (tierCmp != 0) return tierCmp;

      final scoreCmp = b.score.compareTo(a.score);
      if (scoreCmp != 0) return scoreCmp;

      final sourceCmp = a.sourceRank.compareTo(b.sourceRank);
      if (sourceCmp != 0) return sourceCmp;

      if (a.isOfficial != b.isOfficial) {
        return a.isOfficial ? -1 : 1;
      }

      final qualityCmp = b.qualityScore.compareTo(a.qualityScore);
      if (qualityCmp != 0) return qualityCmp;

      return a.tieBreaker.compareTo(b.tieBreaker);
    });

    final desiredCount = minCount.clamp(0, _maxSearchResults);
    final selected = ranked.take(_maxSearchResults).toList(growable: true);

    if (selected.length < desiredCount && fallback.isNotEmpty) {
      fallback.sort((a, b) {
        final sourceCmp = a.sourceRank.compareTo(b.sourceRank);
        if (sourceCmp != 0) return sourceCmp;
        return a.tieBreaker.compareTo(b.tieBreaker);
      });
      for (final candidate in fallback) {
        if (selected.length >= desiredCount) break;
        selected.add(candidate);
      }
    }

    return selected
        .take(_maxSearchResults)
        .map((candidate) => candidate.item)
        .toList(growable: false);
  }

  List<Song> _searchLocalSongs(String query) {
    final safeLocalSongs = _sanitizeSongs(_localSongIndex);
    return _rankAndMerge<Song>(
      local: safeLocalSongs,
      network: const <Song>[],
      query: query,
      getName: (s) => s.name,
      getArtist: (s) => s.artist ?? '',
      getLanguage: (s) => s.language ?? '',
      getQualityScore: (s) => _computeSongQuality(s),
      getId: (s) => s.id,
    );
  }

  double _computeSongQuality(Song s) {
    double score = 10.0;
    if ((s.imageUrl ?? '').isNotEmpty) score += 5.0;
    if (s.duration != null) {
      if (s.duration! >= _idealSongDurationMinSeconds &&
          s.duration! <= _idealSongDurationMaxSeconds) {
        score += 10.0;
      } else if (s.duration! >= _minSongDurationSeconds &&
          s.duration! <= _maxSongDurationSeconds) {
        score += 4.0;
      } else {
        score -= 20.0;
      }
    }
    if (s.year != null) score += 2.0;
    if (_isLikelyMusicType(s.type)) score += 3.0;
    if (s.isOfficial) score += 8.0;
    if (_containsBlockedKeyword(
      '${s.name} ${s.artist ?? ''} ${s.album ?? ''}',
    )) {
      score -= 40.0;
    }
    // Prioritize original versions over covers/remixes/karaoke etc.
    if (_isOriginalVersion(s.name)) {
      score += 15.0;
    } else {
      score -= 12.0;
    }
    return score;
  }

  List<Album> _searchLocalAlbums(String query) {
    final safeLocalAlbums = _sanitizeAlbumsSync(_localAlbumIndex);
    return _rankAndMerge<Album>(
      local: safeLocalAlbums,
      network: const <Album>[],
      query: query,
      getName: (a) => a.name,
      getArtist: (a) => a.artist ?? '',
      getLanguage: (a) => a.language ?? '',
      getQualityScore: (a) => _computeAlbumQuality(a),
      getId: (a) => a.id,
    );
  }

  List<Artist> _searchLocalArtists(String query) {
    return _rankAndMerge<Artist>(
      local: _localArtistIndex,
      network: const <Artist>[],
      query: query,
      getName: (art) => art.name,
      getArtist: (art) => '',
      getLanguage: (art) => '',
      getQualityScore: (art) => art.isVerified ? 10.0 : 1.0,
      getId: (art) => art.id,
      getDedupeKey: (art) => art.name.toLowerCase().trim(),
    );
  }

  double _computeAlbumQuality(Album a) {
    double score = 10.0;
    if ((a.imageUrl ?? '').isNotEmpty) score += 5.0;
    final songs = a.songCount ?? 0;
    if (songs > 0) score += 3.0;
    if (songs > 1) score += 4.0;
    // Strongly prefer complete collections (more songs = higher quality)
    if (songs >= 5) score += 10.0;
    if (songs >= 10) score += 6.0;
    // Penalize single-song albums — they are usually not full collections
    if (songs <= 1) score -= 5.0;
    if (a.year != null) score += 2.0;
    if (a.type == 'ALBUM') score += 2.0;
    if (a.isOfficial) score += 6.0;
    if (_containsBlockedKeyword('${a.name} ${a.artist ?? ''}')) {
      score -= 40.0;
    }
    // Prioritize original albums over derivative compilations
    if (_isOriginalVersion(a.name)) {
      score += 10.0;
    } else {
      score -= 8.0;
    }
    return score;
  }

  double _computeSearchPriorityBoost<T>(T item) {
    if (item is Song) {
      var score = 0.0;
      if (item.duration != null &&
          item.duration! >= _idealSongDurationMinSeconds &&
          item.duration! <= _idealSongDurationMaxSeconds) {
        score += 10.0;
      }
      if (_isLikelyMusicType(item.type)) {
        score += 8.0;
      }
      if (item.isOfficial) {
        score += 12.0;
      }
      // Boost original songs, penalize derivatives
      if (_isOriginalVersion(item.name)) {
        score += 15.0;
      } else {
        score -= 10.0;
      }
      return score;
    }

    if (item is Album) {
      var score = 0.0;
      if (item.isOfficial) {
        score += 8.0;
      }
      final songs = item.songCount ?? 0;
      if (songs > 1) score += 4.0;
      // Strongly boost complete collections in search results
      if (songs >= 5) score += 8.0;
      if (songs >= 10) score += 12.0;
      // Boost original albums
      if (_isOriginalVersion(item.name)) {
        score += 10.0;
      } else {
        score -= 6.0;
      }
      return score;
    }

    return 0.0;
  }

  double _computeSourceOrderBoost(int sourceRank) {
    if (sourceRank >= 1000) return 0.0;
    final boost = 28.0 - sourceRank * 1.6;
    return boost < 0 ? 0.0 : boost;
  }

  Map<String, double> _buildFuzzyScores<T>({
    required List<T> list,
    required String query,
    required String Function(T) getName,
    required String Function(T) getArtist,
    required String Function(T) getId,
  }) {
    final scores = <String, double>{};
    if (list.isEmpty) return scores;

    final fuzzyOptions = FuzzyOptions(
      findAllMatches: true,
      threshold: 0.35,
      keys: [
        WeightedKey(
          name: 'name',
          getter: (T obj) => _normalize(getName(obj)),
          weight: 0.78,
        ),
        WeightedKey(
          name: 'artist',
          getter: (T obj) => _normalize(getArtist(obj)),
          weight: 0.22,
        ),
      ],
    );
    final fuzzy = Fuzzy<T>(list, options: fuzzyOptions);

    for (final result in fuzzy.search(query)) {
      final normalizedScore = (1.0 - result.score).clamp(0.0, 1.0);
      final id = getId(result.item);
      final current = scores[id] ?? 0.0;
      if (normalizedScore > current) {
        scores[id] = normalizedScore;
      }
    }
    return scores;
  }

  _MatchScore _scoreMatch({
    required String query,
    required String compactQuery,
    required List<String> queryTokens,
    required String name,
    required String artist,
    required List<String> targetTokens,
    required double fuzzyBoost,
    required bool queryWantsDerivative,
  }) {
    final compactName = _compact(name);
    final compactArtist = _compact(artist);
    final nameTokens = _tokenize(name);
    final artistTokens = _tokenize(artist);
    final hasExactMatch =
        name == query ||
        (compactQuery.isNotEmpty && compactName == compactQuery);
    final hasStartsWithMatch =
        name.startsWith(query) || compactName.startsWith(compactQuery);
    // Name-level containment is stronger than artist-level
    final hasNameContains =
        name.contains(query) ||
        (compactQuery.isNotEmpty && compactName.contains(compactQuery));
    final hasArtistContains =
        artist.contains(query) ||
        (compactQuery.isNotEmpty && compactArtist.contains(compactQuery));

    final coverage = _getTokenCoverage(queryTokens, targetTokens);
    final nameCoverage = _getTokenCoverage(queryTokens, nameTokens);
    final artistCoverage = _getTokenCoverage(queryTokens, artistTokens);
    final titlePhraseInQuery =
        compactQuery.isNotEmpty &&
        compactName.isNotEmpty &&
        compactQuery.contains(compactName);
    final artistPhraseInQuery =
        compactQuery.isNotEmpty &&
        compactArtist.isNotEmpty &&
        compactQuery.contains(compactArtist);
    // For 1-2 token queries, require ALL tokens; for 3+, allow 1 miss.
    final requiredTokenMatches = queryTokens.isEmpty
        ? 0
        : (queryTokens.length <= 2
              ? queryTokens.length
              : queryTokens.length - 1);
    final hasWordByWordMatch =
        coverage.matchedCount >= requiredTokenMatches &&
        coverage.matchedCount > 0;
    final hasBalancedTitleArtistCoverage =
        nameCoverage.matchedCount > 0 &&
        artistCoverage.matchedCount > 0 &&
        coverage.matchedCount >= requiredTokenMatches;
    final hasStrongTitleArtistIntent =
        titlePhraseInQuery &&
        (artistPhraseInQuery || artistCoverage.matchedCount > 0) &&
        coverage.matchedCount >= requiredTokenMatches;

    var tier = 5;
    var score = 0.0;

    if (hasExactMatch) {
      tier = 0;
      score = 260;
    } else if (hasStrongTitleArtistIntent) {
      tier = 0;
      score = 245;
    } else if (hasBalancedTitleArtistCoverage) {
      tier = 1;
      score = 210;
    } else if (hasStartsWithMatch) {
      tier = 1;
      score = 190;
    } else if (hasNameContains) {
      tier = 2;
      score = 150;
    } else if (hasArtistContains && nameCoverage.matchedCount > 0) {
      tier = 2;
      score = 132;
    } else if (hasArtistContains) {
      tier = 3;
      score = 100;
    } else if (hasWordByWordMatch && coverage.fuzzyCount == 0) {
      // All matched tokens are exact word matches (no fuzzy)
      tier = 3;
      score = 114;
    } else if (hasWordByWordMatch) {
      // Some fuzzy token matches
      tier = 3;
      score = 85;
    } else if (fuzzyBoost >= 0.15 || coverage.fuzzyCount > 0) {
      tier = 4;
      score = 60;
    }

    if (tier > 4) {
      // Before giving up, try bigram overlap on compact strings
      if (compactQuery.length >= 4 && compactName.length >= 4) {
        final bigramScore = _bigramOverlap(compactQuery, compactName);
        if (bigramScore >= 0.45) {
          tier = 4;
          score = 40 + bigramScore * 30;
        }
      }
      if (tier > 4) {
        return const _MatchScore(tier: 5, score: 0.0);
      }
    }

    if (titlePhraseInQuery) {
      score += 18;
    }
    if (artistPhraseInQuery) {
      score += 18;
    } else if (artistCoverage.matchedCount > 0) {
      score += (artistCoverage.matchedCount * 6.0).clamp(0.0, 14.0).toDouble();
    }
    if (artist.contains(query)) {
      score += 8;
    }
    if (queryTokens.isNotEmpty) {
      score += coverage.coverage * 22;
      // Bonus: all tokens matched directly in name
      if (coverage.matchedCount == queryTokens.length &&
          coverage.fuzzyCount == 0) {
        score += 18;
      }
    }
    score += fuzzyBoost * 10;

    final isDerivative = _containsDerivativeKeyword(name);
    if (isDerivative) {
      if (!queryWantsDerivative) {
        score -= tier <= 2 ? 32.0 : 46.0;
        if (titlePhraseInQuery) score -= 16.0;
      } else {
        score += 14.0;
      }
    } else if (queryWantsDerivative) {
      score -= 18.0;
    }

    if (!queryWantsDerivative && titlePhraseInQuery) {
      final extraNameTerms = nameTokens.length - queryTokens.length;
      if (extraNameTerms >= 3) {
        score -= (extraNameTerms * 4.0).clamp(0.0, 18.0).toDouble();
      }
    }

    return _MatchScore(tier: tier, score: score);
  }

  _TokenCoverage _getTokenCoverage(
    List<String> queryTokens,
    List<String> targetTokens,
  ) {
    if (queryTokens.isEmpty || targetTokens.isEmpty) {
      return const _TokenCoverage(
        matchedCount: 0,
        fuzzyCount: 0,
        coverage: 0.0,
      );
    }

    var matchedCount = 0;
    var fuzzyCount = 0;
    for (final term in queryTokens) {
      if (_hasTokenContainment(term, targetTokens)) {
        matchedCount += 1;
        continue;
      }
      if (_hasFuzzyTokenMatch(term, targetTokens)) {
        matchedCount += 1;
        fuzzyCount += 1;
      }
    }

    return _TokenCoverage(
      matchedCount: matchedCount,
      fuzzyCount: fuzzyCount,
      coverage: matchedCount / queryTokens.length,
    );
  }

  bool _hasTokenContainment(String queryTerm, List<String> targetTokens) {
    for (final token in targetTokens) {
      if (token.contains(queryTerm)) return true;
      if (queryTerm.length >= 5 && queryTerm.contains(token)) return true;
    }
    return false;
  }

  bool _hasFuzzyTokenMatch(String queryTerm, List<String> targetTokens) {
    if (queryTerm.length < 3) return false;
    for (final token in targetTokens) {
      if (token.length < 3) continue;
      final maxDistance = queryTerm.length >= 8 ? 2 : 1;
      if ((queryTerm.length - token.length).abs() > maxDistance) continue;
      // Require first char match for single-edit, partial first 2 chars for double-edit
      if (maxDistance <= 1 && queryTerm[0] != token[0]) continue;
      if (maxDistance > 1 &&
          queryTerm[0] != token[0] &&
          (queryTerm.length < 2 ||
              token.length < 2 ||
              queryTerm[1] != token[1])) {
        continue;
      }
      if (_levenshteinDistance(queryTerm, token) <= maxDistance) {
        return true;
      }
    }
    return false;
  }

  double _bigramOverlap(String a, String b) {
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
    final denominator = bigramsA.length > total ? bigramsA.length : total;
    return matches / denominator;
  }

  int _levenshteinDistance(String source, String target) {
    if (source == target) return 0;
    if (source.isEmpty) return target.length;
    if (target.isEmpty) return source.length;

    final rows = source.length + 1;
    final cols = target.length + 1;
    final dp = List<List<int>>.generate(
      rows,
      (_) => List<int>.filled(cols, 0),
      growable: false,
    );

    for (var i = 0; i < rows; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j < cols; j++) {
      dp[0][j] = j;
    }

    for (var i = 1; i < rows; i++) {
      for (var j = 1; j < cols; j++) {
        final cost = source.codeUnitAt(i - 1) == target.codeUnitAt(j - 1)
            ? 0
            : 1;
        final deletion = dp[i - 1][j] + 1;
        final insertion = dp[i][j - 1] + 1;
        final substitution = dp[i - 1][j - 1] + cost;
        dp[i][j] = [
          deletion,
          insertion,
          substitution,
        ].reduce((min, value) => value < min ? value : min);
      }
    }

    return dp[rows - 1][cols - 1];
  }

  Future<void> loadMore() async {
    if (_offlineMode ||
        _loading ||
        _loadingMore ||
        !_hasMore ||
        _query.isEmpty) {
      return;
    }

    _loadingMore = true;
    notifyListeners();

    try {
      _page++;
      final data = await ApiService.searchSongs(
        _query,
        page: _page,
        preferredLanguages: _preferredLanguages,
        limit: _maxSearchResults,
      );
      final newSongs = _sanitizeSongs(_parseList<Song>(data, Song.fromJson));

      if (newSongs.isEmpty) {
        _hasMore = false;
      } else {
        final existingIds = _songs.map((song) => song.id).toSet();
        for (final song in newSongs) {
          if (existingIds.add(song.id)) {
            _songs.add(song);
          }
        }
        if (newSongs.length < 10) _hasMore = false;
      }
    } catch (e) {
      debugPrint('Load more error: $e');
      _hasMore = false;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  void clear() {
    _songs = [];
    _albums = [];
    _artists = [];
    _playlists = [];
    _query = '';
    _searchRecommendations = _recentSearches.take(8).toList(growable: false);
    notifyListeners();
  }

  void showRecommendationsForInput(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      _searchRecommendations = _recentSearches.take(8).toList(growable: false);
      notifyListeners();
      return;
    }

    final recents = _recentSearches
        .where((item) => item.toLowerCase().contains(normalized))
        .take(8)
        .toList(growable: false);
    _searchRecommendations = recents;
    notifyListeners();
  }

  Future<void> removeRecentSearch(String query) async {
    _recentSearches = _recentSearches
        .where((entry) => entry.toLowerCase() != query.toLowerCase())
        .toList(growable: false);
    _searchRecommendations = _recentSearches.take(8).toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentSearchesKey, _recentSearches);
    notifyListeners();
  }

  Future<void> clearRecentSearches() async {
    _recentSearches = [];
    _searchRecommendations = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentSearchesKey);
    notifyListeners();
  }

  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_recentSearchesKey) ?? const [];
    _recentSearches = stored
        .where(
          (q) =>
              ContentFilter.isAllowedSongTitle(q) &&
              !_looksLikeTestOrIncomplete(q),
        )
        .toList(growable: false);
    _searchRecommendations = _recentSearches.take(8).toList(growable: false);
    notifyListeners();
  }

  Future<void> _saveRecentSearch(String query) async {
    if (!ContentFilter.isAllowedSongTitle(query)) return;
    if (_looksLikeTestOrIncomplete(query)) return;

    final existing = _recentSearches
        .where((entry) => entry.toLowerCase() != query.toLowerCase())
        .toList();
    _recentSearches = [
      query,
      ...existing,
    ].take(_maxRecentSearches).toList(growable: false);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentSearchesKey, _recentSearches);
  }

  List<String> _buildRecommendations(String query) {
    final lowerQuery = query.toLowerCase();
    final suggestions = <String>[];

    void addSuggestion(String? value) {
      final text = (value ?? '').trim();
      if (text.isEmpty) return;
      if (text.toLowerCase() == lowerQuery) return;
      if (suggestions.any((item) => item.toLowerCase() == text.toLowerCase())) {
        return;
      }
      if (!ContentFilter.isAllowedSongTitle(text)) return;
      if (_looksLikeTestOrIncomplete(text)) return;

      suggestions.add(text);
    }

    for (final song in _songs.take(6)) {
      addSuggestion(song.name);
      addSuggestion(song.artist);
    }
    for (final album in _albums.take(4)) {
      addSuggestion(album.name);
      addSuggestion(album.artist);
    }
    for (final artist in _artists.take(4)) {
      addSuggestion(artist.name);
    }

    for (final recent in _recentSearches) {
      if (suggestions.length >= 8) break;
      if (recent.toLowerCase().contains(lowerQuery)) {
        addSuggestion(recent);
      }
    }

    return suggestions.take(8).toList(growable: false);
  }

  List<Song> _sanitizeSongs(List<Song> songs) {
    final dedupedByKey = <String, Song>{};
    final dedupedBySignature = <String, Song>{};

    for (final song in songs) {
      if (!_isValidSongForSearch(song)) continue;
      if (!_matchesPreferredLanguage(song.language)) continue;

      final key = song.id.trim().isNotEmpty
          ? 'id:${song.id.trim()}'
          : 'sig:${_songSignature(song)}';
      if (key.endsWith(':')) continue;

      final existingByKey = dedupedByKey[key];
      if (existingByKey == null) {
        dedupedByKey[key] = song;
      } else {
        dedupedByKey[key] = _preferSong(existingByKey, song);
      }
    }

    for (final song in dedupedByKey.values) {
      final signature = _songSignature(song);
      if (signature.isEmpty) continue;

      final existing = dedupedBySignature[signature];
      if (existing == null) {
        dedupedBySignature[signature] = song;
      } else {
        dedupedBySignature[signature] = _preferSong(existing, song);
      }
    }

    final groupedByCore = <String, List<Song>>{};
    for (final song in dedupedBySignature.values) {
      final core = _songCoreSignature(song);
      if (core.isEmpty) continue;
      groupedByCore.putIfAbsent(core, () => <Song>[]).add(song);
    }

    // Within each core group, prefer songs from user's preferred languages
    final output = <Song>[];
    for (final group in groupedByCore.values) {
      group.sort((a, b) {
        // Prefer preferred-language song
        final aLangMatch =
            _preferredLanguageSet.contains(_normalizeLanguage(a.language ?? ''))
            ? 0
            : 1;
        final bLangMatch =
            _preferredLanguageSet.contains(_normalizeLanguage(b.language ?? ''))
            ? 0
            : 1;
        if (aLangMatch != bLangMatch) return aLangMatch.compareTo(bLangMatch);
        // Then prefer the higher quality/more complete one
        return _preferSong(b, a) == b ? 1 : -1;
      });
      output.add(group.first);
    }
    return output;
  }

  Future<List<Album>> _sanitizeAlbums(List<Album> albums) async {
    final languageFiltered = albums
        .where((album) => _matchesPreferredLanguage(album.language))
        .toList();
    return await AlbumFilter.filterAndDeduplicate(languageFiltered);
  }

  List<Album> _sanitizeAlbumsSync(List<Album> albums) {
    final languageFiltered = albums
        .where((album) => _matchesPreferredLanguage(album.language))
        .toList();
    return AlbumFilter.filterAndDeduplicateSync(languageFiltered);
  }

  Song _preferSong(Song a, Song b) {
    int score(Song song) {
      var total = 0;
      if ((song.imageUrl ?? '').trim().isNotEmpty) total += 2;
      if ((song.artist ?? '').trim().isNotEmpty) total += 2;
      if ((song.album ?? '').trim().isNotEmpty) total += 1;
      if ((song.streamUrl ?? '').trim().isNotEmpty) total += 1;
      // Prefer songs matching user's preferred language
      if (_preferredLanguageSet.contains(
        _normalizeLanguage(song.language ?? ''),
      )) {
        total += 5;
      }
      if (song.isOfficial) total += 4;
      // Prefer original versions over covers/remixes
      if (_isOriginalVersion(song.name)) total += 6;
      if (!_isValidSongForSearch(song)) total -= 100;
      return total;
    }

    return score(b) > score(a) ? b : a;
  }

  Album _preferAlbum(Album a, Album b) {
    int score(Album album) {
      var total = 0;
      if ((album.imageUrl ?? '').trim().isNotEmpty) total += 3;
      if ((album.artist ?? '').trim().isNotEmpty) total += 2;
      if ((album.year ?? '').trim().isNotEmpty) total += 2;
      if ((album.language ?? '').trim().isNotEmpty) total += 1;
      if ((album.songCount ?? 0) > 1) total += 4; // Prefer multi-track albums
      if ((album.songCount ?? 0) > 0) total += 2;
      // Strongly prefer full collections
      if ((album.songCount ?? 0) > 3) total += 6;
      if ((album.songCount ?? 0) > 5) total += 8;
      // Prefer albums matching user's language
      if (_preferredLanguageSet.contains(
        _normalizeLanguage(album.language ?? ''),
      )) {
        total += 5;
      }
      if (album.isOfficial) total += 4;
      // Prefer original albums
      if (_isOriginalVersion(album.name)) total += 6;
      if (!_isValidAlbumForSearch(album)) total -= 100;
      return total;
    }

    return score(b) > score(a) ? b : a;
  }

  String _songSignature(Song song) {
    return _normalize('${song.name}|${song.artist ?? ''}|${song.album ?? ''}');
  }

  String _songCoreSignature(Song song) {
    final cleaned = song.name
        .toLowerCase()
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(test|demo|sample|snippet|preview|incomplete|teaser|trailer|official audio|dummy|collection|movie|cartoon|episode|season|dialogue|scene|clip|reaction|review)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _normalize('$cleaned|${song.artist ?? ''}');
  }

  /// Returns true if the title looks like the original version
  /// (no cover/remix/karaoke/lofi/etc. keywords detected).
  bool _isOriginalVersion(String title) {
    final normalized = _normalizeForKeywordMatch(title);
    if (normalized.isEmpty) return true;
    for (final keyword in _derivativeKeywords) {
      final kw = _normalizeForKeywordMatch(keyword);
      if (kw.isEmpty) continue;
      if (kw.contains(' ')) {
        if (normalized.contains(kw)) return false;
      } else {
        if (RegExp(r'\b' + RegExp.escape(kw) + r'\b').hasMatch(normalized)) {
          return false;
        }
      }
    }
    return true;
  }

  String _normalizeForKeywordMatch(String value) {
    return _normalize(value).replaceAll('-', ' ');
  }

  bool _containsDerivativeKeyword(String value) {
    return _containsBlockedKeyword(value, keywords: _derivativeKeywords);
  }

  bool _containsBlockedKeyword(String value, {List<String>? keywords}) {
    final normalized = _normalizeForKeywordMatch(value);
    if (normalized.isEmpty) return false;

    final entries = keywords ?? _blockedSearchKeywords;
    for (final rawKeyword in entries) {
      final keyword = _normalizeForKeywordMatch(rawKeyword);
      if (keyword.isEmpty) continue;

      if (keyword.contains(' ')) {
        if (normalized.contains(keyword)) return true;
        continue;
      }

      if (RegExp(r'\b' + RegExp.escape(keyword) + r'\b').hasMatch(normalized)) {
        return true;
      }
    }

    return false;
  }

  bool _containsBlockedTypeToken(String? type) {
    final normalized = (type ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return false;
    for (final token in _blockedTypeTokens) {
      if (normalized.contains(token)) return true;
    }
    return false;
  }

  bool _isLikelyMusicType(String? type) {
    final normalized = (type ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return true;
    if (_containsBlockedTypeToken(normalized)) return false;
    return true;
  }

  bool _isDurationInSearchRange(int? durationSeconds) {
    if (durationSeconds == null) return true;
    return durationSeconds >= _minSongDurationSeconds &&
        durationSeconds <= _maxSongDurationSeconds;
  }

  bool _isValidSongForSearch(Song song) {
    final title = song.name.trim();
    if (title.isEmpty) return false;
    if ((song.artist ?? '').trim().isEmpty) return false;
    if (!ContentFilter.isAllowedSongTitle(title)) return false;

    final combined = '$title ${song.artist ?? ''} ${song.album ?? ''}';
    if (_containsBlockedKeyword(combined)) return false;
    if (_looksLikeTestOrIncomplete(combined)) return false;
    if (!_isDurationInSearchRange(song.duration)) return false;
    if (!_isLikelyMusicType(song.type)) return false;
    if ((song.streamUrl ?? '').trim().isEmpty) return false;

    return true;
  }

  bool _isValidAlbumForSearch(Album album) {
    final title = album.name.trim();
    if (title.isEmpty) return false;
    if (!ContentFilter.isAllowedSongTitle(title)) return false;
    if (album.id.trim().isEmpty) return false;
    if (album.songCount != null && album.songCount! <= 0) return false;

    final combined = '$title ${album.artist ?? ''}';
    if (_containsBlockedKeyword(combined)) return false;
    if (_looksLikeTestOrIncomplete(combined)) return false;
    if (!_isLikelyMusicType(album.type)) return false;

    final isSingleSongAlbum = (album.songCount ?? 0) <= 1;
    if (isSingleSongAlbum &&
        _containsBlockedKeyword(
          combined,
          keywords: _singleSongAlbumBlockedKeywords,
        )) {
      return false;
    }

    return true;
  }

  bool _looksLikeTestOrIncomplete(String value) {
    final normalized = _normalizeForKeywordMatch(value);
    if (normalized.isEmpty) return false;
    if (normalized == 'this is a sample trailer testing') return true;
    if (_containsBlockedKeyword(normalized)) return true;

    return RegExp(
      r'\b(test|demo|sample|snippet|preview|incomplete|teaser|trailer|official audio|dummy|collection|track\s\d+|sample\s\d+)\b',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  List<T> _parseList<T>(
    List<dynamic> raw,
    T Function(Map<String, dynamic> json) parser,
  ) {
    final parsed = <T>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        parsed.add(parser(Map<String, dynamic>.from(item)));
      } catch (e) {
        debugPrint('Skipped malformed search item: $e');
      }
    }
    return parsed;
  }

  List<T> _mergeUniqueItems<T>({
    required List<T> existing,
    required List<T> incoming,
    required String Function(T item) getId,
  }) {
    final merged = <String, T>{};
    for (final item in existing) {
      final id = getId(item).trim();
      if (id.isEmpty) continue;
      merged[id] = item;
    }
    for (final item in incoming) {
      final id = getId(item).trim();
      if (id.isEmpty) continue;
      merged[id] = item;
    }
    return merged.values.toList(growable: false);
  }

  List<dynamic> _extractAlbumItems(Map<String, dynamic> payload) {
    final data = payload['data'] ?? payload;
    if (data is List) return data;
    if (data is! Map) return const [];

    final results = data['results'];
    if (results is List) return results;
    final albums = data['albums'];
    if (albums is List) return albums;
    final songs = data['songs'];
    if (songs is List) return songs;
    return const [];
  }

  List<Album> _deriveAlbumsFromSongs(List<Song> songs) {
    final deduped = <String, Album>{};
    for (final song in songs) {
      final albumName = (song.album ?? '').trim();
      if (albumName.isEmpty || _looksLikeTestOrIncomplete(albumName)) continue;
      final key = 'song_album_${_normalize(albumName)}';

      final candidate = Album(
        id: key,
        name: albumName,
        artist: song.artist,
        imageUrl: song.imageUrl,
        language: song.language,
        songCount: 1, // At least the song we derived it from
      );

      final existing = deduped[key];
      if (existing == null) {
        deduped[key] = candidate;
      } else {
        deduped[key] = _preferAlbum(existing, candidate);
      }
    }
    return deduped.values.toList(growable: false);
  }

  Artist _mergeArtists(Artist a, Artist b) {
    final bestImage = (a.imageUrl != null && a.imageUrl!.isNotEmpty) ? a.imageUrl : b.imageUrl;
    final role = (a.role != null && a.role!.contains('downloaded')) ? a.role : b.role;
    return Artist(
      id: a.id.startsWith('art_') ? b.id : a.id,
      name: a.name,
      imageUrl: bestImage,
      role: role ?? a.role ?? b.role,
      isVerified: a.isVerified || b.isVerified,
      followerCount: a.followerCount ?? b.followerCount,
    );
  }
}

class _CachedSearchSnapshot {
  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<UserPlaylist> playlists;
  final DateTime storedAt;

  const _CachedSearchSnapshot({
    required this.songs,
    required this.albums,
    required this.artists,
    required this.playlists,
    required this.storedAt,
  });
}

class _RankedCandidate<T> {
  final T item;
  final int languageBucket;
  final int matchTier;
  final double score;
  final double qualityScore;
  final int sourceRank;
  final String tieBreaker;
  final bool isOfficial;

  const _RankedCandidate({
    required this.item,
    required this.languageBucket,
    required this.matchTier,
    required this.score,
    required this.qualityScore,
    required this.sourceRank,
    required this.tieBreaker,
    this.isOfficial = true,
  });
}

class _MatchScore {
  final int tier;
  final double score;

  const _MatchScore({required this.tier, required this.score});
}

class _TokenCoverage {
  final int matchedCount;
  final int fuzzyCount;
  final double coverage;

  const _TokenCoverage({
    required this.matchedCount,
    required this.fuzzyCount,
    required this.coverage,
  });
}
