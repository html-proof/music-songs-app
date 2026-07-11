import 'song.dart';

class UserPlaylist {
  static const Object _unset = Object();

  final String id;
  final String name;
  final String? description;
  final String? coverImageUrl;
  final List<Song> songs;
  final int createdAt;
  final int updatedAt;

  const UserPlaylist({
    required this.id,
    required this.name,
    required this.description,
    required this.coverImageUrl,
    required this.songs,
    required this.createdAt,
    required this.updatedAt,
  });

  UserPlaylist copyWith({
    String? id,
    String? name,
    Object? description = _unset,
    Object? coverImageUrl = _unset,
    List<Song>? songs,
    int? createdAt,
    int? updatedAt,
  }) {
    return UserPlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description == _unset
          ? this.description
          : description as String?,
      coverImageUrl: coverImageUrl == _unset
          ? this.coverImageUrl
          : coverImageUrl as String?,
      songs: songs ?? this.songs,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    final rawSongs = (json['songs'] is List) ? (json['songs'] as List) : [];
    final songs = rawSongs
        .whereType<Map>()
        .map((item) => _songFromStoredJson(Map<String, dynamic>.from(item)))
        .whereType<Song>()
        .toList(growable: false);

    final now = DateTime.now().millisecondsSinceEpoch;
    return UserPlaylist(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: _asNullableString(json['description']),
      coverImageUrl: _asNullableString(
        json['coverImageUrl'] ?? json['cover_image_url'],
      ),
      songs: songs,
      createdAt: _asInt(json['createdAt']) ?? now,
      updatedAt: _asInt(json['updatedAt']) ?? now,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'coverImageUrl': coverImageUrl,
      'songs': songs.map(_songToStoredJson).toList(growable: false),
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  int get totalDurationSeconds {
    var total = 0;
    for (final song in songs) {
      final duration = song.duration ?? 0;
      if (duration > 0) {
        total += duration;
      }
    }
    return total;
  }

  static Song? _songFromStoredJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty) return null;

    final duration = _asInt(json['duration']);
    return Song(
      id: id,
      name: name,
      artist: _asNullableString(json['artist']),
      album: _asNullableString(json['album']),
      albumId: _asNullableString(json['albumId'] ?? json['album_id']),
      sourceAlbumId: _asNullableString(
        json['sourceAlbumId'] ?? json['source_album_id'],
      ),
      sourceAlbumName: _asNullableString(
        json['sourceAlbumName'] ?? json['source_album_name'],
      ),
      sourceAlbumArtist: _asNullableString(
        json['sourceAlbumArtist'] ?? json['source_album_artist'],
      ),
      sourceAlbumImageUrl: _asNullableString(
        json['sourceAlbumImageUrl'] ?? json['source_album_image_url'],
      ),
      imageUrl: _asNullableString(json['imageUrl']),
      streamUrl: _asNullableString(json['streamUrl']),
      language: _asNullableString(json['language']),
      duration: duration != null && duration > 0 ? duration : null,
    );
  }

  static Map<String, dynamic> _songToStoredJson(Song song) {
    return {
      'id': song.id,
      'name': song.name,
      'artist': song.artist,
      'album': song.album,
      'albumId': song.albumId,
      'sourceAlbumId': song.sourceAlbumId,
      'sourceAlbumName': song.sourceAlbumName,
      'sourceAlbumArtist': song.sourceAlbumArtist,
      'sourceAlbumImageUrl': song.sourceAlbumImageUrl,
      'imageUrl': song.imageUrl,
      'streamUrl': song.streamUrl,
      'language': song.language,
      'duration': song.duration,
    };
  }

  static String? _asNullableString(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
