import 'package:flutter/material.dart';
import '../models/artist.dart';
import '../theme/app_theme.dart';
import 'artist_avatar.dart';

class ArtistCard extends StatelessWidget {
  final Artist artist;
  final VoidCallback onTap;

  const ArtistCard({
    super.key,
    required this.artist,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArtistAvatar(
              artistId: artist.id,
              artistName: artist.name,
              imageUrl: artist.imageUrl,
              radius: 52,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    artist.name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (artist.isVerified)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.verified, color: Colors.blue, size: 14),
                  ),
              ],
            ),
            if (artist.role != null && artist.role!.isNotEmpty)
              Text(
                artist.role!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
