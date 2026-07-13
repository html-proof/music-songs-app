import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SpotifyProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool isLoading;
  final bool isBuffering;
  final ValueChanged<Duration> onChanged;
  final ValueChanged<Duration> onChangeEnd;

  const SpotifyProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.isLoading,
    required this.isBuffering,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<SpotifyProgressBar> createState() => _SpotifyProgressBarState();
}

class _SpotifyProgressBarState extends State<SpotifyProgressBar> with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerController;
  bool _isDragging = false;
  double _dragValue = 0.0;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  double _getFraction(Duration pos) {
    if (widget.duration == Duration.zero) return 0.0;
    return (pos.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0);
  }

  void _handleDragStart(DragStartDetails details, BoxConstraints constraints) {
    setState(() {
      _isDragging = true;
    });
    _updateDragValue(details.localPosition.dx, constraints.maxWidth);
  }

  void _handleDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    _updateDragValue(details.localPosition.dx, constraints.maxWidth);
  }

  void _handleDragEnd(DragEndDetails details) {
    setState(() {
      _isDragging = false;
    });
    final Duration seekPos = Duration(
      milliseconds: (_dragValue * widget.duration.inMilliseconds).round(),
    );
    widget.onChangeEnd(seekPos);
  }

  void _handleTapDown(TapDownDetails details, BoxConstraints constraints) {
    _updateDragValue(details.localPosition.dx, constraints.maxWidth);
    final Duration seekPos = Duration(
      milliseconds: (_dragValue * widget.duration.inMilliseconds).round(),
    );
    widget.onChangeEnd(seekPos);
  }

  void _updateDragValue(double localX, double width) {
    final double val = (localX / width).clamp(0.0, 1.0);
    setState(() {
      _dragValue = val;
    });
    final Duration dragPos = Duration(
      milliseconds: (val * widget.duration.inMilliseconds).round(),
    );
    widget.onChanged(dragPos);
  }

  @override
  Widget build(BuildContext context) {
    final double playedFraction = _isDragging ? _dragValue : _getFraction(widget.position);
    final double bufferedFraction = _getFraction(widget.bufferedPosition);

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onHorizontalDragStart: (details) => _handleDragStart(details, constraints),
          onHorizontalDragUpdate: (details) => _handleDragUpdate(details, constraints),
          onHorizontalDragEnd: _handleDragEnd,
          onTapDown: (details) => _handleTapDown(details, constraints),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 32, // Padding area for easy touches
            width: double.infinity,
            alignment: Alignment.center,
            child: AnimatedBuilder(
              animation: _shimmerController,
              builder: (context, child) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, 32),
                  painter: _ProgressBarPainter(
                    playedFraction: playedFraction,
                    bufferedFraction: bufferedFraction,
                    isLoading: widget.isLoading,
                    isBuffering: widget.isBuffering,
                    shimmerProgress: _shimmerController.value,
                    isDragging: _isDragging,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  final double playedFraction;
  final double bufferedFraction;
  final bool isLoading;
  final bool isBuffering;
  final double shimmerProgress;
  final bool isDragging;

  _ProgressBarPainter({
    required this.playedFraction,
    required this.bufferedFraction,
    required this.isLoading,
    required this.isBuffering,
    required this.shimmerProgress,
    required this.isDragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double centerY = size.height / 2;
    final double trackHeight = 4.0;
    final double width = size.width;

    final RRect trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - trackHeight / 2, width, trackHeight),
      const Radius.circular(2),
    );

    // 1. Draw Inactive Background Track
    final Paint backgroundPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(trackRect, backgroundPaint);

    if (isLoading) {
      // 2. Draw Loading Shimmer across the entire track
      final Paint shimmerPaint = Paint()
        ..shader = _createShimmerShader(0, width, centerY)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(trackRect, shimmerPaint);
      return;
    }

    // 3. Draw Buffered Secondary Track
    if (bufferedFraction > 0.0) {
      final RRect bufferedRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - trackHeight / 2, width * bufferedFraction, trackHeight),
        const Radius.circular(2),
      );
      final Paint bufferedPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(bufferedRect, bufferedPaint);
    }

    // 4. Draw Played Primary Track
    if (playedFraction > 0.0) {
      final RRect playedRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - trackHeight / 2, width * playedFraction, trackHeight),
        const Radius.circular(2),
      );
      final Paint playedPaint = Paint()
        ..color = AppTheme.accentPurple
        ..style = PaintingStyle.fill;
      canvas.drawRRect(playedRect, playedPaint);
    }

    // 5. Draw Shimmer for Buffering (from played to buffered fraction, or on unplayed track)
    if (isBuffering && playedFraction < 1.0) {
      final double startX = width * playedFraction;
      final double endX = width * (bufferedFraction > playedFraction ? bufferedFraction : 1.0);
      final RRect bufferingRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(startX, centerY - trackHeight / 2, endX - startX, trackHeight),
        const Radius.circular(2),
      );
      final Paint bufferingPaint = Paint()
        ..shader = _createShimmerShader(startX, endX, centerY)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(bufferingRect, bufferingPaint);
    }

    // 6. Draw Scrubbing Thumb
    final double thumbRadius = isDragging ? 7.0 : 5.0;
    final double thumbX = width * playedFraction;
    final Paint thumbPaint = Paint()
      ..color = AppTheme.accentPurple
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(thumbX, centerY), thumbRadius, thumbPaint);
  }

  Shader _createShimmerShader(double startX, double endX, double centerY) {
    final double length = endX - startX;
    if (length <= 0.0) return const LinearGradient(colors: [Colors.transparent, Colors.transparent]).createShader(Rect.zero);

    final double shimmerCenter = startX + (length * 2 * shimmerProgress) - length;
    
    return LinearGradient(
      colors: [
        Colors.white.withValues(alpha: 0.1),
        Colors.white.withValues(alpha: 0.55),
        Colors.white.withValues(alpha: 0.1),
      ],
      stops: const [0.3, 0.5, 0.7],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ).createShader(
      Rect.fromLTRB(shimmerCenter - length / 2, centerY - 2, shimmerCenter + length / 2, centerY + 2),
    );
  }

  @override
  bool shouldRepaint(covariant _ProgressBarPainter oldDelegate) {
    return oldDelegate.playedFraction != playedFraction ||
        oldDelegate.bufferedFraction != bufferedFraction ||
        oldDelegate.isLoading != isLoading ||
        oldDelegate.isBuffering != isBuffering ||
        oldDelegate.shimmerProgress != shimmerProgress ||
        oldDelegate.isDragging != isDragging;
  }
}
