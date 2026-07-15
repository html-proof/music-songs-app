import '../models/song.dart';

class StreamUrlCacheEntry {
  final Song song;
  final String streamUrl;
  final DateTime expirationTime;

  StreamUrlCacheEntry({
    required this.song,
    required this.streamUrl,
    required this.expirationTime,
  });

  bool get isExpired => DateTime.now().isAfter(expirationTime);
}

class UrlCache {
  static final Map<String, StreamUrlCacheEntry> _resolvedUrlCache = {};
  
  static Song? getCachedSongUrl(String songId) {
    final entry = _resolvedUrlCache[songId];
    if (entry != null && !entry.isExpired) {
      return entry.song.copyWith(streamUrl: entry.streamUrl);
    }
    return null;
  }

  static void setCachedSongUrl(Song song, String streamUrl) {
    if (song.id.trim().isEmpty) return;
    _resolvedUrlCache[song.id] = StreamUrlCacheEntry(
      song: song,
      streamUrl: streamUrl,
      expirationTime: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  static void removeCachedUrl(String songId) {
    _resolvedUrlCache.remove(songId);
  }
}
