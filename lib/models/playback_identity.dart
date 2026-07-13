import 'song.dart';

class PlaybackIdentity {
  final String songId;
  final String title;
  final String? artist;
  final String? album;
  final int? durationSeconds;
  final String? isrc;
  final String? language;
  final bool isExplicit;
  final int sessionId;
  final String? imageUrl;

  PlaybackIdentity({
    required this.songId,
    required this.title,
    this.artist,
    this.album,
    this.durationSeconds,
    this.isrc,
    this.language,
    required this.isExplicit,
    required this.sessionId,
    this.imageUrl,
  });

  factory PlaybackIdentity.fromSong(Song song, int sessionId) {
    return PlaybackIdentity(
      songId: song.id,
      title: song.name,
      artist: song.artist,
      album: song.album,
      durationSeconds: song.duration,
      isrc: song.isrc,
      language: song.language,
      isExplicit: song.isExplicit,
      sessionId: sessionId,
      imageUrl: song.imageUrl,
    );
  }
}
