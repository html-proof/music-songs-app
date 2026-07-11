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
  List<Song> _downloadedSongs = [];
  List<dynamic> _offlineResults = [];
  List<String> _recentSearches = [];
  List<String> _searchRecommendations = [];
  dynamic _topResult;
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
  List<Song> get downloadedSongs => _downloadedSongs;
  List<dynamic> get offlineResults => _offlineResults;
  dynamic get topResult => _topResult;
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
      final Set<String> seenArtistNames = {};
      for (final song in songs) {
        final artistName = song.artist ?? '';
        if (artistName.isNotEmpty && seenArtistNames.add(artistName.toLowerCase())) {
          artists.add(Artist(
            id: 'art_${artistName.toLowerCase().replaceAll(RegExp(r'\s+'), '_')}',
            name: artistName,
            imageUrl: song.imageUrl,
          ));
        }
      }

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
    var str = s.trim().toLowerCase();
    
    // Remove common accents
    const withAccents = 'ÀÁÂÃÄÅàáâãäåÒÓÔÕÕÖØòóôõöøÈÉÊËèéêëðÇçÌÍÎÏìíîïÙÚÛÜùúûüÑñÝýÿ';
    const withoutAccents = 'AAAAAAaaaaaaOOOOOOOoooooooEEEEeeeedCcIIIIiiiiUUUUuuuNnYyy';
    
    for (int i = 0; i < withAccents.length; i++) {
      str = str.replaceAll(withAccents[i], withoutAccents[i]);
    }
    
    return str.replaceAll(RegExp(r'\s+'), ' ');
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
    required List<Song> downloadedSongs,
    required List<dynamic> offlineResults,
    required dynamic topResult,
  }) {
    _queryCache[key] = _CachedSearchSnapshot(
      songs: List<Song>.from(songs),
      albums: List<Album>.from(albums),
      artists: List<Artist>.from(artists),
      playlists: List<UserPlaylist>.from(playlists),
      downloadedSongs: List<Song>.from(downloadedSongs),
      offlineResults: List<dynamic>.from(offlineResults),
      topResult: topResult,
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

    // Refresh offline index
    await _refreshOfflineIndexes();
    if (requestId != _activeRequestId) return;

    // Prepare sets for fast lookups
    final downloadedSongsList = await DownloadService.getDownloadedSongs();
    final downloadedSongIds = downloadedSongsList.map((s) => s.id).toSet();
    final offlineSongIds = _offlineSongIds;
    final offlineAlbumIds = _offlineAlbumIds;

    // Fetch listening history in parallel
    List<dynamic> historyData = [];
    try {
      historyData = await ApiService.getHistory(type: 'play', limit: 80);
    } catch (e) {
      debugPrint('History fetch error: $e');
    }
    if (requestId != _activeRequestId) return;

    final historySongIds = historyData.map((h) => (h['songId'] ?? h['id'] ?? '').toString()).toSet();
    final Map<String, int> historyLangs = {};
    final Map<String, int> historyArtists = {};
    for (final h in historyData) {
      final lang = normalizeLanguage(h['language'] ?? '');
      if (lang.isNotEmpty) historyLangs[lang] = (historyLangs[lang] ?? 0) + 1;
      
      final artistName = h['artist']?.toString().toLowerCase().trim();
      if (artistName != null && artistName.isNotEmpty) {
        historyArtists[artistName] = (historyArtists[artistName] ?? 0) + 1;
      }
    }

    // 1. Instant local search feedback
    final localSongs = _searchLocalSongs(normalizedQuery, downloadedSongIds, offlineSongIds);
    final localAlbums = _searchLocalAlbums(normalizedQuery, offlineAlbumIds);

    if (localSongs.isNotEmpty || localAlbums.isNotEmpty) {
      _songs = localSongs;
      _albums = localAlbums;
      _loading = false;
      notifyListeners();
    }

    // 2. Cache check
    final cacheKey = _searchCacheKey(normalizedQuery);
    final cached = _readQueryCache(cacheKey);
    if (cached != null) {
      _songs = List<Song>.from(cached.songs);
      _albums = List<Album>.from(cached.albums);
      _artists = List<Artist>.from(cached.artists);
      _playlists = List<UserPlaylist>.from(cached.playlists);
      _downloadedSongs = List<Song>.from(cached.downloadedSongs);
      _offlineResults = List<dynamic>.from(cached.offlineResults);
      _topResult = cached.topResult;
      _searchRecommendations = _buildRecommendations(normalizedQuery);
      _loading = false;
      notifyListeners();
      return;
    }

    // Check if query is URL
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
          _playlists = [];
          _downloadedSongs = _songs.where((s) => downloadedSongIds.contains(s.id)).toList();
          _offlineResults = [];
          _searchRecommendations = [];
          _hasMore = false;

          _topResult = _songs.isNotEmpty ? _songs.first : null;
          _writeQueryCache(
            cacheKey,
            songs: _songs,
            albums: _albums,
            artists: _artists,
            playlists: _playlists,
            downloadedSongs: _downloadedSongs,
            offlineResults: _offlineResults,
            topResult: _topResult,
          );
          _saveRecentSearch(query.trim()).catchError((_) {});

          _loading = false;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('URL import failed in search: $e');
      }
    }

    // 3. Search in parallel
    Map<String, List<dynamic>> onlineData = {'songs': [], 'albums': [], 'artists': []};
    List<UserPlaylist> localPlaylists = [];
    
    if (!_offlineMode) {
      try {
        final results = await Future.wait([
          ApiService.globalSearch(
            normalizedQuery,
            preferredLanguages: _preferredLanguages,
            limit: _maxSearchResults,
          ).catchError((e) {
            debugPrint('API search error: $e');
            return <String, List<dynamic>>{};
          }),
          PlaylistService.getPlaylists().catchError((e) {
            debugPrint('Playlists search error: $e');
            return <UserPlaylist>[];
          }),
        ]);
        if (requestId != _activeRequestId) return;
        onlineData = results[0] as Map<String, List<dynamic>>;
        localPlaylists = results[1] as List<UserPlaylist>;
      } catch (e) {
        debugPrint('Parallel search error: $e');
      }
    } else {
      try {
        localPlaylists = await PlaylistService.getPlaylists();
      } catch (e) {
        debugPrint('Offline playlists error: $e');
      }
    }

    if (requestId != _activeRequestId) return;

    // Parse all raw objects
    final parsedOnlineSongs = _parseList<Song>(onlineData['songs'] ?? [], Song.fromJson);
    final parsedOnlineAlbums = _parseList<Album>(onlineData['albums'] ?? [], Album.fromJson);
    final parsedOnlineArtists = _parseList<Artist>(onlineData['artists'] ?? [], Artist.fromJson);

    // Merge offline & downloaded songs/albums/artists with online results
    final List<Song> rawSongs = [
      ...parsedOnlineSongs,
      ...downloadedSongsList,
      ..._localSongIndex.where((s) => offlineSongIds.contains(s.id)),
    ];
    final List<Album> rawAlbums = [
      ...parsedOnlineAlbums,
      ..._localAlbumIndex.where((a) => offlineAlbumIds.contains(a.id)),
    ];
    final List<Artist> rawArtists = [
      ...parsedOnlineArtists,
      ..._localArtistIndex,
    ];
    final List<UserPlaylist> rawPlaylists = localPlaylists.where((p) {
      final nameMatch = p.name.toLowerCase().contains(normalizedQuery);
      final descMatch = p.description?.toLowerCase().contains(normalizedQuery) ?? false;
      return nameMatch || descMatch;
    }).toList();

    // Deduplicate songs, albums, and artists
    final dedupedSongs = _mergeAndDeduplicateSongs(rawSongs, downloadedSongIds);
    final dedupedAlbums = _mergeAndDeduplicateAlbums(rawAlbums);
    final dedupedArtists = _mergeAndDeduplicateArtists(rawArtists);

    // Filter by preferred language
    final filteredSongs = dedupedSongs.where((s) => _isValidSongForSearch(s) && _matchesPreferredLanguage(s.language)).toList();
    final filteredAlbums = dedupedAlbums.where((a) => _isValidAlbumForSearch(a) && _matchesPreferredLanguage(a.language)).toList();

    // 4. Calculate fuzzy scores
    final songFuzzyScores = _buildFuzzyScores<Song>(
      list: filteredSongs,
      query: normalizedQuery,
      getName: (s) => s.name,
      getArtist: (s) => s.artist ?? '',
      getId: (s) => s.id,
    );
    final albumFuzzyScores = _buildFuzzyScores<Album>(
      list: filteredAlbums,
      query: normalizedQuery,
      getName: (a) => a.name,
      getArtist: (a) => a.artist ?? '',
      getId: (a) => a.id,
    );
    final artistFuzzyScores = _buildFuzzyScores<Artist>(
      list: dedupedArtists,
      query: normalizedQuery,
      getName: (art) => art.name,
      getArtist: (art) => '',
      getId: (art) => art.id,
    );
    final playlistFuzzyScores = _buildFuzzyScores<UserPlaylist>(
      list: rawPlaylists,
      query: normalizedQuery,
      getName: (p) => p.name,
      getArtist: (p) => p.description ?? '',
      getId: (p) => p.id,
    );

    // 5. Score every item
    final Map<dynamic, double> scores = {};

    for (final song in filteredSongs) {
      scores[song] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: song.name,
        artist: song.artist,
        album: song.album,
        language: song.language,
        item: song,
        downloadedSongIds: downloadedSongIds,
        offlineSongIds: offlineSongIds,
        offlineAlbumIds: offlineAlbumIds,
        historySongIds: historySongIds,
        historyLangs: historyLangs,
        historyArtists: historyArtists,
        fuzzySimilarity: songFuzzyScores[song.id] ?? 0.0,
      );
    }

    for (final album in filteredAlbums) {
      scores[album] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: album.name,
        artist: album.artist,
        language: album.language,
        item: album,
        downloadedSongIds: downloadedSongIds,
        offlineSongIds: offlineSongIds,
        offlineAlbumIds: offlineAlbumIds,
        historySongIds: historySongIds,
        historyLangs: historyLangs,
        historyArtists: historyArtists,
        fuzzySimilarity: albumFuzzyScores[album.id] ?? 0.0,
      );
    }

    for (final artist in dedupedArtists) {
      scores[artist] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: artist.name,
        item: artist,
        downloadedSongIds: downloadedSongIds,
        offlineSongIds: offlineSongIds,
        offlineAlbumIds: offlineAlbumIds,
        historySongIds: historySongIds,
        historyLangs: historyLangs,
        historyArtists: historyArtists,
        fuzzySimilarity: artistFuzzyScores[artist.id] ?? 0.0,
      );
    }

    for (final playlist in rawPlaylists) {
      scores[playlist] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: playlist.name,
        item: playlist,
        downloadedSongIds: downloadedSongIds,
        offlineSongIds: offlineSongIds,
        offlineAlbumIds: offlineAlbumIds,
        historySongIds: historySongIds,
        historyLangs: historyLangs,
        historyArtists: historyArtists,
        fuzzySimilarity: playlistFuzzyScores[playlist.id] ?? 0.0,
      );
    }

    // 6. Sort and assign
    filteredSongs.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    filteredAlbums.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    dedupedArtists.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    rawPlaylists.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));

    _songs = filteredSongs.take(_maxSearchResults).toList();
    _albums = filteredAlbums.take(_maxSearchResults).toList();
    _artists = dedupedArtists.take(_maxSearchResults).toList();
    _playlists = rawPlaylists.take(_maxSearchResults).toList();

    // 7. Populating Downloaded Songs & Offline Results
    _downloadedSongs = _songs.where((s) => downloadedSongIds.contains(s.id)).toList();

    final List<dynamic> offResults = [];
    offResults.addAll(_songs.where((s) => offlineSongIds.contains(s.id) && !downloadedSongIds.contains(s.id)));
    offResults.addAll(_albums.where((a) => offlineAlbumIds.contains(a.id)));
    offResults.addAll(_artists.where((art) => _localArtistIndex.any((la) => la.name.toLowerCase() == art.name.toLowerCase())));
    offResults.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    _offlineResults = offResults.take(_maxSearchResults).toList();

    // Select dynamic Top Result across Songs, Artists, Albums, and Playlists
    dynamic bestCandidate;
    double bestScore = -1.0;
    
    if (_songs.isNotEmpty) {
      final firstSong = _songs.first;
      final score = scores[firstSong] ?? 0.0;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = firstSong;
      }
    }
    if (_albums.isNotEmpty) {
      final firstAlbum = _albums.first;
      final score = scores[firstAlbum] ?? 0.0;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = firstAlbum;
      }
    }
    if (_artists.isNotEmpty) {
      final firstArtist = _artists.first;
      final score = scores[firstArtist] ?? 0.0;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = firstArtist;
      }
    }
    if (_playlists.isNotEmpty) {
      final firstPlaylist = _playlists.first;
      final score = scores[firstPlaylist] ?? 0.0;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = firstPlaylist;
      }
    }
    _topResult = bestCandidate;

    // Save recommendations and recent search
    _searchRecommendations = _buildRecommendations(normalizedQuery);
    _saveRecentSearch(query.trim()).catchError((_) {});

    _writeQueryCache(
      cacheKey,
      songs: _songs,
      albums: _albums,
      artists: _artists,
      playlists: _playlists,
      downloadedSongs: _downloadedSongs,
      offlineResults: _offlineResults,
      topResult: _topResult,
    );

    if (_songs.length < 10) _hasMore = false;
    _loading = false;
    notifyListeners();
  }

  double _calculateRelevanceScore({
    required String query,
    required String name,
    String? artist,
    String? album,
    String? language,
    required dynamic item,
    required Set<String> downloadedSongIds,
    required Set<String> offlineSongIds,
    required Set<String> offlineAlbumIds,
    required Set<String> historySongIds,
    required Map<String, int> historyLangs,
    required Map<String, int> historyArtists,
    required double fuzzySimilarity,
  }) {
    double score = 0.0;

    final qNorm = _normalize(query);
    final nameNorm = _normalize(name);
    final artistNorm = artist != null ? _normalize(artist) : '';
    final albumNorm = album != null ? _normalize(album) : '';
    final langNorm = language != null ? _normalizeLanguage(language) : '';

    if (qNorm.isEmpty) return 0.0;

    // 1. Exact Title Match (100)
    if (nameNorm == qNorm) {
      score += 100.0;
    }
    // 2. Starts With Query (90)
    else if (nameNorm.startsWith(qNorm)) {
      score += 90.0;
    }

    // 3. Artist Match (85)
    if (item is Artist) {
      if (nameNorm == qNorm || nameNorm.startsWith(qNorm)) {
        score += 85.0;
      }
    } else {
      if (artistNorm.isNotEmpty && (artistNorm == qNorm || artistNorm.startsWith(qNorm))) {
        score += 85.0;
      }
    }

    // 4. Album Match (80)
    if (item is Album) {
      if (nameNorm == qNorm || nameNorm.startsWith(qNorm)) {
        score += 80.0;
      }
    } else if (item is Song) {
      if (albumNorm.isNotEmpty && (albumNorm == qNorm || albumNorm.startsWith(qNorm))) {
        score += 80.0;
      }
    }

    // 5. Popularity (70)
    double popularityFactor = 0.2;
    if (item is Song) {
      if (item.playCount != null) {
        popularityFactor = (item.playCount! / 1000000.0).clamp(0.0, 1.0);
      } else if (item.recommendationScore != null) {
        popularityFactor = (item.recommendationScore! / 100.0).clamp(0.0, 1.0);
      } else {
        popularityFactor = item.isOfficial ? 0.6 : 0.2;
      }
    } else if (item is Album) {
      if (item.playCount != null) {
        popularityFactor = (item.playCount! / 500000.0).clamp(0.0, 1.0);
      } else {
        popularityFactor = item.isOfficial ? 0.6 : 0.2;
      }
    } else if (item is Artist) {
      if (item.followerCount != null) {
        popularityFactor = (item.followerCount! / 10000000.0).clamp(0.0, 1.0);
      } else {
        popularityFactor = item.isVerified ? 0.7 : 0.3;
      }
    } else if (item is UserPlaylist) {
      popularityFactor = (item.songs.length / 50.0).clamp(0.0, 1.0);
    }
    score += 70.0 * popularityFactor;

    // 6. User Listening History (60)
    bool inHistory = false;
    if (item is Song) {
      inHistory = historySongIds.contains(item.id);
    } else if (item is Artist) {
      inHistory = historyArtists.containsKey(nameNorm);
    } else if (item is Album) {
      inHistory = historySongIds.any((id) => _localSongIndex.any((s) => s.id == id && s.album == item.name));
    }
    
    if (inHistory) {
      score += 60.0;
    } else {
      bool topLangOrArtist = false;
      if (langNorm.isNotEmpty && historyLangs.containsKey(langNorm) && historyLangs[langNorm]! >= 3) {
        topLangOrArtist = true;
      }
      if (artistNorm.isNotEmpty && historyArtists.containsKey(artistNorm) && historyArtists[artistNorm]! >= 3) {
        topLangOrArtist = true;
      }
      if (topLangOrArtist) {
        score += 30.0;
      }
    }

    // 7. Preferred Language (50)
    if (langNorm.isNotEmpty && _preferredLanguageSet.contains(langNorm)) {
      score += 50.0;
    }

    // 8. Downloaded/Offline (40)
    bool isOffline = false;
    if (item is Song) {
      isOffline = downloadedSongIds.contains(item.id) || offlineSongIds.contains(item.id);
    } else if (item is Album) {
      isOffline = offlineAlbumIds.contains(item.id);
    } else if (item is Artist) {
      isOffline = _localArtistIndex.any((art) => art.name.toLowerCase() == nameNorm);
    }
    if (isOffline) {
      score += 40.0;
    }

    // 9. Fuzzy Match (30)
    final nameContains = nameNorm.contains(qNorm);
    final artistContains = artistNorm.contains(qNorm);
    if (!nameContains && !artistContains && fuzzySimilarity >= 0.7) {
      score += 30.0;
    }

    return score;
  }

  List<Song> _mergeAndDeduplicateSongs(List<Song> allSongs, Set<String> downloadedSongIds) {
    final Map<String, Song> idMerged = {};
    for (final song in allSongs) {
      if (song.id.isEmpty) continue;
      final existing = idMerged[song.id];
      if (existing == null) {
        idMerged[song.id] = song;
      } else {
        idMerged[song.id] = _mergeTwoSongs(existing, song, downloadedSongIds);
      }
    }

    final Map<String, Song> sigMerged = {};
    for (final song in idMerged.values) {
      final sig = _songCoreSignature(song);
      final existing = sigMerged[sig];
      if (existing == null) {
        sigMerged[sig] = song;
      } else {
        sigMerged[sig] = _mergeTwoSongs(existing, song, downloadedSongIds);
      }
    }

    return sigMerged.values.toList();
  }

  Song _mergeTwoSongs(Song a, Song b, Set<String> downloadedSongIds) {
    final isADownloaded = downloadedSongIds.contains(a.id);
    final isBDownloaded = downloadedSongIds.contains(b.id);
    
    final primary = (isADownloaded || (!isBDownloaded && a.streamUrl != null && a.streamUrl!.isNotEmpty)) ? a : b;
    final secondary = primary == a ? b : a;

    return Song(
      id: primary.id,
      name: primary.name,
      album: (primary.album ?? '').isNotEmpty ? primary.album : secondary.album,
      albumId: (primary.albumId ?? '').isNotEmpty ? primary.albumId : secondary.albumId,
      artist: (primary.artist ?? '').isNotEmpty ? primary.artist : secondary.artist,
      imageUrl: (primary.imageUrl ?? '').isNotEmpty ? primary.imageUrl : secondary.imageUrl,
      streamUrl: (primary.streamUrl ?? '').isNotEmpty ? primary.streamUrl : secondary.streamUrl,
      language: (primary.language ?? '').isNotEmpty ? primary.language : secondary.language,
      duration: primary.duration ?? secondary.duration,
      year: (primary.year ?? '').isNotEmpty ? primary.year : secondary.year,
      type: (primary.type ?? '').isNotEmpty ? primary.type : secondary.type,
      isExplicit: primary.isExplicit || secondary.isExplicit,
      isOfficial: primary.isOfficial || secondary.isOfficial,
      recommendationScore: primary.recommendationScore ?? secondary.recommendationScore,
      playCount: primary.playCount ?? secondary.playCount,
      popularity: primary.popularity ?? secondary.popularity,
    );
  }

  List<Album> _mergeAndDeduplicateAlbums(List<Album> albums) {
    final Map<String, Album> idMerged = {};
    for (final a in albums) {
      if (a.id.isEmpty) continue;
      final existing = idMerged[a.id];
      if (existing == null) {
        idMerged[a.id] = a;
      } else {
        idMerged[a.id] = _preferAlbum(existing, a);
      }
    }

    final Map<String, Album> nameMerged = {};
    for (final a in idMerged.values) {
      final sig = '${a.name.toLowerCase().trim()}|${(a.artist ?? '').toLowerCase().trim()}';
      final existing = nameMerged[sig];
      if (existing == null) {
        nameMerged[sig] = a;
      } else {
        nameMerged[sig] = _preferAlbum(existing, a);
      }
    }
    return nameMerged.values.toList();
  }

  List<Artist> _mergeAndDeduplicateArtists(List<Artist> artists) {
    final Map<String, Artist> idMerged = {};
    for (final a in artists) {
      if (a.id.isEmpty) continue;
      final existing = idMerged[a.id];
      if (existing == null) {
        idMerged[a.id] = a;
      } else {
        final hasImage = (a.imageUrl ?? '').isNotEmpty;
        final existingHasImage = (existing.imageUrl ?? '').isNotEmpty;
        if (!existingHasImage && hasImage) {
          idMerged[a.id] = a;
        }
      }
    }

    final Map<String, Artist> nameMerged = {};
    for (final a in idMerged.values) {
      final nameKey = a.name.toLowerCase().trim();
      final existing = nameMerged[nameKey];
      if (existing == null) {
        nameMerged[nameKey] = a;
      } else {
        final hasImage = (a.imageUrl ?? '').isNotEmpty;
        final existingHasImage = (existing.imageUrl ?? '').isNotEmpty;
        if (!existingHasImage && hasImage) {
          nameMerged[nameKey] = a;
        }
      }
    }
    return nameMerged.values.toList();
  }

  List<Song> _searchLocalSongs(String query, Set<String> downloadedSongIds, Set<String> offlineSongIds) {
    final normalizedQuery = _normalize(query);
    final songs = _localSongIndex.where((s) => _isValidSongForSearch(s) && _matchesPreferredLanguage(s.language)).toList();
    
    final fuzzyScores = _buildFuzzyScores<Song>(
      list: songs,
      query: normalizedQuery,
      getName: (s) => s.name,
      getArtist: (s) => s.artist ?? '',
      getId: (s) => s.id,
    );

    final Map<Song, double> scores = {};
    for (final song in songs) {
      scores[song] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: song.name,
        artist: song.artist,
        album: song.album,
        language: song.language,
        item: song,
        downloadedSongIds: downloadedSongIds,
        offlineSongIds: offlineSongIds,
        offlineAlbumIds: const {},
        historySongIds: const {},
        historyLangs: const {},
        historyArtists: const {},
        fuzzySimilarity: fuzzyScores[song.id] ?? 0.0,
      );
    }

    songs.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    return songs.take(_maxSearchResults).toList();
  }

  List<Album> _searchLocalAlbums(String query, Set<String> offlineAlbumIds) {
    final normalizedQuery = _normalize(query);
    final albums = _localAlbumIndex.where((a) => _isValidAlbumForSearch(a) && _matchesPreferredLanguage(a.language)).toList();

    final fuzzyScores = _buildFuzzyScores<Album>(
      list: albums,
      query: normalizedQuery,
      getName: (a) => a.name,
      getArtist: (a) => a.artist ?? '',
      getId: (a) => a.id,
    );

    final Map<Album, double> scores = {};
    for (final album in albums) {
      scores[album] = _calculateRelevanceScore(
        query: normalizedQuery,
        name: album.name,
        artist: album.artist,
        language: album.language,
        item: album,
        downloadedSongIds: const {},
        offlineSongIds: const {},
        offlineAlbumIds: offlineAlbumIds,
        historySongIds: const {},
        historyLangs: const {},
        historyArtists: const {},
        fuzzySimilarity: fuzzyScores[album.id] ?? 0.0,
      );
    }

    albums.sort((a, b) => (scores[b] ?? 0.0).compareTo(scores[a] ?? 0.0));
    return albums.take(_maxSearchResults).toList();
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
    _downloadedSongs = [];
    _offlineResults = [];
    _topResult = null;
    _query = '';
    _searchRecommendations = _recentSearches.take(8).toList(growable: false);
    notifyListeners();
  }

  void showRecommendationsForInput(String query) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) {
      _searchRecommendations = _recentSearches.take(8).toList(growable: false);
      notifyListeners();
      return;
    }

    final suggestions = <String>[];
    
    // 1. Add matching recent searches
    for (final recent in _recentSearches) {
      if (recent.toLowerCase().contains(normalized)) {
        suggestions.add(recent);
      }
    }

    // 2. Add matching songs from local cache index
    for (final song in _localSongIndex) {
      if (song.name.toLowerCase().contains(normalized)) {
        suggestions.add(song.name);
      }
      if (song.artist != null && song.artist!.toLowerCase().contains(normalized)) {
        suggestions.add(song.artist!);
      }
    }

    // 3. Add matching artists
    for (final artist in _localArtistIndex) {
      if (artist.name.toLowerCase().contains(normalized)) {
        suggestions.add(artist.name);
      }
    }

    // 4. Add matching albums
    for (final album in _localAlbumIndex) {
      if (album.name.toLowerCase().contains(normalized)) {
        suggestions.add(album.name);
      }
    }

    // Deduplicate and limit to 8
    final uniqueSuggestions = <String>[];
    final seen = <String>{};
    for (final s in suggestions) {
      final key = s.trim().toLowerCase();
      if (key.isNotEmpty && seen.add(key)) {
        uniqueSuggestions.add(s);
      }
    }

    _searchRecommendations = uniqueSuggestions.take(8).toList(growable: false);
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

  List<Album> _sanitizeAlbums(List<Album> albums) {
    final languageFiltered = albums
        .where((album) => _matchesPreferredLanguage(album.language))
        .toList();
    return AlbumFilter.filterAndDeduplicate(languageFiltered);
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
}

class _CachedSearchSnapshot {
  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<UserPlaylist> playlists;
  final List<Song> downloadedSongs;
  final List<dynamic> offlineResults;
  final dynamic topResult;
  final DateTime storedAt;

  const _CachedSearchSnapshot({
    required this.songs,
    required this.albums,
    required this.artists,
    required this.playlists,
    required this.downloadedSongs,
    required this.offlineResults,
    required this.topResult,
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
