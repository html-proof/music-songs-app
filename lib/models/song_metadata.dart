class SongMetadata {
  final String title;
  final String artist;
  final String? album;
  final String? movie;
  final String? artwork;
  final int? duration;

  const SongMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.movie,
    this.artwork,
    this.duration,
  });
}
