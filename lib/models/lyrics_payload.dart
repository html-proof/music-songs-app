import 'package:flutter/foundation.dart';

@immutable
class LyricsLine {
  final Duration timestamp;
  final String text;

  const LyricsLine({required this.timestamp, required this.text});

  @override
  String toString() => '[${timestamp.inMinutes.toString().padLeft(2, '0')}:${(timestamp.inSeconds % 60).toString().padLeft(2, '0')}.${(timestamp.inMilliseconds % 1000).toString().padLeft(3, '0')}] $text';
}

@immutable
class LyricsPayload {
  final String? plainLyrics;
  final String? syncedLyrics;
  final String? translationPlainLyrics;
  final String? translationSyncedLyrics;
  final String? provider;
  final double? confidence;

  const LyricsPayload({
    required this.plainLyrics,
    required this.syncedLyrics,
    this.translationPlainLyrics,
    this.translationSyncedLyrics,
    this.provider,
    this.confidence,
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
      'provider': provider,
      'confidence': confidence,
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
      provider: json['provider']?.toString(),
      confidence: json['confidence'] != null ? (double.tryParse(json['confidence'].toString()) ?? 1.0) : null,
    );
  }
}
