import '../models/song.dart';

class StreamUrlCacheEntry {
  final Song song;
  final String streamUrl;
  final DateTime expirationTime;
  final String provider;
  final int bitrate;
  final bool isValidated;

  StreamUrlCacheEntry({
    required this.song,
    required this.streamUrl,
    required this.expirationTime,
    this.provider = 'unknown',
    this.bitrate = 0,
    this.isValidated = true,
  });

  bool get isExpired => DateTime.now().isAfter(expirationTime);
}

class UrlCache {
  static final Map<String, StreamUrlCacheEntry> _resolvedUrlCache = {};
  
  static Song? getCachedSongUrl(String songId) {
    final entry = _resolvedUrlCache[songId];
    if (entry != null && !entry.isExpired && entry.isValidated) {
      return entry.song.copyWith(streamUrl: entry.streamUrl);
    }
    return null;
  }

  static void setCachedSongUrl(
    Song song, 
    String streamUrl, {
    String provider = 'unknown',
    int bitrate = 0,
    bool isValidated = true,
  }) {
    if (song.id.trim().isEmpty) return;
    _resolvedUrlCache[song.id] = StreamUrlCacheEntry(
      song: song,
      streamUrl: streamUrl,
      expirationTime: DateTime.now().add(const Duration(hours: 1)),
      provider: provider,
      bitrate: bitrate,
      isValidated: isValidated,
    );
  }

  static void removeCachedUrl(String songId) {
    _resolvedUrlCache.remove(songId);
  }
}
