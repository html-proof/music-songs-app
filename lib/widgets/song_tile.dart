import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/download_provider.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import 'offline_artwork.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final bool isPlaying;

  const SongTile({
    super.key,
    required this.song,
    this.onTap,
    this.isPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDownloaded = context.watch<DownloadProvider>().isDownloaded(song.id);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isPlaying
            ? AppTheme.accentPurple.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 48,
            height: 48,
            child: OfflineArtwork(
              songId: song.id,
              imageUrl: song.imageUrl,
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
        title: Row(
          children: [
            Expanded(
              child: Text(
                song.name,
                style: TextStyle(
                  color: isPlaying ? AppTheme.accentPurple : AppTheme.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (song.isExplicit)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'E',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (song.type != null && song.type != 'SONG')
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    song.type!,
                    style: const TextStyle(
                      color: AppTheme.accentPurple,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isDownloaded)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: AppTheme.accentPurple,
                        size: 13,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      '${song.artist ?? 'Unknown'} • ${song.album ?? 'Single'}${song.year != null ? ' • ${song.year}' : ''}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${song.language?.toUpperCase() ?? 'MIX'} • ${_formatDuration(song.duration)}',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDownloadButton(context),
            const SizedBox(width: 8),
            isPlaying
                ? const Icon(Icons.equalizer, color: AppTheme.accentPurple)
                : const Icon(
                    Icons.play_arrow_rounded,
                    color: AppTheme.textMuted,
                    size: 26,
                  ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildDownloadButton(BuildContext context) {
    final downloadProvider = context.watch<DownloadProvider>();
    final isDownloaded = downloadProvider.isDownloaded(song.id);
    final isDownloading = downloadProvider.isDownloading(song.id);
    final progress = downloadProvider.progress[song.id] ?? 0.0;

    if (isDownloaded) {
      return const Icon(
        Icons.check_circle_rounded,
        color: AppTheme.accentPurple,
        size: 18,
      );
    }

    if (isDownloading) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2,
          color: AppTheme.accentPurple,
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        downloadProvider.download(song);
      },
      child: const Icon(
        Icons.arrow_circle_down_rounded,
        color: AppTheme.textMuted,
        size: 20,
      ),
    );
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) return '--:--';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }
}
