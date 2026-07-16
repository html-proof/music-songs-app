import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import '../models/stream_metadata.dart';

class StreamResolver {
  static Future<bool> validateStreamUrl(String url, http.Client client) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return false;
    if (isLocalFilePath(cleanUrl)) {
      try {
        final file = File(cleanUrl);
        if (!file.existsSync()) return false;
        final length = file.lengthSync();
        if (length <= 0) return false;
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      final uri = Uri.parse(cleanUrl);
      var response = await client.head(uri).timeout(const Duration(milliseconds: 1500));
      
      if (response.statusCode != 200) {
        final request = http.Request('GET', uri);
        request.headers['Range'] = 'bytes=0-1'; // Request first 2 bytes
        final streamedResponse = await client.send(request).timeout(const Duration(milliseconds: 1500));
        if (streamedResponse.statusCode == 200 || streamedResponse.statusCode == 206) {
          final contentType = (streamedResponse.headers['content-type'] ?? '').toLowerCase();
          if (contentType.isNotEmpty) {
            return true; // We received a partial content or full content response from media server
          }
        }
        return false;
      }
      
      final contentType = (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('html')) {
        return false;
      }
      final contentLengthStr = response.headers['content-length'] ?? '0';
      final contentLength = int.tryParse(contentLengthStr) ?? 0;
      
      if (contentType.contains('audio') ||
          contentType.contains('mpeg') ||
          contentType.contains('octet-stream') ||
          contentType.contains('video') ||
          contentType.contains('application/x-mpegurl')) {
        return true;
      }
      if (contentLength > 0) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Stream validation failed for $cleanUrl: $e');
      return false;
    }
  }

  static bool hasStreamUrl(StreamMetadata metadata) {
    final streamUrl = (metadata.streamUrl).trim();
    if (streamUrl.isEmpty) return false;

    if (streamUrl.contains('null') && !streamUrl.contains('http')) {
      return false;
    }

    if (streamUrl.startsWith('http') || isLocalFilePath(streamUrl)) {
      return true;
    }

    return false;
  }

  static bool isLocalFilePath(String path) {
    if (path.trim().isEmpty) return false;
    return path.startsWith('/') || path.startsWith('file://') || path.contains(':\\');
  }

  static StreamMetadata optimizeRemoteStreamForCurrentQuality(StreamMetadata metadata, {int? duration}) {
    final streamUrl = (metadata.streamUrl).trim();
    if (streamUrl.isEmpty || isLocalFilePath(streamUrl)) return metadata;

    final optimizedUrl = Song.optimizeStreamUrlForData(streamUrl, durationSeconds: duration);
    final normalizedOptimized = (optimizedUrl ?? '').trim();
    if (normalizedOptimized.isEmpty || normalizedOptimized == streamUrl) {
      return metadata;
    }

    return StreamMetadata(streamUrl: normalizedOptimized, bitrate: metadata.bitrate, expiry: metadata.expiry, provider: metadata.provider);
  }

  static bool shouldUpgradeStreamQuality(StreamMetadata metadata) {
    final streamUrl = (metadata.streamUrl).trim();
    if (streamUrl.isEmpty) return true;
    if (isLocalFilePath(streamUrl)) return false;

    final streamBitrate = extractBitrateFromUrl(streamUrl);
    if (streamBitrate == null) return false;
    return streamBitrate < Song.preferredStreamingMaxKbps;
  }

  static int? extractBitrateFromUrl(String? url) {
    final value = (url ?? '').trim();
    if (value.isEmpty) return null;
    
    // Robust regex to find bitrates like _320, /320/, 320.mp4, or _320_v4.
    // Matches the same pattern as Song.optimizeStreamUrlForData.
    final match = RegExp(r'([/_])(\d{2,3})(?=[_/\.]|$)').firstMatch(value);
    
    return int.tryParse(match?.group(2) ?? '');
  }
}
