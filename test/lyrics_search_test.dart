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

  group('Lyrics Service Scraper Fallback Tests', () {
    test('decodeHtmlEntities decodes common HTML entities correctly', () {
      final input = 'Kesariya tera ishq hai piya &amp; &quot;love storiyan&quot;&#039;s';
      final decoded = LyricsService.decodeHtmlEntities(input);
      expect(decoded, 'Kesariya tera ishq hai piya & "love storiyan"\'s');
    });

    test('DuckDuckGo search result links with uddg parameters are parsed correctly', () {
      final link = '//duckduckgo.com/l/?uddg=https://www.azlyrics.com/lyrics/bollywood/kesariya.html&amp;rut=d597257';
      final decodedLink = Uri.decodeFull(link);
      final uddgMatch = RegExp(r'uddg=([^&]+)').firstMatch(decodedLink);
      expect(uddgMatch, isNotNull);
      final targetUrl = uddgMatch!.group(1)!;
      expect(targetUrl, 'https://www.azlyrics.com/lyrics/bollywood/kesariya.html');
    });

    test('generateScraperQueries generates the correct combinations', () {
      final queries = LyricsService.generateScraperQueries(
        'Vaathi Raid (From "Master")',
        'Anirudh Ravichander',
        'Master',
        'Tamil',
      );
      expect(queries, contains('vaathi raid lyrics'));
      expect(queries, contains('vaathi raid master lyrics'));
      expect(queries, contains('vaathi raid anirudh ravichander lyrics'));
      expect(queries, contains('vaathi raid master anirudh lyrics'));
      expect(queries, contains('master vaathi raid lyrics'));
      expect(queries, contains('vaathi raid tamil lyrics'));
      expect(queries, contains('vaathi raid full lyrics'));
    });
  });
}
