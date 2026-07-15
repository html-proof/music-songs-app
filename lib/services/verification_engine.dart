import '../models/song.dart';

class VerificationEngine {
  static const double threshold = 90.0; // Strict 90% threshold for Spotify-quality verification

  static double calculateConfidence(Song candidate, Song target) {
    // 1. ISRC Match (Highest Priority)
    if (candidate.isrc != null && target.isrc != null &&
        candidate.isrc!.isNotEmpty && target.isrc!.isNotEmpty) {
      if (candidate.isrc!.toLowerCase().trim() == target.isrc!.toLowerCase().trim()) {
        return 100.0; // Perfect match
      } else {
        return 0.0; // Hard reject on identifier mismatch
      }
    }

    // 2. MusicBrainz ID Match
    if (candidate.musicbrainzId != null && target.musicbrainzId != null &&
        candidate.musicbrainzId!.isNotEmpty && target.musicbrainzId!.isNotEmpty) {
      if (candidate.musicbrainzId!.toLowerCase().trim() == target.musicbrainzId!.toLowerCase().trim()) {
        return 100.0; // Perfect match
      } else {
        return 0.0; // Hard reject on identifier mismatch
      }
    }

    double titleScore = 0.0;
    double artistScore = 0.0;
    double albumScore = 0.0;
    double durationScore = 0.0;
    double languageScore = 0.0;

    // 3. Title Check (35%)
    final cTitle = _cleanMetadataString(candidate.name);
    final tTitle = _cleanMetadataString(target.name);
    if (cTitle == tTitle) {
      titleScore = 35.0;
    } else if (cTitle.contains(tTitle) || tTitle.contains(cTitle)) {
      titleScore = 20.0;
    } else {
      return 0.0; // Hard reject: titles are completely different
    }

    // 4. Artist Check (35%)
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
        artistScore = 35.0 * (matches / tArtists.length);
      } else {
        artistScore = 0.0; // Complete artist mismatch, give 0 points instead of hard reject
      }
    } else if (tArtist.isNotEmpty || cArtist.isNotEmpty) {
      artistScore = 0.0; // Mismatch between empty and non-empty artists, give 0 points instead of hard reject
    } else {
      artistScore = 35.0; // Both empty (fallback case)
    }

    // 5. Album Check (15%)
    final cAlbum = _cleanMetadataString(candidate.album ?? '');
    final tAlbum = _cleanMetadataString(target.album ?? '');
    if (tAlbum.isNotEmpty && cAlbum.isNotEmpty) {
      if (cAlbum == tAlbum) {
        albumScore = 15.0;
      } else if (cAlbum.contains(tAlbum) || tAlbum.contains(cAlbum)) {
        albumScore = 7.5;
      }
    } else {
      albumScore = 0.0; // Allowed to mismatch but gets 0 points for the album weight
    }

    // 6. Duration Check (10%)
    if (candidate.duration != null && target.duration != null && candidate.duration! > 0 && target.duration! > 0) {
      final diff = (candidate.duration! - target.duration!).abs();
      if (diff <= 5) {
        durationScore = 10.0;
      } else if (diff <= 15) {
        durationScore = 5.0;
      } else {
        return 0.0; // Hard reject: duration differs by more than 15 seconds
      }
    } else {
      durationScore = 10.0; // Accept if duration info is missing from source metadata
    }

    // 7. Language Check (5%)
    final cLang = (candidate.language ?? '').toLowerCase().trim();
    final tLang = (target.language ?? '').toLowerCase().trim();
    if (tLang.isNotEmpty && cLang.isNotEmpty) {
      if (cLang == tLang) {
        languageScore = 5.0;
      } else {
        languageScore = 0.0; // Give 0 points on language mismatch instead of hard reject
      }
    } else {
      languageScore = 5.0;
    }

    double finalScore = titleScore + artistScore + albumScore + durationScore + languageScore;

    // Explicit vs Clean Version Check (-20.0 penalty, dropping below the 90.0 threshold)
    if (candidate.isExplicit != target.isExplicit) {
      finalScore -= 20.0;
    }

    // Version Type Mismatch Checks (Live, Remix, Acoustic, Cover)
    if (_isRemix(target.name) != _isRemix(candidate.name) ||
        _isLive(target.name) != _isLive(candidate.name) ||
        _isAcoustic(target.name) != _isAcoustic(candidate.name) ||
        _isCover(target.name) != _isCover(candidate.name)) {
      return 0.0; // Hard reject on mismatched version types
    }

    return finalScore.clamp(0.0, 100.0);
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
