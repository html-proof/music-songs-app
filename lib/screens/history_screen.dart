import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/offline_artwork.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/search_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../utils/content_filter.dart';
import '../widgets/mini_player.dart';
import 'preferences_screen.dart';
import 'search_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _playHistory = [];
  List<Map<String, dynamic>> _searchHistory = [];
  final Map<String, Song> _resolvedBySongId = {};
  final Set<String> _resolvingSongIds = <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    var playRows = <Map<String, dynamic>>[];
    var searchRows = <Map<String, dynamic>>[];

    try {
      final results = await Future.wait([
        ApiService.getHistory(type: 'play', limit: 30),
        ApiService.getHistory(type: 'search', limit: 30),
      ]);

      playRows = results[0]
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) {
            final name = (row['songName'] ?? row['song_name'] ?? row['name'] ?? row['title'] ?? '').toString();
            return ContentFilter.isAllowedSongTitle(name);
          })
          .toList(growable: false);
      searchRows = results[1]
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (e) {
      debugPrint('History load error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _playHistory = playRows;
          _searchHistory = searchRows;
          _loading = false;
        });
        _hydratePlayHistorySongs();
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              // App Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'History',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const MiniPlayer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _quickActionButton(
                        icon: Icons.history_rounded,
                        label: 'Recently Played',
                        onTap: () => _tabController.animateTo(0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _quickActionButton(
                        icon: Icons.person_outline_rounded,
                        label: 'Profile',
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PreferencesScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _quickActionButton(
                        icon: Icons.search_rounded,
                        label: 'Search',
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SearchScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // Tabs
              TabBar(
                controller: _tabController,
                indicatorColor: AppTheme.accentPurple,
                labelColor: AppTheme.accentPurple,
                unselectedLabelColor: AppTheme.textMuted,
                tabs: const [
                  Tab(
                    text: 'Played',
                    icon: Icon(Icons.play_circle_outline, size: 20),
                  ),
                  Tab(text: 'Searched', icon: Icon(Icons.search, size: 20)),
                ],
              ),
              // Content
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.accentPurple,
                        ),
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: [_buildPlayHistory(), _buildSearchHistory()],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 38,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16, color: AppTheme.textSecondary),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: AppTheme.textMuted.withValues(alpha: 0.35)),
          backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
    );
  }

  Widget _buildPlayHistory() {
    if (_playHistory.isEmpty) {
      return const Center(
        child: Text(
          'No play history yet',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return ListView.builder(
      itemCount: _playHistory.length,
      itemBuilder: (context, index) {
        final item = _playHistory[index];
        final song = _buildSongFromHistory(item);
        final artistName = (song.artist ?? '').trim();
        return ListTile(
          leading: _songArtwork(song),
          title: Text(
            song.name,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: artistName.isEmpty
              ? null
              : GestureDetector(
                  onTap: () => _openArtistSongs(artistName),
                  child: Text(
                    artistName,
                    style: const TextStyle(
                      color: AppTheme.accentPurple,
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: AppTheme.accentPurple,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _timeAgo(item['timestamp']),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 2),
              const Icon(
                Icons.play_arrow_rounded,
                size: 18,
                color: AppTheme.textMuted,
              ),
            ],
          ),
          onTap: () => _playHistorySong(item),
        );
      },
    );
  }

  Widget _buildSearchHistory() {
    if (_searchHistory.isEmpty) {
      return const Center(
        child: Text(
          'No search history yet',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchHistory.length,
      itemBuilder: (context, index) {
        final item = _searchHistory[index];
        final query = (item['query'] ?? '').toString().trim();
        return ListTile(
          leading: const Icon(Icons.search, color: AppTheme.textMuted),
          title: Text(
            query,
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          trailing: Text(
            _timeAgo(item['timestamp']),
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          onTap: query.isEmpty ? null : () => _openSearchResults(query),
        );
      },
    );
  }

  Future<void> _hydratePlayHistorySongs() async {
    final toFetch = <String>[];

    for (final item in _playHistory) {
      final id = _songIdFromHistory(item);
      if (id.isEmpty ||
          _resolvedBySongId.containsKey(id) ||
          _resolvingSongIds.contains(id)) {
        continue;
      }

      final seedSong = _buildSongFromHistory(item);
      final missingImage = (seedSong.imageUrl ?? '').trim().isEmpty;
      final missingStream = (seedSong.streamUrl ?? '').trim().isEmpty;
      if (!missingImage && !missingStream) continue;

      toFetch.add(id);
      if (toFetch.length >= 10) break;
    }

    if (toFetch.isEmpty) return;
    _resolvingSongIds.addAll(toFetch);

    final fetched = <String, Song>{};
    for (final id in toFetch) {
      final song = await _fetchSongById(id);
      if (song != null) {
        fetched[id] = song;
      }
      _resolvingSongIds.remove(id);
    }

    if (fetched.isEmpty || !mounted) return;
    setState(() => _resolvedBySongId.addAll(fetched));
  }

  Future<void> _playHistorySong(Map<String, dynamic> item) async {
    Song? song = _buildSongFromHistory(item);

    if ((song.streamUrl ?? '').trim().isEmpty) {
      song = await _resolveSongForPlayback(item, seed: song);
      if (song == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to play this history item yet.'),
          ),
        );
        return;
      }
      final id = song.id.trim();
      if (id.isNotEmpty && mounted) {
        setState(() => _resolvedBySongId[id] = song!);
      }
    }

    if (!mounted) return;
    await context.read<PlayerProvider>().play(song);
  }

  Future<Song?> _resolveSongForPlayback(
    Map<String, dynamic> item, {
    Song? seed,
  }) async {
    final songId = _songIdFromHistory(item);

    if (songId.isNotEmpty) {
      final cached = _resolvedBySongId[songId];
      if (cached != null && (cached.streamUrl ?? '').trim().isNotEmpty) {
        return cached;
      }

      final fromApi = await _fetchSongById(songId);
      if (fromApi != null && (fromApi.streamUrl ?? '').trim().isNotEmpty) {
        return fromApi;
      }
    }

    final name = _firstNonEmptyString([
      item['songName'],
      item['song_name'],
      item['name'],
      item['title'],
      _payloadMap(item)?['songName'],
      _payloadMap(item)?['song_name'],
      _payloadMap(item)?['name'],
      _payloadMap(item)?['title'],
      seed?.name,
    ]);
    if (name.isEmpty) return seed;

    final artist = _firstNonEmptyString([
      item['artist'],
      item['primaryArtists'],
      _payloadMap(item)?['artist'],
      _payloadMap(item)?['primaryArtists'],
      seed?.artist,
    ]);

    try {
      final query = artist.isEmpty ? name : '$name $artist';
      final rawSongs = await ApiService.searchSongs(query, limit: 8);
      final parsed = <Song>[];
      for (final entry in rawSongs) {
        if (entry is! Map) continue;
        try {
          final song = Song.fromJson(Map<String, dynamic>.from(entry));
          if (song.id.trim().isNotEmpty) parsed.add(song);
        } catch (_) {}
      }

      if (parsed.isNotEmpty) {
        parsed.sort(
          (a, b) =>
              _historySongMatchScore(
                b,
                targetName: name,
                targetArtist: artist,
              ).compareTo(
                _historySongMatchScore(
                  a,
                  targetName: name,
                  targetArtist: artist,
                ),
              ),
        );
        final best = parsed.first;
        if ((best.streamUrl ?? '').trim().isNotEmpty) {
          return best;
        }
      }
    } catch (_) {}

    return seed;
  }

  int _historySongMatchScore(
    Song song, {
    required String targetName,
    required String targetArtist,
  }) {
    final songName = _normalizeText(song.name);
    final expectedName = _normalizeText(targetName);
    final songArtist = _normalizeText(song.artist ?? '');
    final expectedArtist = _normalizeText(targetArtist);

    var score = 0;
    if (songName == expectedName) score += 5;
    if (songName.contains(expectedName) || expectedName.contains(songName)) {
      score += 2;
    }
    if (expectedArtist.isNotEmpty &&
        (songArtist.contains(expectedArtist) ||
            expectedArtist.contains(songArtist))) {
      score += 3;
    }
    if ((song.streamUrl ?? '').trim().isNotEmpty) score += 2;
    if ((song.imageUrl ?? '').trim().isNotEmpty) score += 1;
    return score;
  }

  Future<Song?> _fetchSongById(String songId) async {
    if (songId.trim().isEmpty) return null;

    try {
      final payload = await ApiService.getSong(songId);
      final map = _extractFirstSongMap(payload);
      if (map == null) return null;
      final song = Song.fromJson(map);
      if (song.id.trim().isEmpty || song.name.trim().isEmpty) return null;
      return song;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openArtistSongs(String artistName) async {
    final query = artistName.split(',').first.trim();
    if (query.isEmpty) return;

    await _openSearchResults(query);
  }

  Future<void> _openSearchResults(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;

    await context.read<SearchProvider>().search(normalized);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  Song _buildSongFromHistory(Map<String, dynamic> item) {
    final payload = _payloadMap(item);
    final id = _songIdFromHistory(item);
    final fallback = id.isEmpty ? null : _resolvedBySongId[id];

    final name = _firstNonEmptyString([
      item['songName'],
      item['song_name'],
      item['name'],
      item['title'],
      payload?['songName'],
      payload?['song_name'],
      payload?['name'],
      payload?['title'],
      fallback?.name,
    ]);
    final artist = _firstNonEmptyString([
      item['artist'],
      item['primaryArtists'],
      payload?['artist'],
      payload?['primaryArtists'],
      fallback?.artist,
    ]);
    final album = _firstNonEmptyString([
      item['album'],
      item['albumName'],
      payload?['album'],
      payload?['albumName'],
      fallback?.album,
    ]);
    final imageUrl = _firstNonEmptyString([
      item['imageUrl'],
      item['image_url'],
      item['thumbnail'],
      item['thumbnail_url'],
      item['artwork'],
      _extractImageCandidate(item['image']),
      payload?['imageUrl'],
      payload?['image_url'],
      payload?['thumbnail'],
      payload?['thumbnail_url'],
      payload?['artwork'],
      _extractImageCandidate(payload?['image']),
      fallback?.imageUrl,
    ]);
    final streamUrl = _firstNonEmptyString([
      item['streamUrl'],
      item['stream_url'],
      item['media_url'],
      payload?['streamUrl'],
      payload?['stream_url'],
      payload?['media_url'],
      fallback?.streamUrl,
    ]);

    return Song(
      id: id.isEmpty ? 'history_${_normalizeText('$name|$artist')}' : id,
      name: name.isEmpty ? 'Unknown' : name,
      artist: artist.isEmpty ? null : artist,
      album: album.isEmpty ? null : album,
      imageUrl: imageUrl.isEmpty ? null : imageUrl,
      streamUrl: streamUrl.isEmpty ? null : streamUrl,
      duration: fallback?.duration,
      language: fallback?.language,
    );
  }

  Widget _songArtwork(Song song) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 45,
        height: 45,
        child: OfflineArtwork(
          songId: song.id,
          imageUrl: song.imageUrl,
          fit: BoxFit.cover,
          placeholder: Container(
            color: AppTheme.surfaceDark,
            child: const Icon(Icons.music_note, color: AppTheme.textMuted),
          ),
          errorWidget: Container(
            color: AppTheme.surfaceDark,
            child: const Icon(Icons.music_note, color: AppTheme.textMuted),
          ),
        ),
      ),
    );
  }

  String _songIdFromHistory(Map<String, dynamic> item) {
    final payload = _payloadMap(item);
    return _firstNonEmptyString([
      item['songId'],
      item['song_id'],
      item['id'],
      payload?['songId'],
      payload?['song_id'],
      payload?['id'],
    ]);
  }

  Map<String, dynamic>? _payloadMap(Map<String, dynamic> item) {
    final rawPayload = item['payload'];
    if (rawPayload is Map) {
      return Map<String, dynamic>.from(rawPayload);
    }
    if (rawPayload is String && rawPayload.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPayload);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return null;
  }

  String _firstNonEmptyString(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _extractImageCandidate(dynamic raw) {
    if (raw is String) return raw.trim();
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return _firstNonEmptyString([map['url'], map['link'], map['image']]);
    }
    if (raw is List && raw.isNotEmpty) {
      for (final item in raw.reversed) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final image = _firstNonEmptyString([
          map['url'],
          map['link'],
          map['image'],
        ]);
        if (image.isNotEmpty) return image;
      }
    }
    return '';
  }

  Map<String, dynamic>? _extractFirstSongMap(dynamic payload) {
    if (payload is! Map) return null;
    final data = payload['data'];

    List<dynamic> candidateList(dynamic value) {
      if (value is List) return value;
      return const <dynamic>[];
    }

    final buckets = <List<dynamic>>[
      if (data is Map) candidateList(data['songs']),
      if (data is Map) candidateList(data['results']),
      if (data is List) data,
      candidateList(payload['songs']),
      candidateList(payload['results']),
    ];

    for (final bucket in buckets) {
      if (bucket.isEmpty) continue;
      final first = bucket.first;
      if (first is Map) return Map<String, dynamic>.from(first);
    }
    return null;
  }

  String _normalizeText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _timeAgo(dynamic timestamp) {
    if (timestamp == null) return '';
    var ts = timestamp is int
        ? timestamp
        : int.tryParse(timestamp.toString()) ?? 0;
    if (ts <= 0) return '';
    if (ts < 1000000000000) {
      ts *= 1000; // seconds -> milliseconds
    }

    final diff = DateTime.now().millisecondsSinceEpoch - ts;
    if (diff < 0) return '';

    final minutes = diff ~/ 60000;
    if (minutes < 60) return '${minutes}m ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h ago';
    return '${hours ~/ 24}d ago';
  }
}
