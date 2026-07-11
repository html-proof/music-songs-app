import '../models/song.dart';

class ContentFilter {
  static const Set<String> _blockedExactSongTitles = <String>{
    'this is a sample trailer testing',
  };

  static const List<String> blockedSongTitleKeywords = <String>[
    'sample',
    'test',
    'testing',
    'trailer',
    'demo',

    'dialogue',
  ];

  static final RegExp _blockedSongTitlePattern = RegExp(
    r'\b(sample|test|testing|trailer|demo|official|dialogue)\b',
    caseSensitive: false,
  );

  static bool isAllowedSongTitle(String? title) {
    final normalized = _normalizeTitle(title);
    if (normalized.isEmpty) return false;
    if (_blockedExactSongTitles.contains(normalized)) return false;
    return !_blockedSongTitlePattern.hasMatch(normalized);
  }

  static bool isBlockedSongTitle(String? title) {
    final normalized = _normalizeTitle(title);
    if (normalized.isEmpty) return false;
    return _blockedSongTitlePattern.hasMatch(normalized);
  }

  /// Filters a list of raw song maps, removing test/sample/trailer tracks.
  /// Returns only songs with valid titles.
  static List<Map<String, dynamic>> filterValidSongMaps(
    List<dynamic> songs,
  ) {
    return songs.whereType<Map>().where((song) {
      final title = (song['name'] ?? song['title'] ?? '').toString();
      return isAllowedSongTitle(title);
    }).map((e) => Map<String, dynamic>.from(e)).toList(growable: false);
  }

  /// (non-test/sample/trailer) track. Accepts `List<Song>` or `List<Map>`.
  static bool hasValidSongs(List<dynamic> items) {
    for (final item in items) {
      if (item is Map) {
        final title = (item['name'] ?? item['title'] ?? '').toString();
        if (isAllowedSongTitle(title)) return true;
      } else if (item is Song) {
        if (isAllowedSongTitle(item.name)) return true;
      }
    }
    return false;
  }

  static String _normalizeTitle(String? value) {
    return (value ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
