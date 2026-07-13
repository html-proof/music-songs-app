import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../providers/preferences_provider.dart';
import '../services/api_service.dart';
import '../services/offline_service.dart';
import '../services/player_service.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../utils/content_filter.dart';
import '../utils/language_utils.dart';
import '../utils/album_filter.dart';
import '../widgets/album_card.dart';
import '../widgets/artist_card.dart';
import '../widgets/library_side_drawer.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import '../widgets/offline_artwork.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'downloads_screen.dart';
import 'login_screen.dart';
import 'preferences_screen.dart';
import 'search_screen.dart';
import 'offline_library_screen.dart';
import 'playlist_import_screen.dart';

class HomeScreen extends StatefulWidget {
  final bool showReconnectMessageOnStart;

  const HomeScreen({super.key, this.showReconnectMessageOnStart = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Song> _recommendations = [];
  List<Album> _recommendedAlbums = [];
  List<Song> _trendingSongs = [];
  List<Album> _playlists = [];
  List<Artist> _suggestedArtists = [];
  List<Song> _recentlyPlayed = [];
  List<Song> _downloadedSongs = [];
  bool _loading = true;

  final ScrollController _scrollController = ScrollController();
  int _recommendationLimit = 20;
  PreferencesProvider? _preferencesProvider;
  int _lastSeenPreferencesVersion = -1;
  bool? _lastOfflineState;
  bool _handledReconnectMessageOnStart = false;
  String? _resumeHandledUid;
  bool _resumeCheckInProgress = false;
  bool _isLibraryDrawerOpen = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Rotate seed but do not reload data automatically to prevent unnecessary network requests.
      ApiService.rotateSessionSeed();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final preferences = context.read<PreferencesProvider>();
    if (_preferencesProvider != preferences) {
      _preferencesProvider?.removeListener(_onPreferencesChanged);
      _preferencesProvider = preferences;
      _preferencesProvider?.addListener(_onPreferencesChanged);
    }

    _onPreferencesChanged();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_loading && _recommendations.length < 60) {
        _loadMoreRecommendations();
      }
    }
  }

  void _onPreferencesChanged() {
    final preferences = _preferencesProvider;
    if (preferences == null || preferences.loading) return;
    if (_lastSeenPreferencesVersion == preferences.version) return;

    _lastSeenPreferencesVersion = preferences.version;
    _recommendationLimit = 20;
    _loadData();
  }

  void _onOfflineStateChanged({
    required bool wasOffline,
    required bool isOffline,
  }) {
    if (!mounted) return;

    if (!isOffline && wasOffline) {
      // Reconnected! Playback coordinator will handle resuming media stream. Do not reload content automatically.
    }
  }

  void _maybeHandlePlaybackResume(AuthProvider auth) {
    final uid = auth.user?.uid;
    if (uid == null || uid.isEmpty) {
      _resumeHandledUid = null;
      _resumeCheckInProgress = false;
      return;
    }
    if (_resumeHandledUid == uid || _resumeCheckInProgress) return;

    _resumeHandledUid = uid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handlePendingPlaybackResumeForUser(uid);
    });
  }

  Future<void> _handlePendingPlaybackResumeForUser(String uid) async {
    if (_resumeCheckInProgress) return;
    _resumeCheckInProgress = true;
    try {
      // Since we no longer auto-play on restore (the song loads paused at
      // the saved position), we can always restore silently — no need to
      // prompt the user with a dialog.
      final result = await PlayerService.resumePendingPlaybackAfterLogin();
      if (!mounted || _resumeHandledUid != uid) return;

      if (result == PlaybackResumeResult.resumed) {
        // No snack bar needed — the mini player simply appears at the
        // saved position. The user can press play when they're ready.
      } else if (result == PlaybackResumeResult.offlineSongUnavailable) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Saved session needs internet or a downloaded copy to resume.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      _resumeCheckInProgress = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preferencesProvider?.removeListener(_onPreferencesChanged);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData({bool forceRefresh = false}) async {
    final player = context.read<PlayerProvider>();
    final isOffline = player.isOffline;

    var loaded = await _loadDataInternal(showErrorSnackBar: false, forceRefresh: forceRefresh);
    if (loaded || isOffline) return;

    for (var attempt = 0; attempt < 2; attempt++) {
      await Future.delayed(Duration(seconds: 2 + attempt));
      loaded = await _loadDataInternal(showErrorSnackBar: attempt == 1, forceRefresh: forceRefresh);
      if (loaded) break;
    }
  }

  Future<void> _handlePullToRefresh() => _loadData(forceRefresh: true);

  Future<bool> _loadDataInternal({required bool showErrorSnackBar, bool forceRefresh = false}) async {
    final preferences = context.read<PreferencesProvider>();
    final player = context.read<PlayerProvider>();
    if (preferences.loading) return false;
    var loaded = false;

    if (!preferences.hasCompletedOnboarding) {
      if (!mounted) return false;
      setState(() {
        _recommendations = [];
        _recommendedAlbums = [];
        _trendingSongs = [];
        _playlists = [];
        _suggestedArtists = [];
        _recentlyPlayed = [];
        _loading = false;
      });
      return true;
    }

    final languages = preferences.languages;
    final favoriteArtists = preferences.favoriteArtists;
    final preferredLanguageSet = _preferredLanguageSet(languages);

    // ── STALE-WHILE-REVALIDATE (3ms Path) ──
    // Try to restore from memory cache synchronously first.
    final cachedData = ApiService.getCachedHomeData(
      languages: languages,
      favoriteArtists: favoriteArtists,
    );

    if (cachedData != null && mounted) {
      final recs = _filterSongsByPreferredLanguages(
        _parseSongsSafely(_asMapList(cachedData['recommendations'])),
        preferredLanguageSet,
      );
      final albums = _filterAlbumsByPreferredLanguages(
        _parseAlbumsSafelySync(_asMapList(cachedData['recommendedAlbums'])),
        preferredLanguageSet,
      );
      final trending = _filterSongsByPreferredLanguages(
        _parseSongsSafely(_asMapList(cachedData['trendingSongs'])),
        preferredLanguageSet,
      );
      final playlists = _filterAlbumsByPreferredLanguages(
        _parseAlbumsSafelySync(_asMapList(cachedData['playlists'])),
        preferredLanguageSet,
      );
      final artists = _parseArtistsSafely(
        _asMapList(cachedData['suggestedArtists']),
      );
      final history = _filterSongsByPreferredLanguages(
        _buildRecentlyPlayedSongs(
          historyRows: _asMapList(cachedData['recentlyPlayed']),
          fallbackSongs: [...recs, ...trending],
        ),
        preferredLanguageSet,
      );

      setState(() {
        _recommendations = recs;
        _recommendedAlbums = albums;
        _trendingSongs = trending;
        _playlists = playlists;
        _suggestedArtists = artists;
        _recentlyPlayed = history;
        _loading = false; // Instant pivot to content
      });

      if (!forceRefresh) {
        // Cached content is available and user didn't request force-refresh: STOP HERE!
        // This prevents executing any background network calls, saving mobile data.
        return true;
      }
    } else if (mounted) {
      setState(() => _loading = true);
    }

    try {
      if (player.isOffline) {
        final offlineSongs = await OfflineService.getOfflineSongs();
        final downloadedSongs = await DownloadService.getDownloadedSongs();
        
        final combinedSongsMap = <String, Song>{};
        for (final s in offlineSongs) {
          combinedSongsMap[s.id] = s;
        }
        for (final s in downloadedSongs) {
          combinedSongsMap[s.id] = s;
        }
        final combinedSongs = combinedSongsMap.values.toList();
        
        if (!mounted) return false;
        setState(() {
          _recommendations = _filterSongsByPreferredLanguages(
            combinedSongs.take(50).toList(growable: false),
            preferredLanguageSet,
          );
          _recommendedAlbums = []; // Focus on songs to avoid album/song duplication
          _trendingSongs = [];
          _playlists = [];
          _suggestedArtists = [];
          _recentlyPlayed = [];
          _downloadedSongs = downloadedSongs;
          _loading = false;
        });
        return true;
      }

      final results = await Future.wait([
        ApiService.getPersonalizedRecommendations(
          languages: languages,
          favoriteArtists: favoriteArtists,
          limit: _recommendationLimit,
        ),
        ApiService.getRecommendedAlbums(
          languages: languages,
          favoriteArtists: favoriteArtists,
          limit: 8,
        ),
        ApiService.getTrendingSongs(languages: languages, limit: 12),
        ApiService.getPlaylists(languages: languages, limit: 8),
        ApiService.getSuggestedArtists(
          languages: languages,
          favoriteArtists: favoriteArtists,
          limit: 8,
        ),
        ApiService.getHistory(type: 'play', limit: 6),
        DownloadService.getDownloadedSongs(),
      ]);

      if (!mounted) return false;

      final recommendationMaps = results[0]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final recommendedAlbumMaps = results[1]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final trendingMaps = results[2]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final playlistMaps = results[3]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final artistMaps = results[4]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final historyMaps = results[5]
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .toList();
      final downloadedSongs = results[6] as List<Song>;

      final parsedRecommendations = _filterSongsByPreferredLanguages(
        _parseSongsSafely(recommendationMaps),
        preferredLanguageSet,
      );
      final parsedRecommendedAlbums = _filterAlbumsByPreferredLanguages(
        await _parseAlbumsSafely(recommendedAlbumMaps),
        preferredLanguageSet,
      );
      final parsedTrendingSongs = _filterSongsByPreferredLanguages(
        _parseSongsSafely(trendingMaps),
        preferredLanguageSet,
      );
      final parsedPlaylists = _filterAlbumsByPreferredLanguages(
        await _parseAlbumsSafely(playlistMaps),
        preferredLanguageSet,
      );
      final parsedSuggestedArtists = _parseArtistsSafely(artistMaps);
      final parsedRecentlyPlayed = _filterSongsByPreferredLanguages(
        _buildRecentlyPlayedSongs(
          historyRows: historyMaps,
          fallbackSongs: [...parsedRecommendations, ...parsedTrendingSongs],
        ),
        preferredLanguageSet,
      );

      setState(() {
        _recommendations = parsedRecommendations;
        _recommendedAlbums = parsedRecommendedAlbums;
        _trendingSongs = parsedTrendingSongs;
        _playlists = parsedPlaylists;
        _suggestedArtists = parsedSuggestedArtists;
        _recentlyPlayed = parsedRecentlyPlayed;
        _downloadedSongs = downloadedSongs;
        _loading = false;
      });
      loaded = true;
    } catch (e) {
      debugPrint('Home load error: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
    return loaded;
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) {
      return 'Good Morning';
    } else if (hour < 17) {
      return 'Good Afternoon';
    } else {
      return 'Good Evening';
    }
  }

  List<Color> _getGradientColors(Song? song) {
    if (song == null) return [AppTheme.primaryDark, Colors.black];
    final hash = song.id.hashCode.abs();
    final palettes = [
      [const Color(0xFF1E0E3D), Colors.black],
      [const Color(0xFF0F3D2E), Colors.black],
      [const Color(0xFF3D0F21), Colors.black],
      [const Color(0xFF0A2E44), Colors.black],
      [const Color(0xFF2E2C0F), Colors.black],
      [const Color(0xFF281E1E), Colors.black],
    ];
    return palettes[hash % palettes.length];
  }

  Widget _buildSkeletonLoader() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildSkeletonBox(width: 180, height: 28, radius: 6),
                Row(
                  children: [
                    _buildSkeletonBox(width: 32, height: 32, radius: 16),
                    const SizedBox(width: 12),
                    _buildSkeletonBox(width: 32, height: 32, radius: 16),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            _buildSkeletonBox(width: 120, height: 20, radius: 4),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 3.2,
              ),
              itemCount: 6,
              itemBuilder: (_, __) => _buildSkeletonBox(width: double.infinity, height: 50, radius: 8),
            ),
            const SizedBox(height: 24),
            
            _buildSkeletonBox(width: 130, height: 20, radius: 4),
            const SizedBox(height: 12),
            _buildSkeletonBox(width: double.infinity, height: 160, radius: 16),
            const SizedBox(height: 24),
            
            _buildSkeletonBox(width: 150, height: 20, radius: 4),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 3,
                itemBuilder: (_, __) => Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _buildSkeletonBox(width: 130, height: 180, radius: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonBox({
    required double width,
    required double height,
    required double radius,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  Widget _buildContinueListening(PlayerProvider player) {
    return Consumer<PlayerProvider>(
      builder: (context, activePlayer, _) {
        final song = activePlayer.currentSong;
        if (song == null) return const SizedBox.shrink();

        final posMs = activePlayer.position.inMilliseconds;
        final durMs = activePlayer.duration.inMilliseconds;
        final percent = (durMs > 0) ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.cardDark.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: OfflineArtwork(
                  songId: song.id,
                  imageUrl: song.imageUrl,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorWidget: const Icon(Icons.music_note),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CONTINUE LISTENING',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.accentPurple,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist ?? 'Unknown Artist',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: percent,
                        minHeight: 3,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: const AlwaysStoppedAnimation(AppTheme.accentPurple),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  activePlayer.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  size: 38,
                  color: Colors.white,
                ),
                onPressed: () => activePlayer.togglePlayPause(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRecentlyPlayedGrid(PlayerProvider player) {
    final items = <dynamic>[];
    items.addAll(_recentlyPlayed);
    
    if (items.length < 6) {
      items.addAll(_recommendedAlbums.take(6 - items.length));
    }
    if (items.length < 6) {
      items.addAll(_playlists.take(6 - items.length));
    }
    if (items.length < 6) {
      items.addAll(_recommendations.take(6 - items.length));
    }

    final displayItems = items.take(6).toList();
    if (displayItems.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recently Played',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 3.1,
            ),
            itemCount: displayItems.length,
            itemBuilder: (context, index) {
              final item = displayItems[index];
              String name = '';
              String? img;
              VoidCallback? onTap;

              if (item is Song) {
                name = item.name;
                img = item.imageUrl;
                onTap = () => player.play(item, playlist: [item], index: 0);
              } else if (item is Album) {
                name = item.name;
                img = item.imageUrl;
                onTap = () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: item)),
                );
              }

              return InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                        child: OfflineArtwork(
                          songId: item is Song ? item.id : null,
                          albumId: item is Album ? item.id : null,
                          imageUrl: img,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorWidget: const Icon(Icons.music_note, size: 56),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(PlayerProvider player) {
    final artworkUrl = _recommendedAlbums.isNotEmpty
        ? _recommendedAlbums.first.imageUrl
        : (_recommendations.isNotEmpty ? _recommendations.first.imageUrl : null);

    final recommendedAlbumId = _recommendedAlbums.isNotEmpty ? _recommendedAlbums.first.id : null;
    final recommendedSongId = _recommendedAlbums.isEmpty && _recommendations.isNotEmpty ? _recommendations.first.id : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      width: double.infinity,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            AppTheme.accentPurple.withValues(alpha: 0.85),
            const Color(0xFF0F0B1A),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.accentPurple.withValues(alpha: 0.2),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 140,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              child: Opacity(
                opacity: 0.65,
                child: OfflineArtwork(
                  albumId: recommendedAlbumId,
                  songId: recommendedSongId,
                  imageUrl: artworkUrl,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.5),
                    Colors.transparent,
                  ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'MADE FOR YOU',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Daily Mix 1',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your daily update of custom hits',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white54,
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: () {
                    if (_recommendations.isNotEmpty) {
                      player.play(_recommendations.first, playlist: _recommendations, index: 0);
                    }
                  },
                  icon: const Icon(Icons.play_arrow_rounded, color: Colors.black),
                  label: const Text('Play', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final actions = [
      {
        'title': 'Import Playlist',
        'icon': Icons.playlist_add_rounded,
        'color': AppTheme.accentPurple,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlaylistImportScreen()),
            ),
      },
      {
        'title': 'Offline Library',
        'icon': Icons.offline_pin_rounded,
        'color': Colors.greenAccent,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OfflineLibraryScreen()),
            ),
      },
      {
        'title': 'Downloads',
        'icon': Icons.download_for_offline_rounded,
        'color': Colors.orangeAccent,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
      },
      {
        'title': 'Preferences',
        'icon': Icons.tune_rounded,
        'color': Colors.blueAccent,
        'onTap': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PreferencesScreen()),
            ),
      },
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick Actions',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: actions.length,
              itemBuilder: (context, index) {
                final action = actions[index];
                final color = action['color'] as Color;
                return Container(
                  margin: const EdgeInsets.only(right: 12),
                  child: InkWell(
                    onTap: action['onTap'] as VoidCallback,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.03),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            action['icon'] as IconData,
                            color: color,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            action['title'] as String,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalizedMixes(PlayerProvider player) {
    if (_recommendations.isEmpty) return const SizedBox.shrink();

    final mixes = [
      {'title': 'Daily Mix', 'desc': 'Fresh tailored tracks', 'colors': [const Color(0xFF673AB7), const Color(0xFF512DA8)]},
      {'title': 'Chill Mix', 'desc': 'Unwind and relax', 'colors': [const Color(0xFF00bcd4), const Color(0xFF0097a7)]},
      {'title': 'Workout Mix', 'desc': 'High energy beats', 'colors': [const Color(0xFFff5722), const Color(0xFFe64a19)]},
      {'title': 'English Mix', 'desc': 'Top Western sounds', 'colors': [const Color(0xFFE91E63), const Color(0xFFC2185B)]},
      {'title': 'Hindi Mix', 'desc': 'Best Bollywood tunes', 'colors': [const Color(0xFF4CAF50), const Color(0xFF388E3C)]},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: const [
              Icon(Icons.auto_awesome_motion_rounded, color: AppTheme.accentPurple, size: 20),
              SizedBox(width: 8),
              Text(
                'Made For You',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: mixes.length,
            itemBuilder: (context, index) {
              final mix = mixes[index];
              final colors = mix['colors'] as List<Color>;

              return InkWell(
                onTap: () {
                  final filtered = List<Song>.from(_recommendations);
                  if (mix['title'] == 'English Mix') {
                    filtered.retainWhere((s) => (s.artist ?? '').toLowerCase().contains('taylor') || s.id.hashCode % 2 == 0);
                  } else if (mix['title'] == 'Hindi Mix') {
                    filtered.retainWhere((s) => s.id.hashCode % 2 != 0);
                  }
                  if (filtered.isNotEmpty) {
                    player.play(filtered.first, playlist: filtered, index: 0);
                  }
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 12),
                  width: 140,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      colors: colors,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Icon(Icons.music_note, color: Colors.white, size: 28),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mix['title'] as String,
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            mix['desc'] as String,
                            style: const TextStyle(color: Colors.white70, fontSize: 10),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadedMusic(PlayerProvider player) {
    if (_downloadedSongs.isEmpty) return const SizedBox.shrink();

    final albumIds = _downloadedSongs.map((s) => s.albumId ?? s.album).where((a) => a != null).toSet();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF0D5E4D).withValues(alpha: 0.8),
            const Color(0xFF0A2E26),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.download_done_rounded, color: Colors.greenAccent, size: 22),
              SizedBox(width: 8),
              Text(
                'Downloaded Music',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_downloadedSongs.length} Songs • ${albumIds.length} Albums',
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {
              final songs = List<Song>.from(_downloadedSongs)..shuffle();
              if (songs.isNotEmpty) {
                player.play(songs.first, playlist: songs, index: 0);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            ),
            child: const Text(
              'Play Offline',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  List<Song> _parseSongsSafely(List<Map<String, dynamic>> items) {
    final parsed = <Song>[];
    final seenIds = <String>{};
    final seenKeys = <String>{};

    for (final item in items) {
      try {
        final title = (item['name'] ?? item['title'] ?? '').toString();
        if (!ContentFilter.isAllowedSongTitle(title)) continue;
        
        final id = (item['id'] ?? '').toString().trim();
        if (id.isEmpty || seenIds.contains(id)) continue;

        final song = Song.fromJson(item);
        if (song.name.trim().isEmpty) continue;

        final key = _canonicalSongKey(song);
        if (key.length > 5 && seenKeys.contains(key)) continue;

        seenIds.add(id);
        if (key.length > 5) seenKeys.add(key);
        parsed.add(song);
      } catch (e) {
        debugPrint('Skipped malformed home song: $e');
      }
    }
    return parsed;
  }

  static String _canonicalSongKey(Song song) {
    final name = (song.name).toLowerCase();
    final artist = (song.artist ?? '').toLowerCase().split(',').first.trim();
    final cleanName = name
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(
          RegExp(r'\b(remix|version|live|slowed|reverb|karaoke|instrumental|lofi|cover)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '$cleanName|$artist';
  }

  Future<List<Album>> _parseAlbumsSafely(List<Map<String, dynamic>> items) async {
    final rawAlbums = <Album>[];
    for (final item in items) {
      try {
        rawAlbums.add(Album.fromJson(item));
      } catch (e) {
        debugPrint('Skipped malformed home album: $e');
      }
    }
    return await AlbumFilter.filterAndDeduplicate(rawAlbums);
  }

  List<Album> _parseAlbumsSafelySync(List<Map<String, dynamic>> items) {
    final rawAlbums = <Album>[];
    for (final item in items) {
      try {
        rawAlbums.add(Album.fromJson(item));
      } catch (e) {
        debugPrint('Skipped malformed home album: $e');
      }
    }
    return AlbumFilter.filterAndDeduplicateSync(rawAlbums);
  }

  List<Artist> _parseArtistsSafely(List<Map<String, dynamic>> items) {
    final parsed = <Artist>[];
    for (final item in items) {
      try {
        final artist = Artist.fromJson(item);
        if (artist.id.isNotEmpty && artist.name.trim().isNotEmpty) {
          parsed.add(artist);
        }
      } catch (e) {
        debugPrint('Skipped malformed home artist: $e');
      }
    }
    return parsed;
  }

  Set<String> _preferredLanguageSet(List<String> languages) {
    return LanguageUtils.normalizeLanguageSet(languages);
  }

  List<Song> _filterSongsByPreferredLanguages(
    List<Song> songs,
    Set<String> preferredLanguages,
  ) {
    if (preferredLanguages.isEmpty) return songs;
    return songs
        .where(
          (song) => LanguageUtils.matchesPreferredLanguages(
            song.language,
            preferredLanguages,
          ),
        )
        .toList(growable: false);
  }

  List<Album> _filterAlbumsByPreferredLanguages(
    List<Album> albums,
    Set<String> preferredLanguages,
  ) {
    if (preferredLanguages.isEmpty) return albums;
    return albums
        .where(
          (album) => LanguageUtils.matchesPreferredLanguages(
            album.language,
            preferredLanguages,
          ),
        )
        .toList(growable: false);
  }


  List<Song> _buildRecentlyPlayedSongs({
    required List<Map<String, dynamic>> historyRows,
    required List<Song> fallbackSongs,
  }) {
    final fallbackById = <String, Song>{};
    for (final song in fallbackSongs) {
      final id = song.id.trim();
      if (id.isNotEmpty && !fallbackById.containsKey(id)) {
        fallbackById[id] = song;
      }
    }

    final output = <Song>[];
    final seenIds = <String>{};

    for (final row in historyRows) {
      final payloadRaw = row['payload'];
      final payload = payloadRaw is Map
          ? Map<String, dynamic>.from(payloadRaw)
          : null;

      final id = _firstNonEmptyString([
        row['songId'],
        row['song_id'],
        row['id'],
        payload?['songId'],
        payload?['song_id'],
        payload?['id'],
      ]);
      if (id.isEmpty || seenIds.contains(id)) continue;

      final fallback = fallbackById[id];
      final imageUrl = _firstNonEmptyString([
        row['imageUrl'],
        row['image_url'],
        row['thumbnail'],
        row['thumbnail_url'],
        row['artwork'],
        _extractImageCandidate(row['image']),
        payload?['imageUrl'],
        payload?['image_url'],
        payload?['thumbnail'],
        payload?['thumbnail_url'],
        payload?['artwork'],
        _extractImageCandidate(payload?['image']),
        fallback?.imageUrl,
      ]);
      final name = _firstNonEmptyString([
        row['songName'],
        row['song_name'],
        row['name'],
        row['title'],
        payload?['songName'],
        payload?['song_name'],
        payload?['name'],
        payload?['title'],
        fallback?.name,
      ]);
      if (name.isEmpty) continue;
      if (!ContentFilter.isAllowedSongTitle(name)) continue;

      final artist = _firstNonEmptyString([
        row['artist'],
        row['primaryArtists'],
        payload?['artist'],
        payload?['primaryArtists'],
        fallback?.artist,
      ]);
      final album = _firstNonEmptyString([
        row['album'],
        row['albumName'],
        payload?['albumName'],
        payload?['album'],
        fallback?.album,
      ]);
      final language = _firstNonEmptyString([
        row['language'],
        payload?['language'],
        fallback?.language,
      ]);

      output.add(
        Song(
          id: id,
          name: name,
          artist: artist.isEmpty ? null : artist,
          album: album.isEmpty ? null : album,
          imageUrl: imageUrl.isEmpty ? fallback?.imageUrl : imageUrl,
          streamUrl: fallback?.streamUrl,
          language: language.isEmpty ? fallback?.language : language,
          duration: fallback?.duration,
        ),
      );
      seenIds.add(id);
    }

    return output;
  }

  String _firstNonEmptyString(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  List<Map<String, dynamic>> _asMapList(dynamic list) {
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
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
        final url = _firstNonEmptyString([
          map['url'],
          map['link'],
          map['image'],
        ]);
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }


  Future<void> _loadMoreRecommendations() async {
    if (_recommendationLimit >= 60) return;
    final preferences = context.read<PreferencesProvider>();
    if (!preferences.hasCompletedOnboarding) return;

    try {
      _recommendationLimit = 60;
      final recList = await ApiService.getPersonalizedRecommendations(
        languages: preferences.languages,
        favoriteArtists: preferences.favoriteArtists,
        limit: _recommendationLimit,
      );
      final preferredLanguageSet = _preferredLanguageSet(preferences.languages);
      final newRecs = _filterSongsByPreferredLanguages(
        recList
            .whereType<Map>()
            .where((json) => ContentFilter.isAllowedSongTitle(
                  (json['name'] ?? json['title'] ?? '').toString(),
                ))
            .map((json) => Song.fromJson(Map<String, dynamic>.from(json)))
            .toList(),
        preferredLanguageSet,
      );

      if (!mounted) return;
      setState(() {
        final existingIds = _recommendations.map((song) => song.id).toSet();
        _recommendations.addAll(
          newRecs.where((song) => !existingIds.contains(song.id)),
        );
      });
    } catch (e) {
      debugPrint('Load more recs error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final player = context.read<PlayerProvider>();
    final isOffline = context.select<PlayerProvider, bool>((p) => p.isOffline);
    final currentSong = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final currentSongId = context.select<PlayerProvider, String?>((p) => p.currentSong?.id);
    _maybeHandlePlaybackResume(auth);

    if (_lastOfflineState != isOffline) {
      final wasOffline = _lastOfflineState ?? isOffline;
      _lastOfflineState = isOffline;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onOfflineStateChanged(
          wasOffline: wasOffline,
          isOffline: isOffline,
        );
      });
    }

    if (widget.showReconnectMessageOnStart &&
        !_handledReconnectMessageOnStart &&
        !isOffline) {
      _handledReconnectMessageOnStart = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadData(forceRefresh: true);
      });
    }

    final featuredSong = currentSong ?? (_recommendations.isNotEmpty ? _recommendations.first : null);
    final gradientColors = _getGradientColors(featuredSong);

    return PopScope(
      canPop: !_isLibraryDrawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_isLibraryDrawerOpen) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        extendBody: true,
        key: _scaffoldKey,
        endDrawer: const LibrarySideDrawer(),
        onEndDrawerChanged: (isOpen) {
          if (!mounted) return;
          setState(() {
            _isLibraryDrawerOpen = isOpen;
          });
        },
        body: AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _getGreeting(),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textSecondary,
                                letterSpacing: 1.0,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Hi, ${auth.user?.displayName?.split(' ').first ?? 'Sebastian'}',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.notifications_outlined, color: AppTheme.textPrimary, size: 24),
                            onPressed: () => _showProfileActions(auth),
                          ),
                          IconButton(
                            icon: const Icon(Icons.playlist_add_rounded, color: AppTheme.textPrimary, size: 26),
                            tooltip: 'Import Playlist',
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const PlaylistImportScreen()),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.search_rounded, color: AppTheme.textPrimary, size: 24),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SearchScreen()),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.account_circle_outlined, color: AppTheme.textPrimary, size: 24),
                            onPressed: () => _showProfileActions(auth),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                if (isOffline)
                  Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orangeAccent.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.wifi_off_rounded,
                          color: Colors.orangeAccent,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'You’re offline. Playing downloaded music.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OfflineLibraryScreen(),
                            ),
                          ),
                          child: const Text(
                            'OFFLINE LIBRARY',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                Expanded(
                  child: _loading
                      ? _buildSkeletonLoader()
                      : RefreshIndicator(
                          onRefresh: _handlePullToRefresh,
                          color: AppTheme.accentPurple,
                          child: ListView(
                            controller: _scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: [
                              _buildContinueListening(player),
                              const SizedBox(height: 12),
                              _buildQuickActions(context),
                              const SizedBox(height: 12),
                              _buildRecentlyPlayedGrid(player),
                              const SizedBox(height: 24),
                              _buildHeroCard(player),
                              const SizedBox(height: 16),
                              _buildPersonalizedMixes(player),
                              const SizedBox(height: 16),
                              _buildDownloadedMusic(player),
                              const SizedBox(height: 16),
                              if (_recommendedAlbums.isNotEmpty) ...[
                                _sectionHeader('Recommended Albums', Icons.album_rounded),
                                SizedBox(
                                  height: 210,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                    itemCount: _recommendedAlbums.length,
                                    itemBuilder: (context, index) {
                                      final album = _recommendedAlbums[index];
                                      return AlbumCard(
                                        album: album,
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              if (_trendingSongs.isNotEmpty) ...[
                                _sectionHeader('Trending Now', Icons.trending_up_rounded),
                                ..._trendingSongs.take(5).map(
                                  (song) => SongTile(
                                    song: song,
                                    isPlaying: currentSongId == song.id,
                                    onTap: () => player.play(song, playlist: _trendingSongs, index: _trendingSongs.indexOf(song)),
                                  ),
                                ),
                              ],
                              if (_recommendations.isNotEmpty) ...[
                                _sectionHeader('New Releases', Icons.fiber_new_rounded),
                                ..._recommendations.take(5).map(
                                  (song) => SongTile(
                                    song: song,
                                    isPlaying: currentSongId == song.id,
                                    onTap: () => player.play(song, playlist: _recommendations, index: _recommendations.indexOf(song)),
                                  ),
                                ),
                              ],
                              if (_suggestedArtists.isNotEmpty) ...[
                                _sectionHeader('Popular Artists', Icons.person_outline_rounded),
                                SizedBox(
                                  height: 160,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                    itemCount: _suggestedArtists.length,
                                    itemBuilder: (context, index) {
                                      final artist = _suggestedArtists[index];
                                      return ArtistCard(
                                        artist: artist,
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (_) => ArtistDetailScreen(artist: artist)),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              if (_playlists.isNotEmpty) ...[
                                _sectionHeader('Recommended Playlists', Icons.queue_music_rounded),
                                SizedBox(
                                  height: 210,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                    itemCount: _playlists.length,
                                    itemBuilder: (context, index) {
                                      final playlist = _playlists[index];
                                      return AlbumCard(
                                        album: playlist,
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: playlist)),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              const SizedBox(height: 120),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(useSafeArea: false),
              const SizedBox(height: 10),
              _buildBottomNavBar(auth, player),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.accentPurple, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar(AuthProvider auth, PlayerProvider player) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      height: 64,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 15,
            spreadRadius: 1,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBottomNavItem(
                icon: Icons.home_filled,
                label: 'Home',
                isActive: true,
                onTap: () {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                  );
                },
              ),
              _buildBottomNavItem(
                icon: Icons.search_rounded,
                label: 'Search',
                isActive: false,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
              ),
              _buildBottomNavItem(
                icon: Icons.library_music_rounded,
                label: 'Library',
                isActive: false,
                onTap: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
              _buildBottomNavItem(
                icon: Icons.download_for_offline_rounded,
                label: 'Downloads',
                isActive: false,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                ),
              ),
              _buildBottomNavItem(
                icon: Icons.person_rounded,
                label: 'Profile',
                isActive: false,
                onTap: () => _showProfileActions(auth),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavItem({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isActive ? AppTheme.accentPurple : Colors.white60,
              size: 24,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: isActive ? AppTheme.accentPurple : Colors.white60,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showProfileActions(AuthProvider auth) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded, color: AppTheme.accentPurple),
              title: const Text('Import Playlist'),
              onTap: () => Navigator.pop(sheetContext, 'import_playlist'),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Preferences'),
              onTap: () => Navigator.pop(sheetContext, 'preferences'),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign Out'),
              onTap: () => Navigator.pop(sheetContext, 'logout'),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'import_playlist') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlaylistImportScreen()),
      );
      return;
    }
    if (action == 'preferences') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PreferencesScreen()),
      );
      return;
    }

    if (action == 'logout') {
      await auth.signOut();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const LoginScreen(),
          settings: const RouteSettings(name: '/login'),
        ),
        (_) => false,
      );
    }
  }
}

