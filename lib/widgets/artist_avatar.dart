import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/artist_image_service.dart';
import '../theme/app_theme.dart';

class ArtistAvatar extends StatefulWidget {
  final String artistId;
  final String artistName;
  final String? imageUrl;
  final double radius;
  final BoxFit fit;
  final bool isCircle;

  const ArtistAvatar({
    super.key,
    required this.artistId,
    required this.artistName,
    this.imageUrl,
    this.radius = 24,
    this.fit = BoxFit.cover,
    this.isCircle = true,
  });

  @override
  State<ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<ArtistAvatar> with SingleTickerProviderStateMixin {
  String? _resolvedImageUrl;
  bool _loading = false;
  StreamSubscription? _updateSubscription;
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _shimmerAnimation = Tween<double>(begin: 0.05, end: 0.18).animate(_shimmerController);

    _resolveImage();
    _subscribeToUpdates();
  }

  @override
  void didUpdateWidget(covariant ArtistAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistId != widget.artistId ||
        oldWidget.artistName != widget.artistName ||
        oldWidget.imageUrl != widget.imageUrl) {
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    _shimmerController.dispose();
    super.dispose();
  }

  void _subscribeToUpdates() {
    _updateSubscription?.cancel();
    _updateSubscription = ArtistImageService.onArtistImageUpdated.listen((event) {
      final eventId = event['artistId'] ?? '';
      final eventName = event['artistName'] ?? '';
      final eventUrl = event['imageUrl'] ?? '';
      final cleanName = widget.artistName.trim().toLowerCase();

      if ((eventId.isNotEmpty && eventId == widget.artistId) ||
          (eventName.isNotEmpty && eventName == cleanName)) {
        if (mounted) {
          setState(() {
            _resolvedImageUrl = eventUrl;
            _loading = false;
          });
        }
      }
    });
  }

  Future<void> _resolveImage() async {
    final originalUrl = (widget.imageUrl ?? '').trim();
    if (originalUrl.isNotEmpty) {
      if (mounted) {
        setState(() {
          _resolvedImageUrl = originalUrl;
          _loading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
      });
    }

    try {
      final cachedUrl = await ArtistImageService.getArtistImageUrl(
        widget.artistId,
        widget.artistName,
      );

      if (mounted) {
        setState(() {
          _resolvedImageUrl = cachedUrl;
          _loading = cachedUrl == null; // remains loading if no cache exists yet (searching in background)
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isCircle) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: _buildAvatarContent(),
      );
    }

    final size = widget.radius * 2;

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.cardDark,
      ),
      child: ClipOval(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: _buildAvatarContent(),
        ),
      ),
    );
  }

  Widget _buildAvatarContent() {
    final size = widget.isCircle ? widget.radius * 2 : null;

    if (_loading) {
      return _buildShimmerPlaceholder();
    }

    final url = (_resolvedImageUrl ?? '').trim();
    if (url.isEmpty) {
      return _buildDefaultPlaceholder();
    }

    return CachedNetworkImage(
      key: ValueKey<String>(url),
      imageUrl: url,
      width: size,
      height: size,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 500),
      fadeOutDuration: const Duration(milliseconds: 500),
      placeholder: (context, url) => _buildShimmerPlaceholder(),
      errorWidget: (context, url, error) => _buildDefaultPlaceholder(),
    );
  }

  Widget _buildShimmerPlaceholder() {
    final size = widget.isCircle ? widget.radius * 2 : null;
    return AnimatedBuilder(
      animation: _shimmerAnimation,
      builder: (context, child) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: _shimmerAnimation.value),
            shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.person_rounded,
                color: AppTheme.textMuted.withValues(alpha: 0.4),
                size: widget.isCircle ? widget.radius * 0.95 : 48,
              ),
              if (!widget.isCircle) ...[
                const SizedBox(height: 12),
                Text(
                  'Searching artist image...',
                  style: TextStyle(
                    color: AppTheme.textMuted.withValues(alpha: 0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDefaultPlaceholder() {
    final size = widget.isCircle ? widget.radius * 2 : null;
    return Container(
      width: size,
      height: size,
      color: AppTheme.surfaceDark,
      alignment: Alignment.center,
      child: Icon(
        Icons.person_rounded,
        color: AppTheme.textMuted,
        size: widget.isCircle ? widget.radius * 0.95 : 48,
      ),
    );
  }
}
