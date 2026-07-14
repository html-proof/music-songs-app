import '../models/song.dart';
import 'lyrics_service.dart';

class LyricsAlignmentEngine {
  /// Aligns plain text lyrics to the song's duration using character-length heuristics
  /// to generate a synced LRC string.
  static LyricsPayload align(Song song, LyricsPayload payload) {
    if (payload.syncedLyrics != null && payload.syncedLyrics!.isNotEmpty) {
      return payload;
    }
    final plain = payload.plainLyrics;
    if (plain == null || plain.isEmpty) {
      return payload;
    }

    final durationSec = song.duration ?? 0;
    if (durationSec <= 0) {
      return payload; // Can't align without duration
    }

    // Split plain text into non-empty lines
    final rawLines = plain.split('\n');
    final lines = <String>[];
    for (final rawLine in rawLines) {
      final trimmed = rawLine.trim();
      if (trimmed.isNotEmpty) {
        lines.add(trimmed);
      }
    }

    if (lines.isEmpty) {
      return payload;
    }

    final confidence = calculateHeuristicConfidence(lines.length, durationSec, plain);

    // Heuristics for intro and outro duration
    double intro;
    if (durationSec < 60) {
      intro = 2.0;
    } else if (durationSec < 180) {
      intro = 5.0;
    } else {
      intro = 8.0;
    }

    final outro = 5.0;

    final activeDuration = durationSec - intro - outro;
    if (activeDuration <= 0) {
      // Song is too short for intro/outro, align evenly
      return _alignEvenly(lines, durationSec, payload, confidence);
    }

    // Heuristic alignment: allocate duration based on character length of each line
    final totalChars = lines.fold<int>(0, (sum, line) => sum + line.length);
    if (totalChars == 0) {
      return _alignEvenly(lines, durationSec, payload, confidence);
    }

    final syncedBuffer = StringBuffer();
    double currentPos = intro;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineWeight = line.length / totalChars;
      final lineDuration = activeDuration * lineWeight;

      // Format timestamp as [mm:ss.xx]
      final mm = (currentPos / 60).floor();
      final ss = (currentPos % 60).floor();
      final xx = ((currentPos % 1) * 100).round().toString().padLeft(2, '0');
      final timestamp = '[${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}.$xx]';

      syncedBuffer.writeln('$timestamp$line');

      currentPos += lineDuration;
    }

    return LyricsPayload(
      plainLyrics: payload.plainLyrics,
      syncedLyrics: syncedBuffer.toString().trim(),
      translationPlainLyrics: payload.translationPlainLyrics,
      translationSyncedLyrics: payload.translationSyncedLyrics,
      provider: 'ai_alignment',
      confidence: confidence,
    );
  }

  static LyricsPayload _alignEvenly(List<String> lines, int durationSec, LyricsPayload payload, double confidence) {
    final syncedBuffer = StringBuffer();
    final step = durationSec / lines.length;
    double currentPos = 0.0;

    for (final line in lines) {
      final mm = (currentPos / 60).floor();
      final ss = (currentPos % 60).floor();
      final xx = ((currentPos % 1) * 100).round().toString().padLeft(2, '0');
      final timestamp = '[${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}.$xx]';

      syncedBuffer.writeln('$timestamp$line');
      currentPos += step;
    }

    return LyricsPayload(
      plainLyrics: payload.plainLyrics,
      syncedLyrics: syncedBuffer.toString().trim(),
      translationPlainLyrics: payload.translationPlainLyrics,
      translationSyncedLyrics: payload.translationSyncedLyrics,
      provider: 'ai_alignment',
      confidence: confidence,
    );
  }

  /// Calculates a confidence score between 0.1 and 0.85 for heuristic alignment
  static double calculateHeuristicConfidence(int lineCount, int durationSec, String plainLyrics) {
    if (lineCount <= 0 || durationSec <= 0) return 0.0;
    
    // Calculate character density (chars per second)
    final totalChars = plainLyrics.replaceAll(RegExp(r'\s+'), '').length;
    final charsPerSec = totalChars / durationSec;
    
    var score = 1.0;
    
    // Penalty for too few or too many lines
    final linesPerMin = (lineCount / (durationSec / 60.0));
    if (linesPerMin < 3.0) {
      score -= (3.0 - linesPerMin) * 0.15; // Too sparse
    } else if (linesPerMin > 35.0) {
      score -= (linesPerMin - 35.0) * 0.02; // Too dense
    }

    // Penalty for abnormal character density
    if (charsPerSec < 0.8) {
      score -= (0.8 - charsPerSec) * 0.5;
    } else if (charsPerSec > 12.0) {
      score -= (charsPerSec - 12.0) * 0.08;
    }
    
    // Minimum line count penalty
    if (lineCount < 4) {
      score -= (4 - lineCount) * 0.15;
    }
    
    return score.clamp(0.1, 0.85);
  }
}
