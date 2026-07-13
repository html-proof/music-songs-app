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
      return _alignEvenly(lines, durationSec, payload);
    }

    // Heuristic alignment: allocate duration based on character length of each line
    final totalChars = lines.fold<int>(0, (sum, line) => sum + line.length);
    if (totalChars == 0) {
      return _alignEvenly(lines, durationSec, payload);
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
    );
  }

  static LyricsPayload _alignEvenly(List<String> lines, int durationSec, LyricsPayload payload) {
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
    );
  }
}
