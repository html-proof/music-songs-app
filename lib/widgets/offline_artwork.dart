import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';

class OfflineArtwork extends StatefulWidget {
  final String? songId;
  final String? albumId;
  final String? playlistId;
  final String? imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;
  final BorderRadius? borderRadius;

  const OfflineArtwork({
    super.key,
    this.songId,
    this.albumId,
    this.playlistId,
    this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.borderRadius,
  });

  @override
  State<OfflineArtwork> createState() => _OfflineArtworkState();
}

class _OfflineArtworkState extends State<OfflineArtwork> {
  File? _localFile;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _checkLocalFile();
  }

  @override
  void didUpdateWidget(covariant OfflineArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.playlistId != widget.playlistId ||
        oldWidget.imageUrl != widget.imageUrl) {
      _checkLocalFile();
    }
  }

  Future<void> _checkLocalFile() async {
    try {
      String? path;
      if (widget.songId != null && widget.songId!.isNotEmpty) {
        // For songs, we use the comprehensive resolution service
        // which handles fallbacks to album and artist artwork.
        // Note: We'd need a Song object here, but if we only have IDs,
        // we'll have to resolve manually or pass the Song object to the widget.
        // Since we are refactoring the widget, we'll assume songId is the primary key.

        // For now, we can't use ArtworkService.getLocalArtworkPath directly
        // because it requires a Song object. We'll implement a simplified version
        // here or update the widget to take a Song object.

        // Let's implement the folder check here.
        final dirPath = await DownloadService.getDownloadsDirPath();
        final songFile = File('$dirPath/songs/${widget.songId}/artwork.jpg');
        if (await songFile.exists()) {
          path = songFile.path;
        } else {
          final legacyFile = File('$dirPath/${widget.songId}.jpg');
          if (await legacyFile.exists()) {
            path = legacyFile.path; // Migration happens in ArtworkService.getLocalArtworkPath
          }
        }
      }

      if (path == null && widget.albumId != null && widget.albumId!.isNotEmpty) {
        final dirPath = await DownloadService.getDownloadsDirPath();
        final albumFile = File('$dirPath/albums/${widget.albumId}.jpg');
        if (await albumFile.exists()) {
          path = albumFile.path;
        } else {
          final legacyAlbumFile = File('$dirPath/album_${widget.albumId}.jpg');
          if (await legacyAlbumFile.exists()) {
            path = legacyAlbumFile.path;
          }
        }
      }

      if (path == null && widget.playlistId != null && widget.playlistId!.isNotEmpty) {
        final dirPath = await DownloadService.getDownloadsDirPath();
        final playlistFile = File('$dirPath/playlists/${widget.playlistId}.jpg');
        if (await playlistFile.exists()) {
          path = playlistFile.path;
        } else {
          final legacyPlaylistFile = File('$dirPath/playlist_${widget.playlistId}.jpg');
          if (await legacyPlaylistFile.exists()) {
            path = legacyPlaylistFile.path;
          }
        }
      }

      if (mounted) {
        setState(() {
          _localFile = path != null ? File(path) : null;
          _checked = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checked = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget imageWidget;

    if (_localFile != null) {
      imageWidget = Image.file(
        _localFile!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) => _buildFallbackOrError(),
      );
    } else if (!_checked) {
      imageWidget = widget.placeholder ?? _buildDefaultPlaceholder();
    } else {
      final url = (widget.imageUrl ?? '').trim();
      if (url.isEmpty) {
        imageWidget = widget.errorWidget ?? _buildDefaultPlaceholder();
      } else {
        imageWidget = CachedNetworkImage(
          imageUrl: url,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          placeholder: (context, url) => widget.placeholder ?? _buildDefaultPlaceholder(),
          errorWidget: (context, url, error) => widget.errorWidget ?? _buildDefaultPlaceholder(),
        );
      }
    }

    final keyString = widget.songId ?? widget.imageUrl ?? widget.albumId ?? widget.playlistId ?? '';

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: SizedBox(
        key: ValueKey(keyString),
        width: widget.width,
        height: widget.height,
        child: widget.borderRadius != null
            ? ClipRRect(
                borderRadius: widget.borderRadius!,
                child: imageWidget,
              )
            : imageWidget,
      ),
    );
  }

  Widget _buildFallbackOrError() {
    final url = (widget.imageUrl ?? '').trim();
    if (url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        placeholder: (context, url) => widget.placeholder ?? _buildDefaultPlaceholder(),
        errorWidget: (context, url, error) => widget.errorWidget ?? _buildDefaultPlaceholder(),
      );
    }
    return widget.errorWidget ?? _buildDefaultPlaceholder();
  }

  Widget _buildDefaultPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: AppTheme.surfaceDark,
      child: const Icon(
        Icons.music_note_rounded,
        color: AppTheme.textMuted,
        size: 32,
      ),
    );
  }
}
