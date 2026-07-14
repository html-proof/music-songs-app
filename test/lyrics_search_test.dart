import 'package:flutter_test/flutter_test.dart';
import 'package:music_hub/services/lyrics_service.dart';
import 'package:music_hub/services/lyrics_manager.dart';
import 'package:music_hub/services/lyrics_alignment_engine.dart';

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

  group('Lyrics Manager Enhanced LRC Parsing Tests', () {
    test('parseSyncedLyrics parses word-level timestamp tags correctly', () {
      final enhancedLrc = '[00:10.50]<00:10.50> Hello <00:10.80> World <00:11.20> again';
      final lines = LyricsManager.parseSyncedLyrics(enhancedLrc);
      
      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line.text, 'Hello World again');
      expect(line.time.inMilliseconds, 10500);
      expect(line.words, isNotNull);
      expect(line.words, hasLength(3));

      expect(line.words![0].word, 'Hello');
      expect(line.words![0].startOffset.inMilliseconds, 0); // 10500 - 10500
      expect(line.words![0].endOffset.inMilliseconds, 300);  // 10800 - 10500

      expect(line.words![1].word, 'World');
      expect(line.words![1].startOffset.inMilliseconds, 300); // 10800 - 10500
      expect(line.words![1].endOffset.inMilliseconds, 700);  // 11200 - 10500

      expect(line.words![2].word, 'again');
      expect(line.words![2].startOffset.inMilliseconds, 700); // 11200 - 10500
      expect(line.words![2].endOffset.inMilliseconds, 1100); // 11200 - 10500 + 400 default
    });

    test('parseSyncedLyrics handles lines without word-level tags gracefully', () {
      final standardLrc = '[00:10.50] Hello World';
      final lines = LyricsManager.parseSyncedLyrics(standardLrc);

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line.text, 'Hello World');
      expect(line.words, isNull);
    });
  });

  group('Lyrics Alignment Engine Heuristic Confidence Tests', () {
    test('calculateHeuristicConfidence returns low score for too short text', () {
      final score = LyricsAlignmentEngine.calculateHeuristicConfidence(2, 180, 'Short lyrics\nVery short');
      expect(score, lessThan(0.6));
    });

    test('calculateHeuristicConfidence returns higher score for normal lyrics duration ratio', () {
      final plainLyrics = 'Line one\nLine two\nLine three\nLine four\nLine five\nLine six\nLine seven\nLine eight';
      final score = LyricsAlignmentEngine.calculateHeuristicConfidence(8, 120, plainLyrics);
      expect(score, greaterThan(0.6));
      expect(score, lessThanOrEqualTo(0.85)); // Heuristic cap
    });
  });
}
