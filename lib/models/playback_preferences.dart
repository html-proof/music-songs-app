import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:async';

import 'user_preferences.dart';

class PlaybackPreferences {
  static AudioQuality selectedAudioQuality = AudioQuality.auto;
  static bool dataSaverEnabled = false;
  static int temporaryAutoKbps = 320;
  static int adaptiveLowKbps = 64;
  static const String defaultSpeedProbeUrl = 'https://www.google.com/favicon.ico';

  static Future<void> applyPreferredAudioQuality() async {
    // This method is currently a placeholder as its original implementation
    // used a singleton PreferencesService.instance which is not present.
  }

  static Future<int> resolvePreferredStreamingKbps() async {
    if (selectedAudioQuality != AudioQuality.auto) {
      if (dataSaverEnabled) {
        final connectivityResult = await (Connectivity().checkConnectivity());
        if (!connectivityResult.contains(ConnectivityResult.wifi)) {
          return adaptiveLowKbps;
        }
      }
      return selectedAudioQuality.kbps;
    }

    final speedMbps = await measureNetworkSpeedMbps();
    final autoKbps = adaptiveBitrateFromSpeed(speedMbps);

    if (dataSaverEnabled) {
      final connectivityResult = await (Connectivity().checkConnectivity());
      if (!connectivityResult.contains(ConnectivityResult.wifi)) {
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
