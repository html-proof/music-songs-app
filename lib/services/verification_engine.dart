import '../models/song.dart';

class VerificationEngine {
  static const double threshold = 70.0;

  static double calculateConfidence(Song candidate, Song target) {
    // 1. ISRC Match (Highest Priority)
    if (candidate.isrc != null && target.isrc != null &&
        candidate.isrc!.isNotEmpty && target.isrc!.isNotEmpty) {
      if (candidate.isrc!.toLowerCase().trim() == target.isrc!.toLowerCase().trim()) {
        return 100.0; // Perfect unique key match
      } else {
        return 0.0; // Explicit mismatch on standard identifier
      }
    }

    // 2. MusicBrainz ID Match (Very High Priority)
    if (candidate.musicbrainzId != null && target.musicbrainzId != null &&
        candidate.musicbrainzId!.isNotEmpty && target.musicbrainzId!.isNotEmpty) {
      if (candidate.musicbrainzId!.toLowerCase().trim() == target.musicbrainzId!.toLowerCase().trim()) {
        return 100.0; // Perfect match
      } else {
        return 0.0; // Explicit mismatch on standard identifier
      }
    }

    double score = 0.0;

    // 3. Title Match (Very High)
    final cTitle = _cleanMetadataString(candidate.name);
    final tTitle = _cleanMetadataString(target.name);
    if (cTitle == tTitle) {
      score += 40.0;
    } else if (cTitle.contains(tTitle) || tTitle.contains(cTitle)) {
      score += 20.0;
    } else {
      return 0.0; // Titles are completely different
    }

    // 4. Artist Match (Very High)
    final cArtist = _cleanMetadataString(candidate.artist ?? '');
    final tArtist = _cleanMetadataString(target.artist ?? '');
    if (tArtist.isNotEmpty && cArtist.isNotEmpty) {
      final tArtists = tArtist.split(',').map((e) => e.trim()).toList();
      final cArtists = cArtist.split(',').map((e) => e.trim()).toList();
      int matches = 0;
      for (final ta in tArtists) {
        if (ta.isNotEmpty && cArtists.any((ca) => ca == ta || ca.contains(ta) || ta.contains(ca))) {
          matches++;
        }
      }
      if (matches > 0) {
        score += 40.0 * (matches / tArtists.length);
      } else {
        score -= 30.0; // Penalty for complete artist mismatch
      }
    } else if (tArtist.isNotEmpty || cArtist.isNotEmpty) {
      score -= 20.0;
    }

    // 5. Album Match (High)
    final cAlbum = _cleanMetadataString(candidate.album ?? '');
    final tAlbum = _cleanMetadataString(target.album ?? '');
    if (tAlbum.isNotEmpty && cAlbum.isNotEmpty) {
      if (cAlbum == tAlbum) {
        score += 15.0;
      } else if (cAlbum.contains(tAlbum) || tAlbum.contains(cAlbum)) {
        score += 7.0;
      }
    }

    // 6. Duration Match (High)
    if (candidate.duration != null && target.duration != null && candidate.duration! > 0 && target.duration! > 0) {
      final diff = (candidate.duration! - target.duration!).abs();
      if (diff <= 5) {
        score += 20.0;
      } else if (diff <= 12) {
        score += 10.0;
      } else if (diff > 20) {
        score -= 40.0; // Penalty for large duration difference (cover, live, preview, etc.)
      }
    }

    // 7. Language Match (Medium)
    final cLang = (candidate.language ?? '').toLowerCase().trim();
    final tLang = (target.language ?? '').toLowerCase().trim();
    if (tLang.isNotEmpty && cLang.isNotEmpty) {
      if (cLang == tLang) {
        score += 10.0;
      } else {
        score -= 40.0; // Heavy penalty for language mismatch
      }
    }

    // 8. Explicit/Non-Explicit Version Match (Medium)
    if (candidate.isExplicit != target.isExplicit) {
      score -= 15.0;
    }

    // 9. Version Type Mismatch Checks (Remix, Live, Acoustic, Cover)
    if (_isRemix(target.name) != _isRemix(candidate.name)) {
      score -= 50.0; // Remix mismatch
    }
    if (_isLive(target.name) != _isLive(candidate.name)) {
      score -= 50.0; // Live mismatch
    }
    if (_isAcoustic(target.name) != _isAcoustic(candidate.name)) {
      score -= 50.0; // Acoustic mismatch
    }
    if (_isCover(target.name) != _isCover(candidate.name)) {
      score -= 50.0; // Cover mismatch
    }

    // 10. Release Year Match (Low)
    final cYear = candidate.year?.trim();
    final tYear = target.year?.trim();
    if (cYear != null && tYear != null && cYear.isNotEmpty && tYear.isNotEmpty) {
      if (cYear == tYear) {
        score += 5.0;
      }
    }

    // 11. Popularity (Low)
    if (candidate.popularity != null) {
      score += (candidate.popularity! / 100.0) * 5.0;
    }

    return score;
  }

  static String _cleanMetadataString(String str) {
    return str
        .toLowerCase()
        .replaceAll(RegExp(r'\(feat\..*?\)|\[feat\..*?\]|\(with.*?\)|\[with.*?\]'), '')
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isRemix(String title) {
    final lower = title.toLowerCase();
    return lower.contains('remix') || lower.contains(' mix') || lower.contains('re-mix') || lower.contains('re-recorded');
  }

  static bool _isLive(String title) {
    final lower = title.toLowerCase();
    return lower.contains('live') || lower.contains('concert') || lower.contains('tour');
  }

  static bool _isAcoustic(String title) {
    final lower = title.toLowerCase();
    return lower.contains('acoustic') || lower.contains('unplugged') || lower.contains('stripped');
  }

  static bool _isCover(String title) {
    final lower = title.toLowerCase();
    return lower.contains('cover') || lower.contains('tribute') || lower.contains('originally performed by');
  }
}
