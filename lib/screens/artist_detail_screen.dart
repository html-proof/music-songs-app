import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/artist.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/album_card.dart';
import '../widgets/mini_player.dart';
import '../screens/album_detail_screen.dart';
import '../utils/album_filter.dart';
import '../widgets/artist_avatar.dart';

class ArtistDetailScreen extends StatefulWidget {
  final Artist artist;

  const ArtistDetailScreen({super.key, required this.artist});

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  Artist? _detailedArtist;
  List<Song> _topTracks = [];
  List<Album> _albums = [];
  bool _isLoading = true;
  String? _error;
  bool _isFollowing = false;

  @override
  void initState() {
    super.initState();
    _detailedArtist = widget.artist;
    _fetchArtistDetails();
  }

  Future<void> _fetchArtistDetails() async {
    try {
      final id = widget.artist.id;
      final results = await Future.wait([
        ApiService.getArtistById(id),
        ApiService.getArtistSongs(id),
        ApiService.getArtistAlbums(id, artistName: widget.artist.name),
      ]);

      if (!mounted) return;

      final artistJson = results[0] as Map<String, dynamic>?;
      final songsJson = results[1] as List;
      final albumsJson = results[2] as List;

      setState(() {
        if (artistJson != null) {
          _detailedArtist = Artist.fromJson(artistJson);
        }
        _topTracks = songsJson
            .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
            .take(10)
            .toList();
        _albums = AlbumFilter.filterAndDeduplicate(
          albumsJson
              .map((a) => Album.fromJson(Map<String, dynamic>.from(a)))
              .toList(),
        );
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error fetching artist details: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final artist = _detailedArtist ?? widget.artist;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    _buildAppBar(artist),
                    if (_isLoading)
                      const SliverFillRemaining(
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.accentPurple,
                          ),
                        ),
                      )
                    else if (_error != null)
                      SliverFillRemaining(
                        child: Center(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: AppTheme.textSecondary),
                          ),
                        ),
                      )
                    else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          child: Row(
                            children: [
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: _isFollowing ? Colors.white38 : Colors.white,
                                    width: 1.2,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                ),
                                onPressed: () {
                                  setState(() {
                                    _isFollowing = !_isFollowing;
                                  });
                                },
                                child: Text(
                                  _isFollowing ? 'Following' : 'Follow',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
                                onPressed: () {},
                              ),
                              const Spacer(),
                              if (_topTracks.isNotEmpty)
                                CircleAvatar(
                                  radius: 26,
                                  backgroundColor: AppTheme.accentPurple,
                                  child: IconButton(
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.black87,
                                      size: 28,
                                    ),
                                    onPressed: () {
                                      player.play(
                                        _topTracks[0],
                                        playlist: _topTracks,
                                        index: 0,
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_topTracks.isNotEmpty) ...[
                        _buildSectionHeader('Popular Songs'),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = _topTracks[index];
                              return SongTile(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                onTap: () => player.play(song, playlist: _topTracks),
                              );
                            },
                            childCount: _topTracks.length,
                          ),
                        ),
                      ],
                      if (_albums.isNotEmpty) ...[
                        _buildSectionHeader('Albums & Singles'),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 220,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: _albums.length,
                              itemBuilder: (context, index) {
                                final album = _albums[index];
                                return AlbumCard(
                                  album: album,
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AlbumDetailScreen(album: album),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                    ],
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

  Widget _buildAppBar(Artist artist) {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      backgroundColor: Colors.transparent,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            ArtistAvatar(
              artistId: artist.id,
              artistName: artist.name,
              imageUrl: artist.imageUrl,
              fit: BoxFit.cover,
              isCircle: false,
            ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black87,
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          artist.name,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (artist.isVerified)
                        const Padding(
                          padding: EdgeInsets.only(left: 8, top: 8),
                          child: Icon(Icons.verified, color: Colors.blue, size: 24),
                        ),
                    ],
                  ),
                  if (artist.role != null && artist.role!.isNotEmpty)
                    Text(
                      artist.role!,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                  if (artist.followerCount != null)
                    Text(
                      '${artist.followerCount} followers',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 14,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
