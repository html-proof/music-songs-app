import 'dart:async';
import '../models/song.dart';
import '../models/playback_identity.dart';

class PlaybackCoordinator {
  static String? _currentRequestId;
  static PlaybackIdentity? _currentIdentity;

  static final StreamController<String?> _requestController = StreamController<String?>.broadcast();
  static final StreamController<PlaybackIdentity?> _identityController = StreamController<PlaybackIdentity?>.broadcast();

  static String? get currentRequestId => _currentRequestId;
  static PlaybackIdentity? get currentIdentity => _currentIdentity;

  static Stream<String?> get requestStream => _requestController.stream;
  static Stream<PlaybackIdentity?> get identityStream => _identityController.stream;

  /// Generates a new unique request ID, cancels any previous requests,
  /// and locks the playback identity to the target song.
  static String newRequest(Song song) {
    final requestId = '${song.id}_${DateTime.now().microsecondsSinceEpoch}';
    _currentRequestId = requestId;
    _requestController.add(requestId);

    // Immediately lock identity to the new song
    final identity = PlaybackIdentity.fromSong(song, DateTime.now().millisecondsSinceEpoch);
    _currentIdentity = identity;
    _identityController.add(identity);

    return requestId;
  }

  /// Verifies if a given request ID is still the active one.
  static bool isValid(String? requestId) {
    if (requestId == null || _currentRequestId == null) return false;
    return requestId == _currentRequestId;
  }

  /// Locks a specific identity (e.g. during state hydration/restoration).
  static void lockIdentity(PlaybackIdentity identity) {
    _currentIdentity = identity;
    _identityController.add(identity);
  }

  /// Clears the active request and identity.
  static void reset() {
    _currentRequestId = null;
    _currentIdentity = null;
    _requestController.add(null);
    _identityController.add(null);
  }
}
