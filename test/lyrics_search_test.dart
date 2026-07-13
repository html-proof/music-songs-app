import 'package:flutter_test/flutter_test.dart';
import 'package:music_hub/services/lyrics_service.dart';

void main() {
  group('Lyrics Search Query Normalization Tests', () {
    test('normalizeQuery strips "lyrics" and "official video"', () {
      final query = 'Kesariya official video lyrics';
      final normalized = LyricsService.normalizeQuery(query);
      expect(normalized, 'kesariya');
    });

    test('normalizeQuery strips special characters and extra spaces', () {
      final query = '  Kesariya - Arijit Singh (Official Video)  ';
      final normalized = LyricsService.normalizeQuery(query);
      expect(normalized, 'kesariya arijit singh');
    });

    test('normalizeQuery strips "remastered", "live", "karaoke", "hd", "4k"', () {
      final query = 'Blinding Lights Live Karaoke HD 4K Remastered';
      final normalized = LyricsService.normalizeQuery(query);
      expect(normalized, 'blinding lights');
    });

    test('normalizeQuery handles mixed casing and extra spacing', () {
      final query = 'ShAyAD   FULL   LYRICS   song   lyrics';
      final normalized = LyricsService.normalizeQuery(query);
      expect(normalized, 'shayad full song');
    });
  });
}
