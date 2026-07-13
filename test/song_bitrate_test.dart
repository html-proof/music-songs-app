import 'package:flutter_test/flutter_test.dart';
import 'package:music_hub/models/song.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Song Bitrate Optimization Tests', () {
    const originalUrl = 'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_320.mp4';

    test('Data Saver (32 kbps) snaps to 12 kbps', () {
      final optimized = Song.optimizeStreamUrlForData(originalUrl, maxKbps: 32);
      expect(
        optimized,
        'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_12.mp4',
      );
    });

    test('Low (64 kbps) snaps to 48 kbps', () {
      final optimized = Song.optimizeStreamUrlForData(originalUrl, maxKbps: 64);
      expect(
        optimized,
        'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_48.mp4',
      );
    });

    test('Normal (96 kbps) snaps to 96 kbps', () {
      final optimized = Song.optimizeStreamUrlForData(originalUrl, maxKbps: 96);
      expect(
        optimized,
        'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_96.mp4',
      );
    });

    test('High (160 kbps) snaps to 160 kbps', () {
      final optimized = Song.optimizeStreamUrlForData(originalUrl, maxKbps: 160);
      expect(
        optimized,
        'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_160.mp4',
      );
    });

    test('Very High (320 kbps) snaps to 320 kbps', () {
      final optimized = Song.optimizeStreamUrlForData(originalUrl, maxKbps: 320);
      expect(
        optimized,
        'https://aac.saavncdn.com/706/9c2bb7d991b30c3bd0132e44c61651b5_320.mp4',
      );
    });
  });
}
