import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android-only audio enhancement bridge.
///
/// This is a Dolby-like tuning layer (EQ + bass + virtualizer), not licensed
/// Dolby Atmos processing.
class AudioEffectsService {
  static const MethodChannel _channel = MethodChannel(
    'music_hub/audio_effects',
  );

  static bool _dolbyLikeEnabled = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> setAudioSessionId(int? sessionId) async {
    if (!_isAndroid) return;

    try {
      await _channel.invokeMethod<void>('setAudioSessionId', {'id': sessionId});
      if (_dolbyLikeEnabled) {
        await _channel.invokeMethod<void>('setDolbyLikeEnabled', {
          'enabled': true,
        });
      }
    } catch (e) {
      debugPrint('AudioEffectsService.setAudioSessionId failed: $e');
    }
  }

  static Future<void> setDolbyLikeEnabled(bool enabled) async {
    _dolbyLikeEnabled = enabled;
    if (!_isAndroid) return;

    try {
      await _channel.invokeMethod<void>('setDolbyLikeEnabled', {
        'enabled': enabled,
      });
    } catch (e) {
      debugPrint('AudioEffectsService.setDolbyLikeEnabled failed: $e');
    }
  }

  static Future<void> dispose() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('disposeEffects');
    } catch (e) {
      debugPrint('AudioEffectsService.dispose failed: $e');
    }
  }
}
