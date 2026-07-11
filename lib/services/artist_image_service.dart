import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

class ArtistImageService {
  static final Dio _dio = Dio();
  static Map<String, Map<String, dynamic>> _cache = {};
  static File? _cacheFile;
  static bool _initialized = false;
  static final Set<String> _pendingSearches = {};

  static const Duration _cacheTtl = Duration(days: 30);

  // Broadcast stream controller to notify UI widgets when an image is cached
  static final StreamController<Map<String, String>> _updateController =
      StreamController<Map<String, String>>.broadcast();

  static Stream<Map<String, String>> get onArtistImageUpdated =>
      _updateController.stream;

  static Future<void> _init() async {
    if (_initialized) return;
    try {
      final supportDir = await getApplicationSupportDirectory();
      _cacheFile = File('${supportDir.path}/artist_images.json');
      if (await _cacheFile!.exists()) {
        final content = await _cacheFile!.readAsString();
        final decoded = json.decode(content);
        if (decoded is Map) {
          _cache = decoded.map(
            (key, value) => MapEntry(
              key.toString(),
              Map<String, dynamic>.from(value as Map),
            ),
          );
        }
      }
      _initialized = true;
    } catch (e) {
      debugPrint('[ArtistImageService] Initialization failed: $e');
    }
  }

  static Future<void> _saveCache() async {
    try {
      if (_cacheFile == null) return;
      final encoded = json.encode(_cache);
      await _cacheFile!.writeAsString(encoded);
    } catch (e) {
      debugPrint('[ArtistImageService] Failed to save cache to disk: $e');
    }
  }

  /// Get the artist image URL, checking cache first, then searching background APIs.
  static Future<String?> getArtistImageUrl(
    String artistId,
    String artistName,
  ) async {
    final cleanName = artistName.trim().toLowerCase();
    if (cleanName.isEmpty) return null;

    await _init();

    // Check memory / disk cache
    final cached = _cache[cleanName] ?? _cache[artistId];
    if (cached != null) {
      final url = cached['url'] as String?;
      final timestamp = cached['timestamp'] as int?;
      if (url != null && timestamp != null) {
        final cachedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
        final age = DateTime.now().difference(cachedAt);
        if (age < _cacheTtl) {
          // Cache is valid
          return url;
        } else {
          // Cache expired, trigger background refresh silently
          unawaited(_searchAndCacheArtistImage(artistId, artistName));
          return url;
        }
      }
    }

    // Cache miss, trigger background recovery and return null (which shows the shimmer/searching state)
    unawaited(_searchAndCacheArtistImage(artistId, artistName));
    return null;
  }

  static Future<void> _searchAndCacheArtistImage(
    String artistId,
    String artistName,
  ) async {
    final cleanName = artistName.trim();
    if (cleanName.isEmpty) return;

    final searchKey = artistId.isNotEmpty ? artistId : cleanName.toLowerCase();
    if (_pendingSearches.contains(searchKey)) return;

    _pendingSearches.add(searchKey);

    try {
      debugPrint('[ArtistImageService] Starting background recovery for: $cleanName');
      
      // Step 1: Try Deezer API
      String? imageUrl = await _tryDeezer(cleanName);

      // Step 2: Try Wikipedia pageimages API as fallback
      if (imageUrl == null || imageUrl.isEmpty) {
        imageUrl = await _tryWikipedia(cleanName);
      }

      if (imageUrl != null && imageUrl.isNotEmpty) {
        // Validate image URL resolves and is a valid image
        final isValid = await _validateImage(imageUrl);
        if (isValid) {
          final entry = {
            'url': imageUrl,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          };
          _cache[cleanName.toLowerCase()] = entry;
          if (artistId.isNotEmpty) {
            _cache[artistId] = entry;
          }
          await _saveCache();
          debugPrint('[ArtistImageService] Successfully recovered image for $cleanName: $imageUrl');

          // Notify all active listeners
          _updateController.add({
            'artistId': artistId,
            'artistName': cleanName.toLowerCase(),
            'imageUrl': imageUrl,
          });
        } else {
          debugPrint('[ArtistImageService] Image validation failed for URL: $imageUrl');
        }
      } else {
        debugPrint('[ArtistImageService] Recover failed: no images found for $cleanName');
      }
    } catch (e) {
      debugPrint('[ArtistImageService] Background search failed for $cleanName: $e');
    } finally {
      _pendingSearches.remove(searchKey);
    }
  }

  static Future<String?> _tryDeezer(String cleanName) async {
    try {
      debugPrint('[ArtistImageService] Searching Deezer API for: $cleanName');
      final response = await _dio.get(
        'https://api.deezer.com/search/artist',
        queryParameters: {'q': cleanName},
        options: Options(
          headers: {'User-Agent': 'MusicHub/1.0 (com.jio.music_hub)'},
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      final data = response.data;
      if (data is Map && data['data'] is List) {
        final list = data['data'] as List;
        for (final item in list) {
          if (item is Map) {
            final name = (item['name'] ?? '').toString().trim();
            if (name.toLowerCase() == cleanName.toLowerCase()) {
              final imageUrl = (item['picture_xl'] ??
                      item['picture_big'] ??
                      item['picture_medium'] ??
                      item['picture'] ??
                      '')
                  .toString()
                  .trim();
              if (imageUrl.isNotEmpty) return imageUrl;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ArtistImageService] Deezer request failed: $e');
    }
    return null;
  }

  static Future<String?> _tryWikipedia(String cleanName) async {
    try {
      debugPrint('[ArtistImageService] Searching Wikipedia Pageimages API for: $cleanName');
      final response = await _dio.get(
        'https://en.wikipedia.org/w/api.php',
        queryParameters: {
          'action': 'query',
          'titles': cleanName,
          'prop': 'pageimages',
          'format': 'json',
          'pithumbsize': '512',
          'redirects': '1',
        },
        options: Options(
          headers: {'User-Agent': 'MusicHub/1.0 (com.jio.music_hub)'},
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      final data = response.data;
      if (data is Map && data['query'] is Map) {
        final query = data['query'] as Map;
        if (query['pages'] is Map) {
          final pages = query['pages'] as Map;
          if (pages.isNotEmpty) {
            final firstPageKey = pages.keys.first;
            final pageData = pages[firstPageKey];
            if (pageData is Map && pageData['thumbnail'] is Map) {
              final thumb = pageData['thumbnail'] as Map;
              final source = (thumb['source'] ?? '').toString().trim();
              if (source.isNotEmpty) return source;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ArtistImageService] Wikipedia request failed: $e');
    }
    return null;
  }

  static Future<bool> _validateImage(String url) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      if (response.statusCode == 200) {
        final contentType = response.headers.value('content-type') ?? '';
        if (contentType.toLowerCase().startsWith('image/')) {
          return true;
        }
      }
    } catch (_) {
      // If HEAD request fails, try a GET request with limited range or small timeout
      try {
        final response = await _dio.get(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        if (response.statusCode == 200) {
          final contentType = response.headers.value('content-type') ?? '';
          if (contentType.toLowerCase().startsWith('image/') || response.data != null) {
            return true;
          }
        }
      } catch (_) {}
    }
    return false;
  }
}
