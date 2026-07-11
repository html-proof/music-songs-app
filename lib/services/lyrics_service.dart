import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'api_service.dart';
import 'lyrics_cache.dart';

@immutable
class LyricsPayload {
  final String? plainLyrics;
  final String? syncedLyrics;
  final String? translationPlainLyrics;
  final String? translationSyncedLyrics;

  const LyricsPayload({
    required this.plainLyrics,
    required this.syncedLyrics,
    this.translationPlainLyrics,
    this.translationSyncedLyrics,
  });

  bool get hasPlain => plainLyrics != null && plainLyrics!.trim().isNotEmpty;
  bool get hasSynced => syncedLyrics != null && syncedLyrics!.trim().isNotEmpty;
  bool get hasTranslationPlain =>
      translationPlainLyrics != null &&
      translationPlainLyrics!.trim().isNotEmpty;
  bool get hasTranslationSynced =>
      translationSyncedLyrics != null &&
      translationSyncedLyrics!.trim().isNotEmpty;
  bool get hasTranslation => hasTranslationPlain || hasTranslationSynced;
  bool get hasAny => hasPlain || hasSynced || hasTranslation;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'plainLyrics': plainLyrics,
      'syncedLyrics': syncedLyrics,
      'translationPlainLyrics': translationPlainLyrics,
      'translationSyncedLyrics': translationSyncedLyrics,
    };
  }

  factory LyricsPayload.fromJson(Map<String, dynamic> json) {
    final plainLyrics = json['plainLyrics'] ?? json['originalPlainLyrics'];
    final syncedLyrics = json['syncedLyrics'] ?? json['originalSyncedLyrics'];

    return LyricsPayload(
      plainLyrics: plainLyrics?.toString(),
      syncedLyrics: syncedLyrics?.toString(),
      translationPlainLyrics: json['translationPlainLyrics']?.toString(),
      translationSyncedLyrics: json['translationSyncedLyrics']?.toString(),
    );
  }
}

enum _TrackVersionType { original, remix, live, remaster, acoustic }

enum _LanguageMatchState { match, mismatch, unknown }

@immutable
class _LyricsLookup {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String? language;
  final int? durationSeconds;

  const _LyricsLookup({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.language,
    required this.durationSeconds,
  });

  factory _LyricsLookup.fromSong(Song song) {
    final sourceAlbum = (song.sourceAlbumName ?? '').trim();
    final album = sourceAlbum.isNotEmpty
        ? sourceAlbum
        : (song.album ?? '').trim();

    return _LyricsLookup(
      trackId: song.id.trim(),
      title: song.name.trim(),
      artist: (song.artist ?? '').trim(),
      album: album,
      language: song.language?.toString().trim(),
      durationSeconds: song.duration,
    );
  }
}

@immutable
class _LyricsCandidate {
  final String? plainLyrics;
  final String? syncedLyrics;
  final String trackName;
  final String artistName;
  final String albumName;
  final int? durationSeconds;
  final String? language;

  const _LyricsCandidate({
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    required this.language,
  });
}

@immutable
class _ScoredCandidate {
  final _LyricsCandidate candidate;
  final int score;

  const _ScoredCandidate({required this.candidate, required this.score});
}

@immutable
class _LrcLine {
  final int millis;
  final String timestampTag;
  final String text;

  const _LrcLine({
    required this.millis,
    required this.timestampTag,
    required this.text,
  });
}

class LyricsService {
  static const String _lrclibBaseUrl = 'https://lrclib.net/api';
  static const Duration _requestTimeout = Duration(seconds: 6);
  static final RegExp _lrcTagRegex = RegExp(
    r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]',
    multiLine: true,
  );

  static Future<File?> _localLrcFile(String songId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/music_hub_downloads');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File('${dir.path}/$songId.lrc');
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveLocalLrc(String songId, LyricsPayload payload) async {
    try {
      final file = await _localLrcFile(songId);
      if (file != null) {
        await file.writeAsString(jsonEncode(payload.toJson()));
        debugPrint('[LyricsService] Saved local LRC for song $songId');
      }
    } catch (e) {
      debugPrint('[LyricsService] Failed to save local LRC file: $e');
    }
  }

  static Future<LyricsPayload?> loadLocalLrc(String songId) async {
    try {
      final file = await _localLrcFile(songId);
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          debugPrint('[LyricsService] Loaded local LRC from file for song $songId');
          return LyricsPayload.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (e) {
      debugPrint('[LyricsService] Failed to load local LRC file: $e');
    }
    return null;
  }

  /// Backward-compatible plain lyrics API.
  static Future<String?> getLyrics(String artist, String title) async {
    final payload = await getLyricsPayload(artist, title);
    return payload?.plainLyrics;
  }

  /// Backward-compatible API that resolves by artist + title.
  static Future<LyricsPayload?> getLyricsPayload(
    String artist,
    String title,
  ) async {
    final lookup = _LyricsLookup(
      trackId: '',
      title: title.trim(),
      artist: artist.trim(),
      album: '',
      language: null,
      durationSeconds: null,
    );
    final candidates = await _fetchCandidates(lookup);
    return _selectBestPayload(lookup, candidates);
  }

  /// Song-aware API with strict metadata validation for language/version/timing.
  static Future<LyricsPayload?> getLyricsPayloadForSong(Song song) async {
    final lookup = _LyricsLookup.fromSong(song);
    if (lookup.title.isEmpty) return null;

    final candidates = await _fetchCandidates(lookup);
    return _selectBestPayload(lookup, candidates);
  }

  /// Search for lyrics by a raw query string.
  static Future<LyricsPayload?> getLyricsByQuery(String query, Song song) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    try {
      final entries = await _lrclibSearchEntries(trimmed);
      if (entries.isEmpty) return null;

      final candidates = entries
          .map((json) => _candidateFromJson(json))
          .whereType<_LyricsCandidate>()
          .toList();

      final lookup = _LyricsLookup.fromSong(song);
      return _selectBestPayload(lookup, candidates);
    } catch (e) {
      debugPrint('[LyricsService] Failed search by query "$query": $e');
    }
    return null;
  }

  static void prefetchLyricsForSong(Song song) {
    final title = song.name.trim();
    if (title.isEmpty) return;
    final artist = (song.artist ?? '').trim();
    final album = (song.sourceAlbumName ?? song.album ?? '').trim();
    final duration = song.duration ?? 0;

    Future(() async {
      try {
        final cached = await LyricsCache.get(
          songId: song.id,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
        );
        if (cached != null) return;

        final payload = await getLyricsPayloadForSong(song);
        if (payload != null && payload.hasAny) {
          await LyricsCache.put(
            songId: song.id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            payload: payload,
            providerSource: 'lrclib',
          );
        }
      } catch (e) {
        debugPrint('[LyricsService] Failed prefetching lyrics: $e');
      }
    });
  }

  static Future<List<_LyricsCandidate>> _fetchCandidates(
    _LyricsLookup lookup,
  ) async {
    final candidates = <_LyricsCandidate>[];
    final dedupeKeys = <String>{};

    void addCandidateFromJson(Map<String, dynamic> json) {
      final candidate = _candidateFromJson(json);
      if (candidate == null) return;
      final key = _candidateDedupeKey(candidate);
      if (dedupeKeys.contains(key)) return;
      dedupeKeys.add(key);
      candidates.add(candidate);
    }

    // --- NEW: Fetch from our own Saavn backend first ---
    if (lookup.trackId.isNotEmpty) {
      final saavnCandidate = await _fetchSaavnCandidate(
        lookup.trackId,
        artist: lookup.artist,
      );
      if (saavnCandidate != null) {
        // Saavn lyrics are usually high quality for these tracks.
        // We add it to candidates.
        final key = _candidateDedupeKey(saavnCandidate);
        if (!dedupeKeys.contains(key)) {
          dedupeKeys.add(key);
          candidates.add(saavnCandidate);
        }
      }
    }

    final cleanArtist = _cleanArtist(lookup.artist);
    final cleanTitle = _cleanTitle(lookup.title);
    final cleanAlbum = _cleanTitle(lookup.album);

    final exactQueries = <({String artist, String title})>[
      (artist: cleanArtist, title: cleanTitle),
      (artist: lookup.artist, title: lookup.title),
    ];
    
    // Fetch Exact entries concurrently
    final exactFutures = <Future<Map<String, dynamic>?>>[];
    for (final query in exactQueries) {
      if (query.title.trim().isEmpty) continue;
      exactFutures.add(
        _lrclibGetEntry(
          artist: query.artist.trim(),
          title: query.title.trim(),
          album: cleanAlbum,
          durationSeconds: lookup.durationSeconds,
        ),
      );
    }

    final exactResults = await Future.wait(exactFutures);
    for (final exactEntry in exactResults) {
      if (exactEntry != null) {
        addCandidateFromJson(exactEntry);
      }
    }

    // If exact lookup failed or returned nothing, try without duration for better hit rate
    if (candidates.isEmpty) {
      final exactWithoutDurationFutures = <Future<Map<String, dynamic>?>>[];
      for (final query in exactQueries) {
        if (query.title.trim().isEmpty) continue;
        exactWithoutDurationFutures.add(
          _lrclibGetEntry(
            artist: query.artist.trim(),
            title: query.title.trim(),
            // Intentionally omitting album and duration to satisfy strict LRCLIB /get
          ),
        );
      }
      final resultsWithoutDuration = await Future.wait(exactWithoutDurationFutures);
      for (final entry in resultsWithoutDuration) {
        if (entry != null) addCandidateFromJson(entry);
      }
    }

    final searchQueries = <String>{
      '$cleanArtist $cleanTitle'.trim(),
      '$cleanTitle $cleanArtist'.trim(),
      cleanTitle,
      if (cleanAlbum.isNotEmpty) '$cleanTitle $cleanAlbum'.trim(),
    }.where((query) => query.isNotEmpty).toList();

    // Fetch up to 4 search queries in parallel for maximum coverage
    final searchFutures = <Future<List<Map<String, dynamic>>>>[];
    for (final query in searchQueries.take(4)) {
      searchFutures.add(_lrclibSearchEntries(query));
    }

    final searchResults = await Future.wait(searchFutures);
    for (final entries in searchResults) {
      for (final entry in entries) {
        addCandidateFromJson(entry);
      }
    }

    return candidates;
  }

  static Future<Map<String, dynamic>?> _lrclibGetEntry({
    required String artist,
    required String title,
    String? album,
    int? durationSeconds,
  }) async {
    try {
      final query = <String, String>{
        'track_name': title,
        if (artist.trim().isNotEmpty) 'artist_name': artist,
        if ((album ?? '').trim().isNotEmpty) 'album_name': album!.trim(),
        if (durationSeconds != null && durationSeconds > 0)
          'duration': durationSeconds.toString(),
      };
      final uri = Uri.parse(
        '$_lrclibBaseUrl/get',
      ).replace(queryParameters: query);

      final res = await http
          .get(
            uri,
            headers: {'User-Agent': 'MusicHub/2.0 (https://github.com)'},
          )
          .timeout(_requestTimeout);

      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[LyricsService] LRCLIB get failed: $e');
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> _lrclibSearchEntries(
    String query,
  ) async {
    try {
      final uri = Uri.parse(
        '$_lrclibBaseUrl/search',
      ).replace(queryParameters: {'q': query});

      final res = await http
          .get(
            uri,
            headers: {'User-Agent': 'MusicHub/2.0 (https://github.com)'},
          )
          .timeout(_requestTimeout);

      if (res.statusCode != 200) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(res.body);
      if (decoded is! List || decoded.isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      return decoded
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[LyricsService] LRCLIB search failed: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<_LyricsCandidate?> _fetchSaavnCandidate(
    String trackId, {
    String? artist,
  }) async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/api/songs/$trackId/lyrics');
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'MusicHub/2.0'},
      ).timeout(_requestTimeout);

      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);

      // Handle both { data: { lyrics: '...' } } and { lyrics: '...' }
      final data = body['data'] ?? body;
      final lyrics = data['lyrics']?.toString();

      if (lyrics == null || lyrics.isEmpty) return null;

      // Detect if the 'lyrics' field itself contains LRC time tags
      final hasLrcTags = _lrcTagRegex.hasMatch(lyrics);

      return _LyricsCandidate(
        plainLyrics: hasLrcTags ? null : lyrics,
        syncedLyrics: hasLrcTags ? lyrics : data['snippets']?.toString(),
        trackName: data['name'] ?? '',
        artistName: data['artist'] ?? artist ?? '',
        albumName: data['album'] ?? '',
        durationSeconds: null,
        language: null,
      );
    } catch (e) {
      debugPrint('[LyricsService] Saavn candidate fetch failed: $e');
      return null;
    }
  }

  static _LyricsCandidate? _candidateFromJson(Map<String, dynamic> json) {
    if (json['instrumental'] == true) return null;

    final payload = _payloadFromJson(json);
    if (payload == null) return null;

    return _LyricsCandidate(
      plainLyrics: payload.plainLyrics,
      syncedLyrics: payload.syncedLyrics,
      trackName:
          _normalizeOptionalString(
            json['trackName'] ??
                json['track_name'] ??
                json['name'] ??
                json['title'],
          ) ??
          '',
      artistName:
          _normalizeOptionalString(
            json['artistName'] ?? json['artist_name'] ?? json['artist'],
          ) ??
          '',
      albumName:
          _normalizeOptionalString(
            json['albumName'] ?? json['album_name'] ?? json['album'],
          ) ??
          '',
      durationSeconds: _parseDurationSeconds(json['duration']),
      language: _normalizeOptionalString(json['language'] ?? json['lang']),
    );
  }

  static String _candidateDedupeKey(_LyricsCandidate candidate) {
    final lyricsSample = (candidate.syncedLyrics ?? candidate.plainLyrics ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    final compactSample = lyricsSample.length > 72
        ? lyricsSample.substring(0, 72)
        : lyricsSample;
    return '${_normalizeMatchText(candidate.trackName)}::'
        '${_normalizeMatchText(candidate.artistName)}::'
        '${candidate.durationSeconds ?? 0}::'
        '${compactSample.hashCode}';
  }

  static LyricsPayload? _selectBestPayload(
    _LyricsLookup lookup,
    List<_LyricsCandidate> candidates,
  ) {
    if (candidates.isEmpty) return null;

    final expectedLanguage = _normalizeLanguage(lookup.language);
    final strictPayload = _selectBestPayloadByMode(
      lookup,
      candidates,
      expectedLanguage: expectedLanguage,
      relaxed: false,
    );
    if (strictPayload != null) {
      return strictPayload;
    }

    final relaxedPayload = _selectBestPayloadByMode(
      lookup,
      candidates,
      expectedLanguage: expectedLanguage,
      relaxed: true,
    );
    if (relaxedPayload != null) {
      return relaxedPayload;
    }

    return _selectLoosePayload(
      lookup,
      candidates,
      expectedLanguage: expectedLanguage,
    );
  }

  static LyricsPayload? _selectBestPayloadByMode(
    _LyricsLookup lookup,
    List<_LyricsCandidate> candidates, {
    required String? expectedLanguage,
    required bool relaxed,
  }) {
    _ScoredCandidate? bestOriginal;
    _ScoredCandidate? bestTranslation;

    for (final candidate in candidates) {
      final score = _scoreCandidate(lookup, candidate, relaxed: relaxed);
      if (score == null) continue;

      if (expectedLanguage == null) {
        if (bestOriginal == null || score > bestOriginal.score) {
          bestOriginal = _ScoredCandidate(candidate: candidate, score: score);
        }
        continue;
      }

      final candidateLanguage = _candidateLanguage(candidate);
      final languageState = _languageMatchState(
        expectedLanguage,
        candidateLanguage,
      );

      if (languageState == _LanguageMatchState.mismatch) {
        final translatedScore = score + (relaxed ? 6 : 8);
        if (bestTranslation == null ||
            translatedScore > bestTranslation.score) {
          bestTranslation = _ScoredCandidate(
            candidate: candidate,
            score: translatedScore,
          );
        }
        continue;
      }

      final adjustedScore = switch (languageState) {
        _LanguageMatchState.match => score + 24,
        _LanguageMatchState.unknown => score - (relaxed ? 2 : 6),
        _LanguageMatchState.mismatch => score,
      };

      if (bestOriginal == null || adjustedScore > bestOriginal.score) {
        bestOriginal = _ScoredCandidate(
          candidate: candidate,
          score: adjustedScore,
        );
      }
    }

    return _payloadFromCandidatePair(
      bestOriginal?.candidate,
      bestTranslation?.candidate,
    );
  }

  static LyricsPayload? _selectLoosePayload(
    _LyricsLookup lookup,
    List<_LyricsCandidate> candidates, {
    required String? expectedLanguage,
  }) {
    _LyricsCandidate? bestOriginal;
    _LyricsCandidate? bestTranslation;
    var bestOriginalScore = -1;
    var bestTranslationScore = -1;

    for (final candidate in candidates) {
      final score = _looseCandidateScore(lookup, candidate);
      final candidateLanguage = _candidateLanguage(candidate);
      final languageState = expectedLanguage == null
          ? _LanguageMatchState.unknown
          : _languageMatchState(expectedLanguage, candidateLanguage);

      if (expectedLanguage != null &&
          languageState == _LanguageMatchState.mismatch) {
        if (score > bestTranslationScore) {
          bestTranslationScore = score;
          bestTranslation = candidate;
        }
        continue;
      }

      final adjustedScore =
          score +
          (languageState == _LanguageMatchState.match
              ? 10
              : languageState == _LanguageMatchState.unknown
              ? 4
              : 0);
      if (adjustedScore > bestOriginalScore) {
        bestOriginalScore = adjustedScore;
        bestOriginal = candidate;
      }
    }

    if (bestOriginal == null) {
      for (final candidate in candidates) {
        if (_isValidLyrics(candidate.plainLyrics) ||
            _isValidSyncedLyrics(candidate.syncedLyrics)) {
          bestOriginal = candidate;
          break;
        }
      }
    }

    return _payloadFromCandidatePair(bestOriginal, bestTranslation);
  }

  static int _looseCandidateScore(
    _LyricsLookup lookup,
    _LyricsCandidate candidate,
  ) {
    var score = 0;

    final expectedTitle = _normalizeMatchText(_cleanTitle(lookup.title));
    final candidateTitle = _normalizeMatchText(
      _cleanTitle(
        candidate.trackName.isNotEmpty ? candidate.trackName : lookup.title,
      ),
    );
    score += (_similarityScore(expectedTitle, candidateTitle) * 100).round();

    final expectedArtist = _normalizeMatchText(_cleanArtist(lookup.artist));
    if (expectedArtist.isNotEmpty) {
      final candidateArtist = _normalizeMatchText(
        _cleanArtist(candidate.artistName),
      );
      score += (_similarityScore(expectedArtist, candidateArtist) * 30).round();
    }

    if (_isValidSyncedLyrics(candidate.syncedLyrics)) {
      score += 55;
    } else if (_isValidLyrics(candidate.plainLyrics)) {
      score += 12;
    }

    final lengthScore = (candidate.plainLyrics ?? candidate.syncedLyrics ?? '')
        .trim()
        .length;
    score += math.min(24, (lengthScore / 70).floor());

    return score;
  }

  static LyricsPayload? _payloadFromCandidatePair(
    _LyricsCandidate? original,
    _LyricsCandidate? translation,
  ) {
    if (original == null && translation == null) {
      return null;
    }

    final originalSynced = original?.syncedLyrics;
    final originalPlain = _coalescePlainLyrics(
      original?.plainLyrics,
      originalSynced,
    );

    String? translationSynced = translation?.syncedLyrics;
    String? translationPlain = _coalescePlainLyrics(
      translation?.plainLyrics,
      translationSynced,
    );

    if (originalSynced != null) {
      final aligned = _alignTranslationToOriginalTimestamps(
        originalSynced: originalSynced,
        translationSynced: translationSynced,
        translationPlain: translationPlain,
      );
      if (aligned != null) {
        translationSynced = aligned;
        translationPlain = _stripTimestamps(aligned);
      }
    }

    if (!_isValidLyrics(originalPlain) &&
        !_isValidSyncedLyrics(originalSynced) &&
        !_isValidLyrics(translationPlain) &&
        !_isValidSyncedLyrics(translationSynced)) {
      return null;
    }

    return LyricsPayload(
      plainLyrics: originalPlain,
      syncedLyrics: originalSynced,
      translationPlainLyrics: translationPlain,
      translationSyncedLyrics: translationSynced,
    );
  }

  static int? _scoreCandidate(
    _LyricsLookup lookup,
    _LyricsCandidate candidate, {
    required bool relaxed,
  }) {
    final expectedTitle = _normalizeMatchText(_cleanTitle(lookup.title));
    final rawCandidateTitle = candidate.trackName.isNotEmpty
        ? candidate.trackName
        : lookup.title;
    final candidateTitle = _normalizeMatchText(_cleanTitle(rawCandidateTitle));

    final titleScore = _similarityScore(expectedTitle, candidateTitle);
    if (titleScore < (relaxed ? 0.38 : 0.55)) return null;

    final expectedArtist = _normalizeMatchText(_cleanArtist(lookup.artist));
    final candidateArtist = _normalizeMatchText(
      _cleanArtist(candidate.artistName),
    );
    if (expectedArtist.isNotEmpty) {
      final artistScore = _similarityScore(expectedArtist, candidateArtist);
      if (artistScore < (relaxed ? 0.18 : 0.35)) return null;
    }

    final expectedVersion = _detectVersionType(
      '${lookup.title} ${lookup.album}',
    );
    final candidateVersion = _detectVersionType(
      '${candidate.trackName} ${candidate.albumName}',
    );
    if (!_isVersionCompatible(
      expectedVersion,
      candidateVersion,
      relaxed: relaxed,
    )) {
      return null;
    }

    final expectedDuration = lookup.durationSeconds;
    final candidateDuration = candidate.durationSeconds;
    if (expectedDuration != null &&
        expectedDuration > 0 &&
        candidateDuration != null &&
        candidateDuration > 0 &&
        (expectedDuration - candidateDuration).abs() > (relaxed ? 8 : 1)) {
      return null;
    }

    var score = (titleScore * 100).round();

    if (expectedArtist.isNotEmpty) {
      final artistScore = _similarityScore(expectedArtist, candidateArtist);
      score += (artistScore * 60).round();
    }

    final expectedAlbum = _normalizeMatchText(_cleanTitle(lookup.album));
    if (expectedAlbum.isNotEmpty) {
      final candidateAlbum = _normalizeMatchText(
        _cleanTitle(candidate.albumName),
      );
      final albumScore = _similarityScore(expectedAlbum, candidateAlbum);
      score += (albumScore * 30).round();
    }

    if (expectedDuration != null &&
        expectedDuration > 0 &&
        candidateDuration != null &&
        candidateDuration > 0) {
      final diff = (expectedDuration - candidateDuration).abs();
      if (diff == 0) {
        score += 24;
      } else if (diff <= 1) {
        score += 16;
      } else if (relaxed && diff <= 3) {
        score += 10;
      } else if (relaxed && diff <= 8) {
        score += 4;
      }
    } else if (expectedDuration != null && expectedDuration > 0) {
      score -= 8;
    }

    if (candidate.syncedLyrics != null) {
      // Significantly higher bonus for synced lyrics to favor Spotify-like tracking
      score += 48;
    }

    return score;
  }

  static _LanguageMatchState _languageMatchState(
    String expectedLanguage,
    String? candidateLanguage,
  ) {
    if (candidateLanguage == null) return _LanguageMatchState.unknown;
    return expectedLanguage == candidateLanguage
        ? _LanguageMatchState.match
        : _LanguageMatchState.mismatch;
  }

  static String? _candidateLanguage(_LyricsCandidate candidate) {
    final declared = _normalizeLanguage(candidate.language);
    if (declared != null) return declared;

    final text = candidate.plainLyrics?.trim().isNotEmpty == true
        ? candidate.plainLyrics!
        : _stripTimestamps(candidate.syncedLyrics ?? '');
    return _detectLanguageFromLyrics(text);
  }

  static String? _coalescePlainLyrics(String? plain, String? synced) {
    if (_isValidLyrics(plain)) return plain!.trim();
    if (_isValidSyncedLyrics(synced)) {
      return _stripTimestamps(synced!);
    }
    return null;
  }

  static String? _alignTranslationToOriginalTimestamps({
    required String originalSynced,
    String? translationSynced,
    String? translationPlain,
  }) {
    final originalLines = _parseLrcLines(originalSynced);
    if (originalLines.length < 2) return null;

    final translatedTexts = <String>[];
    if (_isValidSyncedLyrics(translationSynced)) {
      translatedTexts.addAll(
        _parseLrcLines(
          translationSynced!,
        ).map((line) => line.text.trim()).where((line) => line.isNotEmpty),
      );
    }
    if (translatedTexts.isEmpty && _isValidLyrics(translationPlain)) {
      translatedTexts.addAll(
        translationPlain!
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
    }
    if (translatedTexts.length < 2) return null;

    final lineGap = (translatedTexts.length - originalLines.length).abs();
    final allowedGap = math.max(1, (originalLines.length * 0.20).round());
    if (lineGap > allowedGap) return null;

    final count = math.min(originalLines.length, translatedTexts.length);
    final output = StringBuffer();
    for (var i = 0; i < count; i++) {
      output.writeln('${originalLines[i].timestampTag} ${translatedTexts[i]}');
    }
    return output.toString().trim();
  }

  static _TrackVersionType _detectVersionType(String value) {
    final normalized = value.toLowerCase();
    if (RegExp(r'\b(remix|re[- ]mix|dj mix|mix)\b').hasMatch(normalized)) {
      return _TrackVersionType.remix;
    }
    if (RegExp(r'\b(live|concert|unplugged live)\b').hasMatch(normalized)) {
      return _TrackVersionType.live;
    }
    if (RegExp(r'\b(remaster|remastered)\b').hasMatch(normalized)) {
      return _TrackVersionType.remaster;
    }
    if (RegExp(r'\b(acoustic|unplugged)\b').hasMatch(normalized)) {
      return _TrackVersionType.acoustic;
    }
    return _TrackVersionType.original;
  }

  static bool _isVersionCompatible(
    _TrackVersionType expected,
    _TrackVersionType candidate, {
    required bool relaxed,
  }) {
    if (relaxed && expected == _TrackVersionType.original) {
      return true;
    }
    if (expected == _TrackVersionType.original) {
      return candidate == _TrackVersionType.original;
    }
    return expected == candidate;
  }

  static double _similarityScore(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a == b) return 1.0;

    if (a.contains(b) || b.contains(a)) {
      final shortest = math.min(a.length, b.length);
      final longest = math.max(a.length, b.length);
      return shortest / longest;
    }

    final setA = _tokenSet(a);
    final setB = _tokenSet(b);
    if (setA.isEmpty || setB.isEmpty) return 0.0;

    final overlap = setA.intersection(setB).length;
    final maxSize = math.max(setA.length, setB.length);
    return overlap / maxSize;
  }

  static Set<String> _tokenSet(String value) {
    return value
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toSet();
  }

  static String _normalizeMatchText(String value) {
    return value
        .toLowerCase()
        .replaceAll("'", ' ')
        .replaceAll(RegExp(r'[\(\)\[\]\{\},.!?;:"@#\$%\^&\*\+\=/\\|<>_-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String? _normalizeLanguage(String? language) {
    final normalized = language
        ?.toLowerCase()
        .replaceAll(RegExp(r'[^a-z]'), '')
        .trim();
    if (normalized == null || normalized.isEmpty) return null;

    const aliasMap = <String, String>{
      'en': 'english',
      'eng': 'english',
      'english': 'english',
      'hi': 'hindi',
      'hindi': 'hindi',
      'hindustani': 'hindi',
      'ml': 'malayalam',
      'malayalam': 'malayalam',
      'ta': 'tamil',
      'tamil': 'tamil',
      'te': 'telugu',
      'telugu': 'telugu',
      'kn': 'kannada',
      'kannada': 'kannada',
      'bn': 'bengali',
      'bengali': 'bengali',
      'bangla': 'bengali',
      'pa': 'punjabi',
      'punjabi': 'punjabi',
      'gu': 'gujarati',
      'gujarati': 'gujarati',
      'mr': 'marathi',
      'marathi': 'marathi',
      'ur': 'urdu',
      'urdu': 'urdu',
    };

    return aliasMap[normalized] ?? normalized;
  }

  static String? _detectLanguageFromLyrics(String lyrics) {
    final sample = lyrics.trim();
    if (sample.isEmpty) return null;

    final malayalam = RegExp(r'[\u0D00-\u0D7F]').allMatches(sample).length;
    final tamil = RegExp(r'[\u0B80-\u0BFF]').allMatches(sample).length;
    final telugu = RegExp(r'[\u0C00-\u0C7F]').allMatches(sample).length;
    final kannada = RegExp(r'[\u0C80-\u0CFF]').allMatches(sample).length;
    final devanagari = RegExp(r'[\u0900-\u097F]').allMatches(sample).length;
    final bengali = RegExp(r'[\u0980-\u09FF]').allMatches(sample).length;
    final gujarati = RegExp(r'[\u0A80-\u0AFF]').allMatches(sample).length;
    final gurmukhi = RegExp(r'[\u0A00-\u0A7F]').allMatches(sample).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(sample).length;

    final topScore = <String, int>{
      'malayalam': malayalam,
      'tamil': tamil,
      'telugu': telugu,
      'kannada': kannada,
      'hindi': devanagari,
      'bengali': bengali,
      'gujarati': gujarati,
      'punjabi': gurmukhi,
      'english': latin,
    }.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    if (topScore.isEmpty || topScore.first.value < 4) return null;
    return topScore.first.key;
  }

  static LyricsPayload? _payloadFromJson(Map<String, dynamic> json) {
    final plainRaw = (json['plainLyrics'] ??
            json['originalPlainLyrics'] ??
            json['lyrics'] ??
            json['plain_lyrics'])
        ?.toString()
        .trim();
    final normalizedSynced = _normalizeSyncedLyrics(
      (json['syncedLyrics'] ??
              json['originalSyncedLyrics'] ??
              json['synced_lyrics'])
          ?.toString()
          .trim(),
    );

    final plainValid = _isValidLyrics(plainRaw);
    final syncedValid = _isValidSyncedLyrics(normalizedSynced);
    if (!plainValid && !syncedValid) return null;

    final syncedLyrics = syncedValid ? normalizedSynced : null;
    final plainLyrics = plainValid
        ? plainRaw
        : (syncedLyrics != null ? _stripTimestamps(syncedLyrics) : null);

    if (!_isValidLyrics(plainLyrics) && syncedLyrics == null) return null;
    return LyricsPayload(plainLyrics: plainLyrics, syncedLyrics: syncedLyrics);
  }

  static String? _normalizeSyncedLyrics(String? rawSyncedLyrics) {
    if (rawSyncedLyrics == null || rawSyncedLyrics.trim().isEmpty) return null;
    final parsedLines = _parseLrcLines(rawSyncedLyrics);
    if (parsedLines.length < 2) return null;

    return parsedLines
        .map((line) => '${line.timestampTag} ${line.text}')
        .join('\n');
  }

  static List<_LrcLine> _parseLrcLines(String rawSyncedLyrics) {
    final lines = <_LrcLine>[];
    final seenTimestamps = <int>{};

    for (final row in rawSyncedLyrics.split('\n')) {
      final matches = _lrcTagRegex.allMatches(row).toList(growable: false);
      if (matches.isEmpty) continue;

      final text = row.replaceAll(_lrcTagRegex, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minute = int.tryParse(match.group(1) ?? '') ?? -1;
        final second = int.tryParse(match.group(2) ?? '') ?? -1;
        if (minute < 0 || second < 0 || second >= 60) continue;

        final millis = _fractionToMillis(match.group(3));
        final totalMillis = (minute * 60 * 1000) + (second * 1000) + millis;
        if (seenTimestamps.contains(totalMillis)) continue;
        seenTimestamps.add(totalMillis);

        lines.add(
          _LrcLine(
            millis: totalMillis,
            timestampTag: _timestampTagFromMillis(totalMillis),
            text: text,
          ),
        );
      }
    }

    lines.sort((a, b) => a.millis.compareTo(b.millis));
    return lines;
  }

  static int _fractionToMillis(String? rawFraction) {
    if (rawFraction == null || rawFraction.isEmpty) return 0;
    if (rawFraction.length == 3) return int.tryParse(rawFraction) ?? 0;
    if (rawFraction.length == 2) return (int.tryParse(rawFraction) ?? 0) * 10;
    return (int.tryParse(rawFraction) ?? 0) * 100;
  }

  static String _timestampTagFromMillis(int millis) {
    final safeMillis = millis < 0 ? 0 : millis;
    final totalSeconds = safeMillis ~/ 1000;
    final minute = totalSeconds ~/ 60;
    final second = totalSeconds % 60;
    final fraction = safeMillis % 1000;
    return '[${minute.toString().padLeft(2, '0')}:${second.toString().padLeft(2, '0')}.${fraction.toString().padLeft(3, '0')}]';
  }

  static bool _isValidLyrics(String? lyrics) {
    if (lyrics == null) return false;
    final cleaned = lyrics.trim();
    if (cleaned.isEmpty) return false;
    return cleaned.length > 20;
  }

  static bool _isValidSyncedLyrics(String? syncedLyrics) {
    if (syncedLyrics == null) return false;
    return _parseLrcLines(syncedLyrics).length >= 2;
  }

  static String _stripTimestamps(String syncedLyrics) {
    return syncedLyrics
        .replaceAll(_lrcTagRegex, '')
        .replaceAll(RegExp(r'^\s*\n', multiLine: true), '')
        .trim();
  }

  static int? _parseDurationSeconds(dynamic value) {
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

  static String _cleanArtist(String artist) {
    var cleaned = artist
        .split(',')
        .first
        .split('&')
        .first
        .split('feat.')
        .first
        .split('ft.')
        .first;

    cleaned = cleaned
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'[™®℗♪♫]'), '')
        .trim();

    try {
      cleaned = cleaned.replaceAll(
        RegExp(r'[\u{1F600}-\u{1F64F}|\u{1F300}-\u{1F5FF}|\u{1F680}-\u{1F6FF}|\u{2600}-\u{26FF}|\u{2700}-\u{27BF}]', unicode: true),
        '',
      );
    } catch (_) {}

    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _cleanTitle(String title) {
    var cleaned = title;

    final patterns = [
      RegExp(r'\(?\b(remastered|remaster|live|concert|official video|official audio|official music video|official|video|audio|lyric video|lyrics video|unplugged)\b.*?\)?', caseSensitive: false),
      RegExp(r'\[?\b(remastered|remaster|live|concert|official video|official audio|official music video|official|video|audio|lyric video|lyrics video|unplugged)\b.*?\]?', caseSensitive: false),
      RegExp(r'\b(feat\.|ft\.).*', caseSensitive: false),
      RegExp(r'-\s*$'),
    ];

    for (final pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, '');
    }

    cleaned = cleaned.replaceAll(RegExp(r'\(\d{4}\)'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\[\d{4}\]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\(\s*\)'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\[\s*\]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\(.*?\)'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\[.*?\]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[™®℗♪♫]'), '');

    try {
      cleaned = cleaned.replaceAll(
        RegExp(r'[\u{1F600}-\u{1F64F}|\u{1F300}-\u{1F5FF}|\u{1F680}-\u{1F6FF}|\u{2600}-\u{26FF}|\u{2700}-\u{27BF}]', unicode: true),
        '',
      );
    } catch (_) {}

    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
