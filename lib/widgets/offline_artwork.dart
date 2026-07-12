import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';

class OfflineArtwork extends StatefulWidget {
  static final Map<String, String> _artworkPathCache = {};

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
    _initOrCheck();
  }

  @override
  void didUpdateWidget(covariant OfflineArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.playlistId != widget.playlistId ||
        oldWidget.imageUrl != widget.imageUrl) {
      _initOrCheck();
    }
  }

  void _initOrCheck() {
    final keyString = widget.songId ?? widget.imageUrl ?? widget.albumId ?? widget.playlistId ?? '';
    final cachedPath = OfflineArtwork._artworkPathCache[keyString];
    if (cachedPath != null) {
      _localFile = File(cachedPath);
      _checked = true;
    } else {
      _localFile = null;
      _checked = false;
      _checkLocalFile();
    }
  }

  Future<void> _checkLocalFile() async {
    final keyString = widget.songId ?? widget.imageUrl ?? widget.albumId ?? widget.playlistId ?? '';
    try {
      String? path;
      if (widget.songId != null && widget.songId!.isNotEmpty) {
        final dirPath = await DownloadService.getDownloadsDirPath();
        final songFile = File('$dirPath/songs/${widget.songId}/artwork.jpg');
        if (await songFile.exists()) {
          path = songFile.path;
        } else {
          final legacyFile = File('$dirPath/${widget.songId}.jpg');
          if (await legacyFile.exists()) {
            path = legacyFile.path;
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

      if (path != null) {
        OfflineArtwork._artworkPathCache[keyString] = path;
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
