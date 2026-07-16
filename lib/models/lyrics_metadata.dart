class LyricsMetadata {
  final String? songId;
  final String? isrc;
  final String? songUrl;

  final String title;
  final String artist;
  final int duration;
  final String? language;
  final String? album;

  const LyricsMetadata({
    required this.title,
    required this.artist,
    required this.duration,
    this.language,
    this.album,
    this.songId,
    this.isrc,
    this.songUrl,
  });
}
