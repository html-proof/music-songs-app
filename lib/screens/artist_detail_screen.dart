import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_manager.dart';

import '../models/artist.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
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
  List<Album> _singles = [];
  List<Song> _downloadedSongs = [];
  List<Artist> _relatedArtists = [];
  String? _biography;
  bool _isLoading = true;
  String? _error;
  bool _isFollowing = false;
  StreamSubscription? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _detailedArtist = widget.artist;
    _fetchArtistDetails();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _fetchArtistDetails() async {
    try {
      final isOffline = ConnectivityManager.isOffline;

      // Always load downloaded songs for this artist.
      final allDownloaded = await DownloadService.getDownloadedSongs();
      final artistNameLower = widget.artist.name.toLowerCase().trim();
      final matchingDownloaded = allDownloaded
          .where((s) => s.artist?.toLowerCase().trim() == artistNameLower)
          .toList();

      if (isOffline) {
        final offlineAlbums = await AlbumFilter.filterAndDeduplicate(
          matchingDownloaded.map((s) => Album(
            id: s.albumId ?? 'song_album_${s.album?.toLowerCase().replaceAll(RegExp(r'\s+'), '_')}',
            name: s.album ?? 'Unknown Album',
            artist: s.artist,
            imageUrl: s.imageUrl,
            songCount: 1,
          )).toList(),
        );

        if (!mounted) return;
        setState(() {
          _topTracks = matchingDownloaded;
          _downloadedSongs = matchingDownloaded;
          _albums = offlineAlbums;
          _singles = [];
          _relatedArtists = [];
          _biography = null;
          _isLoading = false;
          _error = null;
        });
        return;
      }

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

      final parsedTracks = songsJson
          .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
          .take(10)
          .toList();

      final allParsedAlbums = await AlbumFilter.filterAndDeduplicate(
        albumsJson
            .map((a) => Album.fromJson(Map<String, dynamic>.from(a)))
            .toList(),
      );

      // Split into albums vs singles based on type or songCount.
      final albumsList = <Album>[];
      final singlesList = <Album>[];
      for (final album in allParsedAlbums) {
        final type = (album.type ?? '').toUpperCase();
        if (type == 'SINGLE' || (album.songCount != null && album.songCount! <= 2 && type != 'ALBUM')) {
          singlesList.add(album);
        } else {
          albumsList.add(album);
        }
      }

      // Extract biography from artist JSON.
      String? bio;
      if (artistJson != null) {
        bio = (artistJson['bio'] ?? artistJson['biography'] ?? artistJson['wiki'] ?? '').toString().trim();
        if (bio.isEmpty) bio = null;
      }

      // Extract related / similar artists from artist JSON.
      List<Artist> related = [];
      if (artistJson != null) {
        final similarArtists = artistJson['similarArtists'] ?? artistJson['similar_artists'] ?? artistJson['relatedArtists'];
        if (similarArtists is List) {
          related = similarArtists
              .whereType<Map>()
              .map((a) => Artist.fromJson(Map<String, dynamic>.from(a)))
              .where((a) => a.name.isNotEmpty)
              .take(10)
              .toList();
        }
      }

      if (!mounted) return;
      setState(() {
        if (artistJson != null) {
          _detailedArtist = Artist.fromJson(artistJson);
        }
        _topTracks = parsedTracks;
        _albums = albumsList;
        _singles = singlesList;
        _downloadedSongs = matchingDownloaded;
        _relatedArtists = related;
        _biography = bio;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      debugPrint('Error fetching artist details: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load artist details';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final currentSongId = context.select<PlayerProvider, String?>((p) => p.currentSong?.id);
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
                      if (context.select<PlayerProvider, bool>((p) => p.isOffline))
                        SliverToBoxAdapter(
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.orangeAccent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.4)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.cloud_off_rounded, color: Colors.orangeAccent, size: 20),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Offline Mode — displaying downloaded songs and albums only',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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

                      // Biography
                      if (_biography != null && _biography!.isNotEmpty) ...[
                        _buildSectionHeader('About'),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              _biography!,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 14,
                                height: 1.5,
                              ),
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],

                      // Popular Songs
                      if (_topTracks.isNotEmpty) ...[
                        _buildSectionHeader('Popular Songs'),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = _topTracks[index];
                              return SongTile(
                                song: song,
                                isPlaying: currentSongId == song.id,
                                onTap: () => player.play(song, playlist: _topTracks),
                              );
                            },
                            childCount: _topTracks.length,
                          ),
                        ),
                      ],

                      // Downloaded Songs (only if there are downloaded songs not already in top tracks)
                      if (_downloadedSongs.isNotEmpty && !ConnectivityManager.isOffline) ...[
                        _buildSectionHeader('Downloaded'),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = _downloadedSongs[index];
                              return SongTile(
                                song: song,
                                isPlaying: currentSongId == song.id,
                                onTap: () => player.play(song, playlist: _downloadedSongs),
                              );
                            },
                            childCount: _downloadedSongs.length > 5 ? 5 : _downloadedSongs.length,
                          ),
                        ),
                      ],

                      // Albums
                      if (_albums.isNotEmpty) ...[
                        _buildSectionHeader('Albums'),
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

                      // Singles
                      if (_singles.isNotEmpty) ...[
                        _buildSectionHeader('Singles'),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 220,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: _singles.length,
                              itemBuilder: (context, index) {
                                final album = _singles[index];
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

                      // Related Artists
                      if (_relatedArtists.isNotEmpty) ...[
                        _buildSectionHeader('Fans Also Like'),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 160,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: _relatedArtists.length,
                              itemBuilder: (context, index) {
                                final related = _relatedArtists[index];
                                return GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ArtistDetailScreen(artist: related),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    width: 110,
                                    margin: const EdgeInsets.only(right: 14),
                                    child: Column(
                                      children: [
                                        ArtistAvatar(
                                          artistId: related.id,
                                          artistName: related.name,
                                          imageUrl: related.imageUrl,
                                          radius: 45,
                                          isCircle: true,
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          related.name,
                                          style: const TextStyle(
                                            color: AppTheme.textPrimary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                        ),
                                        if (related.isVerified)
                                          const Padding(
                                            padding: EdgeInsets.only(top: 2),
                                            child: Icon(Icons.verified, color: Colors.blue, size: 14),
                                          ),
                                      ],
                                    ),
                                  ),
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
