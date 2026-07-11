import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'download_service.dart';

class ArtworkService {
  /// Resolves the local artwork path following the professional fallback hierarchy:
  /// Song Folder Artwork -> Album Cover -> Artist Cover
  static Future<String?> getLocalArtworkPath(Song song) async {
    if (song.id.isEmpty) return null;

    try {
      final downloadsDirPath = await DownloadService.getDownloadsDirPath();

      // 1. Try Song-specific artwork (New Structure)
      final songArtworkFile = File('$downloadsDirPath/songs/${song.id}/artwork.jpg');
      if (await songArtworkFile.exists()) {
        return songArtworkFile.path;
      }

      // 2. Lazy Migration: Try Legacy flat structure
      final legacyArtworkFile = File('$downloadsDirPath/${song.id}.jpg');
      if (await legacyArtworkFile.exists()) {
        final newFolder = Directory('$downloadsDirPath/songs/${song.id}');
        if (!await newFolder.exists()) {
          await newFolder.create(recursive: true);
        }
        final newPath = '${newFolder.path}/artwork.jpg';
        await legacyArtworkFile.rename(newPath);
        return newPath;
      }

      // 3. Try Album Cover
      if (song.albumId != null && song.albumId!.isNotEmpty) {
        final albumFile = File('$downloadsDirPath/albums/${song.albumId}.jpg');
        if (await albumFile.exists()) {
          return albumFile.path;
        }
      }

      // 4. Try Artist Cover
      // Note: This requires artistId which may not be in Song model,
      // but we check if we can derive it or if we have a stored artist image.
      // For now, we focus on song and album as they are primary.

      return null;
    } catch (e) {
      debugPrint('[ArtworkService] Error resolving local artwork path: $e');
      return null;
    }
  }

  /// Resolves the best network URL for artwork based on professional fallback:
  /// Song Image -> Album Image -> Artist Image
  static String resolveArtworkUrl(Song song) {
    final url = (song.imageUrl ?? song.sourceAlbumImageUrl ?? '').trim();
    if (url.isNotEmpty) {
      return url;
    }

    // Fallback to a default music placeholder would be handled by the UI widget,
    // but we return empty here to indicate no specific image is found.
    return '';
  }
}
