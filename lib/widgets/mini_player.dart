import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/download_provider.dart';
import '../screens/album_detail_screen.dart';
import '../screens/player_screen.dart';
import '../services/api_service.dart';
import '../services/listening_safety_service.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';
import 'offline_artwork.dart';

class MiniPlayer extends StatefulWidget {
  final bool useSafeArea;
  const MiniPlayer({super.key, this.useSafeArea = true});

  static final Map<String, Album> _albumLookupCache = <String, Album>{};
  static final Map<String, String> _songToAlbumIdCache = <String, String>{};
  static bool _albumNavigationInProgress = false;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  Song? _lastSong;

  Future<void> _openCurrentSongAlbum(
    BuildContext context, {
    required Song song,
    required bool isOffline,
  }) async {
    if (MiniPlayer._albumNavigationInProgress) return;
    MiniPlayer._albumNavigationInProgress = true;
    try {
      final preferredAlbumId =
          ((song.sourceAlbumId ?? '').trim().isNotEmpty
                  ? song.sourceAlbumId
                  : song.albumId)
              ?.trim();
      final fallbackBundle = await _buildLocalFallbackBundle(
        context,
        song: song,
        preferredAlbumId: preferredAlbumId ?? '',
      );

      if (isOffline) {
        if (!context.mounted) return;
        await _openLocalAlbumFallback(
          context,
          bundle: fallbackBundle,
          currentSongId: song.id,
        );
        return;
      }

      try {
        final officialAlbum = await _resolveOfficialAlbum(
          song: song,
          preferredAlbumId: preferredAlbumId ?? '',
        );
        if (officialAlbum != null) {
          if (!context.mounted) return;
          await _openAlbumDetail(context, officialAlbum);
          return;
        }
      } catch (_) {}

      if (!context.mounted) return;
      await _openLocalAlbumFallback(
        context,
        bundle: fallbackBundle,
        currentSongId: song.id,
      );
    } finally {
      MiniPlayer._albumNavigationInProgress = false;
    }
  }

  Future<void> _showAddToPlaylistSheet(BuildContext context, Song song) async {
    final provider = context.read<PlaylistProvider>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final playlists = sheetContext.watch<PlaylistProvider>().playlists;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Add to Playlist',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: AppTheme.accentPurple,
                ),
                title: const Text('Create New Playlist'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final name = await _promptPlaylistName(context);
                  if (name == null || name.trim().isEmpty) return;
                  await provider.createPlaylist(name.trim(), initialSong: song);
                  if (!context.mounted) return;
                },
              ),
              if (playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Text(
                    'No playlists yet. Create one to save songs.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: playlists
                        .map((playlist) {
                          return ListTile(
                            leading: const Icon(Icons.queue_music_rounded),
                            title: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${playlist.songs.length} songs'),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await provider.addSongToPlaylist(
                                playlist.id,
                                song,
                              );
                              if (!context.mounted) return;
                            },
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _promptPlaylistName(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Create Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            counterText: '',
          ),
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim().isEmpty ? null : value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.pop(dialogContext, value.isEmpty ? null : value);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAlbumDetail(BuildContext context, Album album) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
    );
  }

  Future<Album?> _resolveOfficialAlbum({
    required Song song,
    required String preferredAlbumId,
  }) async {
    var albumId = preferredAlbumId.trim();
    if (albumId.isEmpty) {
      albumId = await _fetchOfficialAlbumIdForSong(song);
    }
    if (albumId.isEmpty) return null;

    return _fetchAlbumById(albumId, fallbackSong: song);
  }

  Future<Album?> _fetchAlbumById(
    String albumId, {
    required Song fallbackSong,
  }) async {
    final normalizedId = albumId.trim();
    if (normalizedId.isEmpty) return null;

    final cached = MiniPlayer._albumLookupCache[normalizedId];
    if (cached != null) return cached;

    final payload = await ApiService.getAlbums(id: normalizedId);
    final albumMap = _extractAlbumMapFromPayload(
      payload,
      expectedAlbumId: normalizedId,
    );

    Album album;
    if (albumMap != null) {
      final parsed = Album.fromJson(albumMap);
      album = parsed.id.trim().isNotEmpty
          ? parsed
          : Album(
              id: normalizedId,
              name: parsed.name,
              artist: parsed.artist,
              imageUrl: parsed.imageUrl,
              language: parsed.language,
              songCount: parsed.songCount,
              year: parsed.year,
            );
    } else {
      final fallbackName =
          (fallbackSong.sourceAlbumName ?? fallbackSong.album ?? '').trim();
      if (fallbackName.isEmpty) return null;
      album = Album(
        id: normalizedId,
        name: fallbackName,
        artist: (fallbackSong.sourceAlbumArtist ?? fallbackSong.artist)?.trim(),
        imageUrl: (fallbackSong.sourceAlbumImageUrl ?? fallbackSong.imageUrl)
            ?.trim(),
        language: fallbackSong.language,
      );
    }

    MiniPlayer._albumLookupCache[normalizedId] = album;
    return album;
  }

  Map<String, dynamic>? _extractAlbumMapFromPayload(
    Map<String, dynamic> payload, {
    required String expectedAlbumId,
  }) {
    final data = payload['data'] ?? payload;

    Map<String, dynamic>? pickFromList(List<dynamic> list) {
      final maps = list
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(growable: false);
      if (maps.isEmpty) return null;

      if (expectedAlbumId.trim().isNotEmpty) {
        for (final map in maps) {
          final id = (map['id'] ?? '').toString().trim();
          if (id == expectedAlbumId) {
            return map;
          }
        }
      }
      return maps.first;
    }

    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final looksLikeAlbum =
          (map['name'] ?? map['title'] ?? '').toString().trim().isNotEmpty &&
          map['songs'] is List;
      if (looksLikeAlbum) return map;
      if (map['album'] is Map) {
        return Map<String, dynamic>.from(map['album'] as Map);
      }
      if (map['results'] is List) {
        return pickFromList(map['results'] as List);
      }
      if (map['albums'] is List) {
        return pickFromList(map['albums'] as List);
      }
      if ((map['name'] ?? map['title'] ?? '').toString().trim().isNotEmpty) {
        return map;
      }
      return null;
    }

    if (data is List) {
      return pickFromList(data);
    }
    return null;
  }

  Future<String> _fetchOfficialAlbumIdForSong(Song song) async {
    final songId = song.id.trim();
    if (songId.isEmpty) return '';

    final cached = MiniPlayer._songToAlbumIdCache[songId];
    if (cached != null && cached.trim().isNotEmpty) {
      return cached;
    }

    try {
      final payload = await ApiService.getSong(songId);
      final songMap = _extractSongPayloadMap(payload);
      if (songMap == null) return '';

      final albumId = _extractAlbumIdFromSongMap(songMap);
      if (albumId.isNotEmpty) {
        MiniPlayer._songToAlbumIdCache[songId] = albumId;
      }
      return albumId;
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic>? _extractSongPayloadMap(Map<String, dynamic> payload) {
    final data = payload['data'] ?? payload;
    if (data is Map) {
      if (data['songs'] is List && (data['songs'] as List).isNotEmpty) {
        final first = (data['songs'] as List).first;
        if (first is Map) return Map<String, dynamic>.from(first);
      }
      if (data['results'] is List && (data['results'] as List).isNotEmpty) {
        final first = (data['results'] as List).first;
        if (first is Map) return Map<String, dynamic>.from(first);
      }
      if (data['song'] is Map) {
        return Map<String, dynamic>.from(data['song'] as Map);
      }
      return Map<String, dynamic>.from(data);
    }
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return null;
  }

  String _extractAlbumIdFromSongMap(Map<String, dynamic> songMap) {
    final direct =
        (songMap['sourceAlbumId'] ??
                songMap['source_album_id'] ??
                songMap['albumId'] ??
                songMap['album_id'] ??
                '')
            .toString()
            .trim();
    if (direct.isNotEmpty) return direct;

    final album = songMap['album'];
    if (album is Map) {
      final nested = (album['id'] ?? album['albumId'] ?? '').toString().trim();
      if (nested.isNotEmpty) return nested;
    }
    return '';
  }

  Future<_LocalAlbumBundle> _buildLocalFallbackBundle(
    BuildContext context, {
    required Song song,
    required String preferredAlbumId,
  }) async {
    final offlineMatch = await _findOfflineAlbumGroup(
      song,
      preferredAlbumId: preferredAlbumId,
    );
    if (offlineMatch != null) {
      return _LocalAlbumBundle(
        albumId: offlineMatch.albumId,
        albumName: offlineMatch.albumName,
        artist: offlineMatch.artist,
        imageUrl: offlineMatch.imageUrl,
        songs: offlineMatch.songs
            .map((record) => record.song)
            .toList(growable: false),
      );
    }

    final queue = context.read<PlayerProvider>().queue;
    final fallbackAlbumName =
        (song.sourceAlbumName ?? song.album ?? 'Unknown Album').trim();
    final fallbackArtist = (song.sourceAlbumArtist ?? song.artist)?.trim();
    final fallbackImage =
        (song.sourceAlbumImageUrl ?? song.imageUrl)?.trim().isNotEmpty == true
        ? (song.sourceAlbumImageUrl ?? song.imageUrl)!.trim()
        : null;

    final albumSongs = queue
        .where(
          (queuedSong) => _songBelongsToAlbum(
            queuedSong,
            preferredAlbumId: preferredAlbumId,
            fallbackAlbumName: fallbackAlbumName,
          ),
        )
        .toList(growable: false);

    return _LocalAlbumBundle(
      albumId: preferredAlbumId.isNotEmpty
          ? preferredAlbumId
          : (song.albumId ?? '').trim(),
      albumName: fallbackAlbumName.isEmpty
          ? 'Unknown Album'
          : fallbackAlbumName,
      artist: fallbackArtist,
      imageUrl: fallbackImage,
      songs: albumSongs.isEmpty ? <Song>[song] : albumSongs,
    );
  }

  Future<OfflineAlbumGroup?> _findOfflineAlbumGroup(
    Song song, {
    required String preferredAlbumId,
  }) async {
    try {
      final offlineAlbums = await OfflineService.getOfflineAlbums();
      final wantedId = preferredAlbumId.trim();
      if (wantedId.isNotEmpty) {
        for (final group in offlineAlbums) {
          if (group.albumId.trim() == wantedId) {
            return group;
          }
        }
      }

      final wantedName = _normalizeLookup(
        song.sourceAlbumName ?? song.album ?? '',
      );
      if (wantedName.isEmpty) return null;

      for (final group in offlineAlbums) {
        final groupName = _normalizeLookup(group.albumName);
        if (groupName == wantedName) {
          return group;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _songBelongsToAlbum(
    Song song, {
    required String preferredAlbumId,
    required String fallbackAlbumName,
  }) {
    final expectedId = preferredAlbumId.trim();
    if (expectedId.isNotEmpty) {
      final songAlbumIds = <String>{
        (song.sourceAlbumId ?? '').trim(),
        (song.albumId ?? '').trim(),
      };
      if (songAlbumIds.contains(expectedId)) {
        return true;
      }
    }

    final expectedName = _normalizeLookup(fallbackAlbumName);
    if (expectedName.isEmpty) return false;
    final songAlbumName = _normalizeLookup(
      song.sourceAlbumName ?? song.album ?? '',
    );
    return songAlbumName == expectedName;
  }

  Future<void> _openLocalAlbumFallback(
    BuildContext context, {
    required _LocalAlbumBundle bundle,
    required String currentSongId,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _LocalAlbumFallbackScreen(
          bundle: bundle,
          currentSongId: currentSongId,
        ),
      ),
    );
  }

  String _normalizeLookup(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _openPlayerScreen(BuildContext context) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) => const PlayerScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0, 1.0); // Full slide up
          const end = Offset.zero;
          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: Curves.easeOutQuart));
          final offsetAnimation = animation.drive(tween);

          return SlideTransition(
            position: offsetAnimation,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final currentActive = player.activeSong;
        if (currentActive != null) {
          _lastSong = currentActive;
        }

        final song = _lastSong;
        if (song == null) {
          return const SizedBox.shrink();
        }

        final msg = player.qualityAdjustmentMessage;
        if (msg != null && msg.isNotEmpty) {
          player.consumeQualityAdjustmentMessage();
        }

        final isLoadingNew = player.isLoadingNewSong;
        final isDownloaded = context.watch<DownloadProvider>().isDownloaded(song.id);
        final artworkUrl = song.imageUrl?.trim();
        final subtitle = isLoadingNew
            ? 'Loading...'
            : (song.artist?.trim().isNotEmpty == true
                ? song.artist!.trim()
                : 'Unknown Artist');
        final canSkipPrevious = player.canSkipPrevious;
        final canSkipNext = player.canSkipNext;
        final outputDevice = player.outputDeviceState;
        final interruptionPaused =
            player.isInterruptionActive && !player.isPlaying;

        final body = RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _openPlayerScreen(context),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: OfflineArtwork(
                                            key: ValueKey(
                                              'mini-art-${song.id}-$artworkUrl',
                                            ),
                                            songId: song.id,
                                            imageUrl: artworkUrl,
                                            fit: BoxFit.cover,
                                            placeholder: Container(
                                              color: AppTheme.cardDark,
                                              child: const Icon(
                                                Icons.music_note,
                                                color: AppTheme.textMuted,
                                              ),
                                            ),
                                            errorWidget: Container(
                                              color: AppTheme.cardDark,
                                              child: const Icon(
                                                Icons.music_note,
                                                color: AppTheme.textMuted,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              song.name,
                                              style: const TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Row(
                                              children: [
                                                if (player.isOffline) ...[
                                                  const Icon(
                                                    Icons.wifi_off_rounded,
                                                    color: AppTheme.textMuted,
                                                    size: 12,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  const Text(
                                                    'Offline',
                                                    style: TextStyle(
                                                      color: AppTheme.textMuted,
                                                      fontSize: 10.5,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ] else if (player.isWeakConnection) ...[
                                                  const Icon(
                                                    Icons.signal_cellular_connected_no_internet_4_bar_rounded,
                                                    color: Colors.orangeAccent,
                                                    size: 12,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  const Text(
                                                    'Weak',
                                                    style: TextStyle(
                                                      color: Colors.orangeAccent,
                                                      fontSize: 10.5,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                                if (isDownloaded) ...[
                                                  const Icon(
                                                    Icons.check_circle_rounded,
                                                    color: AppTheme.accentPurple,
                                                    size: 12,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Flexible(
                                                  child: Text(
                                                    subtitle,
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.72,
                                                          ),
                                                      fontSize: 11.3,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (outputDevice
                                                    .isExternal) ...[
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                        ),
                                                    child: Text(
                                                      '•',
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.3,
                                                            ),
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                  ),
                                                  Flexible(
                                                    child: Text(
                                                      outputDevice.name,
                                                      style: const TextStyle(
                                                        color: Color(
                                                          0xFF44D79D,
                                                        ),
                                                        fontSize: 10.5,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        letterSpacing: 0.2,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                                const SizedBox(width: 6),
                                                _MiniOutputIcon(
                                                  device: outputDevice,
                                                  isInterrupted: player
                                                      .isInterruptionActive,
                                                ),
                                                if (interruptionPaused) ...[
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    'Paused',
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.68,
                                                          ),
                                                      fontSize: 10.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              _MiniControlButton(
                                icon: Icons.album_outlined,
                                tooltip: 'Tap album icon to view album',
                                onTap: () => _openCurrentSongAlbum(
                                  context,
                                  song: song,
                                  isOffline: player.isOffline,
                                ),
                              ),
                              _MiniControlButton(
                                icon: Icons.add_circle_outline_rounded,
                                tooltip: 'Add to playlist',
                                onTap: () =>
                                    _showAddToPlaylistSheet(context, song),
                              ),
                              _MiniControlButton(
                                icon: Icons.skip_previous_rounded,
                                tooltip: 'Previous',
                                enabled: canSkipPrevious,
                                onTap: player.skipPrevious,
                              ),
                              _GlassPlayPauseButton(
                                isPlaying: player.isPlaying,
                                isLoading: player.isBuffering || player.isLoadingNewSong,
                                onPressed: player.togglePlayPause,
                              ),
                              _MiniControlButton(
                                icon: Icons.skip_next_rounded,
                                tooltip: 'Next',
                                enabled: canSkipNext,
                                onTap: player.skipNext,
                              ),
                              if (player.isConversationContextEligible ||
                                  player.isConversationMode)
                                _MiniControlButton(
                                  icon: player.isConversationMode
                                      ? Icons.record_voice_over_rounded
                                      : Icons.headset_rounded,
                                  color: player.isConversationMode
                                      ? AppTheme.accentPurple
                                      : null,
                                  tooltip: 'Conversation Mode',
                                  onTap: () => player.toggleConversationMode(),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const _MiniSeekBar(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          if (widget.useSafeArea) {
            return SafeArea(
              top: false,
              left: false,
              right: false,
              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: body,
            );
          } else {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: body,
            );
          }
      },
    );
  }
}

class _GlassPlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final Future<void> Function() onPressed;

  const _GlassPlayPauseButton({
    required this.isPlaying,
    required this.onPressed,
    this.isLoading = false,
  });

  @override
  State<_GlassPlayPauseButton> createState() => _GlassPlayPauseButtonState();
}

class _GlassPlayPauseButtonState extends State<_GlassPlayPauseButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Always tappable: during loading, togglePlayPause() cancels the stuck load.
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: () => widget.onPressed(),
      child: Container(
        width: 52,
        height: 52,
        alignment: Alignment.center,
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.28),
                width: 1.2,
              ),
              boxShadow: _pressed
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: widget.isLoading
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  )
                : Icon(
                    widget.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
          ),
        ),
      ),
    );
  }
}

class _MiniControlButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final Color? color;
  final Future<void> Function() onTap;

  const _MiniControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: 22,
        color: enabled
            ? (color ?? Colors.white.withValues(alpha: 0.92))
            : Colors.white.withValues(alpha: 0.38),
      ),
      onPressed: !enabled ? null : () => onTap(),
      splashRadius: 18,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Simple, clean icon that shows the current audio output device.
///
/// 🎧 Headphones icon → external device connected
/// 📱 Phone icon → playing through device speaker
/// Tap shows device name via tooltip.
class _MiniOutputIcon extends StatelessWidget {
  final AudioOutputRouteState device;
  final bool isInterrupted;

  const _MiniOutputIcon({required this.device, this.isInterrupted = false});

  @override
  Widget build(BuildContext context) {
    final isExternal = device.isExternal;

    final IconData icon;
    final Color iconColor;
    final String tooltip;

    if (isExternal) {
      icon = _iconForOutput(device.type);
      iconColor = const Color(0xFF44D79D); // green
      tooltip = device.name;
    } else {
      icon = Icons.smartphone_rounded;
      iconColor = Colors.white.withValues(alpha: 0.50);
      tooltip = 'Phone Speaker';
    }

    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOut,
        child: Icon(
          icon,
          key: ValueKey('${device.type.name}:$isInterrupted'),
          size: 14,
          color: iconColor,
        ),
      ),
    );
  }

  IconData _iconForOutput(AudioOutputRouteType type) {
    switch (type) {
      case AudioOutputRouteType.wiredHeadphones:
      case AudioOutputRouteType.bluetoothHeadphones:
        return Icons.headphones_rounded;
      case AudioOutputRouteType.carAudio:
        return Icons.directions_car_filled_rounded;
      case AudioOutputRouteType.bluetoothSpeaker:
      case AudioOutputRouteType.externalSpeaker:
        return Icons.speaker_rounded;
      case AudioOutputRouteType.phoneSpeaker:
        return Icons.smartphone_rounded;
      case AudioOutputRouteType.unknown:
        return Icons.graphic_eq_rounded;
    }
  }
}

class _MiniSeekBar extends StatefulWidget {
  const _MiniSeekBar();

  @override
  State<_MiniSeekBar> createState() => _MiniSeekBarState();
}

class _MiniSeekBarState extends State<_MiniSeekBar> {
  double? _dragRatio;

  double _ratioFromPosition(Offset localPosition, double width) {
    if (width <= 0) return 0;
    return (localPosition.dx / width).clamp(0.0, 1.0);
  }

  Future<void> _seekByRatio(
    double ratio,
    int totalMs, {
    bool immediate = false,
  }) async {
    if (totalMs <= 0) return;
    final targetMs = (totalMs * ratio).round();
    await context.read<PlayerProvider>().seek(
      Duration(milliseconds: targetMs),
      immediate: immediate,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (int, int, bool)>(
      selector: (_, p) =>
          (p.position.inMilliseconds, p.duration.inMilliseconds, p.isBuffering),
      builder: (context, data, _) {
        final positionMs = data.$1;
        final totalMs = data.$2;
        final isBuffering = data.$3;

        final safeRatio = totalMs <= 0
            ? 0.0
            : (positionMs / totalMs).clamp(0.0, 1.0);
        final displayRatio = (_dragRatio ?? safeRatio).clamp(0.0, 1.0);

        return Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final thumbLeft = (width - 6) * displayRatio;

                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown: isBuffering
                      ? null
                      : (details) async {
                          final ratio = _ratioFromPosition(
                            details.localPosition,
                            width,
                          );
                          setState(() => _dragRatio = ratio);
                          context.read<PlayerProvider>().setSeeking(true);
                          await _seekByRatio(ratio, totalMs, immediate: true);
                          if (mounted) {
                            setState(() => _dragRatio = null);
                            context.read<PlayerProvider>().setSeeking(false);
                          }
                        },
                  onHorizontalDragStart: isBuffering
                      ? null
                      : (_) {
                          context.read<PlayerProvider>().setSeeking(true);
                        },
                  onHorizontalDragUpdate: isBuffering
                      ? null
                      : (details) {
                          final ratio = _ratioFromPosition(
                            details.localPosition,
                            width,
                          );
                          setState(() => _dragRatio = ratio);
                          _seekByRatio(ratio, totalMs, immediate: false);
                        },
                  onHorizontalDragEnd: isBuffering
                      ? null
                      : (_) async {
                          if (_dragRatio != null) {
                            await _seekByRatio(_dragRatio!, totalMs, immediate: true);
                          }
                          if (mounted) {
                            setState(() => _dragRatio = null);
                            context.read<PlayerProvider>().setSeeking(false);
                          }
                        },
                  onHorizontalDragCancel: isBuffering
                      ? null
                      : () {
                          if (mounted) {
                            setState(() => _dragRatio = null);
                            context.read<PlayerProvider>().setSeeking(false);
                          }
                        },
                  child: SizedBox(
                    height: 12,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 2,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                        Container(
                          height: 2,
                          width: width * displayRatio,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppTheme.accentPurple,
                                AppTheme.accentPurple,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                        Positioned(
                          left: thumbLeft.clamp(
                            0.0,
                            (width - 6).clamp(0.0, width),
                          ),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.9),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 2,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

@immutable
class _LocalAlbumBundle {
  final String albumId;
  final String albumName;
  final String? artist;
  final String? imageUrl;
  final List<Song> songs;

  const _LocalAlbumBundle({
    required this.albumId,
    required this.albumName,
    required this.artist,
    required this.imageUrl,
    required this.songs,
  });
}

class _LocalAlbumFallbackScreen extends StatelessWidget {
  final _LocalAlbumBundle bundle;
  final String currentSongId;

  const _LocalAlbumFallbackScreen({
    required this.bundle,
    required this.currentSongId,
  });

  @override
  Widget build(BuildContext context) {
    final displayAlbumName = bundle.albumName.trim().isEmpty
        ? 'Unknown Album'
        : bundle.albumName.trim();
    final displayArtist = (bundle.artist ?? '').trim();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'ALBUM',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _LocalAlbumArtwork(
                  albumId: bundle.albumId,
                  imageUrl: bundle.imageUrl,
                  size: 210,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  displayAlbumName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (displayArtist.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: Consumer<PlayerProvider>(
                  builder: (context, player, _) {
                    final activeSongId =
                        (player.currentSong?.id ?? currentSongId).trim();
                    final songs = bundle.songs;
                    if (songs.isEmpty) {
                      return const Center(
                        child: Text(
                          'No offline songs available for this album.',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        final track = songs[index];
                        final isActive = track.id.trim() == activeSongId;
                        final subtitle = (track.artist ?? '').trim().isNotEmpty
                            ? track.artist!.trim()
                            : 'Unknown Artist';

                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppTheme.accentPurple.withValues(alpha: 0.18)
                                : AppTheme.surfaceDark.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            leading: Text(
                              '${index + 1}'.padLeft(2, '0'),
                              style: TextStyle(
                                color: isActive
                                    ? AppTheme.accentPurple
                                    : AppTheme.textMuted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            title: Text(
                              track.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isActive
                                    ? AppTheme.accentPurple
                                    : AppTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Icon(
                              isActive
                                  ? Icons.graphic_eq_rounded
                                  : Icons.play_arrow_rounded,
                              color: isActive
                                  ? AppTheme.accentPurple
                                  : AppTheme.textMuted,
                            ),
                            onTap: () {
                              context.read<PlayerProvider>().play(
                                track,
                                playlist: songs,
                                index: index,
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalAlbumArtwork extends StatelessWidget {
  final String? albumId;
  final String? imageUrl;
  final double size;

  const _LocalAlbumArtwork({
    this.albumId,
    required this.imageUrl,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return OfflineArtwork(
      albumId: albumId,
      imageUrl: imageUrl,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: _placeholder(),
      errorWidget: _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: AppTheme.cardDark,
      child: const Icon(
        Icons.album_rounded,
        color: AppTheme.textMuted,
        size: 52,
      ),
    );
  }
}
