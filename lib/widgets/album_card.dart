import 'package:flutter/material.dart';
import '../models/album.dart';
import '../theme/app_theme.dart';
import 'offline_artwork.dart';

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;

  const AlbumCard({super.key, required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(right: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: OfflineArtwork(
                albumId: album.id,
                imageUrl: album.imageUrl,
                width: 140,
                height: 140,
                fit: BoxFit.cover,
                placeholder: Container(
                  color: Colors.white10,
                  child: const Icon(Icons.album, color: AppTheme.textMuted),
                ),
                errorWidget: const Icon(Icons.album, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              album.artist ?? 'Various Artists',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (album.type != null && album.type != 'ALBUM')
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accentPurple.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      album.type!,
                      style: const TextStyle(
                        color: AppTheme.accentPurple,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                Text(
                  '${album.year ?? '----'} • ${album.language?.toUpperCase() ?? 'MIX'}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
