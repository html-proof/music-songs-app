import 'dart:async';
import '../models/song.dart';
import '../models/playback_identity.dart';
import 'search_coordinator.dart';
import 'stability_logger.dart';

class PlaybackCoordinator {
  static String? _currentRequestId;
  static PlaybackIdentity? _currentIdentity;
  static int _lastPreResolvedIndex = -1;

  static final StreamController<String?> _requestController = StreamController<String?>.broadcast();
  static final StreamController<PlaybackIdentity?> _identityController = StreamController<PlaybackIdentity?>.broadcast();

  static String? get currentRequestId => _currentRequestId;
  static PlaybackIdentity? get currentIdentity => _currentIdentity;

  static Stream<String?> get requestStream => _requestController.stream;
  static Stream<PlaybackIdentity?> get identityStream => _identityController.stream;

  /// Generates a new unique request ID, cancels any previous requests,
  /// and locks the playback identity to the target song.
  static String newRequest(Song song) {
    // Immediately cancel any pending background searches!
    SearchCoordinator.cancelAll();

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

  /// Pre-resolves the next few songs in the queue to ensure instant transitions.
  static Future<void> preResolveQueue(List<Song> queue, int currentIndex) async {
    if (currentIndex == _lastPreResolvedIndex) return;
    _lastPreResolvedIndex = currentIndex;

    StabilityLogger.info('PlaybackCoordinator', 'Pre-resolving queue from index $currentIndex');

    // Resolve the next 3 songs in the background
    for (int i = currentIndex + 1; i <= currentIndex + 3 && i < queue.length; i++) {
      final song = queue[i];
      unawaited(SearchCoordinator.recoverSong(song, sessionId: 'pre-resolve-$i'));
    }
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
    _lastPreResolvedIndex = -1;
  }
}
