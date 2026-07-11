import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_service.dart';

/// Service that uses the microphone to detect loud ambient noise (like a conversation)
/// and automatically triggers Conversation Mode to lower the volume.
class SmartVolumeService {
  static const String _micDetectionPrefKey = 'smart_volume_mic_detection_enabled';
  
  static bool _isDetectionEnabled = false;
  static bool get isDetectionEnabled => _isDetectionEnabled;

  static NoiseMeter? _noiseMeter;
  static StreamSubscription<NoiseReading>? _noiseSubscription;
  
  static bool _isListening = false;
  static Timer? _silenceTimer;
  static DateTime? _lastNoiseDetectedAt;
  
  // Decibel threshold for detecting speech/loud noise
  static const double _dbThreshold = 65.0; 
  // How long silence must last before restoring volume safely
  static const Duration _silenceDelay = Duration(seconds: 4);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isDetectionEnabled = prefs.getBool(_micDetectionPrefKey) ?? false;
    
    // Wire up to player state so we only listen when playing
    PlayerService.playingStream.listen((isPlaying) {
      if (isPlaying) {
        if (_isDetectionEnabled) _startListening();
      } else {
        _stopListening();
      }
    });

    if (_isDetectionEnabled && PlayerService.player.playing) {
      _startListening();
    }
  }

  static Future<void> setDetectionEnabled(bool enabled) async {
    if (enabled) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        debugPrint('Microphone permission denied for Smart Volume.');
        return;
      }
    }
    
    _isDetectionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_micDetectionPrefKey, enabled);

    if (enabled) {
      if (PlayerService.player.playing) _startListening();
    } else {
      _stopListening();
    }
  }

  static void _startListening() {
    if (_isListening) return;
    
    _noiseMeter ??= NoiseMeter();
    
    try {
      _noiseSubscription = _noiseMeter?.noise.listen(
        _onData,
        onError: _onError,
      );
      _isListening = true;
      debugPrint('Smart Volume: Started listening for conversation.');
    } catch (e) {
      debugPrint('Smart Volume: Failed to start listening: $e');
      _isListening = false;
    }
  }

  static void _stopListening() {
    if (!_isListening) return;
    
    _noiseSubscription?.cancel();
    _silenceTimer?.cancel();
    _isListening = false;
    debugPrint('Smart Volume: Stopped listening.');
    
    // If we were in conversation mode because of noise, restore it
    if (PlayerService.conversationModeActive) {
      PlayerService.toggleConversationMode(); // turn it off
    }
  }

  static void _onData(NoiseReading noiseReading) {
    if (!_isListening) return;
    
    final currentDb = noiseReading.meanDecibel;
    
    if (currentDb > _dbThreshold) {
      _lastNoiseDetectedAt = DateTime.now();
      
      // If conversation mode is NOT active, activate it!
      if (!PlayerService.conversationModeActive) {
        debugPrint('Smart Volume: Detected loud noise (${currentDb.toStringAsFixed(1)} dB). Ducking volume.');
        PlayerService.toggleConversationMode();
      }
      
      // Cancel any pending restore timer since it's still loud
      _silenceTimer?.cancel();
    } else {
      // It's quiet. If we are in conversation mode, check if we've been quiet long enough.
      if (PlayerService.conversationModeActive && _lastNoiseDetectedAt != null) {
        final timeSinceNoise = DateTime.now().difference(_lastNoiseDetectedAt!);
        
        if (timeSinceNoise > _silenceDelay) {
          // It's been quiet for 4 seconds, restore volume!
          _silenceTimer?.cancel();
          _lastNoiseDetectedAt = null;
          debugPrint('Smart Volume: Silence detected. Restoring volume.');
          PlayerService.toggleConversationMode();
        }
      }
    }
  }

  static void _onError(Object error) {
    debugPrint('Smart Volume Error: $error');
    _isListening = false;
  }
}
