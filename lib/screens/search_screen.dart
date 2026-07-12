import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/search_provider.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player.dart';
import '../widgets/album_card.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';
import '../screens/playlist_detail_screen.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../widgets/offline_artwork.dart';
import '../widgets/artist_avatar.dart';
import '../services/background_learning_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const Duration _backendKeepAliveInterval = Duration(seconds: 10);
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;
  Timer? _backendKeepAliveTimer;
  bool? _lastOfflineMode;
  String _activeTab = 'All';

  final List<Map<String, dynamic>> _browseCategories = const [
    {'title': 'Pop', 'color': Color(0xFFE02B57)},
    {'title': 'Rock', 'color': Color(0xFF1E3264)},
    {'title': 'Tamil', 'color': Color(0xFFE8115B)},
    {'title': 'Malayalam', 'color': Color(0xFFBC4620)},
    {'title': 'Hindi', 'color': Color(0xFF27856A)},
    {'title': 'English', 'color': Color(0xFF7D4B32)},
    {'title': 'Workout', 'color': Color(0xFF3C1263)},
    {'title': 'Chill', 'color': Color(0xFF509BF5)},
    {'title': 'Focus', 'color': Color(0xFF477D95)},
    {'title': 'Sleep', 'color': Color(0xFF1D2F54)},
    {'title': 'Party', 'color': Color(0xFFAF2896)},
    {'title': 'Podcast', 'color': Color(0xFF0D73EC)},
  ];


  @override
  void initState() {
    super.initState();
    _startBackendKeepAlive();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      if (!mounted) return;
      context.read<SearchProvider>().showRecommendationsForInput('');
    });
    _scrollController.addListener(_onScroll);
  }

  void _startBackendKeepAlive() {
    unawaited(ApiService.warmUpBackend(forcePing: true));
    _backendKeepAliveTimer?.cancel();
    _backendKeepAliveTimer = Timer.periodic(_backendKeepAliveInterval, (_) {
      unawaited(ApiService.warmUpBackend(forcePing: true));
    });
  }

  void _startVoiceSearch() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Voice Search',
      barrierColor: Colors.black.withValues(alpha: 0.85),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return _VoiceSearchOverlay(
          onSearch: (query) {
            _controller.text = query;
            _controller.selection = TextSelection.collapsed(offset: query.length);
            final searchProvider = Provider.of<SearchProvider>(context, listen: false);
            searchProvider.search(query);
            searchProvider.showRecommendationsForInput(query);
            setState(() {});
          },
        );
      },
    );
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      context.read<SearchProvider>().loadMore();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _backendKeepAliveTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<SearchProvider>();
    final player = context.read<PlayerProvider>();
    final isOffline = context.select<PlayerProvider, bool>((p) => p.isOffline);
    final currentSongId = context.select<PlayerProvider, String?>((p) => p.currentSong?.id);
    final topResult = _selectTopResult(search);
    final topResultSong = topResult is Song ? topResult : null;
    final topResultIndex = topResultSong == null
        ? -1
        : search.songs.indexOf(topResultSong);
    final remainingSongs = topResultSong == null
        ? search.songs
        : search.songs
              .where((song) => !_isSameSong(song, topResultSong))
              .toList(growable: false);

    final showBrowseCategories = _controller.text.trim().isEmpty;
    final showEmptyState = !search.loading &&
        !showBrowseCategories &&
        search.songs.isEmpty &&
        search.albums.isEmpty &&
        search.artists.isEmpty;

    if (_lastOfflineMode != isOffline) {
      _lastOfflineMode = isOffline;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SearchProvider>().setOfflineMode(isOffline);
      });
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              // Search Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        style: const TextStyle(color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: isOffline
                              ? 'Offline search in cached songs...'
                              : 'Search songs, artists, albums...',
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (_controller.text.isNotEmpty)
                                IconButton(
                                  icon: const Icon(
                                    Icons.clear,
                                    color: AppTheme.textMuted,
                                  ),
                                  onPressed: () {
                                    _controller.clear();
                                    search.clear();
                                    search.showRecommendationsForInput('');
                                    setState(() {
                                      _activeTab = 'All';
                                    });
                                  },
                                ),
                              IconButton(
                                icon: const Icon(
                                  Icons.mic_none_rounded,
                                  color: AppTheme.textMuted,
                                ),
                                onPressed: _startVoiceSearch,
                              ),
                            ],
                          ),
                        ),
                        onSubmitted: (q) {
                          _searchDebounce?.cancel();
                          search.search(q);
                          search.showRecommendationsForInput(q);
                        },
                        onChanged: (q) {
                          setState(() {}); // Rebuild for clear icon
                          _searchDebounce?.cancel();
                          search.showRecommendationsForInput(q);

                          final normalized = q.trim();
                          if (normalized.isEmpty) {
                            search.clear();
                            setState(() {
                              _activeTab = 'All';
                            });
                            return;
                          }

                          _searchDebounce = Timer(
                            const Duration(milliseconds: 250),
                            () {
                              if (!mounted) return;
                              context.read<SearchProvider>().search(normalized);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              if (isOffline)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Text(
                    "You're offline. Online search is disabled. Showing cached results only.",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

              // Results
              Expanded(
                child: search.loading
                    ? const _SkeletonLoader()
                    : showBrowseCategories
                        ? ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: [
                              if (search.recentSearches.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Text(
                                      'Recent Searches',
                                      style: TextStyle(
                                        color: AppTheme.textPrimary,
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const Spacer(),
                                    TextButton(
                                      onPressed: () => search.clearRecentSearches(),
                                      child: const Text('Clear'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: search.recentSearches.map((item) {
                                    return InputChip(
                                      label: Text(item),
                                      labelStyle: const TextStyle(color: AppTheme.textPrimary),
                                      backgroundColor: AppTheme.surfaceDark,
                                      side: BorderSide.none,
                                      deleteIconColor: AppTheme.textMuted,
                                      onDeleted: () {
                                        search.removeRecentSearch(item);
                                      },
                                      onPressed: () {
                                        _controller.text = item;
                                        _controller.selection = TextSelection.collapsed(offset: item.length);
                                        search.search(item);
                                        search.showRecommendationsForInput(item);
                                        setState(() {});
                                      },
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 20),
                              ],
                              const Text(
                                'Trending',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  'Top Malayalam',
                                  'Top Hindi',
                                  'Top English',
                                  'New Releases',
                                  'Imagine Dragons',
                                  'Anirudh',
                                  'Aavesham',
                                  'Believer',
                                ].map((item) {
                                  return ActionChip(
                                    label: Text(item),
                                    labelStyle: const TextStyle(color: AppTheme.textPrimary),
                                    backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.6),
                                    side: const BorderSide(color: AppTheme.accentPurple, width: 0.5),
                                    onPressed: () {
                                      _controller.text = item;
                                      _controller.selection = TextSelection.collapsed(offset: item.length);
                                      search.search(item);
                                      search.showRecommendationsForInput(item);
                                      setState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                  'Browse All',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              const SizedBox(height: 16),
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing: 14,
                                  childAspectRatio: 1.6,
                                ),
                                itemCount: _browseCategories.length,
                                itemBuilder: (context, index) {
                                  final category = _browseCategories[index];
                                  return GestureDetector(
                                    onTap: () {
                                      final title = category['title'] as String;
                                      _controller.text = title;
                                      _controller.selection = TextSelection.collapsed(offset: title.length);
                                      search.search(title);
                                      search.showRecommendationsForInput(title);
                                      setState(() {});
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: category['color'] as Color,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      padding: const EdgeInsets.all(16),
                                      child: Stack(
                                        children: [
                                          Text(
                                            category['title'] as String,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Positioned(
                                            bottom: -10,
                                            right: -10,
                                            child: Opacity(
                                              opacity: 0.16,
                                              child: Transform.scale(
                                                scale: 1.8,
                                                child: Transform.rotate(
                                                  angle: 0.35,
                                                  child: const Icon(Icons.music_note_rounded, size: 56, color: Colors.white),
                                                ),
                                              ),
                                            ),
                                          )
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 100),
                            ],
                          )
                        : showEmptyState
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.music_off_rounded,
                                      size: 64,
                                      color: AppTheme.textMuted,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No results found for "${search.query}"',
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Column(
                                children: [
                                  _buildSearchTabs(),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    child: ListView(
                                      controller: _scrollController,
                                      padding: const EdgeInsets.symmetric(horizontal: 16),
                                      children: [
                                        // Top Result
                                        if (topResult != null && _activeTab == 'All') ...[
                                          const Padding(
                                            padding: EdgeInsets.symmetric(vertical: 16),
                                            child: Text(
                                              'Top Result',
                                              style: TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          _TopResultCard(
                                            item: topResult,
                                            onTap: () {
                                              if (topResult is Song) {
                                                unawaited(BackgroundLearningService.recordUserSelection(
                                                  query: search.query,
                                                  songId: topResult.id,
                                                ));
                                                player.play(
                                                  topResult,
                                                  playlist: search.songs,
                                                  index: topResultIndex < 0 ? 0 : topResultIndex,
                                                );
                                              } else if (topResult is Album) {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) => AlbumDetailScreen(album: topResult),
                                                  ),
                                                );
                                              } else if (topResult is Artist) {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) => ArtistDetailScreen(artist: topResult),
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                          const SizedBox(height: 12),
                                        ],

                                        if (topResult is Artist || (search.artists.isNotEmpty && search.artists.first.name.toLowerCase().startsWith(_controller.text.trim().toLowerCase()))) ...[
                                          _buildArtistsSection(context, search),
                                          _buildSongsSection(context, search, remainingSongs, currentSongId, player, topResultIndex),
                                        ] else ...[
                                          _buildSongsSection(context, search, remainingSongs, currentSongId, player, topResultIndex),
                                          _buildArtistsSection(context, search),
                                        ],

                                        _buildAlbumsSection(context, search),
                                        _buildPlaylistsSection(context, search),

                                        const SizedBox(height: 100),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
              ),

              // Mini Player
              const MiniPlayer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchTabs() {
    final tabs = ['All', 'Songs', 'Albums', 'Artists', 'Playlists'];
    return SizedBox(
      height: 38,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final isActive = _activeTab == tab;
          return GestureDetector(
            onTap: () => setState(() => _activeTab = tab),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: isActive ? AppTheme.accentPurple : AppTheme.cardDark,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Center(
                child: Text(
                  tab,
                  style: TextStyle(
                    color: isActive ? Colors.black87 : AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  dynamic _selectTopResult(SearchProvider search) {
    if (search.songs.isEmpty && search.albums.isEmpty && search.artists.isEmpty) {
      return null;
    }

    final query = search.query.toLowerCase().trim();
    if (query.isEmpty) return null;

    double scoreItem(dynamic item) {
      double points = 0.0;
      String name = '';
      if (item is Artist) {
        name = item.name.toLowerCase().trim();
        if (item.isVerified) points += 20.0;
        if (item.role != null && item.role!.contains('downloaded')) points += 10.0;
      } else if (item is Album) {
        name = item.name.toLowerCase().trim();
        if (item.isOfficial) points += 5.0;
      } else if (item is Song) {
        name = item.name.toLowerCase().trim();
        if (item.isOfficial) points += 5.0;
      }

      if (name == query) {
        points += 100.0;
      } else if (name.startsWith(query)) {
        points += 50.0;
      } else if (name.contains(query)) {
        points += 15.0;
      }
      return points;
    }

    dynamic bestItem;
    double bestScore = -999.0;

    for (final artist in search.artists.take(3)) {
      final s = scoreItem(artist);
      if (s > bestScore) {
        bestScore = s;
        bestItem = artist;
      }
    }

    for (final song in search.songs.take(3)) {
      final s = scoreItem(song);
      if (s > bestScore) {
        bestScore = s;
        bestItem = song;
      }
    }

    for (final album in search.albums.take(3)) {
      final s = scoreItem(album);
      if (s > bestScore) {
        bestScore = s;
        bestItem = album;
      }
    }

    return bestItem;
  }

  bool _isSameSong(Song a, Song b) {
    final aId = a.id.trim();
    final bId = b.id.trim();
    if (aId.isNotEmpty && bId.isNotEmpty) return aId == bId;

    final aKey = '${a.name}|${a.artist ?? ''}|${a.album ?? ''}'
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final bKey = '${b.name}|${b.artist ?? ''}|${b.album ?? ''}'
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return aKey == bKey;
  }

  Widget _buildArtistsSection(BuildContext context, SearchProvider search) {
    if (search.artists.isEmpty || (_activeTab != 'All' && _activeTab != 'Artists')) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeTab != 'All') const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Artists',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...search.artists.map((artist) {
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: AppTheme.cardDark,
              child: ClipOval(
                child: ArtistAvatar(
                  artistId: artist.id,
                  artistName: artist.name,
                  imageUrl: artist.imageUrl,
                  radius: 26,
                  isCircle: true,
                ),
              ),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    artist.name,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (artist.isVerified)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.verified, color: Colors.blue, size: 16),
                  ),
              ],
            ),
            subtitle: Text(
              artist.role != null && artist.role!.isNotEmpty
                  ? artist.role!
                  : 'Artist',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.textMuted,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ArtistDetailScreen(artist: artist),
                ),
              );
            },
          );
        }),
      ],
    );
  }

  Widget _buildSongsSection(
    BuildContext context,
    SearchProvider search,
    List<Song> remainingSongs,
    String? currentSongId,
    PlayerProvider player,
    int topResultIndex,
  ) {
    if (remainingSongs.isEmpty || (_activeTab != 'All' && _activeTab != 'Songs')) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeTab != 'All') const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Songs',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...List.generate(remainingSongs.length, (index) {
          final song = remainingSongs[index];
          final originalIndex = search.songs.indexOf(song);
          return SongTile(
            song: song,
            isPlaying: currentSongId == song.id,
            onTap: () {
              unawaited(BackgroundLearningService.recordUserSelection(
                query: search.query,
                songId: song.id,
              ));
              player.play(
                song,
                playlist: search.songs,
                index: originalIndex < 0 ? 0 : originalIndex,
              );
            },
          );
        }),
      ],
    );
  }

  Widget _buildAlbumsSection(BuildContext context, SearchProvider search) {
    if (search.albums.isEmpty || (_activeTab != 'All' && _activeTab != 'Albums')) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeTab != 'All') const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Albums',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: search.albums.length,
            itemBuilder: (context, index) {
              final album = search.albums[index];
              if (album.songCount != null && album.songCount! <= 0) {
                return const SizedBox.shrink();
              }
              return AlbumCard(
                album: album,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AlbumDetailScreen(album: album),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistsSection(BuildContext context, SearchProvider search) {
    if (search.playlists.isEmpty || (_activeTab != 'All' && _activeTab != 'Playlists')) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeTab != 'All') const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Playlists',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: search.playlists.length,
            itemBuilder: (context, index) {
              final playlist = search.playlists[index];
              return Container(
                width: 140,
                margin: const EdgeInsets.only(right: 14),
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PlaylistDetailScreen(
                          playlistId: playlist.id,
                        ),
                      ),
                    );
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AspectRatio(
                          aspectRatio: 1.0,
                          child: OfflineArtwork(
                            playlistId: playlist.id,
                            imageUrl: playlist.coverImageUrl,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: AppTheme.surfaceDark,
                              child: const Icon(Icons.playlist_play_rounded, size: 48, color: AppTheme.textMuted),
                            ),
                            errorWidget: Container(
                              color: AppTheme.surfaceDark,
                              child: const Icon(Icons.playlist_play_rounded, size: 48, color: AppTheme.textMuted),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        playlist.name,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${playlist.songs.length} songs',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
}

class _TopResultCard extends StatelessWidget {
  final dynamic item;
  final VoidCallback onTap;

  const _TopResultCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (item == null) return const SizedBox.shrink();

    String name = '';
    String subtitle = '';
    Widget artwork;
    Widget trailingIcon;

    if (item is Artist) {
      final artist = item as Artist;
      name = artist.name;
      subtitle = artist.isVerified ? 'Verified Artist' : 'Artist';
      artwork = ClipOval(
        child: SizedBox(
          width: 80,
          height: 80,
          child: ArtistAvatar(
            artistId: artist.id,
            artistName: artist.name,
            imageUrl: artist.imageUrl,
            radius: 40,
            isCircle: true,
          ),
        ),
      );
      trailingIcon = const Icon(
        Icons.chevron_right_rounded,
        color: AppTheme.textSecondary,
        size: 32,
      );
    } else if (item is Album) {
      final album = item as Album;
      name = album.name;
      subtitle = 'Album • ${album.artist ?? 'Unknown Artist'}';
      artwork = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: OfflineArtwork(
          albumId: album.id,
          imageUrl: album.imageUrl,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          placeholder: Container(
            color: AppTheme.cardDark,
            child: const Icon(Icons.album_rounded, color: Colors.white24, size: 36),
          ),
          errorWidget: Container(
            color: AppTheme.cardDark,
            child: const Icon(Icons.album_rounded, color: Colors.white24, size: 36),
          ),
        ),
      );
      trailingIcon = const Icon(
        Icons.chevron_right_rounded,
        color: AppTheme.textSecondary,
        size: 32,
      );
    } else if (item is Song) {
      final song = item as Song;
      name = song.name;
      subtitle = 'Song • ${song.artist ?? 'Unknown Artist'}';
      artwork = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: OfflineArtwork(
          songId: song.id,
          imageUrl: song.imageUrl,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          placeholder: Container(
            color: AppTheme.cardDark,
            child: const Icon(Icons.music_note, color: Colors.white24, size: 36),
          ),
          errorWidget: Container(
            color: AppTheme.cardDark,
            child: const Icon(Icons.music_note, color: Colors.white24, size: 36),
          ),
        ),
      );
      trailingIcon = const Icon(
        Icons.play_circle_fill_rounded,
        color: AppTheme.accentPurple,
        size: 40,
      );
    } else {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppTheme.accentPurple.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            artwork,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item is Artist && (item as Artist).isVerified)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(Icons.verified, color: Colors.blue, size: 16),
                        ),
                      Expanded(
                        child: Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            trailingIcon,
          ],
        ),
      ),
    );
  }
}

class _VoiceSearchOverlay extends StatefulWidget {
  final ValueChanged<String> onSearch;

  const _VoiceSearchOverlay({required this.onSearch});

  @override
  State<_VoiceSearchOverlay> createState() => _VoiceSearchOverlayState();
}

class _VoiceSearchOverlayState extends State<_VoiceSearchOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  String _statusText = 'Listening...';
  String _transcribedText = '';
  bool _finished = false;

  final List<String> _mockQueries = const [
    'Imagine',
    'Believer',
    'Indie Hits',
    'KGF',
    'Anirudh',
    'Tamil Hits',
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _simulateSpeechRecognition();
  }

  Future<void> _simulateSpeechRecognition() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() {
      _statusText = 'Recognizing...';
    });

    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    final randomQuery =
        (_mockQueries.toList()..shuffle()).first;
    setState(() {
      _finished = true;
      _statusText = 'Did you say:';
      _transcribedText = '"$randomQuery"';
    });

    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;
    widget.onSearch(randomQuery);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _statusText,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 20,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            if (_transcribedText.isNotEmpty)
              Text(
                _transcribedText,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
            const SizedBox(height: 50),
            Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    return Container(
                      width: 120 + (_finished ? 0.0 : _controller.value * 80),
                      height: 120 + (_finished ? 0.0 : _controller.value * 80),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.accentPurple
                            .withValues(alpha: _finished ? 0.0 : (1.0 - _controller.value) * 0.26),
                      ),
                    );
                  },
                ),
                Container(
                  width: 100,
                  height: 100,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.cardDark,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentPurple,
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.mic_rounded,
                    color: AppTheme.accentPurple,
                    size: 48,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 50),
            if (!_finished)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final waveValue =
                          (sin(_controller.value * 2 * pi + index * 0.8) + 1.0) / 2.0;
                      return Container(
                        width: 6,
                        height: 15 + waveValue * 30,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.accentPurple,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    },
                  );
                }),
              ),
            const SizedBox(height: 80),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.textMuted),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: 6,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceDark.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 120,
                      height: 12,
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceDark.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
