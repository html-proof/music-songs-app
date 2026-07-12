import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_manager.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../providers/preferences_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../utils/content_filter.dart';
import '../utils/language_utils.dart';
import '../utils/album_filter.dart';
import '../widgets/album_card.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import '../widgets/offline_artwork.dart';

enum _RecommendationMode { sameArtist, trending }

class AlbumDetailScreen extends StatefulWidget {
  final Album album;

  const AlbumDetailScreen({super.key, required this.album});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  static const int _artistAlbumPageSize = 20;
  static const int _artistAlbumTarget = 20;

  final ScrollController _moreAlbumsScrollController = ScrollController();
  StreamSubscription? _connectivitySubscription;

  List<Song> _songs = [];
  bool _isLoading = true;
  bool _isUnavailable = false;
  String? _error;

  List<Album> _moreAlbums = [];
  int _visibleMoreAlbumsCount = 0;
  bool _isLoadingMore = false;
  bool _artistRecommendationsExhausted = false;
  int _artistAlbumsNextPage = 1;
  String _artistRecommendationId = '';
  String _artistRecommendationName = '';
  _RecommendationMode? _recommendationMode;

  @override
  void initState() {
    super.initState();
    _moreAlbumsScrollController.addListener(_onMoreAlbumsScroll);
    _fetchAlbumDetails();
    _connectivitySubscription = ConnectivityManager.eventStream.listen((event) {
      if (event == ConnectivityEvent.restored) {
        _fetchAlbumDetails();
      }
    });
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _moreAlbumsScrollController
      ..removeListener(_onMoreAlbumsScroll)
      ..dispose();
    super.dispose();
  }

  void _onMoreAlbumsScroll() {
    if (!_moreAlbumsScrollController.hasClients) return;
    final position = _moreAlbumsScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 120) {
      _revealOrLoadNextAlbums();
    }
  }

  void _revealOrLoadNextAlbums() {
    if (_visibleMoreAlbumsCount < _moreAlbums.length) {
      setState(() {
        _visibleMoreAlbumsCount =
            (_visibleMoreAlbumsCount + _artistAlbumPageSize).clamp(
              0,
              _moreAlbums.length,
            );
      });
      return;
    }

    if (_moreAlbums.length >= _artistAlbumTarget ||
        _artistRecommendationsExhausted ||
        _isLoadingMore) {
      return;
    }

    _loadNextArtistRecommendationPage();
  }

  Future<void> _fetchAlbumDetails() async {
    try {
      final data = await ApiService.getAlbums(id: widget.album.id);
      if (!mounted) return;

      final songList = data['data']?['songs'] as List? ?? const [];
      final contextAlbumId = widget.album.id.trim();
      final contextAlbumName = widget.album.name.trim().isEmpty
          ? 'Unknown Album'
          : widget.album.name.trim();
      final rawSongs = songList.whereType<Map>().toList();

      final songs = rawSongs
          .where((json) {
            final title = (json['name'] ?? json['title'] ?? '').toString();
            return ContentFilter.isAllowedSongTitle(title);
          })
          .map((json) {
            final parsed = Song.fromJson(Map<String, dynamic>.from(json));
            return parsed.withPlaybackSource(
              albumId: contextAlbumId.isNotEmpty
                  ? contextAlbumId
                  : (parsed.albumId ?? '').trim(),
              albumName: contextAlbumName,
              albumArtist: widget.album.artist,
              albumImageUrl: widget.album.imageUrl,
            );
          })
          .toList(growable: false);

      if (!await AlbumFilter.isValidAlbum(widget.album, tracks: songs)) {
        if (!mounted) return;
        // Album has no valid/playable songs — show unavailable state.
        setState(() {
          _isUnavailable = true;
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _songs = songs;
        _isLoading = false;
      });

      final artistInfo = _extractPrimaryArtist(data['data']);
      await _loadInitialArtistRecommendations(
        artistInfo.id,
        artistInfo.name ?? widget.album.artist,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadInitialArtistRecommendations(
    String artistId,
    String? artistName,
  ) async {
    if (_isLoadingMore) return;

    setState(() {
      _artistRecommendationId = artistId.trim();
      _artistRecommendationName = _displayArtistName(artistName);
      _artistAlbumsNextPage = 1;
      _artistRecommendationsExhausted = false;
      _recommendationMode = null;
      _moreAlbums = [];
      _visibleMoreAlbumsCount = 0;
      _isLoadingMore = true;
    });

    try {
      final preferredLanguages = _preferredLanguages();
      final excludeIds = <String>{widget.album.id};

      final firstBatch = await _buildRecommendationBatch(
        artistId: _artistRecommendationId,
        artistName: _artistRecommendationName,
        preferredLanguages: preferredLanguages,
        excludeIds: excludeIds,
        desiredCount: _artistAlbumPageSize,
        page: _artistAlbumsNextPage,
      );

      late final _RecommendationMode mode;
      late final List<Album> initialBatch;

      if (firstBatch.isNotEmpty) {
        mode = _RecommendationMode.sameArtist;
        final topUp = firstBatch.toList(growable: true);
        if (topUp.length < _artistAlbumPageSize) {
          final topUpExcludeIds = <String>{
            ...excludeIds,
            ...topUp.map((album) => album.id),
          };
          final remaining = _artistAlbumPageSize - topUp.length;
          final trendingFallback = await _fetchTrendingAlbumFallback(
            preferredLanguages: preferredLanguages,
            excludeIds: topUpExcludeIds,
            limit: remaining,
            blockedArtists: _blockedTrendingArtistNames(),
          );
          final candidates = trendingFallback
              .map((map) => Album.fromJson(map))
              .where((album) => album.id != widget.album.id)
              .where((album) => !topUpExcludeIds.contains(album.id))
              .toList();
          final fallbackAlbums = (await AlbumFilter.filterValid(candidates)).take(remaining);
          topUp.addAll(fallbackAlbums);
        }
        initialBatch = topUp.take(_artistAlbumPageSize).toList(growable: false);
      } else {
        mode = _RecommendationMode.trending;
        final trendingFallback = await _fetchTrendingAlbumFallback(
          preferredLanguages: preferredLanguages,
          excludeIds: excludeIds,
          limit: _artistAlbumPageSize,
          blockedArtists: _blockedTrendingArtistNames(),
        );
        final candidates = trendingFallback
            .map((map) => Album.fromJson(map))
            .where((album) => album.id != widget.album.id)
            .toList();
        initialBatch = (await AlbumFilter.filterValid(candidates))
            .take(_artistAlbumPageSize)
            .toList(growable: false);
      }

      if (!mounted) return;
      setState(() {
        _recommendationMode = mode;
        _moreAlbums = initialBatch;
        _visibleMoreAlbumsCount = _moreAlbums.length.clamp(
          0,
          _artistAlbumPageSize,
        );
        if (mode == _RecommendationMode.sameArtist && _moreAlbums.isNotEmpty) {
          _artistAlbumsNextPage += 1;
        }
        _artistRecommendationsExhausted =
            _moreAlbums.isEmpty || _moreAlbums.length < _artistAlbumPageSize;
        _isLoadingMore = false;
      });
    } catch (e) {
      debugPrint('Error loading artist recommendations: $e');
      if (!mounted) return;
      setState(() {
        _artistRecommendationsExhausted = true;
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _loadNextArtistRecommendationPage() async {
    if (_isLoadingMore ||
        _artistRecommendationsExhausted ||
        _moreAlbums.length >= _artistAlbumTarget) {
      return;
    }

    setState(() => _isLoadingMore = true);
    try {
      final preferredLanguages = _preferredLanguages();
      final excludeIds = _moreAlbums.map((album) => album.id).toSet()
        ..add(widget.album.id);
      final remaining = _artistAlbumTarget - _moreAlbums.length;
      final batchSize = remaining.clamp(0, _artistAlbumPageSize).toInt();
      final mode = _recommendationMode ?? _RecommendationMode.sameArtist;

      final List<Album> nextBatch;
      if (mode == _RecommendationMode.trending) {
        final trendingMaps = await _fetchTrendingAlbumFallback(
          preferredLanguages: preferredLanguages,
          excludeIds: excludeIds,
          limit: batchSize,
          blockedArtists: _blockedTrendingArtistNames(),
        );
        final candidates = trendingMaps
            .map((map) => Album.fromJson(map))
            .where((album) => album.id != widget.album.id)
            .toList();
        nextBatch = (await AlbumFilter.filterValid(candidates))
            .take(batchSize)
            .toList(growable: false);
      } else {
        nextBatch = await _buildRecommendationBatch(
          artistId: _artistRecommendationId,
          artistName: _artistRecommendationName,
          preferredLanguages: preferredLanguages,
          excludeIds: excludeIds,
          desiredCount: batchSize,
          page: _artistAlbumsNextPage,
        );
      }

      if (!mounted) return;
      setState(() {
        if (nextBatch.isNotEmpty) {
          _moreAlbums = [
            ..._moreAlbums,
            ...nextBatch,
          ].take(_artistAlbumTarget).toList(growable: false);
          if (mode == _RecommendationMode.sameArtist) {
            _artistAlbumsNextPage += 1;
          }
        }

        final nextVisible = _visibleMoreAlbumsCount + _artistAlbumPageSize;
        _visibleMoreAlbumsCount = nextVisible.clamp(0, _moreAlbums.length);

        if (nextBatch.isEmpty ||
            nextBatch.length < batchSize ||
            _moreAlbums.length >= _artistAlbumTarget) {
          _artistRecommendationsExhausted = true;
        }
        _isLoadingMore = false;
      });
    } catch (e) {
      debugPrint('Error loading additional recommendations: $e');
      if (!mounted) return;
      setState(() {
        _artistRecommendationsExhausted = true;
        _isLoadingMore = false;
      });
    }
  }

  Future<List<Album>> _buildRecommendationBatch({
    required String artistId,
    required String artistName,
    required Set<String> preferredLanguages,
    required Set<String> excludeIds,
    required int desiredCount,
    required int page,
  }) async {
    final output = <Map<String, dynamic>>[];

    final sameArtistRaw = await ApiService.getArtistAlbums(
      artistId,
      artistName: artistName,
      limit: _artistAlbumPageSize,
      page: page,
    );
    final rankedSameArtist = _rankAndFilterAlbumMaps(
      raw: sameArtistRaw,
      preferredLanguages: preferredLanguages,
      excludeIds: excludeIds,
      filterSingles: _songs.length > 1,
    );
    _appendMapsWithDedup(
      target: output,
      source: rankedSameArtist,
      excludeIds: excludeIds,
      limit: desiredCount,
    );

    final candidates = output
        .map((map) => Album.fromJson(map))
        .where((album) => album.id != widget.album.id)
        .toList();
    return (await AlbumFilter.filterValid(candidates))
        .take(desiredCount)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchTrendingAlbumFallback({
    required Set<String> preferredLanguages,
    required Set<String> excludeIds,
    required int limit,
    required Set<String> blockedArtists,
  }) async {
    if (limit <= 0) return const [];

    final languages = preferredLanguages.isNotEmpty
        ? preferredLanguages.toList(growable: false)
        : [
            if ((widget.album.language ?? '').trim().isNotEmpty)
              widget.album.language!.trim().toLowerCase(),
          ];

    try {
      final raw = await ApiService.getTrendingAlbums(
        languages: languages,
        limit: limit * 2,
      );
      final ranked = _rankAndFilterAlbumMaps(
        raw: raw,
        preferredLanguages: preferredLanguages,
        excludeIds: excludeIds,
        filterSingles: _songs.length > 1,
      );
      final filtered = ranked
          .where((album) => !_albumHasBlockedArtist(album, blockedArtists))
          .take(limit)
          .toList(growable: false);
      return filtered;
    } catch (_) {
      return const [];
    }
  }

  Set<String> _blockedTrendingArtistNames() {
    final blocked = <String>{
      ..._extractArtistTokens(widget.album.artist),
      ..._extractArtistTokens(_artistRecommendationName),
    };
    blocked.remove('this artist');
    return blocked;
  }

  bool _albumHasBlockedArtist(
    Map<String, dynamic> album,
    Set<String> blockedArtists,
  ) {
    if (blockedArtists.isEmpty) return false;

    final albumArtists = <String>{
      ..._extractArtistTokens(album['artist']),
      ..._extractArtistTokens(album['primaryArtists']),
      ..._extractArtistTokens(album['primary_artists']),
      ..._extractArtistTokens(album['artists']),
      ..._extractArtistTokens(album['subtitle']),
    };
    if (albumArtists.isEmpty) return false;

    for (final artist in albumArtists) {
      if (blockedArtists.contains(artist)) return true;
    }
    return false;
  }

  Set<String> _extractArtistTokens(dynamic value) {
    final output = <String>{};

    void addToken(String raw) {
      final normalized = _normalizeText(raw);
      if (normalized.isEmpty ||
          normalized == 'various artists' ||
          normalized == 'this artist') {
        return;
      }
      output.add(normalized);
    }

    void parse(dynamic input) {
      if (input == null) return;

      if (input is String) {
        final value = input.trim();
        if (value.isEmpty) return;
        final cleaned = value.replaceAll(
          RegExp(r'\b(feat|ft)\.?\b', caseSensitive: false),
          ' ',
        );
        final pieces = cleaned.split(RegExp(r',|&|/|;'));
        for (final piece in pieces) {
          final token = piece.trim();
          if (token.isNotEmpty) addToken(token);
        }
        return;
      }

      if (input is List) {
        for (final item in input) {
          parse(item);
        }
        return;
      }

      if (input is Map) {
        parse(input['name'] ?? input['title']);
        parse(input['primary']);
      }
    }

    parse(value);
    return output;
  }

  Set<String> _preferredLanguages() {
    final prefs = context.read<PreferencesProvider>();
    return LanguageUtils.normalizeLanguageSet(prefs.languages);
  }

  List<Map<String, dynamic>> _rankAndFilterAlbumMaps({
    required List<dynamic> raw,
    required Set<String> preferredLanguages,
    required Set<String> excludeIds,
    required bool filterSingles,
  }) {
    final deduped = <String, Map<String, dynamic>>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = _albumId(map);
      if (id.isEmpty || excludeIds.contains(id)) continue;
      if (id == widget.album.id) continue;
      if (filterSingles && _isLikelySingleAlbum(map)) continue;
      if (!_matchesPreferredLanguage(map, preferredLanguages)) continue;

      final name = (map['name'] ?? map['title'] ?? '').toString().trim();
      if (name.isEmpty) continue;

      final normalizedName = name.toLowerCase()
          .replaceAll(RegExp(r'\(.*?\)'), ' ')
          .replaceAll(RegExp(r'\[.*?\]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      // Secondary check: avoid same named album even if ID is different
      if (normalizedName.isEmpty || deduped.values.any((m) {
        final existingName = (m['name'] ?? m['title'] ?? '').toString().toLowerCase();
        return existingName.contains(normalizedName) || normalizedName.contains(existingName);
      })) {
        continue;
      }

      deduped[id] = map;
    }

    final list = deduped.values.toList(growable: false);
    list.sort((a, b) {
      final aLang = _matchesPreferredLanguage(a, preferredLanguages);
      final bLang = _matchesPreferredLanguage(b, preferredLanguages);
      if (aLang != bLang) return bLang ? 1 : -1;

      final aYear = _releaseYear(a);
      final bYear = _releaseYear(b);
      if (aYear != bYear) return bYear.compareTo(aYear);

      final aPopularity = _albumPopularityScore(a);
      final bPopularity = _albumPopularityScore(b);
      if (aPopularity != bPopularity) {
        return bPopularity.compareTo(aPopularity);
      }

      final aRelease = _releaseTimestamp(a);
      final bRelease = _releaseTimestamp(b);
      if (aRelease != bRelease) return bRelease.compareTo(aRelease);

      final aName = (a['name'] ?? a['title'] ?? '').toString().toLowerCase();
      final bName = (b['name'] ?? b['title'] ?? '').toString().toLowerCase();
      return aName.compareTo(bName);
    });
    return list;
  }

  void _appendMapsWithDedup({
    required List<Map<String, dynamic>> target,
    required List<Map<String, dynamic>> source,
    required Set<String> excludeIds,
    required int limit,
  }) {
    for (final map in source) {
      if (target.length >= limit) break;
      final id = _albumId(map);
      if (id.isEmpty || excludeIds.contains(id)) continue;
      excludeIds.add(id);
      target.add(map);
    }
  }

  _ArtistInfo _extractPrimaryArtist(dynamic albumData) {
    String id = '';
    String? name;
    if (albumData is! Map) {
      return _ArtistInfo(id: id, name: widget.album.artist);
    }

    final data = Map<String, dynamic>.from(albumData);

    void readArtist(dynamic input, {int depth = 0}) {
      if (input == null || depth > 3) return;

      if (input is String) {
        final value = input.trim();
        if (value.isNotEmpty && (name ?? '').trim().isEmpty) {
          name = value;
        }
        return;
      }

      if (input is List) {
        for (final entry in input) {
          readArtist(entry, depth: depth + 1);
          if (id.isNotEmpty && (name ?? '').trim().isNotEmpty) return;
        }
        return;
      }

      if (input is Map) {
        final map = Map<String, dynamic>.from(input);
        final candidateId = (map['id'] ?? map['artistId'] ?? '')
            .toString()
            .trim();
        final candidateName =
            (map['name'] ??
                    map['title'] ??
                    map['artist'] ??
                    map['primaryArtists'] ??
                    '')
                .toString()
                .trim();

        if (candidateId.isNotEmpty && id.isEmpty) id = candidateId;
        if (candidateName.isNotEmpty && (name ?? '').trim().isEmpty) {
          name = candidateName;
        }

        readArtist(map['primary'], depth: depth + 1);
        readArtist(map['all'], depth: depth + 1);
      }
    }

    readArtist(data['primaryArtists']);
    readArtist(data['primary_artists']);
    readArtist(data['artists']);
    readArtist(data['artistMap']);
    readArtist(data['artist']);

    return _ArtistInfo(
      id: id,
      name: (name ?? '').trim().isEmpty ? widget.album.artist : name,
    );
  }

  String _displayArtistName(String? candidate) {
    final value = (candidate ?? '').trim();
    if (value.isNotEmpty) return value;
    final fallback = (widget.album.artist ?? '').trim();
    return fallback.isNotEmpty ? fallback : 'this artist';
  }

  bool _matchesPreferredLanguage(
    Map<String, dynamic> album,
    Set<String> preferredLanguages,
  ) {
    return LanguageUtils.matchesPreferredLanguages(
      album['language'],
      preferredLanguages,
    );
  }

  int _releaseYear(Map<String, dynamic> album) {
    final year = _toInt(album['year']);
    if (year != null) return year;
    final release = _releaseTimestamp(album);
    if (release <= 0) return 0;
    return release ~/ 10000;
  }

  int _releaseTimestamp(Map<String, dynamic> album) {
    final direct =
        _toInt(album['releaseDate']) ??
        _toInt(album['release_date']) ??
        _toInt(album['releaseTimestamp']) ??
        _toInt(album['release_timestamp']);
    if (direct != null) return direct;

    final dateText = (album['releaseDate'] ?? album['release_date'] ?? '')
        .toString()
        .trim();
    if (dateText.isNotEmpty) {
      final parsed = DateTime.tryParse(dateText);
      if (parsed != null) {
        return parsed.year * 10000 + parsed.month * 100 + parsed.day;
      }
    }

    final year = _toInt(album['year']);
    if (year != null) return year * 10000;
    return 0;
  }

  int _albumPopularityScore(Map<String, dynamic> album) {
    return _toInt(album['playCount']) ??
        _toInt(album['play_count']) ??
        _toInt(album['followerCount']) ??
        _toInt(album['follower_count']) ??
        _toInt(album['listeners']) ??
        _toInt(album['popularity']) ??
        _toInt(album['score']) ??
        0;
  }

  bool _isLikelySingleAlbum(Map<String, dynamic> album) {
    // Check if any song in the album (if present) is a sample/trailer
    final songsInfo = album['songs'];
    if (songsInfo is List && songsInfo.isNotEmpty) {
      // If no valid songs remain after filtering, hide the album completely
      if (!ContentFilter.hasValidSongs(songsInfo)) return true;

      final validSongs = songsInfo.where((s) {
        if (s is! Map) return false;
        final sTitle = (s['name'] ?? s['title'] ?? '').toString();
        return ContentFilter.isAllowedSongTitle(sTitle);
      }).toList();

      // If after filtering we have 1 or 0 songs, it's a "single" (or effectively empty/fake)
      if (validSongs.length <= 1) return true;
    }

    final songCount =
        _toInt(album['songCount']) ??
        _toInt(album['song_count']) ??
        _toInt(album['songsCount']) ??
        _toInt(album['totalSongs']) ??
        0;
    if (songCount > 0 && songCount <= 1) return true;

    final name = (album['name'] ?? album['title'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return name.contains('single');
  }

  String _albumId(Map<String, dynamic> album) {
    return (album['id'] ?? '').toString().trim();
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  String _formatTotalDuration(List<Song> songs) {
    final totalSeconds = songs.fold<int>(
      0,
      (sum, song) => sum + ((song.duration ?? 0) > 0 ? song.duration! : 0),
    );
    if (totalSeconds <= 0) return 'Duration unavailable';

    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    return '${seconds}s';
  }

  String _normalizeText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _preferredLanguageSummary() {
    final preferred = _preferredLanguages().toList(growable: false);
    if (preferred.isEmpty) return 'your selected';
    final labels = preferred
        .map(LanguageUtils.displayLabel)
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    if (labels.isEmpty) return 'your selected';
    if (labels.length <= 3) return labels.join(', ');
    return '${labels.take(3).join(', ')} +${labels.length - 3}';
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final currentSongId = context.select<PlayerProvider, String?>((p) => p.currentSong?.id);
    final downloadProvider = context.watch<DownloadProvider>();
    final hasMoreSection = _moreAlbums.isNotEmpty || _isLoadingMore;
    final preferredLanguages = _preferredLanguages();
    final visibleCount = _visibleMoreAlbumsCount.clamp(0, _moreAlbums.length);

    if (_error != null || _isUnavailable) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: AppTheme.backgroundGradient,
          ),
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppTheme.textSecondary,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isUnavailable
                                ? Icons.album_outlined
                                : Icons.error_outline_rounded,
                            color: AppTheme.textMuted,
                            size: 64,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _isUnavailable
                                ? "This album isn't available."
                                : _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_isUnavailable) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'No playable songs were found in this album.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 14,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text(
                              'Go Back',
                              style: TextStyle(color: AppTheme.accentPurple),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 300,
                      pinned: true,
                      backgroundColor: Colors.transparent,
                      flexibleSpace: FlexibleSpaceBar(
                        title: Text(
                          widget.album.name,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(blurRadius: 10, color: Colors.black),
                            ],
                          ),
                        ),
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            OfflineArtwork(
                              albumId: widget.album.id,
                              imageUrl: widget.album.imageUrl ?? '',
                              fit: BoxFit.cover,
                              errorWidget: const Icon(Icons.album, size: 100),
                            ),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    AppTheme.primaryDark,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.album.artist ?? 'Various Artists',
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                                if (widget.album.year != null)
                                  Text(
                                    widget.album.year!,
                                    style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 14,
                                    ),
                                  ),
                              ],
                            ),
                            if (widget.album.type != null &&
                                widget.album.type != 'ALBUM')
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.accentPurple.withValues(
                                      alpha: 0.2,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.album.type!,
                                    style: const TextStyle(
                                      color: AppTheme.accentPurple,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            if (!_isLoading && _songs.isNotEmpty)
                              Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          onPressed: () {
                                            if (_songs.isNotEmpty) {
                                              player.play(
                                                _songs[0],
                                                playlist: _songs,
                                                index: 0,
                                              );
                                            }
                                          },
                                          icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                                          label: const Text('Play', style: TextStyle(fontWeight: FontWeight.bold)),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: AppTheme.accentPurple,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () async {
                                            if (_songs.isNotEmpty) {
                                              if (!player.shuffleModeEnabled) {
                                                await player.toggleShuffleMode();
                                              }
                                              final randomIndex = Random().nextInt(_songs.length);
                                              player.play(
                                                _songs[randomIndex],
                                                playlist: _songs,
                                                index: randomIndex,
                                              );
                                            }
                                          },
                                          icon: const Icon(Icons.shuffle_rounded, color: AppTheme.accentPurple, size: 18),
                                          label: const Text('Shuffle', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                          style: OutlinedButton.styleFrom(
                                            side: const BorderSide(color: AppTheme.accentPurple, width: 1.5),
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      _buildDownloadAlbumButton(context, downloadProvider),
                                      const Spacer(),
                                      Text(
                                        '${_songs.length} Songs • ${_formatTotalDuration(_songs)}',
                                        style: const TextStyle(
                                          color: AppTheme.textMuted,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (_isLoading)
                      const SliverFillRemaining(
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.accentPurple,
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final song = _songs[index];
                          return SongTile(
                            song: song,
                            isPlaying: currentSongId == song.id,
                            onTap: () => player.play(
                              song,
                              playlist: _songs,
                              index: index,
                            ),
                          );
                        }, childCount: _songs.length),
                      ),
                    if (hasMoreSection)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 24,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Recommended',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                height: 200,
                                child: visibleCount == 0
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                          color: AppTheme.accentPurple,
                                        ),
                                      )
                                    : ListView.builder(
                                        controller: _moreAlbumsScrollController,
                                        scrollDirection: Axis.horizontal,
                                        itemCount: visibleCount,
                                        itemBuilder: (context, index) {
                                          final album = _moreAlbums[index];
                                          return AlbumCard(
                                            album: album,
                                            onTap: () {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) =>
                                                      AlbumDetailScreen(
                                                        album: album,
                                                      ),
                                                ),
                                              );
                                            },
                                          );
                                        },
                                      ),
                              ),
                              if (_isLoadingMore && visibleCount > 0)
                                const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Center(
                                    child: SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: AppTheme.accentPurple,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (!hasMoreSection &&
                        !_isLoading &&
                        preferredLanguages.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                          child: Text(
                            'No ${_preferredLanguageSummary()} recommendations available right now.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 100)),
                  ],
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadAlbumButton(BuildContext context, DownloadProvider downloadProvider) {
    if (_songs.isEmpty) return const SizedBox.shrink();

    final isAlbumDownloaded = _songs.isNotEmpty && _songs.every((s) => downloadProvider.isDownloaded(s.id));
    final albumProgress = downloadProvider.playlistProgress;
    final isAlbumDownloading = albumProgress != null &&
        albumProgress.playlistId == widget.album.id &&
        !albumProgress.isCompleted &&
        !albumProgress.isCancelled;

    if (isAlbumDownloaded) {
      return TextButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check_circle_rounded, color: AppTheme.accentPurple, size: 20),
        label: const Text(
          'Downloaded',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      );
    }

    if (isAlbumDownloading) {
      final progressPct = (albumProgress.progress * 100).toInt();
      return TextButton.icon(
        onPressed: () {
          downloadProvider.cancelPlaylistDownload();
        },
        icon: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.accentPurple,
          ),
        ),
        label: Text(
          'Downloading... $progressPct%',
          style: const TextStyle(
            color: AppTheme.accentPurple,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      );
    }

    final failedCount = _songs.where((s) => !downloadProvider.isDownloaded(s.id)).length;
    final labelText = failedCount < _songs.length && failedCount > 0
        ? 'Download Missing ($failedCount)'
        : 'Download Album';

    return TextButton.icon(
      onPressed: () {
        downloadProvider.downloadPlaylist(
          widget.album.id,
          widget.album.name,
          _songs,
        );
      },
      icon: const Icon(Icons.arrow_circle_down_rounded, color: AppTheme.textSecondary, size: 20),
      label: Text(
        labelText,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontWeight: FontWeight.bold,
          fontSize: 13.5,
        ),
      ),
    );
  }
}

class _ArtistInfo {
  final String id;
  final String? name;

  const _ArtistInfo({required this.id, required this.name});
}
