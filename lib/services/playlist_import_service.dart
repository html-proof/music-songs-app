import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import '../models/song.dart';

/// Service for importing playlists from other music apps.
/// Works WITHOUT any third-party API keys by using search-based matching.
class PlaylistImportService {
  static const Duration _importTimeout = Duration(seconds: 180);
  static const Duration _parseTimeout = Duration(seconds: 90);

  /// Parse text or URL into song items (preview before importing).
  /// Returns list of { title, artist } maps.
  static Future<PlaylistParseResult> parsePlaylist({
    required String type,
    required String content,
  }) async {
    try {
      final normalizedContent = type == 'url'
          ? _normalizeExternalPlaylistUrl(content)
          : content;

      final response = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/api/playlist/parse'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'type': type, 'content': normalizedContent}),
          )
          .timeout(_parseTimeout);

      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (_) {
        data = null;
      }

      if (response.statusCode != 200) {
        return PlaylistParseResult(
          items: [],
          name: '',
          error:
              data?['error']?.toString() ??
              'Server error: ${response.statusCode}',
        );
      }

      if (data == null) {
        return const PlaylistParseResult(
          items: [],
          name: '',
          error: 'Invalid server response while parsing playlist.',
        );
      }

      if (data['success'] == false) {
        return PlaylistParseResult(
          items: [],
          name: (data['name'] ?? '').toString(),
          error: (data['error'] ?? 'No songs found at this URL.').toString(),
        );
      }

      final rawItems = data['items'] as List?;
      final items =
          rawItems
              ?.whereType<Map>()
              .map(
                (item) => PlaylistImportItem(
                  title: (item['title'] ?? '').toString(),
                  artist: (item['artist'] ?? '').toString(),
                ),
              )
              .where((item) => item.title.isNotEmpty)
              .toList() ??
          const <PlaylistImportItem>[];

      return PlaylistParseResult(
        items: items,
        name: (data['name'] ?? '').toString(),
      );
    } on TimeoutException {
      return const PlaylistParseResult(
        items: [],
        name: '',
        error:
            'Parsing timed out. Please try again with a direct playlist link.',
      );
    } catch (e) {
      debugPrint('[PlaylistImportService] Parse error: $e');
      return PlaylistParseResult(
        items: [],
        name: '',
        error: 'Failed to parse: $e',
      );
    }
  }

  /// Import a playlist — searches and matches each song.
  /// Returns matched songs and unmatched items.
  static Future<PlaylistImportResult> importPlaylist({
    required String type,
    required String content,
    String? playlistName,
    List<String> preferredLanguages = const [],
    void Function(double progress)? onProgress,
  }) async {
    try {
      final normalizedContent = type == 'url'
          ? _normalizeExternalPlaylistUrl(content)
          : content;

      onProgress?.call(0.1);

      final response = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/api/playlist/import'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'type': type,
              'content': normalizedContent,
              'playlistName': playlistName,
              'preferredLanguages': preferredLanguages,
            }),
          )
          .timeout(_importTimeout);

      onProgress?.call(0.9);

      if (response.statusCode != 200) {
        return PlaylistImportResult.error(
          'Server error: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        return PlaylistImportResult.error(
          data['error']?.toString() ?? 'Import failed',
        );
      }

      final matched =
          (data['matched'] as List?)
              ?.map((item) {
                final songData = item['song'];
                if (songData is! Map) return null;
                try {
                  return MatchedSong(
                    original: PlaylistImportItem(
                      title: (item['original']?['title'] ?? '').toString(),
                      artist: (item['original']?['artist'] ?? '').toString(),
                    ),
                    song: Song.fromJson(Map<String, dynamic>.from(songData)),
                  );
                } catch (_) {
                  return null;
                }
              })
              .whereType<MatchedSong>()
              .toList() ??
          [];

      final unmatched =
          (data['unmatched'] as List?)
              ?.map(
                (item) => UnmatchedItem(
                  title: (item['title'] ?? '').toString(),
                  artist: (item['artist'] ?? '').toString(),
                  reason: (item['reason'] ?? 'Not found').toString(),
                ),
              )
              .toList() ??
          [];

      final stats = data['stats'];

      onProgress?.call(1.0);

      return PlaylistImportResult(
        playlistName: (data['playlistName'] ?? 'Imported Playlist').toString(),
        matched: matched,
        unmatched: unmatched,
        totalCount: stats?['total'] ?? 0,
        matchRate: stats?['matchRate'] ?? 0,
      );
    } on TimeoutException {
      debugPrint('[PlaylistImportService] Import error: timeout');
      return PlaylistImportResult.error(
        'Import timed out. Please try again with a smaller playlist or later.',
      );
    } catch (e) {
      debugPrint('[PlaylistImportService] Import error: $e');
      return PlaylistImportResult.error('Import failed: $e');
    }
  }

  /// Parse raw text locally into items (no network call).
  /// Useful for instant preview as user types.
  static List<PlaylistImportItem> parseTextLocally(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    return lines.map(_parseLine).where((i) => i.title.isNotEmpty).toList();
  }

  static PlaylistImportItem _parseLine(String line) {
    // Strip numbering
    var cleaned = line
        .replaceAll(RegExp(r'^\d+[\.\)\-\s]+'), '')
        .replaceAll(RegExp(r'^[\•\-\*\#]+\s*'), '')
        .trim();

    // Try common delimiters
    for (final delimiter in [' - ', ' – ', ' — ', ' by ', ' • ', ' | ']) {
      if (cleaned.contains(delimiter)) {
        final parts = cleaned.split(delimiter);
        if (parts.length >= 2) {
          return PlaylistImportItem(
            title: parts[0].trim(),
            artist: parts.sublist(1).join(delimiter).trim(),
          );
        }
      }
    }

    return PlaylistImportItem(title: cleaned, artist: '');
  }

  static String _normalizeExternalPlaylistUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;

    value = value.replaceAll(RegExp(r'^<+|>+$'), '');
    value = value.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '');

    final spotifyUri = RegExp(
      r'^spotify:playlist:([a-zA-Z0-9]+)$',
    ).firstMatch(value);
    if (spotifyUri != null) {
      return 'https://open.spotify.com/playlist/${spotifyUri.group(1)}';
    }

    final hasScheme = RegExp(
      r'^https?://',
      caseSensitive: false,
    ).hasMatch(value);
    if (!hasScheme) {
      final looksLikeHostPath = RegExp(
        r'^(?:www\.)?[a-z0-9.-]+\.[a-z]{2,}/\S+',
        caseSensitive: false,
      ).hasMatch(value);
      if (looksLikeHostPath) {
        value = 'https://$value';
      }
    }

    return value;
  }
}

// ─── Data Models ──────────────────────────────────────────────

class PlaylistImportItem {
  final String title;
  final String artist;

  const PlaylistImportItem({required this.title, required this.artist});
}

class PlaylistParseResult {
  final List<PlaylistImportItem> items;
  final String name;
  final String? error;

  const PlaylistParseResult({
    required this.items,
    required this.name,
    this.error,
  });

  bool get hasError => error != null && error!.isNotEmpty;
}

class MatchedSong {
  final PlaylistImportItem original;
  final Song song;

  const MatchedSong({required this.original, required this.song});
}

class UnmatchedItem {
  final String title;
  final String artist;
  final String reason;

  const UnmatchedItem({
    required this.title,
    required this.artist,
    required this.reason,
  });
}

class PlaylistImportResult {
  final String playlistName;
  final List<MatchedSong> matched;
  final List<UnmatchedItem> unmatched;
  final int totalCount;
  final int matchRate;
  final String? errorMessage;

  const PlaylistImportResult({
    required this.playlistName,
    required this.matched,
    required this.unmatched,
    required this.totalCount,
    required this.matchRate,
    this.errorMessage,
  });

  factory PlaylistImportResult.error(String message) {
    return PlaylistImportResult(
      playlistName: '',
      matched: const [],
      unmatched: const [],
      totalCount: 0,
      matchRate: 0,
      errorMessage: message,
    );
  }

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
  bool get hasResults => matched.isNotEmpty || unmatched.isNotEmpty;
}
