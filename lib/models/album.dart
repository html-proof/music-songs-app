import '../utils/text_cleaner.dart';

class Album {
  final String id;
  final String name;
  final String? artist;
  final String? imageUrl;
  final String? language;
  final int? songCount;
  final String? year;
  final String? type;
  final bool isOfficial;
  final int? playCount;
  final int? popularity;

  Album({
    required this.id,
    required this.name,
    this.artist,
    this.imageUrl,
    this.language,
    this.songCount,
    this.year,
    this.type,
    this.isOfficial = true,
    this.playCount,
    this.popularity,
  });

  factory Album.fromJson(Map<String, dynamic> json) {
    final imageUrl = _extractImageUrl(json);
    final artist = TextCleaner.decodeHtmlEntities(_extractArtistName(json));
    final normalizedArtist = artist.trim();

    final playCount = int.tryParse(
      (json['playCount'] ?? json['play_count'] ?? json['playcount'] ?? '')
          .toString(),
    );
    final popularity = int.tryParse(
      (json['popularity'] ?? json['playCount'] ?? json['play_count'] ?? '')
          .toString(),
    );

    return Album(
      id: json['id']?.toString() ?? '',
      name: TextCleaner.decodeHtmlEntities(
        (json['name'] ?? json['title'] ?? 'Unknown').toString(),
      ),
      artist: normalizedArtist.isEmpty ? null : normalizedArtist,
      imageUrl: imageUrl,
      language: json['language'],
      songCount: json['songCount'] != null
          ? int.tryParse(json['songCount'].toString())
          : null,
      year:
          json['year']?.toString() ??
          json['releaseDate']?.toString().split('-').first,
      type: json['type']?.toString().toUpperCase() ?? 'ALBUM',
      isOfficial: json['is_official'] != false && json['isOfficial'] != false,
      playCount: playCount,
      popularity: popularity,
    );
  }

  static String? _extractImageUrl(Map<String, dynamic> json) {
    final image = json['image'];
    if (image is List && image.isNotEmpty) {
      final last = image.last;
      if (last is Map) {
        return (last['url'] ?? last['link'])?.toString();
      }
    } else if (image is String) {
      return image;
    }
    return null;
  }

  static String _extractArtistName(Map<String, dynamic> json) {
    final direct =
        (json['primaryArtists'] ??
                json['primary_artists'] ??
                json['artist'] ??
                json['subtitle'] ??
                '')
            .toString()
            .trim();
    if (direct.isNotEmpty && direct.toLowerCase() != 'null') return direct;

    final artists = json['artists'];
    if (artists is Map) {
      final primary = artists['primary'];
      if (primary is List && primary.isNotEmpty) {
        final names = primary
            .whereType<Map>()
            .map((item) => (item['name'] ?? '').toString().trim())
            .where((name) => name.isNotEmpty)
            .toList(growable: false);
        if (names.isNotEmpty) return names.join(', ');
      }
      final all = artists['all'];
      if (all is List && all.isNotEmpty) {
        final names = all
            .whereType<Map>()
            .map((item) => (item['name'] ?? '').toString().trim())
            .where((name) => name.isNotEmpty)
            .toList(growable: false);
        if (names.isNotEmpty) return names.join(', ');
      }
    }

    return '';
  }
}
