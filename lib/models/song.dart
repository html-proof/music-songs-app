import '../utils/text_cleaner.dart';
import 'lyrics_metadata.dart';
import 'stream_metadata.dart';
import 'song_metadata.dart';


class Song {
  static const Object _unset = Object();
  static const int streamingMaxKbps = 480;
  static const List<int> _knownStreamBitratesKbps = [12, 48, 96, 160, 320, 480];
  static int _preferredStreamingMaxKbps = streamingMaxKbps;
  static double _streamingTargetMaxMb = 0.0;

  static int get preferredStreamingMaxKbps => _preferredStreamingMaxKbps;
  static double get streamingTargetMaxMb => _streamingTargetMaxMb;

  static void setPreferredStreamingMaxKbps(int kbps) {
    _preferredStreamingMaxKbps = kbps.clamp(1, streamingMaxKbps).toInt();
  }

  /// Set the per-song data cap in MB. 0.0 = no cap.
  static void setStreamingTargetMaxMb(double mb) {
    _streamingTargetMaxMb = mb < 0 ? 0.0 : mb;
  }

  final String id;
  final String name;
  final String? album;
  final String? albumId;
  final String? sourceAlbumId;
  final String? sourceAlbumName;
  final String? sourceAlbumArtist;
  final String? sourceAlbumImageUrl;
  final String? artist;
  final String? imageUrl;
  final String? streamUrl;
  final String? language;
  final int? duration;
  final String? year;
  final String? type;
  final bool isExplicit;
  final bool isOfficial;
  final double? recommendationScore;
  final int? playCount;
  final int? popularity;
  final String? songUrl;
  final bool? hasLyrics;
  final String? isrc;
  final String? musicbrainzId;

  Song({
    required this.id,
    required this.name,
    this.album,
    this.albumId,
    this.sourceAlbumId,
    this.sourceAlbumName,
    this.sourceAlbumArtist,
    this.sourceAlbumImageUrl,
    this.artist,
    this.imageUrl,
    this.streamUrl,
    this.language,
    this.duration,
    this.year,
    this.type,
    this.isExplicit = false,
    this.isOfficial = true,
    this.recommendationScore,
    this.playCount,
    this.popularity,
    this.songUrl,
    this.hasLyrics,
    this.isrc,
    this.musicbrainzId,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    // Extract artist name from various API formats
    String? artistName;
    if (json['primaryArtists'] != null) {
      if (json['primaryArtists'] is String) {
        artistName = TextCleaner.decodeHtmlEntities(
          json['primaryArtists'].toString(),
        );
      } else if (json['primaryArtists'] is List) {
        artistName = (json['primaryArtists'] as List)
            .map((a) => a is String ? a : a['name'] ?? '')
            .map((name) => TextCleaner.decodeHtmlEntities(name.toString()))
            .join(', ');
      }
    }
    if (artistName == null && json['artists'] != null) {
      final primary = json['artists']['primary'];
      if (primary is List && primary.isNotEmpty) {
        artistName = primary
            .map((a) => a['name'] ?? '')
            .map((name) => TextCleaner.decodeHtmlEntities(name.toString()))
            .join(', ');
      }
    }

    final duration = _extractDurationSeconds(json['duration']);
    final imageUrl = _extractImageUrl(json);
    final streamUrl = _extractStreamUrl(json, durationSeconds: duration);

    final playCount = int.tryParse(
      (json['playCount'] ?? json['play_count'] ?? json['playcount'] ?? '')
          .toString(),
    );
    final popularity = int.tryParse(
      (json['popularity'] ?? json['playCount'] ?? json['play_count'] ?? '')
          .toString(),
    );

    return Song(
      id: json['id']?.toString() ?? '',
      name: TextCleaner.decodeHtmlEntities(
        (json['name'] ?? json['title'] ?? 'Unknown').toString(),
      ),
      album: TextCleaner.decodeHtmlEntities(
        (json['album'] is Map
                ? json['album']['name']
                : json['album']?.toString() ?? '')
            .toString(),
      ),
      albumId: _extractAlbumId(json),
      sourceAlbumId: _normalizeOptionalString(
        json['sourceAlbumId'] ?? json['source_album_id'],
      ),
      sourceAlbumName: _normalizeOptionalString(
        json['sourceAlbumName'] ?? json['source_album_name'],
      ),
      sourceAlbumArtist: _normalizeOptionalString(
        json['sourceAlbumArtist'] ?? json['source_album_artist'],
      ),
      sourceAlbumImageUrl: _normalizeOptionalString(
        json['sourceAlbumImageUrl'] ?? json['source_album_image_url'],
      ),
      artist: artistName,
      imageUrl: imageUrl,
      streamUrl: streamUrl,
      language: json['language']?.toString(),
      duration: duration,
      year:
          json['year']?.toString() ??
          json['releaseDate']?.toString().split('-').first,
      type: json['type']?.toString().toUpperCase() ?? 'SONG',
      isExplicit:
          json['explicitContent'] == true || json['explicit_content'] == true,
      isOfficial: json['is_official'] != false && json['isOfficial'] != false,
      recommendationScore: json['_recommendationScore']?.toDouble(),
      playCount: playCount,
      popularity: popularity,
      songUrl: json['url']?.toString() ?? json['perma_url']?.toString(),
      hasLyrics: json['hasLyrics'] == true || json['has_lyrics'] == true,
      isrc: json['isrc']?.toString() ?? json['ISRC']?.toString(),
      musicbrainzId: json['musicbrainzId']?.toString() ??
          json['musicbrainz_id']?.toString() ??
          json['mbid']?.toString() ??
          json['musicbrainz_track_id']?.toString(),
    );
  }

  Song copyWith({
    String? id,
    String? name,
    Object? album = _unset,
    Object? albumId = _unset,
    Object? sourceAlbumId = _unset,
    Object? sourceAlbumName = _unset,
    Object? sourceAlbumArtist = _unset,
    Object? sourceAlbumImageUrl = _unset,
    Object? artist = _unset,
    Object? imageUrl = _unset,
    Object? streamUrl = _unset,
    Object? language = _unset,
    Object? duration = _unset,
    Object? year = _unset,
    Object? type = _unset,
    bool? isExplicit,
    Object? recommendationScore = _unset,
    Object? playCount = _unset,
    Object? popularity = _unset,
    Object? songUrl = _unset,
    Object? hasLyrics = _unset,
    Object? isrc = _unset,
    Object? musicbrainzId = _unset,
  }) {
    return Song(
      id: id ?? this.id,
      name: name ?? this.name,
      album: album == _unset ? this.album : album as String?,
      albumId: albumId == _unset ? this.albumId : albumId as String?,
      sourceAlbumId: sourceAlbumId == _unset
          ? this.sourceAlbumId
          : sourceAlbumId as String?,
      sourceAlbumName: sourceAlbumName == _unset
          ? this.sourceAlbumName
          : sourceAlbumName as String?,
      sourceAlbumArtist: sourceAlbumArtist == _unset
          ? this.sourceAlbumArtist
          : sourceAlbumArtist as String?,
      sourceAlbumImageUrl: sourceAlbumImageUrl == _unset
          ? this.sourceAlbumImageUrl
          : sourceAlbumImageUrl as String?,
      artist: artist == _unset ? this.artist : artist as String?,
      imageUrl: imageUrl == _unset ? this.imageUrl : imageUrl as String?,
      streamUrl: streamUrl == _unset ? this.streamUrl : streamUrl as String?,
      language: language == _unset ? this.language : language as String?,
      duration: duration == _unset ? this.duration : duration as int?,
      year: year == _unset ? this.year : year as String?,
      type: type == _unset ? this.type : type as String?,
      isExplicit: isExplicit ?? this.isExplicit,
      recommendationScore: recommendationScore == _unset
          ? this.recommendationScore
          : recommendationScore as double?,
      playCount: playCount == _unset ? this.playCount : playCount as int?,
      popularity: popularity == _unset ? this.popularity : popularity as int?,
      songUrl: songUrl == _unset ? this.songUrl : songUrl as String?,
      hasLyrics: hasLyrics == _unset ? this.hasLyrics : hasLyrics as bool?,
      isrc: isrc == _unset ? this.isrc : isrc as String?,
      musicbrainzId: musicbrainzId == _unset ? this.musicbrainzId : musicbrainzId as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'album': album,
      'albumId': albumId,
      'sourceAlbumId': sourceAlbumId,
      'sourceAlbumName': sourceAlbumName,
      'sourceAlbumArtist': sourceAlbumArtist,
      'sourceAlbumImageUrl': sourceAlbumImageUrl,
      'primaryArtists': artist,
      'imageUrl': imageUrl,
      'streamUrl': streamUrl,
      'language': language,
      'duration': duration,
      'year': year,
      'type': type,
      'explicitContent': isExplicit,
      'isOfficial': isOfficial,
      '_recommendationScore': recommendationScore,
      'playCount': playCount,
      'popularity': popularity,
      'url': songUrl,
      'hasLyrics': hasLyrics,
      'isrc': isrc,
      'musicbrainzId': musicbrainzId,
    };
  }

  Song withPlaybackSource({
    required String albumId,
    required String albumName,
    String? albumArtist,
    String? albumImageUrl,
  }) {
    final currentImage = (imageUrl ?? '').trim();
    final normalizedAlbumId = albumId.trim();
    final normalizedAlbumName = albumName.trim();
    return copyWith(
      album: normalizedAlbumName.isEmpty ? album : normalizedAlbumName,
      albumId: normalizedAlbumId.isEmpty ? this.albumId : normalizedAlbumId,
      sourceAlbumId: normalizedAlbumId.isEmpty
          ? sourceAlbumId
          : normalizedAlbumId,
      sourceAlbumName: normalizedAlbumName.isEmpty
          ? sourceAlbumName
          : normalizedAlbumName,
      sourceAlbumArtist: albumArtist,
      sourceAlbumImageUrl: albumImageUrl,
      imageUrl: currentImage.isEmpty ? albumImageUrl : imageUrl,
    );
  }

  static String? _extractImageUrl(Map<String, dynamic> json) {
    final rawImage = json['image'];
    if (rawImage is List && rawImage.isNotEmpty) {
      final selected = _pickImageFromCollection(rawImage);
      if (selected != null) return selected;
    } else if (rawImage is Map) {
      final selected = _normalizeOptionalString(
        rawImage['url'] ?? rawImage['link'] ?? rawImage['image'],
      );
      if (selected != null) return selected;
    } else if (rawImage is String) {
      final selected = _normalizeOptionalString(rawImage);
      if (selected != null) return selected;
    }

    final album = json['album'];
    final albumImage = album is Map
        ? album['image'] ?? album['imageUrl'] ?? album['image_url']
        : null;

    final fallbackCandidates = [
      json['imageUrl'],
      json['image_url'],
      json['thumbnail'],
      json['thumbnailUrl'],
      json['thumbnail_url'],
      json['artwork'],
      albumImage,
    ];

    for (final candidate in fallbackCandidates) {
      final normalized = _normalizeOptionalString(candidate);
      if (normalized != null) return normalized;
    }
    return null;
  }

  static String? _extractAlbumId(Map<String, dynamic> json) {
    final direct = _normalizeOptionalString(
      json['albumId'] ?? json['album_id'] ?? json['albumID'],
    );
    if (direct != null) return direct;

    final album = json['album'];
    if (album is Map) {
      return _normalizeOptionalString(album['id'] ?? album['albumId']);
    }
    return null;
  }

  static String? _pickImageFromCollection(List<dynamic> entries) {
    String? selected;
    var selectedScore = -1;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final url = _normalizeOptionalString(
        map['url'] ?? map['link'] ?? map['image'],
      );
      if (url == null) continue;

      final qualityText =
          _normalizeOptionalString(map['quality'] ?? map['label']) ?? '';
      final qualityScore =
          int.tryParse(
            RegExp(r'(\d{2,4})').firstMatch(qualityText)?.group(1) ?? '',
          ) ??
          0;

      if (selected == null || qualityScore >= selectedScore) {
        selected = url;
        selectedScore = qualityScore;
      }
    }
    return selected;
  }

  static String? _extractStreamUrl(
    Map<String, dynamic> json, {
    int? durationSeconds,
  }) {
    if (json['downloadUrl'] is List &&
        (json['downloadUrl'] as List).isNotEmpty) {
      final urls = json['downloadUrl'] as List;
      final selected = _pickPreferredStreamUrl(
        urls,
        targetKbps: _preferredStreamingMaxKbps,
        durationSeconds: durationSeconds,
        maxMegabytes: streamingTargetMaxMb,
      );
      if (selected != null && selected.trim().isNotEmpty) {
        return selected.trim();
      }
    }

    final rawStream = _normalizeOptionalString(
      json['streamUrl'] ?? json['stream_url'] ?? json['media_url'],
    );
    return optimizeStreamUrlForData(
      rawStream,
      maxKbps: _preferredStreamingMaxKbps,
      durationSeconds: durationSeconds,
      maxMegabytes: streamingTargetMaxMb,
    );
  }

  static int? _extractDurationSeconds(dynamic value) {
    if (value == null) return null;
    if (value is num) return _normalizeDurationUnit(value.toInt());

    final raw = value.toString().trim();
    if (raw.isEmpty) return null;

    if (raw.contains(':')) {
      final parts = raw.split(':');
      if (parts.length == 2) {
        final minutes = int.tryParse(parts[0]) ?? 0;
        final seconds = int.tryParse(parts[1]) ?? 0;
        return (minutes * 60) + seconds;
      }
      if (parts.length == 3) {
        final hours = int.tryParse(parts[0]) ?? 0;
        final minutes = int.tryParse(parts[1]) ?? 0;
        final seconds = int.tryParse(parts[2]) ?? 0;
        return (hours * 3600) + (minutes * 60) + seconds;
      }
    }

    return _normalizeDurationUnit(int.tryParse(raw));
  }

  static int? _normalizeDurationUnit(int? rawDuration) {
    if (rawDuration == null || rawDuration <= 0) return null;
    if (rawDuration > 36000 && rawDuration % 1000 == 0) {
      return rawDuration ~/ 1000;
    }
    return rawDuration;
  }

  static String? _normalizeOptionalString(dynamic value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  /// Reduces stream data usage by capping known bitrate URLs to [maxKbps].
  /// Example: ..._320.mp4 -> ..._96.mp4
  static String? optimizeStreamUrlForData(
    String? url, {
    int? maxKbps,
    int? durationSeconds,
    double? maxMegabytes,
  }) {
    final raw = (url ?? '').trim();
    if (raw.isEmpty) return null;

    final effectiveMaxKbps = _resolveDataCapKbps(
      durationSeconds: durationSeconds,
      maxKbps: maxKbps ?? _preferredStreamingMaxKbps,
      maxMegabytes: maxMegabytes ?? streamingTargetMaxMb,
    );

    // Match known bitrates in the filename to avoid hitting other IDs or tokens.
    final bitrateRegex = RegExp(r'([/_])(48|64|96|128|160|192|256|320|480)(?=[_/\.]|$)');
    final pathSegments = raw.split('/');
    if (pathSegments.isEmpty) return raw;

    final filenameIndex = pathSegments.length - 1;
    final filename = pathSegments[filenameIndex];

    final optimizedFilename = filename.replaceAllMapped(bitrateRegex, (m) {
      final prefix = m.group(1)!;
      final bitrateStr = m.group(2);
      final bitrate = int.tryParse(bitrateStr ?? '') ?? 0;

      if (bitrate > effectiveMaxKbps) {
        return '$prefix$effectiveMaxKbps';
      }
      return m.group(0)!;
    });

    pathSegments[filenameIndex] = optimizedFilename;
    return pathSegments.join('/');
  }


  static String? _pickPreferredStreamUrl(
    List<dynamic> urls, {
    int? targetKbps,
    int? durationSeconds,
    double? maxMegabytes,
  }) {
    final effectiveTargetKbps = _resolveDataCapKbps(
      durationSeconds: durationSeconds,
      maxKbps: targetKbps ?? streamingMaxKbps,
      maxMegabytes: maxMegabytes ?? streamingTargetMaxMb,
    );
    final candidates = <MapEntry<int, String>>[];
    String? fallback;
    String? previewFallback;

    for (final item in urls) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final url = (map['url'] ?? map['link'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      final isPreviewUrl =
          url.contains('preview.saavncdn.com') || url.contains('_p.mp4');
      if (isPreviewUrl) {
        previewFallback ??= url;
        continue;
      }

      fallback ??= url;
      int? bitrate;

      final qualityText = (map['quality'] ?? '').toString().toLowerCase();
      final qualityMatch = RegExp(r'(\d+)\s*kbps').firstMatch(qualityText);
      if (qualityMatch != null) {
        bitrate = int.tryParse(qualityMatch.group(1) ?? '');
      }

      bitrate ??= int.tryParse(
        RegExp(r'([/_])(\d{2,3})(?=[_/\.]|$)')
            .firstMatch(url)
            ?.group(2) ?? '',
      );

      if (bitrate != null) {
        candidates.add(MapEntry(bitrate, url));
      }
    }

    if (candidates.isEmpty) {
      return optimizeStreamUrlForData(
        fallback ?? previewFallback,
        maxKbps: effectiveTargetKbps,
        durationSeconds: durationSeconds,
        maxMegabytes: maxMegabytes ?? streamingTargetMaxMb,
      );
    }

    candidates.sort((a, b) => a.key.compareTo(b.key));
    MapEntry<int, String>? selected;
    for (final candidate in candidates) {
      if (candidate.key <= effectiveTargetKbps) {
        selected = candidate;
      }
    }

    selected ??= candidates.first;
    return optimizeStreamUrlForData(
      selected.value,
      maxKbps: effectiveTargetKbps,
      durationSeconds: durationSeconds,
      maxMegabytes: maxMegabytes ?? streamingTargetMaxMb,
    );
  }

  static int _resolveDataCapKbps({
    int? durationSeconds,
    int maxKbps = streamingMaxKbps,
    double maxMegabytes = -1,
  }) {
    final effectiveMb = maxMegabytes < 0 ? _streamingTargetMaxMb : maxMegabytes;
    final effectiveMax = maxKbps.clamp(1, streamingMaxKbps).toInt();
    
    final targetLimit = (effectiveMb <= 0 || durationSeconds == null || durationSeconds <= 0)
        ? effectiveMax
        : ((effectiveMb * 1024 * 8) / durationSeconds).floor().clamp(1, effectiveMax).toInt();

    int selected = _knownStreamBitratesKbps.first;
    for (final step in _knownStreamBitratesKbps) {
      if (step <= targetLimit) {
        selected = step;
      }
    }
    return selected;
  }
}

extension SongMetadataExtension on Song {
  LyricsMetadata toLyricsMetadata() {
    return LyricsMetadata(
      title: name,
      artist: artist ?? '',
      duration: duration ?? 0,
      language: language,
      album: sourceAlbumName ?? album,
      songId: id,
      isrc: isrc,
      songUrl: songUrl,
    );
  }

  StreamMetadata toStreamMetadata() {
    return StreamMetadata(
      streamUrl: streamUrl ?? '',
      provider: 'jiosaavn',
    );
  }

  SongMetadata toSongMetadata() {
    return SongMetadata(
      title: name,
      artist: artist ?? '',
      album: sourceAlbumName ?? album,
      movie: album,
      artwork: imageUrl,
      duration: duration,
    );
  }
}
