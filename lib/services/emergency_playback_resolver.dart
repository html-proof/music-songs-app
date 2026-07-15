import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'api_service.dart';
import 'download_service.dart';
import 'offline_service.dart';
import 'verification_engine.dart';
import 'player_service.dart';

class EmergencyPlaybackResolver {
  static final List<String> _alternateCdns = [
    'aac.saavncdn.com',
    'jiosaavn.cdn.jio.com',
    'snoidcdnems04.cdnsrv.jio.com',
  ];

  /// The main entry point for the Emergency Playback Recovery Layer.
  static Future<Song?> resolve(Song targetSong, {http.Client? client}) async {
    final localClient = client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    bool shouldCloseClient = client == null;

    try {
      debugPrint('EMERGENCY RESOLVER: Triggered for ${targetSong.id} - ${targetSong.name}');
      
      // Stage 1: Local / Cached Backup (Offline Backup / Stage 7 combined here)
      // We check if it's already on disk.
      final localPath = await _checkLocalCaches(targetSong);
      if (localPath != null) {
         debugPrint('EMERGENCY RESOLVER: Found local backup at $localPath');
         return targetSong.copyWith(streamUrl: localPath);
      }

      // Stage 2: Parallel Metadata Search
      final candidates = await _performParallelSearch(targetSong, localClient);
      if (candidates.isEmpty) {
         debugPrint('EMERGENCY RESOLVER: No candidates found in parallel search.');
         return null;
      }

      // Stage 3: Similar Track Matching
      final bestMatch = _findBestMatch(targetSong, candidates);
      if (bestMatch == null) {
         debugPrint('EMERGENCY RESOLVER: No candidate met the similarity threshold.');
         return null;
      }

      // Fetch stream details for the best match if missing
      Song resolvedCandidate = bestMatch;
      if (!(resolvedCandidate.streamUrl != null && resolvedCandidate.streamUrl!.isNotEmpty)) {
        try {
          final fetched = await _intelligentRetry(
            () => PlayerService.fetchSongDetailsForPlaybackWithClientPublic(resolvedCandidate, localClient)
          );
          if (fetched != null) resolvedCandidate = fetched;
        } catch (e) {
          debugPrint('EMERGENCY RESOLVER: Failed to fetch stream details for match: $e');
        }
      }

      if (resolvedCandidate.streamUrl == null || resolvedCandidate.streamUrl!.isEmpty) {
        return null;
      }

      // Stage 4: Stream Validation & Stage 5: Alternate CDN
      final validatedUrl = await _validateAndFallbackCdn(resolvedCandidate.streamUrl!, localClient);
      
      if (validatedUrl != null) {
        debugPrint('EMERGENCY RESOLVER: SUCCESS. Recovered playback using $validatedUrl');
        return resolvedCandidate.copyWith(streamUrl: validatedUrl);
      }

      debugPrint('EMERGENCY RESOLVER: FAILED. All recovery methods exhausted.');
      return null;
    } finally {
      if (shouldCloseClient) {
        localClient.close();
      }
    }
  }

  // --- STAGE 1 & 7: Offline Backup ---
  static Future<String?> _checkLocalCaches(Song song) async {
    final songId = song.id.trim();
    if (songId.isEmpty) return null;

    // 1. Check Download
    try {
      if (await DownloadService.isSongDownloadedInDb(songId)) {
        final downloadPath = await DownloadService.getLocalPath(songId);
        if (downloadPath != null && downloadPath.isNotEmpty && File(downloadPath).existsSync()) {
          return downloadPath;
        }
      }
    } catch (_) {}

    // 2. Check Offline Cache
    try {
      final offlinePath = OfflineService.getLocalPath(songId);
      if (offlinePath != null && offlinePath.isNotEmpty && File(offlinePath).existsSync()) {
        return offlinePath;
      }
    } catch (_) {}

    return null;
  }

  // --- STAGE 2: Metadata Search (Parallel) ---
  static Future<List<Song>> _performParallelSearch(Song song, http.Client client) async {
    final queries = _generateSearchVariants(song);
    debugPrint('EMERGENCY RESOLVER: Dispatching ${queries.length} parallel searches: $queries');

    final futures = queries.map((query) => _searchWithRetry(query, client));
    final results = await Future.wait(futures);

    final Map<String, Song> uniqueCandidates = {};
    for (final resultList in results) {
      for (final s in resultList) {
        if (s.id != song.id) {
          uniqueCandidates[s.id] = s;
        }
      }
    }
    return uniqueCandidates.values.toList();
  }

  static Set<String> _generateSearchVariants(Song song) {
    final queries = <String>{};
    final name = song.name.trim();
    
    // Clean variants
    final cleanName = name.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), '').trim();
    final shortName = cleanName.split('-').first.trim();
    
    String artist = '';
    if (song.artist != null && song.artist!.isNotEmpty) {
      artist = song.artist!.split(',').first.trim();
    }

    String album = (song.album ?? '').trim();

    String? movieQuery;
    final movieMatch = RegExp(r'(?:\([Ff]rom\s+([^)]+)\)|\[[Ff]rom\s+([^\]]+)\])').firstMatch(name);
    if (movieMatch != null) {
      final rawMovie = (movieMatch.group(1) ?? movieMatch.group(2))?.trim() ?? '';
      var cleanMovie = rawMovie;
      if (cleanMovie.startsWith('"') || cleanMovie.startsWith("'")) cleanMovie = cleanMovie.substring(1);
      if (cleanMovie.endsWith('"') || cleanMovie.endsWith("'")) cleanMovie = cleanMovie.substring(0, cleanMovie.length - 1);
      movieQuery = cleanMovie.trim();
    }

    // 1. Title
    if (name.isNotEmpty) queries.add(name);
    // 2. Artist
    if (artist.isNotEmpty) queries.add(artist);
    // 3. Album
    if (album.isNotEmpty) queries.add(album);
    // 4. Title + Artist
    if (cleanName.isNotEmpty && artist.isNotEmpty) queries.add('$cleanName $artist');
    // 5. Title + Album
    if (cleanName.isNotEmpty && album.isNotEmpty) queries.add('$cleanName $album');
    // 6. Title + Movie
    if (cleanName.isNotEmpty && movieQuery != null && movieQuery.isNotEmpty) {
      queries.add('$cleanName $movieQuery');
      // 7. Title + Movie + Artist
      if (artist.isNotEmpty) queries.add('$cleanName $movieQuery $artist');
    }
    // 8. Cleaned Title
    if (cleanName.isNotEmpty && cleanName != name) queries.add(cleanName);
    // 9. Short Title
    if (shortName.isNotEmpty && shortName != cleanName) queries.add(shortName);

    return queries;
  }

  static Future<List<Song>> _searchWithRetry(String query, http.Client client) async {
    try {
      return await _intelligentRetry(() async {
        final encodedQuery = Uri.encodeComponent(query);
        final url = Uri.parse('${ApiService.baseUrl}/api/search/songs?query=$encodedQuery&limit=5');
        final response = await client.get(url).timeout(const Duration(seconds: 4));
        
        if (response.statusCode == 200) {
          final data = _parseJsonMap(response.body);
          if (data['success'] == true && data['data'] != null && data['data']['results'] != null) {
            final results = data['data']['results'] as List;
            return results.map((e) => Song.fromJson(Map<String, dynamic>.from(e))).toList();
          }
        }
        return <Song>[];
      });
    } catch (e) {
      return <Song>[];
    }
  }

  static Map<String, dynamic> _parseJsonMap(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  // --- STAGE 3: Similar Track Matching ---
  static Song? _findBestMatch(Song target, List<Song> candidates) {
    Song? bestCandidate;
    double bestScore = -1;

    for (final candidate in candidates) {
      // 1. Calculate base verification confidence
      double score = VerificationEngine.calculateConfidence(candidate, target);
      
      // 2. Duration check (±2 seconds tolerance) gives a massive boost
      if (target.duration != null && candidate.duration != null) {
        final diff = (target.duration! - candidate.duration!).abs();
        if (diff <= 2) {
          score += 40.0;
        } else if (diff <= 5) {
          score += 15.0;
        } else if (diff > 15) {
          score -= 50.0; // Penalty for large duration mismatch
        }
      }
      
      if (score > bestScore && score >= VerificationEngine.threshold) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }
    
    debugPrint('EMERGENCY RESOLVER: Best match score: $bestScore');
    return bestCandidate;
  }

  // --- STAGE 4 & 5: Stream Validation & Alternate CDN ---
  static Future<String?> _validateAndFallbackCdn(String urlStr, http.Client client) async {
    Uri? originalUri = Uri.tryParse(urlStr);
    if (originalUri == null) return null;

    // 1. Try original
    if (await _validateStream(originalUri, client)) {
      return originalUri.toString();
    }

    // 2. Try alternate CDNs
    final host = originalUri.host;
    for (final cdn in _alternateCdns) {
      if (cdn == host) continue; // Already tried
      
      final altUri = originalUri.replace(host: cdn);
      debugPrint('EMERGENCY RESOLVER: Trying alternate CDN: $cdn');
      if (await _validateStream(altUri, client)) {
        return altUri.toString();
      }
    }

    return null;
  }

  static Future<bool> _validateStream(Uri uri, http.Client client) async {
    try {
      // Must respond within 2 seconds
      final request = http.Request('HEAD', uri);
      final response = await client.send(request).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        final contentType = response.headers['content-type']?.toLowerCase() ?? '';
        final contentLengthStr = response.headers['content-length'];
        
        // Check MIME type
        if (contentType.startsWith('audio/') || contentType == 'application/mp4' || contentType == 'video/mp4') {
          // Check if not empty
          if (contentLengthStr != null) {
            final len = int.tryParse(contentLengthStr);
            if (len != null && len > 1024) {
              return true; // Valid audio stream
            }
          } else {
            return true; // Unknown length but valid type
          }
        }
      }
    } catch (_) {}
    return false;
  }

  // --- STAGE 6: Intelligent Retry ---
  static Future<T> _intelligentRetry<T>(Future<T> Function() action) async {
    int maxAttempts = 3;
    int attempt = 0;
    
    while (attempt < maxAttempts) {
      attempt++;
      try {
        return await action();
      } catch (e) {
        bool isTransient = false;
        if (e is TimeoutException || e is SocketException) {
          isTransient = true;
        } else if (e is http.ClientException) {
          isTransient = true;
        }

        if (isTransient && attempt < maxAttempts) {
          // Exponential backoff with jitter
          final delayMs = (500 * pow(2, attempt - 1)).toInt() + Random().nextInt(300);
          debugPrint('EMERGENCY RESOLVER: Transient error. Retrying in ${delayMs}ms (Attempt $attempt/$maxAttempts)');
          await Future.delayed(Duration(milliseconds: delayMs));
        } else {
          rethrow;
        }
      }
    }
    throw Exception('Retry failed');
  }
}
