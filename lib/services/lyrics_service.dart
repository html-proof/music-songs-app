import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import '../models/lyrics_metadata.dart';
import '../models/lyrics_payload.dart';
import 'api_service.dart';
import 'lyrics_alignment_engine.dart';
import 'lyrics_cache.dart';
import 'stability_logger.dart';


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
  final String? isrc;
  final bool isExplicit;

  const _LyricsLookup({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.language,
    required this.durationSeconds,
    this.isrc,
    this.isExplicit = false,
  });

  factory _LyricsLookup.fromMetadata(LyricsMetadata song) {
    final album = (song.album ?? '').trim();
    return _LyricsLookup(
      trackId: (song.songId ?? '').trim(),
      title: song.title.trim(),
      artist: song.artist.trim(),
      album: album,
      language: song.language?.trim(),
      durationSeconds: song.duration,
      isrc: song.isrc?.trim(),
      isExplicit: false,
    );
  }

  factory _LyricsLookup.fromSong(Song song) {
    return _LyricsLookup.fromMetadata(song.toLyricsMetadata());
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
  final String? isrc;
  final String? songId;

  const _LyricsCandidate({
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    required this.language,
    this.isrc,
    this.songId,
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

  static http.Client? _activeClient;

  static void cancelActiveSearches() {
    try {
      _activeClient?.close();
      _activeClient = null;
    } catch (_) {}
  }

  static bool _isClosedError(Object e) {
    return e.toString().toLowerCase().contains('client is already closed');
  }

  static String normalizeQuery(String text) {
    var cleaned = text.toLowerCase();
    
    // Remove specific terms as per requirement
    final patterns = [
      RegExp(r'\b(official video|official audio|official music video|full video|official|audio|video|lyrics|full lyrics|song lyrics|hd|4k|remastered|live|karaoke)\b', caseSensitive: false),
      RegExp(r'[^\w\s]', unicode: true), // Special characters
    ];
    
    for (final pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, '');
    }
    
    // Extra spaces
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

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

  static Future<LyricsPayload?> alignAudioWithServer(Song song, String plainLyrics) async {
    final client = ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      final audioUrl = song.streamUrl ?? '';
      if (audioUrl.isEmpty) return null;

      debugPrint('[LyricsService] Attempting server forced-alignment for: ${song.name}');
      final response = await client.post(
        Uri.parse('http://localhost:8000/align'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'audio_url': audioUrl,
          'lyrics': plainLyrics,
          'title': song.name,
          'artist': song.artist ?? '',
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final syncedLrc = data['synced_lyrics']?.toString();
        final confidence = double.tryParse(data['confidence']?.toString() ?? '1.0') ?? 1.0;
        
        if (syncedLrc != null && syncedLrc.trim().isNotEmpty) {
          debugPrint('[LyricsService] Server alignment successful with confidence $confidence');
          return LyricsPayload(
            plainLyrics: plainLyrics,
            syncedLyrics: syncedLrc,
            provider: 'forced_alignment',
            confidence: confidence,
          );
        }
      }
    } catch (e) {
      debugPrint('[LyricsService] Failed to align lyrics via server: $e');
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


  static Future<LyricsPayload?> getLyricsPayloadForSong(LyricsMetadata song) async {
    final lookup = _LyricsLookup.fromSong(Song(id: song.songId ?? "", name: song.title, artist: song.artist, album: song.album, duration: song.duration, language: song.language, isrc: song.isrc, songUrl: song.songUrl));
    if (lookup.title.isEmpty) return null;

    final candidates = await _fetchCandidates(lookup);
    final bestPayload = _selectBestPayload(lookup, candidates);
    if (bestPayload != null && bestPayload.hasAny) {
      return bestPayload;
    }

    if (song.songUrl != null && song.songUrl!.isNotEmpty) {
      debugPrint('[LyricsService] Falling back to JioSaavn scrape for: ${song.title}');
      final scraped = await _scrapeJioSaavnLyrics(song.songUrl!);
      if (scraped != null && scraped.hasAny) {
        return scraped;
      }
    }

    return null;
  }

  static String _getPrimaryArtist(String artistText) {
    if (artistText.isEmpty) return '';
    return artistText.split(RegExp(r',|;|feat\.|ft\.', caseSensitive: false)).first.trim();
  }

  static List<LyricsLine> _parseCandidateLines(_LyricsCandidate candidate, {required bool isSynced}) {
    if (isSynced) {
      if (candidate.syncedLyrics == null) return const [];
      return _parseLrcLines(candidate.syncedLyrics!).map((l) {
        return LyricsLine(
          timestamp: Duration(milliseconds: l.millis),
          text: l.text,
        );
      }).toList();
    } else {
      if (candidate.plainLyrics == null) return const [];
      return candidate.plainLyrics!
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map((line) => LyricsLine(timestamp: Duration.zero, text: line))
          .toList();
    }
  }

  static bool _validateCandidate(_LyricsCandidate candidate, {required bool isSynced, String? expectedLanguage}) {
    final lines = _parseCandidateLines(candidate, isSynced: isSynced);
    if (lines.isEmpty) return false;
    if (lines.length < 5) return false;

    if (isSynced) {
      final allZero = lines.every((l) => l.timestamp == Duration.zero);
      if (allZero) return false;
    }

    // Check duplicate lines
    final texts = lines.map((l) => l.text.trim().toLowerCase()).where((t) => t.isNotEmpty).toList();
    if (texts.isEmpty) return false;
    final uniqueTexts = texts.toSet();
    final duplicateRatio = 1.0 - (uniqueTexts.length / texts.length);
    if (duplicateRatio > 0.70) return false;

    // Check for HTML/XML
    final htmlRegExp = RegExp(r'<[^>]+>');
    int htmlCount = 0;
    for (final l in lines) {
      if (htmlRegExp.hasMatch(l.text)) {
        htmlCount++;
      }
    }
    if (lines.isNotEmpty && (htmlCount / lines.length) > 0.20) {
      return false;
    }

    // Check wrong language (if expectedLanguage is known/provided)
    if (expectedLanguage != null && expectedLanguage.isNotEmpty) {
      final fullText = lines.map((l) => l.text).join('\n');
      final detectedLang = _detectLanguageFromLyrics(fullText);
      final normExpected = _normalizeLanguage(expectedLanguage);
      if (detectedLang != null && normExpected != null && detectedLang != normExpected) {
        return false;
      }
    }

    return true;
  }

  static LyricsPayload? _payloadFromCandidate(_LyricsCandidate cand, String provider) {
    final synced = cand.syncedLyrics;
    final plain = _coalescePlainLyrics(cand.plainLyrics, synced);
    if (synced == null && plain == null) return null;
    return LyricsPayload(
      plainLyrics: plain,
      syncedLyrics: synced,
      provider: provider,
    );
  }

  static String _stripMovieName(String title) {
    var cleaned = title.replaceAll(
      RegExp(r'\(?([Ff]rom\s+.*?)\)?|\[?([Ff]rom\s+.*?)\]?', caseSensitive: false),
      '',
    );
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static _LyricsCandidate? _findBestCandidate(
    _LyricsLookup lookup,
    List<_LyricsCandidate> candidates,
    double minConfidence,
  ) {
    if (candidates.isEmpty) return null;

    final valid = candidates.where((cand) {
      final hasSynced = _isValidSyncedLyrics(cand.syncedLyrics);
      final hasPlain = _isValidLyrics(cand.plainLyrics);
      if (!hasSynced && !hasPlain) return false;

      final isSynced = hasSynced;
      if (!_validateCandidate(cand, isSynced: isSynced, expectedLanguage: lookup.language)) return false;

      final conf = _calculateConfidenceScore(lookup, cand);
      return conf >= minConfidence;
    }).toList();

    if (valid.isEmpty) return null;

    // Sort by confidence score (descending)
    valid.sort((a, b) => _calculateConfidenceScore(lookup, b)
        .compareTo(_calculateConfidenceScore(lookup, a)));

    return valid.first;
  }

  static Future<LyricsPayload?> _winnerPayload(
    _LyricsCandidate winner,
    LyricsMetadata song,
    String provider,
  ) async {
    final isVerified = provider.startsWith('lrclib');
    var payload = _payloadFromCandidate(winner, isVerified ? 'verified' : 'scraper');
    if (payload != null && payload.hasAny) {
      if (!payload.hasSynced && payload.hasPlain) {
        final songObj = Song(
          id: song.songId ?? "",
          name: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.duration,
          language: song.language,
          isrc: song.isrc,
          songUrl: song.songUrl,
        );
        final serverAligned = await alignAudioWithServer(songObj, payload.plainLyrics!);
        if (serverAligned != null) {
          payload = serverAligned;
        } else {
          payload = LyricsAlignmentEngine.align(songObj, payload);
        }
      }
      return payload;
    }
    return null;
  }

  static Future<LyricsPayload?> progressiveLyricsSearch(LyricsMetadata song) async {
    final songId = (song.songId ?? "").trim();
    final title = song.title.trim();
    final artist = song.artist.trim();
    final album = (song.album ?? '').trim();
    final duration = song.duration;
    final isrc = (song.isrc ?? '').trim();
    final cleanTitle = _cleanTitle(title);
    final cleanArtist = _cleanArtist(artist);
    final language = song.language;

    StabilityLogger.info('Lyrics', 'Starting priority sequential search for: $title (ID: $songId)');

    cancelActiveSearches();
    final client = ApiService.createSecureHttpClient(pinCertificates: false);
    _activeClient = client;

    bool isCancelled() => _activeClient != client;

    final lookup = _LyricsLookup.fromMetadata(song);
    final candidates = <_LyricsCandidate>[];

    void addResult(Map<String, dynamic>? entry) {
      if (entry != null) {
        final cand = _candidateFromJson(entry);
        if (cand != null) {
          candidates.add(cand);
        }
      }
    }

    void addResults(List<Map<String, dynamic>> entries) {
      for (final entry in entries) {
        final cand = _candidateFromJson(entry);
        if (cand != null) {
          candidates.add(cand);
        }
      }
    }

    // Step 1: Direct JioSaavn Song ID Lookup
    if (songId.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final directCandidate = await _scrapeJioSaavnLyricsDirect(
          songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          client: client,
        );
        if (isCancelled()) return null;
        if (directCandidate != null) {
          candidates.add(directCandidate);
        }
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.75);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();

        // Cache the lyrics locally using LyricsCache
        await LyricsCache.put(
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          payload: winner.plainLyrics != null || winner.syncedLyrics != null
              ? LyricsPayload(
                  plainLyrics: winner.plainLyrics,
                  syncedLyrics: winner.syncedLyrics,
                  provider: 'jiosaavn API',
                )
              : null,
          providerSource: 'saavn',
        );

        return _winnerPayload(winner, song, 'jiosaavn_direct_id');
      }
    }

    // Prepare cleaned components
    final titleWithoutMovie = _stripMovieName(title);

    // Step 2: JioSaavn Search-by-Name Fallback
    if (titleWithoutMovie.isNotEmpty && cleanArtist.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final jioCandidates = await _searchJioSaavnCandidates(
          '$titleWithoutMovie $cleanArtist',
          client: client,
        );
        if (isCancelled()) return null;
        for (final jioCand in jioCandidates) {
          if (isCancelled()) return null;
          if (jioCand.plainLyrics != null || jioCand.syncedLyrics != null) {
            final conf = _calculateConfidenceScore(lookup, jioCand);
            if (conf >= 0.75) {
              candidates.add(jioCand);
            }
          } else if (jioCand.songId != null && jioCand.songId!.isNotEmpty) {
            final conf = _calculateConfidenceScore(lookup, jioCand);
            if (conf >= 0.75) {
              final fetchedCand = await _scrapeJioSaavnLyricsDirect(
                jioCand.songId!,
                title: jioCand.trackName,
                artist: jioCand.artistName,
                album: jioCand.albumName,
                duration: jioCand.durationSeconds,
                client: client,
              );
              if (isCancelled()) return null;
              if (fetchedCand != null) {
                candidates.add(fetchedCand);
              }
            }
          }
        }
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.75);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();

        // Cache the lyrics locally using LyricsCache
        await LyricsCache.put(
          songId: winner.songId ?? songId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          payload: winner.plainLyrics != null || winner.syncedLyrics != null
              ? LyricsPayload(
                  plainLyrics: winner.plainLyrics,
                  syncedLyrics: winner.syncedLyrics,
                  provider: 'jiosaavn API',
                )
              : null,
          providerSource: 'saavn',
        );

        return _winnerPayload(winner, song, 'jiosaavn_search_by_name');
      }
    }

    // Step 3: LRCLIB Fallback Chain

    // A. ISRC Lookup (Direct & highest confidence)
    if (isrc.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final res = await _lrclibGetEntry(artist: '', title: '', isrc: isrc, client: client);
        if (isCancelled()) return null;
        addResult(res);
      } catch (_) {}
      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.90);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();
        return _winnerPayload(winner, song, 'lrclib_isrc');
      }
    }

    // B. Song Title (without movie) + Artist
    if (titleWithoutMovie.isNotEmpty && cleanArtist.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final res = await _lrclibGetEntry(
          artist: cleanArtist,
          title: titleWithoutMovie,
          durationSeconds: duration > 0 ? duration : null,
          client: client,
        );
        if (isCancelled()) return null;
        addResult(res);

        final searchRes = await _lrclibSearchEntries('$titleWithoutMovie $cleanArtist', client: client);
        if (isCancelled()) return null;
        addResults(searchRes);
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.82);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();
        return _winnerPayload(winner, song, 'lrclib_primary');
      }
    }

    // C. Song Title + Artist + Album
    if (titleWithoutMovie.isNotEmpty && cleanArtist.isNotEmpty && album.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final res = await _lrclibGetEntry(
          artist: cleanArtist,
          title: titleWithoutMovie,
          album: album,
          durationSeconds: duration > 0 ? duration : null,
          client: client,
        );
        if (isCancelled()) return null;
        addResult(res);

        final searchRes = await _lrclibSearchEntries('$titleWithoutMovie $cleanArtist $album', client: client);
        if (isCancelled()) return null;
        addResults(searchRes);
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.82);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();
        return _winnerPayload(winner, song, 'lrclib_primary_album');
      }
    }

    // D. Clean Song Title + Artist
    if (cleanTitle.isNotEmpty && cleanArtist.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final res = await _lrclibGetEntry(
          artist: cleanArtist,
          title: cleanTitle,
          durationSeconds: duration > 0 ? duration : null,
          client: client,
        );
        if (isCancelled()) return null;
        addResult(res);

        final searchRes = await _lrclibSearchEntries('$cleanTitle $cleanArtist', client: client);
        if (isCancelled()) return null;
        addResults(searchRes);
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.82);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();
        return _winnerPayload(winner, song, 'lrclib_clean_title');
      }
    }

    // E. Song Title only
    if (titleWithoutMovie.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final searchRes = await _lrclibSearchEntries(titleWithoutMovie, client: client);
        if (isCancelled()) return null;
        addResults(searchRes);
      } catch (_) {}

      if (isCancelled()) return null;
      final winner = _findBestCandidate(lookup, candidates, 0.80);
      if (winner != null) {
        if (_activeClient == client) _activeClient = null;
        client.close();
        return _winnerPayload(winner, song, 'lrclib_title_only');
      }
    }

    // Last Resort (JioSaavn Scraper, Search Engine Scraper, or Movie Album name)

    // A. JioSaavn Web Scraper
    if (song.songUrl != null && song.songUrl!.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final scraped = await _scrapeJioSaavnLyrics(song.songUrl!, client: client);
        if (isCancelled()) return null;
        if (scraped != null) {
          candidates.add(_LyricsCandidate(
            plainLyrics: scraped.plainLyrics,
            syncedLyrics: scraped.syncedLyrics,
            trackName: title,
            artistName: artist,
            albumName: album,
            durationSeconds: duration,
            language: language,
          ));
        }
      } catch (_) {}
    }

    // B. Search Engine Scraper with movie/album search queries
    if (isCancelled()) return null;
    try {
      final scraped = await _scrapeLyricsFromSearchEngine(title, artist, album, language, client);
      if (isCancelled()) return null;
      if (scraped != null) {
        candidates.add(_LyricsCandidate(
          plainLyrics: scraped.plainLyrics,
          syncedLyrics: scraped.syncedLyrics,
          trackName: title,
          artistName: artist,
          albumName: album,
          durationSeconds: duration,
          language: language,
        ));
      }
    } catch (_) {}

    // C. Original title queries containing movie/album name as a last resort
    if (title.isNotEmpty && artist.isNotEmpty) {
      if (isCancelled()) return null;
      try {
        final res = await _lrclibGetEntry(
          artist: artist,
          title: title,
          album: album.isNotEmpty ? album : null,
          durationSeconds: duration > 0 ? duration : null,
          client: client,
        );
        if (isCancelled()) return null;
        addResult(res);
      } catch (_) {}
    }

    if (_activeClient == client) {
      _activeClient = null;
    }
    client.close();

    final winner = _findBestCandidate(lookup, candidates, 0.50); // Relaxed threshold for last resort
    if (winner != null) {
      return _winnerPayload(winner, song, 'last_resort');
    }

    _logDetailedLyricsFailure(
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      cleanTitle: cleanTitle,
      cleanArtist: cleanArtist,
      isrc: isrc,
      reason: 'All priority sequential search fallback steps completed with no matching candidate.',
    );
    return null;
  }

  static void _logDetailedLyricsFailure({
    required String songId,
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String cleanTitle,
    required String cleanArtist,
    required String isrc,
    required String reason,
  }) {
    StabilityLogger.warning('Lyrics',
      '=== LYRICS RESOLUTION FAILURE ===\n'
      'Song ID: $songId\n'
      'Title: $title\n'
      'Artist: $artist\n'
      'Album: $album\n'
      'Duration: ${duration}s\n'
      'Normalized Title: $cleanTitle\n'
      'Normalized Artist: $cleanArtist\n'
      'ISRC: $isrc\n'
      'Failure Reason: $reason\n'
      '================================='
    );
  }

  static String decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  static List<String> generateScraperQueries(
      String title, String artist, String? album, String? language) {
    String clean(String text) {
      var cleaned = text.toLowerCase();
      // Remove brackets and content like (Official Video), [Lyrics], etc.
      cleaned = cleaned.replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '');
      // Remove specific words
      cleaned = cleaned.replaceAll(
        RegExp(r'\b(official video|official audio|official music video|full video|official|audio|video|lyrics|full lyrics|song lyrics|hd|4k|remastered|live|karaoke)\b', caseSensitive: false),
        '',
      );
      // Remove all punctuation/non-alphanumeric except spaces
      cleaned = cleaned.replaceAll(RegExp(r'[^\w\s]', unicode: true), '');
      // Remove duplicate spaces
      cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
      return cleaned;
    }

    final cleanTitle = clean(title);
    final cleanArtist = clean(artist);
    
    // Extract movie name if present in title
    String? movie;
    final movieMatch = RegExp(r'(?:\([Ff]rom\s+([^)]+)\)|\[[Ff]rom\s+([^\]]+)\])').firstMatch(title);
    if (movieMatch != null) {
      movie = (movieMatch.group(1) ?? movieMatch.group(2));
    }
    
    final cleanMovie = (movie != null && movie.isNotEmpty) ? clean(movie) : ((album != null && album.isNotEmpty) ? clean(album) : '');

    final Set<String> queries = {};
    
    if (cleanTitle.isNotEmpty) {
      queries.add('$cleanTitle lyrics');
      if (cleanMovie.isNotEmpty) {
        queries.add('$cleanTitle $cleanMovie lyrics');
      }
      if (cleanArtist.isNotEmpty) {
        queries.add('$cleanTitle $cleanArtist lyrics');
      }
      if (cleanArtist.isNotEmpty && cleanMovie.isNotEmpty) {
        final firstArtistWord = cleanArtist.split(' ').first;
        queries.add('$cleanTitle $cleanMovie $firstArtistWord lyrics');
      }
      if (cleanMovie.isNotEmpty) {
        queries.add('$cleanMovie $cleanTitle lyrics');
      }
      if (language != null && language.isNotEmpty) {
        final cleanLang = clean(language);
        if (cleanLang.isNotEmpty) {
          queries.add('$cleanTitle $cleanLang lyrics');
        }
      }
      queries.add('$cleanTitle full lyrics');
    }
    
    return queries.toList();
  }

  static Future<LyricsPayload?> _scrapeLyricsFromSearchEngine(
      String title, String artist, String? album, String? language, http.Client client) async {
    try {
      final queries = generateScraperQueries(title, artist, album, language);
      if (queries.isEmpty) return null;

      // Try the top 3 generated queries sequentially to avoid flooding network
      final queriesToTry = queries.take(3).toList();

      for (final queryStr in queriesToTry) {
        final query = Uri.encodeComponent(queryStr);
        final ddgUrl = 'https://html.duckduckgo.com/html/?q=$query';

        StabilityLogger.info('Lyrics', 'Scraping search engine fallback with query: $queryStr');

        try {
          final List<String> targetUrls = [];

          // Try DuckDuckGo first
          try {
            final searchResponse = await _getWithRetry(
              Uri.parse(ddgUrl),
              headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              },
              client: client,
              timeout: const Duration(seconds: 4),
            );

            if (searchResponse.statusCode == 200) {
              final html = searchResponse.body;
              final regExp = RegExp(r'href="([^"]+)"');
              final matches = regExp.allMatches(html);

              for (final match in matches) {
                final rawLink = match.group(1)!;
                final decodedLink = Uri.decodeFull(rawLink);
                final uddgMatch = RegExp(r'uddg=([^&]+)').firstMatch(decodedLink);
                if (uddgMatch != null) {
                  final targetUrl = uddgMatch.group(1)!;
                  if (targetUrl.contains('azlyrics.com/lyrics/') || targetUrl.contains('songlyrics.com/')) {
                    targetUrls.add(targetUrl);
                  }
                }
              }
            }
          } catch (e) {
            if (_isClosedError(e)) rethrow;
            debugPrint('[LyricsService] DuckDuckGo query failed: $e');
          }

          // Fallback to Google Search if DuckDuckGo yielded nothing
          if (targetUrls.isEmpty) {
            try {
              final googleUrl = 'https://www.google.com/search?q=$query';
              StabilityLogger.info('Lyrics', 'Scraping Google search fallback with query: $queryStr');
              final googleResponse = await _getWithRetry(
                Uri.parse(googleUrl),
                headers: {
                  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                },
                client: client,
                timeout: const Duration(seconds: 4),
              );

              if (googleResponse.statusCode == 200) {
                final html = googleResponse.body;
                final regExp = RegExp(r'href="([^"]+)"');
                final matches = regExp.allMatches(html);

                for (final match in matches) {
                  final rawLink = match.group(1)!;
                  final decodedLink = Uri.decodeFull(rawLink);
                  if (decodedLink.contains('azlyrics.com/lyrics/') || decodedLink.contains('songlyrics.com/')) {
                    final startIndex = decodedLink.indexOf('http');
                    if (startIndex != -1) {
                      var targetUrl = decodedLink.substring(startIndex);
                      final ampIndex = targetUrl.indexOf('&');
                      if (ampIndex != -1) {
                        targetUrl = targetUrl.substring(0, ampIndex);
                      }
                      targetUrls.add(targetUrl);
                    }
                  }
                }
              }
            } catch (e) {
              if (_isClosedError(e)) rethrow;
              debugPrint('[LyricsService] Google query failed: $e');
            }
          }

          if (targetUrls.isEmpty) {
            continue;
          }

          for (final url in targetUrls) {
            try {
              StabilityLogger.info('Lyrics', 'Scraping target URL: $url');
              final response = await _getWithRetry(
                Uri.parse(url),
                headers: {
                  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                },
                client: client,
                timeout: const Duration(seconds: 4),
              );

              if (response.statusCode != 200) continue;

              final pageHtml = response.body;
              String? rawLyrics;

              if (url.contains('azlyrics.com')) {
                final commentRegExp = RegExp(r'<!-- Usage of azlyrics\.com content[\s\S]*?-->([\s\S]*?)</div>');
                final lyricsMatch = commentRegExp.firstMatch(pageHtml);
                if (lyricsMatch != null) {
                  rawLyrics = lyricsMatch.group(1)!;
                }
              } else if (url.contains('songlyrics.com')) {
                final lyricsDivRegExp = RegExp(r'<p id="songLyricsDiv"[^>]*>([\s\S]*?)</p>');
                final lyricsMatch = lyricsDivRegExp.firstMatch(pageHtml);
                if (lyricsMatch != null) {
                  rawLyrics = lyricsMatch.group(1)!;
                }
              }

              if (rawLyrics != null) {
                var lyrics = rawLyrics.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
                lyrics = lyrics.replaceAll(RegExp(r'<[^>]*>'), '');
                lyrics = decodeHtmlEntities(lyrics);

                if (lyrics.isNotEmpty && !lyrics.toLowerCase().contains('we do not have the lyrics for this song')) {
                  StabilityLogger.info('Lyrics', 'Successfully scraped search engine lyrics from: $url');
                  return LyricsPayload(
                    plainLyrics: lyrics,
                    syncedLyrics: null,
                    provider: 'Search Scraper (${Uri.parse(url).host})',
                  );
                }
              }
            } catch (e) {
              if (_isClosedError(e)) rethrow;
              debugPrint('[LyricsService] Scraper failed for $url: $e');
            }
          }
        } catch (e) {
          if (_isClosedError(e)) rethrow;
          debugPrint('[LyricsService] DuckDuckGo request failed for query $queryStr: $e');
        }
      }
    } catch (e) {
      if (!_isClosedError(e)) {
        debugPrint('[LyricsService] Error during search engine lyrics scraping: $e');
      }
    }
    return null;
  }

  static Future<_LyricsCandidate?> _scrapeJioSaavnLyricsDirect(
    String songId, {
    required String title,
    required String artist,
    required String album,
    int? duration,
    http.Client? client,
  }) async {
    final sId = songId.trim();
    if (sId.isEmpty) return null;
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      // 1. Direct api.php call
      final lyricsUrl = 'https://www.jiosaavn.com/api.php?__call=lyrics.getLyrics&lyrics_id=$sId&ctx=web6dot0&api_version=4&_format=json';
      final res = await _getWithRetry(
        Uri.parse(lyricsUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
        client: clientToUse,
        timeout: const Duration(seconds: 4),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data != null && data is Map && data['status'] != 'failure' && data['lyrics'] != null) {
          var rawLyrics = data['lyrics'].toString();
          if (rawLyrics.isNotEmpty) {
            rawLyrics = rawLyrics.replaceAll(RegExp(r'</?br/?>'), '\n');
            rawLyrics = rawLyrics.replaceAll(RegExp(r'<[^>]*>'), '');
            
            rawLyrics = rawLyrics
                .replaceAll('&amp;', '&')
                .replaceAll('&quot;', '"')
                .replaceAll('&#039;', "'")
                .replaceAll('&apos;', "'")
                .replaceAll('&lt;', '<')
                .replaceAll('&gt;', '>');

            final cleaned = rawLyrics.trim();
            if (cleaned.isNotEmpty) {
              return _LyricsCandidate(
                plainLyrics: cleaned,
                syncedLyrics: null,
                trackName: title,
                artistName: artist,
                albumName: album,
                durationSeconds: duration,
                language: null,
                songId: sId,
              );
            }
          }
        }
      }
    } catch (e) {
      if (_isClosedError(e)) rethrow;
      debugPrint('[LyricsService] Direct JioSaavn api.php lyrics retrieval failed: $e');
    }

    // 2. Unofficial API endpoints (/lyrics/?query=...)
    final endpoints = [
      '${ApiService.baseUrl}/lyrics/?query=$sId&lyrics=true',
      '${ApiService.baseUrl}/lyrics?query=$sId&lyrics=true',
      'https://jiosaavn-api-murex.vercel.app/lyrics/?query=$sId&lyrics=true',
      'https://jiosaavn-api-murex.vercel.app/lyrics?query=$sId&lyrics=true',
    ];
    for (final url in endpoints) {
      try {
        final res = await _getWithRetry(
          Uri.parse(url),
          headers: {'User-Agent': 'MusicHub/2.0'},
          client: clientToUse,
          timeout: const Duration(seconds: 4),
        );
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final data = body['data'] ?? body;
          final lyrics = data['lyrics']?.toString();
          if (lyrics != null && lyrics.isNotEmpty) {
            final hasLrcTags = _lrcTagRegex.hasMatch(lyrics);
            return _LyricsCandidate(
              plainLyrics: hasLrcTags ? null : lyrics,
              syncedLyrics: hasLrcTags ? lyrics : data['snippets']?.toString(),
              trackName: data['name'] ?? title,
              artistName: data['artist'] ?? artist,
              albumName: data['album'] ?? album,
              durationSeconds: duration,
              language: null,
              songId: sId,
            );
          }
        }
      } catch (e) {
        if (_isClosedError(e)) rethrow;
      }
    }

    // 3. Fallback to existing _fetchSaavnCandidate (which uses baseUrl /api/songs/:id/lyrics)
    try {
      final saavnCandidate = await _fetchSaavnCandidate(
        sId,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        client: clientToUse,
      );
      if (saavnCandidate != null) {
        return saavnCandidate;
      }
    } catch (e) {
      if (_isClosedError(e)) rethrow;
    }

    return null;
  }

  static Future<List<_LyricsCandidate>> _searchJioSaavnCandidates(
    String query, {
    http.Client? client,
  }) async {
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    final results = <_LyricsCandidate>[];

    final endpoints = [
      '${ApiService.baseUrl}/api/search/songs?query=${Uri.encodeComponent(query)}',
      'https://jiosaavn-api-murex.vercel.app/api/search/songs?query=${Uri.encodeComponent(query)}',
      '${ApiService.baseUrl}/result/?query=${Uri.encodeComponent(query)}&lyrics=true',
      '${ApiService.baseUrl}/result?query=${Uri.encodeComponent(query)}&lyrics=true',
      'https://jiosaavn-api-murex.vercel.app/result/?query=${Uri.encodeComponent(query)}&lyrics=true',
      'https://jiosaavn-api-murex.vercel.app/result?query=${Uri.encodeComponent(query)}&lyrics=true',
    ];

    for (final url in endpoints) {
      try {
        final res = await _getWithRetry(
          Uri.parse(url),
          headers: {'User-Agent': 'MusicHub/2.0'},
          client: clientToUse,
          timeout: const Duration(seconds: 4),
        );
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final data = body['data'] ?? body;
          List<dynamic> items = [];
          if (data is List) {
            items = data;
          } else if (data is Map) {
            if (data['results'] is List) {
              items = data['results'] as List;
            } else if (data['songs'] is List) {
              items = data['songs'] as List;
            } else if (data['songs'] is Map && data['songs']['results'] is List) {
              items = data['songs']['results'] as List;
            } else {
              items = [data];
            }
          }

          for (final item in items) {
            if (item is! Map) continue;
            final map = Map<String, dynamic>.from(item);
            
            final songId = map['id']?.toString() ?? '';
            if (songId.isEmpty) continue;

            final trackName = map['name'] ?? map['title'] ?? '';
            String artistName = '';
            if (map['artists'] != null) {
              if (map['artists'] is Map) {
                final primary = map['artists']['primary'];
                if (primary is List) {
                  artistName = primary.map((a) => a['name'] ?? '').join(', ');
                } else {
                  artistName = map['artists']['primary']?.toString() ?? '';
                }
              } else {
                artistName = map['artists']?.toString() ?? '';
              }
            } else if (map['primaryArtists'] != null) {
              artistName = map['primaryArtists'].toString();
            }

            final albumName = map['album'] is Map ? map['album']['name']?.toString() : map['album']?.toString();
            final duration = _parseDurationSeconds(map['duration']);

            final lyrics = map['lyrics']?.toString();
            if (lyrics != null && lyrics.trim().isNotEmpty) {
              final hasLrcTags = _lrcTagRegex.hasMatch(lyrics);
              results.add(_LyricsCandidate(
                plainLyrics: hasLrcTags ? null : lyrics,
                syncedLyrics: hasLrcTags ? lyrics : map['snippets']?.toString(),
                trackName: trackName,
                artistName: artistName,
                albumName: albumName ?? '',
                durationSeconds: duration,
                language: map['language']?.toString(),
                isrc: map['isrc']?.toString(),
                songId: songId,
              ));
            } else {
              results.add(_LyricsCandidate(
                plainLyrics: null,
                syncedLyrics: null,
                trackName: trackName,
                artistName: artistName,
                albumName: albumName ?? '',
                durationSeconds: duration,
                language: map['language']?.toString(),
                isrc: map['isrc']?.toString(),
                songId: songId,
              ));
            }
          }
        }
      } catch (e) {
        if (_isClosedError(e)) rethrow;
      }
      if (results.isNotEmpty) break;
    }
    return results;
  }

  static Future<LyricsPayload?> _scrapeJioSaavnLyrics(String songUrl, {http.Client? client}) async {
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      final uri = Uri.parse(songUrl);
      final segments = uri.pathSegments;
      if (segments.length < 3 || segments[0] != 'song') {
        return null;
      }
      final id = segments[2];
      final lyricsUrl = 'https://www.jiosaavn.com/api.php?__call=lyrics.getLyrics&lyrics_id=$id&ctx=web6dot0&api_version=4&_format=json';
      
      final res = await _getWithRetry(
        Uri.parse(lyricsUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
        client: clientToUse,
        timeout: const Duration(seconds: 4),
      );

      if (res.statusCode != 200) return null;
      
      final data = jsonDecode(res.body);
      if (data == null || data is! Map || data['status'] == 'failure' || data['lyrics'] == null) {
        return null;
      }

      var rawLyrics = data['lyrics'].toString();
      if (rawLyrics.isEmpty) return null;

      rawLyrics = rawLyrics.replaceAll(RegExp(r'</?br/?>'), '\n');
      rawLyrics = rawLyrics.replaceAll(RegExp(r'<[^>]*>'), '');
      
      rawLyrics = rawLyrics
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#039;', "'")
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');

      final cleaned = rawLyrics.trim();
      if (cleaned.isEmpty) return null;

      return LyricsPayload(
        plainLyrics: cleaned,
        syncedLyrics: null,
        provider: 'jiosaavn API',
      );
    } catch (e) {
      if (_isClosedError(e)) rethrow;
      debugPrint('[LyricsService] JioSaavn scrape failed: $e');
      return null;
    } finally {
      if (client == null) {
        clientToUse.close();
      }
    }
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

  static void prefetchLyricsForSong(LyricsMetadata song) {
    final title = song.title.trim();
    if (title.isEmpty) return;
    final artist = song.artist.trim();
    final album = (song.album ?? '').trim();
    final duration = song.duration;

    Future(() async {
      try {
        final songObj = Song(
          id: song.songId ?? "",
          name: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.duration,
          language: song.language,
          isrc: song.isrc,
          songUrl: song.songUrl,
        );

        final cached = await LyricsCache.get(
          songId: song.songId ?? "",
          title: title,
          artist: artist,
          album: album,
          duration: duration,
        );
        if (cached != null) return;

        final payload = await getLyricsPayloadForSong(song);
        if (payload != null && payload.hasAny) {
          var finalPayload = payload;
          if (!payload.hasSynced && payload.hasPlain) {
            final serverAligned = await alignAudioWithServer(songObj, payload.plainLyrics!);
            finalPayload = serverAligned ?? LyricsAlignmentEngine.align(songObj, payload);
          }
          await LyricsCache.put(
            songId: song.songId ?? "",
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            payload: finalPayload,
            providerSource: finalPayload.provider ?? 'lrclib',
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
        title: lookup.title,
        artist: lookup.artist,
        album: lookup.album,
        duration: lookup.durationSeconds,
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

  static Future<http.Response> _getWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    required http.Client client,
    Duration timeout = const Duration(seconds: 4),
    int maxRetries = 2,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        final res = await client.get(uri, headers: headers).timeout(timeout);
        final status = res.statusCode;
        if (status == 200 || status == 404 || status == 400 || status == 401 || status == 403) {
          return res;
        }
        if (attempt >= maxRetries + 1) {
          return res;
        }
      } catch (e) {
        final isClosed = e.toString().toLowerCase().contains('client is already closed');
        if (isClosed || attempt >= maxRetries + 1) {
          rethrow;
        }
      }
      final sleepMs = math.pow(2, attempt) * 200;
      await Future.delayed(Duration(milliseconds: sleepMs.toInt()));
    }
  }

  static Future<Map<String, dynamic>?> _lrclibGetEntry({
    required String artist,
    required String title,
    String? album,
    int? durationSeconds,
    String? isrc,
    http.Client? client,
  }) async {
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      final query = <String, String>{
        if (isrc != null && isrc.trim().isNotEmpty) 'isrc': isrc.trim(),
        if (title.trim().isNotEmpty) 'track_name': title,
        if (artist.trim().isNotEmpty) 'artist_name': artist,
        if ((album ?? '').trim().isNotEmpty) 'album_name': album!.trim(),
        if (durationSeconds != null && durationSeconds > 0)
          'duration': durationSeconds.toString(),
      };
      final uri = Uri.parse(
        '$_lrclibBaseUrl/get',
      ).replace(queryParameters: query);

      final res = await _getWithRetry(
        uri,
        headers: {'User-Agent': 'MusicHub/2.0 (https://github.com)'},
        client: clientToUse,
        timeout: _requestTimeout,
      );

      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      if (_isClosedError(e)) rethrow;
      debugPrint('[LyricsService] LRCLIB get failed: $e');
      return null;
    } finally {
      if (client == null) {
        clientToUse.close();
      }
    }
  }

  static Future<List<Map<String, dynamic>>> _lrclibSearchEntries(
    String query, {
    http.Client? client,
  }) async {
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      final uri = Uri.parse(
        '$_lrclibBaseUrl/search',
      ).replace(queryParameters: {'q': query});

      final res = await _getWithRetry(
        uri,
        headers: {'User-Agent': 'MusicHub/2.0 (https://github.com)'},
        client: clientToUse,
        timeout: _requestTimeout,
      );

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
      if (_isClosedError(e)) rethrow;
      debugPrint('[LyricsService] LRCLIB search failed: $e');
      return const <Map<String, dynamic>>[];
    } finally {
      if (client == null) {
        clientToUse.close();
      }
    }
  }

  static Future<_LyricsCandidate?> _fetchSaavnCandidate(
    String trackId, {
    required String title,
    required String artist,
    required String album,
    int? duration,
    http.Client? client,
  }) async {
    final clientToUse = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/api/songs/$trackId/lyrics');
      final res = await _getWithRetry(
        uri,
        headers: {'User-Agent': 'MusicHub/2.0'},
        client: clientToUse,
        timeout: _requestTimeout,
      );

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
        trackName: data['name'] ?? title,
        artistName: data['artist'] ?? artist,
        albumName: data['album'] ?? album,
        durationSeconds: duration,
        language: null,
        songId: trackId,
      );
    } catch (e) {
      if (_isClosedError(e)) rethrow;
      debugPrint('[LyricsService] Saavn candidate fetch failed: $e');
      return null;
    } finally {
      if (client == null) {
        clientToUse.close();
      }
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
      isrc: _normalizeOptionalString(json['isrc']),
      songId: _normalizeOptionalString(json['id'] ?? json['songId'] ?? json['song_id']),
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

    var targetCandidates = candidates.where((candidate) {
      final score = _calculateConfidenceScore(lookup, candidate);
      debugPrint('[LyricsService] Candidate: "${candidate.trackName}" by "${candidate.artistName}", Confidence: $score');
      return score >= 0.82;
    }).toList();

    if (targetCandidates.isEmpty) {
      debugPrint('[LyricsService] No candidates passed 0.82. Trying relaxed threshold >= 0.50...');
      targetCandidates = candidates.where((candidate) {
        final score = _calculateConfidenceScore(lookup, candidate);
        return score >= 0.50;
      }).toList();
    }

    if (targetCandidates.isEmpty) {
      debugPrint('[LyricsService] Rejecting all lyrics candidates due to confidence score below 0.50');
      return null;
    }

    final expectedLanguage = _normalizeLanguage(lookup.language);
    final strictPayload = _selectBestPayloadByMode(
      lookup,
      targetCandidates,
      expectedLanguage: expectedLanguage,
      relaxed: false,
    );
    if (strictPayload != null) {
      return strictPayload;
    }

    final relaxedPayload = _selectBestPayloadByMode(
      lookup,
      targetCandidates,
      expectedLanguage: expectedLanguage,
      relaxed: true,
    );
    if (relaxedPayload != null) {
      return relaxedPayload;
    }

    return _selectLoosePayload(
      lookup,
      targetCandidates,
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
      provider: 'lrclib',
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

    final expectedDuration = lookup.durationSeconds;
    final candidateDuration = candidate.durationSeconds;
    final durationDiff = (expectedDuration != null &&
            expectedDuration > 0 &&
            candidateDuration != null &&
            candidateDuration > 0)
        ? (expectedDuration - candidateDuration).abs()
        : null;

    if (durationDiff != null && durationDiff > (relaxed ? 8 : 1)) {
      return null;
    }

    final expectedArtist = _normalizeMatchText(_cleanArtist(lookup.artist));
    final candidateArtist = _normalizeMatchText(
      _cleanArtist(candidate.artistName),
    );
    if (expectedArtist.isNotEmpty) {
      final artistScore = _similarityScore(expectedArtist, candidateArtist);
      final isVeryStrongMatch = titleScore >= 0.85 && durationDiff != null && durationDiff <= 3;
      final requiredArtistScore = isVeryStrongMatch ? 0.0 : (relaxed ? 0.18 : 0.35);
      if (artistScore < requiredArtistScore) return null;
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

  static String removeDiacritics(String str) {
    var withDia = 'ÀÁÂÃÄÅàáâãäåÒÓÔÕÕÖØòóôõöøÈÉÊËèéêëðÇçÐÌÍÎÏìíîïÙÚÛÜùúûüÑñÝýÿ';
    var defaultLetter = 'AAAAAAaaaaaaOOOOOOOooooooEEEEeeeeeCcDIIIIiiiiUUUUuuuuNnYyy';
    for (int i = 0; i < withDia.length; i++) {
      str = str.replaceAll(withDia[i], defaultLetter[i]);
    }
    str = str.replaceAll('ß', 'ss');
    str = str.replaceAll('æ', 'ae');
    str = str.replaceAll('œ', 'oe');
    return str;
  }

  static String _normalizeMatchText(String value) {
    var cleaned = value.toLowerCase();
    cleaned = removeDiacritics(cleaned);
    return cleaned
        .replaceAll("'", ' ')
        .replaceAll(RegExp(r'[\(\)\[\]\{\},.!?;:"@#\$%\^&\*\+\=/\\|<>_-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static double _calculateConfidenceScore(_LyricsLookup lookup, _LyricsCandidate candidate) {
    if (lookup.trackId.isNotEmpty &&
        candidate.songId != null && candidate.songId!.trim().isNotEmpty &&
        lookup.trackId.toLowerCase() == candidate.songId!.trim().toLowerCase()) {
      return 1.0;
    }

    if (lookup.isrc != null && lookup.isrc!.trim().isNotEmpty &&
        candidate.isrc != null && candidate.isrc!.trim().isNotEmpty &&
        lookup.isrc!.trim().toLowerCase() == candidate.isrc!.trim().toLowerCase()) {
      return 1.0;
    }

    double confidence = 1.0;

    final expectedTitle = _normalizeMatchText(lookup.title);
    final candidateTitle = _normalizeMatchText(candidate.trackName);
    double titleSimilarity = _similarityScore(expectedTitle, candidateTitle);

    final expectedCleanTitle = _normalizeMatchText(_cleanTitle(lookup.title));
    final candidateCleanTitle = _normalizeMatchText(_cleanTitle(candidate.trackName));
    final cleanTitleSimilarity = _similarityScore(expectedCleanTitle, candidateCleanTitle);
    if (cleanTitleSimilarity > titleSimilarity) {
      titleSimilarity = cleanTitleSimilarity;
    }

    if (titleSimilarity < 0.75) {
      return 0.0;
    }

    if (titleSimilarity < 0.85) {
      confidence -= (1.0 - titleSimilarity) * 0.5;
    }

    final expectedArtist = _normalizeMatchText(lookup.artist);
    final candidateArtist = _normalizeMatchText(candidate.artistName);
    double artistSimilarity = _similarityScore(expectedArtist, candidateArtist);

    final expectedPrimary = _normalizeMatchText(_getPrimaryArtist(lookup.artist));
    final candidatePrimary = _normalizeMatchText(_getPrimaryArtist(candidate.artistName));
    final primarySimilarity = _similarityScore(expectedPrimary, candidatePrimary);
    if (primarySimilarity > artistSimilarity) {
      artistSimilarity = primarySimilarity;
    }

    if (artistSimilarity < 0.85) {
      confidence -= (1.0 - artistSimilarity) * 0.4;
    }

    if (lookup.album.isNotEmpty && candidate.albumName.isNotEmpty) {
      final expectedAlbum = _normalizeMatchText(lookup.album);
      final candidateAlbum = _normalizeMatchText(candidate.albumName);
      double albumSimilarity = _similarityScore(expectedAlbum, candidateAlbum);

      final expectedCleanAlbum = _normalizeMatchText(_cleanTitle(lookup.album));
      final candidateCleanAlbum = _normalizeMatchText(_cleanTitle(candidate.albumName));
      final cleanAlbumSimilarity = _similarityScore(expectedCleanAlbum, candidateCleanAlbum);
      if (cleanAlbumSimilarity > albumSimilarity) {
        albumSimilarity = cleanAlbumSimilarity;
      }

      if (albumSimilarity < 0.70) {
        confidence -= (1.0 - albumSimilarity) * 0.15;
      }
    }

    if (lookup.durationSeconds != null && lookup.durationSeconds! > 0 &&
        candidate.durationSeconds != null && candidate.durationSeconds! > 0) {
      final durationDiff = (lookup.durationSeconds! - candidate.durationSeconds!).abs();
      if (durationDiff > 4) {
        confidence -= (durationDiff - 4) * 0.05 + 0.1;
      }
    }

    if (lookup.language != null && lookup.language!.isNotEmpty) {
      final expectedLang = _normalizeLanguage(lookup.language);
      final candidateLang = _normalizeLanguage(candidate.language);
      if (expectedLang != null && candidateLang != null && expectedLang != candidateLang) {
        confidence -= 0.2;
      }
    }

    final candidateLower = '${candidate.trackName.toLowerCase()} ${candidate.albumName.toLowerCase()}';
    final songIsExplicit = lookup.isExplicit;
    final candidateIsExplicit = candidateLower.contains('explicit') || 
                                 (candidate.plainLyrics != null && _containsExplicitKeywords(candidate.plainLyrics!));
    final candidateIsClean = candidateLower.contains('clean') || candidateLower.contains('edit');

    if (songIsExplicit && candidateIsClean) {
      confidence -= 0.2;
    } else if (!songIsExplicit && candidateIsExplicit) {
      confidence -= 0.2;
    }

    return confidence.clamp(0.0, 1.0);
  }

  static bool _containsExplicitKeywords(String text) {
    final lower = text.toLowerCase();
    final explicitWords = [
      ' fuck ', ' fuckin', ' faggot ', ' shit ', ' bitch ', ' asshole '
    ];
    for (final word in explicitWords) {
      if (lower.contains(word)) return true;
    }
    return false;
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
    return LyricsPayload(
      plainLyrics: plainLyrics,
      syncedLyrics: syncedLyrics,
      provider: 'lrclib',
    );
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
