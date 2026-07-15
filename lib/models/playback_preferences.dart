import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';

import 'song.dart';
import '../services/preferences_service.dart';

class PlaybackPreferences {
  static AudioQuality selectedAudioQuality = AudioQuality.auto;
  static bool dataSaverEnabled = false;
  static int temporaryAutoKbps = 320;
  static int adaptiveLowKbps = 64;
  static const String defaultSpeedProbeUrl = 'https://www.google.com/favicon.ico';

  static Future<void> applyPreferredAudioQuality() async {
    final prefs = PreferencesService.instance;
    final qualityStr = prefs.getString('audio_quality') ?? 'auto';
    final dataSaver = prefs.getBool('data_saver_enabled') ?? false;

    dataSaverEnabled = dataSaver;

    switch (qualityStr) {
      case 'low':
        selectedAudioQuality = AudioQuality.low;
        break;
      case 'medium':
        selectedAudioQuality = AudioQuality.medium;
        break;
      case 'high':
        selectedAudioQuality = AudioQuality.high;
        break;
      case 'auto':
      default:
        selectedAudioQuality = AudioQuality.auto;
        break;
    }
  }

  static Future<int> resolvePreferredStreamingKbps() async {
    if (selectedAudioQuality != AudioQuality.auto) {
      if (dataSaverEnabled) {
        final connectivityResult = await (Connectivity().checkConnectivity());
        if (connectivityResult != ConnectivityResult.wifi) {
          return adaptiveLowKbps;
        }
      }
      return selectedAudioQuality.bitrateKbps;
    }

    final speedMbps = await measureNetworkSpeedMbps();
    final autoKbps = adaptiveBitrateFromSpeed(speedMbps);

    if (dataSaverEnabled) {
      final connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult != ConnectivityResult.wifi) {
        return autoKbps < adaptiveLowKbps ? autoKbps : adaptiveLowKbps;
      }
    }

    temporaryAutoKbps = autoKbps;
    return autoKbps;
  }

  static Future<double> measureNetworkSpeedMbps() async {
    try {
      final client = http.Client();
      final stopwatch = Stopwatch()..start();
      final request = http.Request('GET', Uri.parse(defaultSpeedProbeUrl));
      
      final response = await client.send(request).timeout(const Duration(seconds: 2));
      
      int bytesDownloaded = 0;
      await for (final chunk in response.stream) {
        bytesDownloaded += chunk.length;
      }
      
      stopwatch.stop();
      client.close();

      if (stopwatch.elapsedMilliseconds == 0) return 1.0; 

      final seconds = stopwatch.elapsedMilliseconds / 1000.0;
      final bits = bytesDownloaded * 8;
      final megabits = bits / 1000000.0;
      final speedMbps = megabits / seconds;

      return speedMbps;
    } catch (e) {
      return 1.0; 
    }
  }

  static int adaptiveBitrateFromSpeed(double speedMbps) {
    if (speedMbps > 2.0) return 320; 
    if (speedMbps > 1.0) return 160; 
    if (speedMbps > 0.5) return 96;  
    return 64; 
  }
}
