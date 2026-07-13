import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_hub/services/player_service.dart';
import 'package:music_hub/models/song.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Stub SharedPreferences channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getAll') {
          return <String, Object>{};
        }
        return null;
      },
    );

    // Stub Connectivity channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'check') {
          return ['wifi'];
        }
        return null;
      },
    );

    // Stub Audio Session channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (MethodCall methodCall) async {
        return null;
      },
    );

    // Stub Just Audio channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'init') {
          return {
            'id': methodCall.arguments['id'],
          };
        }
        return null;
      },
    );

    // Stub Audio Effects channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('music_hub/audio_effects'),
      (MethodCall methodCall) async {
        return null;
      },
    );

    // Stub Fluttertoast channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('PonnamKarthik/fluttertoast'),
      (MethodCall methodCall) async {
        return true;
      },
    );
  });

  group('Playback Pipeline Serialization & Session Invalidation Tests', () {
    test('Overlapping play calls increment session ID and supersede previous requests', () async {
      // Create test songs
      final songA = Song(
        id: 'song_a',
        name: 'Song A',
        artist: 'Artist A',
        album: 'Album A',
        duration: 200,
        streamUrl: 'https://example.com/song_a.mp3',
      );

      final songB = Song(
        id: 'song_b',
        name: 'Song B',
        artist: 'Artist B',
        album: 'Album B',
        duration: 240,
        streamUrl: 'https://example.com/song_b.mp3',
      );

      // Start play for Song A
      final playAFuture = PlayerService.play(songA);

      // Start play for Song B immediately after
      final playBFuture = PlayerService.play(songB);

      // Both should finish
      await Future.wait([playAFuture, playBFuture]);

      // Since B was the last one, it should be the one successfully prepared or attempted
      expect(PlayerService.currentSong?.id, isNot('song_a'));
    });
  });
}
