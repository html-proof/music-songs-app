import '../models/album.dart';
import '../models/song.dart';
import 'content_filter.dart';

class AlbumFilter {
  /// Validates an album to ensure it meets quality requirements and contains playable tracks.
  ///
  /// Rejects the album if:
  /// - The title is empty or is blocked by ContentFilter.
  /// - The ID is empty.
  /// - The artwork is missing or empty.
  /// - No artist information exists.
  /// - songCount is explicitly <= 0.
  /// - (If tracks are provided) The list is empty, or all tracks are unplayable, previews, or samples.
  static bool isValidAlbum(Album album, {List<Song>? tracks}) {
    final title = album.name.trim();
    if (title.isEmpty) return false;

    // Title validation using content filters
    if (!ContentFilter.isAllowedSongTitle(title)) return false;

    final id = album.id.trim();
    if (id.isEmpty) return false;

    // Reject missing/empty artwork
    if (album.imageUrl == null || album.imageUrl!.trim().isEmpty) return false;

    // Reject missing/empty artist info
    if (album.artist == null || album.artist!.trim().isEmpty) return false;

    // Reject song counts <= 0
    if (album.songCount != null && album.songCount! <= 0) return false;

    // Detailed tracks validation
    if (tracks != null) {
      if (tracks.isEmpty) return false;

      final playableTracks = tracks.where((track) {
        if (track.name.trim().isEmpty) return false;
        
        final url = (track.streamUrl ?? '').trim();
        if (url.isEmpty) return false;

        // Filter out previews, samples, or snippet tracks
        final lowerTitle = track.name.toLowerCase();
        final lowerUrl = url.toLowerCase();
        if (lowerTitle.contains('preview') ||
            lowerTitle.contains('sample') ||
            lowerTitle.contains('snippet')) {
          return false;
        }
        if (lowerUrl.contains('preview') ||
            lowerUrl.contains('sample') ||
            lowerUrl.contains('snippet')) {
          return false;
        }

        return true;
      });

      if (playableTracks.isEmpty) return false;
    }

    return true;
  }

  /// Filters and deduplicates a list of albums.
  ///
  /// Discards invalid albums and merges entries sharing the same Title & Artist.
  /// Always keeps the version with the highest song count or most complete metadata.
  static List<Album> filterAndDeduplicate(List<Album> albums) {
    final uniqueAlbums = <String, Album>{};

    for (final album in albums) {
      if (!isValidAlbum(album)) continue;

      // Generate a normalized title + artist signature to detect duplicates
      final titleKey = album.name.toLowerCase()
          .replaceAll(RegExp(r'\(.*?\)'), '')
          .replaceAll(RegExp(r'\[.*?\]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final artistKey = (album.artist ?? '').toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final signature = '$titleKey|$artistKey';

      final existing = uniqueAlbums[signature];
      if (existing == null) {
        uniqueAlbums[signature] = album;
      } else {
        // Resolve duplicates by songCount first
        final existingCount = existing.songCount ?? 0;
        final currentCount = album.songCount ?? 0;

        if (currentCount > existingCount) {
          uniqueAlbums[signature] = album;
        } else if (currentCount == existingCount) {
          // Break tie with metadata completeness score
          final scoreExisting = _completenessScore(existing);
          final scoreCurrent = _completenessScore(album);
          if (scoreCurrent > scoreExisting) {
            uniqueAlbums[signature] = album;
          }
        }
      }
    }

    return uniqueAlbums.values.toList(growable: false);
  }

  static int _completenessScore(Album album) {
    var score = 0;
    if ((album.imageUrl ?? '').trim().isNotEmpty) score += 3;
    if ((album.artist ?? '').trim().isNotEmpty) score += 2;
    if ((album.year ?? '').trim().isNotEmpty) score += 2;
    if ((album.language ?? '').trim().isNotEmpty) score += 1;
    if (album.isOfficial) score += 2;
    return score;
  }
}
