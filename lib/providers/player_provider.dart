import 'dart:async';

import 'package:flutter/material.dart';
import '../services/connectivity_manager.dart';
import 'package:just_audio/just_audio.dart';
import '../services/listening_safety_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart';
import '../services/player_service.dart';
import '../services/stability_logger.dart';
import '../services/playback_coordinator.dart';

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  Song? get currentSong => PlayerService.currentSong;
  List<Song> get queue => PlayerService.queue;
  int get currentIndex => PlayerService.currentIndex;
  bool get canSkipPrevious => !PlayerService.isLoadingNewSong && !isSwitchingSource && PlayerService.canSkipPrevious;
  bool get canSkipNext => !PlayerService.isLoadingNewSong && !isSwitchingSource && PlayerService.canSkipNext;

  Song? get activeSong {
    final identity = PlaybackCoordinator.currentIdentity;
    if (identity != null) {
      return Song(
        id: identity.songId,
        name: identity.title,
        artist: identity.artist,
        album: identity.album,
        duration: identity.durationSeconds,
        isExplicit: identity.isExplicit,
        imageUrl: identity.imageUrl,
      );
    }
    return PlayerService.currentSong;
  }

  /// True while PlayerService is resolving a new song's stream URL.
  bool get isLoadingNewSong =>
      playbackState == PlaybackState.resolvingSong ||
      playbackState == PlaybackState.verifyingIdentity ||
      playbackState == PlaybackState.loadingStream ||
      playbackState == PlaybackState.preparingDecoder;

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;

  Duration get bufferedPosition => _bufferedPosition;
  PlaybackState get playbackState => PlayerService.playbackState;
  bool _isOffline = false;
  bool _isBuffering = false;
  bool _isQualitySwitching = false;
  bool _isSwitchingSource = false;
  bool _isInterruptionActive = false;
  bool _isConversationMode = false;
  bool _isSeeking = false;
  String? _qualityAdjustmentMessage;
  Song? _resolvingSong;
  bool _shuffleModeEnabled = false;
  LoopMode _loopMode = LoopMode.off;

  final List<StreamSubscription> _subscriptions = [];
  DateTime _lastPositionUpdate = DateTime.now();
  Timer? _watchdogTimer;
  Timer? _loadingSafetyTimer;

  Song? get resolvingSong => _resolvingSong;
  bool get isPlaying => _isPlaying;
  bool get shuffleModeEnabled => _shuffleModeEnabled;
  LoopMode get loopMode => _loopMode;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isOffline => _isOffline;
  bool get isWeakConnection => ConnectivityManager.isWeak;
  bool get isBuffering => _isBuffering;
  bool get isQualitySwitching => _isQualitySwitching;
  bool get isSwitchingSource => _isSwitchingSource;
  bool get isInterruptionActive => _isInterruptionActive;
  bool get isConversationMode => _isConversationMode;
  bool get isConversationModeActive => _isConversationMode;
  bool get isSeeking => _isSeeking;
  bool get isConversationContextEligible =>
      PlayerService.isConversationContextEligible();

  Future<void> toggleConversationMode() async {
    await PlayerService.toggleConversationMode();
    notifyListeners();
  }

  /// Last quality adjustment message (e.g. "Upgrading audio quality to High…").
  /// Consumed once via [consumeQualityAdjustmentMessage].
  String? get qualityAdjustmentMessage => _qualityAdjustmentMessage;

  /// Returns and clears the pending quality adjustment message.
  String? consumeQualityAdjustmentMessage() {
    final msg = _qualityAdjustmentMessage;
    _qualityAdjustmentMessage = null;
    return msg;
  }

  bool _headphonesConnected = false;
  String? _headphoneDeviceName;
  bool _bluetoothHeadsetConnected = false;
  String? _bluetoothDeviceName;
  AudioOutputRouteState _outputDeviceState =
      ListeningSafetyService.outputDeviceState;

  bool get headphonesConnected => _headphonesConnected;
  String? get headphoneDeviceName => _headphoneDeviceName;
  bool get bluetoothHeadsetConnected => _bluetoothHeadsetConnected;
  String? get bluetoothDeviceName => _bluetoothDeviceName;
  AudioOutputRouteState get outputDeviceState => _outputDeviceState;
  bool _hydrationInProgress = false;
  bool _ignorePositionUntilZero = false;

  PlayerProvider() {
    WidgetsBinding.instance.addObserver(this);
    _bindListeners();
    _initConnectivity();
    _syncRuntimeSnapshot(notify: false);
    unawaited(_hydrateSongStateIfMissing(force: true));
    _startWatchdog();

    _headphonesConnected = ListeningSafetyService.headphonesConnected;
    _headphoneDeviceName = ListeningSafetyService.headphoneDeviceName;
    _bluetoothHeadsetConnected =
        ListeningSafetyService.bluetoothHeadsetConnected;
    _bluetoothDeviceName = ListeningSafetyService.bluetoothDeviceName;
    _outputDeviceState = ListeningSafetyService.outputDeviceState;
    _isConversationMode = PlayerService.conversationModeActive;
    _shuffleModeEnabled = PlayerService.shuffleModeEnabled;
    _loopMode = PlayerService.loopMode;
  }

  void _bindListeners() {
    _subscriptions.add(PlayerService.playingStream.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
      if (playing) {
        unawaited(_hydrateSongStateIfMissing());
      }
    }));

    _subscriptions.add(PlayerService.loopModeStream.listen((mode) {
      _loopMode = mode;
      notifyListeners();
    }));

    int lastNotifiedMs = -1;
    _subscriptions.add(PlayerService.positionStream.listen((pos) {
      _lastPositionUpdate = DateTime.now();

      if (_ignorePositionUntilZero) {
        final state = PlayerService.processingState;
        final playing = PlayerService.isPlaying;
        if (pos == Duration.zero ||
            pos.inMilliseconds < 300 ||
            state == ProcessingState.ready ||
            playing) {
          _ignorePositionUntilZero = false;
        } else {
          return;
        }
      }
      if (!_isSeeking && (!_isSwitchingSource || pos == Duration.zero) && !_isQualitySwitching) {
        // Allow position updates to flow through even during loading,
        // as long as the audio engine is actually playing. This prevents
        // the timestamp from being frozen at 00:00.
        if (_resolvingSong != null || _isBuffering) {
          // Only accept position updates if the player is actually playing
          final playerPlaying = PlayerService.isPlaying;
          if (!playerPlaying && pos != Duration.zero) return;
        }
        _position = pos;
        final currentMs = pos.inMilliseconds;
        if ((currentMs - lastNotifiedMs).abs() >= 240 || currentMs < 1000 || pos == Duration.zero) {
          lastNotifiedMs = currentMs;
          notifyListeners();
        }
      }
    }));

    _subscriptions.add(PlayerService.durationStream.listen((dur) {
      if (_isQualitySwitching) return;
      if (dur != null && dur > Duration.zero) {
        _duration = dur;
      } else {
        final song = activeSong;
        if (song != null && song.duration != null && song.duration! > 0) {
          _duration = Duration(seconds: song.duration!);
        } else {
          _duration = Duration.zero;
        }
      }
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.currentIndexStream.listen((index) {
      if (_isQualitySwitching) return;
      final song = PlayerService.currentSong;
      if (song != null) {
        _position = Duration.zero;
        _duration = (song.duration != null && song.duration! > 0)
            ? Duration(seconds: song.duration!)
            : Duration.zero;
        _ignorePositionUntilZero = true;
      }
      notifyListeners();
      unawaited(_hydrateSongStateIfMissing());
    }));

    _subscriptions.add(PlayerService.playerStateStream.listen((state) {
      if (_isSwitchingSource || _isQualitySwitching) return;
      _isBuffering =
          state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      if (state.processingState == ProcessingState.ready) {
        _ignorePositionUntilZero = false;
      }
      notifyListeners();
      if (state.processingState != ProcessingState.idle) {
        unawaited(_hydrateSongStateIfMissing());
      }
    }));

    _subscriptions.add(PlayerService.qualitySwitchingStream.listen((switching) {
      _isQualitySwitching = switching;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.sourceSwitchingStream.listen((switching) {
      _isSwitchingSource = switching;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.interruptionActiveStream.listen((active) {
      _isInterruptionActive = active;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.conversationModeStream.listen((active) {
      _isConversationMode = active;
      notifyListeners();
    }));

    _subscriptions.add(ListeningSafetyService.headphoneStream.listen((connected) {
      _headphonesConnected = connected;
      _headphoneDeviceName = ListeningSafetyService.headphoneDeviceName;
      _bluetoothHeadsetConnected =
          ListeningSafetyService.bluetoothHeadsetConnected;
      _bluetoothDeviceName = ListeningSafetyService.bluetoothDeviceName;
      notifyListeners();
    }));

    _subscriptions.add(ListeningSafetyService.outputDeviceStream.listen((outputState) {
      _outputDeviceState = outputState;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.qualityAdjustmentMessageStream.listen((message) {
      _qualityAdjustmentMessage = message;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.resolvingSongStream.listen((song) {
      _resolvingSong = song;
      if (song != null) {
        _position = Duration.zero;
        _ignorePositionUntilZero = true;
        // Start a safety timer: if _resolvingSong isn't cleared within 15s,
        // force-clear it to prevent permanent UI lockup.
        _loadingSafetyTimer?.cancel();
        _loadingSafetyTimer = Timer(const Duration(seconds: 15), () {
          if (_resolvingSong != null) {
            StabilityLogger.warning('Playback', 'Loading safety timer: force-clearing stuck _resolvingSong after 15s.');
            _resolvingSong = null;
            notifyListeners();
          }
        });
      } else {
        _position = Duration.zero;
        _ignorePositionUntilZero = true;
        _loadingSafetyTimer?.cancel();
        _loadingSafetyTimer = null;
      }
      notifyListeners();
    }));

    _subscriptions.add(PlaybackCoordinator.identityStream.listen((_) {
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.playbackStateStream.listen((_) {
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.bufferedPositionStream.listen((buf) {
      if (_isQualitySwitching) return;
      _bufferedPosition = buf;
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.shuffleModeStream.listen((enabled) {
      _shuffleModeEnabled = enabled;
      notifyListeners();
    }));
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final isPlaying = PlayerService.isPlaying;
      final isConnected = _isOffline == false;
      final isCompleted = PlayerService.playerState.processingState == ProcessingState.completed;

      if (isPlaying && isConnected && !isCompleted) {
        final timeSinceLastUpdate = DateTime.now().difference(_lastPositionUpdate);
        if (timeSinceLastUpdate > const Duration(seconds: 3)) {
          StabilityLogger.warning('Playback', 'Watchdog detected stuck UI stream listeners (last update: ${timeSinceLastUpdate.inSeconds}s ago). Reconnecting listeners and triggering recovery.');

          // Reset status flags to prevent stale deadlock
          _isBuffering = false;
          _isSwitchingSource = false;
          _isQualitySwitching = false;

          // Re-subscribe UI listeners
          reconnectListeners();

          // Trigger service-level playback recovery
          unawaited(PlayerService.recoverPlayback());
        }
      }
    });
  }

  void reconnectListeners() {
    StabilityLogger.info('Playback', 'Reconnecting PlayerProvider stream listeners.');
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _bindListeners();
    _initConnectivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncRuntimeSnapshot();
      unawaited(_hydrateSongStateIfMissing(force: true));
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      unawaited(PlayerService.savePlaybackStateOnBackground());
    }
  }

  Future<void> _hydrateSongStateIfMissing({bool force = false}) async {
    if (_hydrationInProgress) return;

    final hasSong = currentSong != null;
    final playerState = PlayerService.playerState;
    final hasActiveSession =
        PlayerService.isPlaying ||
        playerState.processingState != ProcessingState.idle ||
        PlayerService.playerCurrentIndex != null ||
        (PlayerService.duration?.inMilliseconds ?? 0) > 0;

    if (!force && (hasSong || !hasActiveSession)) return;

    _hydrationInProgress = true;
    try {
      final hydrated = await PlayerService.syncRuntimeSongStateIfMissing();
      if (hydrated) {
        _syncRuntimeSnapshot(notify: false);
        notifyListeners();
      }
    } finally {
      _hydrationInProgress = false;
    }
  }

  void _syncRuntimeSnapshot({bool notify = true}) {
    _isPlaying = PlayerService.isPlaying;
    _position = PlayerService.position;
    _bufferedPosition = PlayerService.bufferedPosition;
    final dur = PlayerService.duration;
    if (dur != null && dur > Duration.zero) {
      _duration = dur;
    } else {
      final song = activeSong;
      if (song != null && song.duration != null && song.duration! > 0) {
        _duration = Duration(seconds: song.duration!);
      } else {
        _duration = Duration.zero;
      }
    }
    final state = PlayerService.processingState;
    _isBuffering =
        state == ProcessingState.buffering || state == ProcessingState.loading;
    _isQualitySwitching = PlayerService.isQualitySwitching;
    _isSwitchingSource = PlayerService.isSwitchingSource;
    _isInterruptionActive = PlayerService.isInterruptionActive;
    _isConversationMode = PlayerService.conversationModeActive;
    _outputDeviceState = ListeningSafetyService.outputDeviceState;
    _shuffleModeEnabled = PlayerService.shuffleModeEnabled;
    _loopMode = PlayerService.loopMode;
    if (notify) notifyListeners();
  }

  Future<void> play(Song song, {List<Song>? playlist, int? index}) async {
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _ignorePositionUntilZero = true;
    // Eagerly set duration from song metadata so the progress bar renders
    // immediately with the correct end time (e.g. "0:00 ── 3:45").
    _duration = (song.duration != null && song.duration! > 0)
        ? Duration(seconds: song.duration!)
        : Duration.zero;
    notifyListeners();
    await PlayerService.play(song, playlist: playlist, index: index);
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    await PlayerService.togglePlayPause();
  }

  Future<void> seek(Duration position, {bool immediate = false}) async {
    _ignorePositionUntilZero = false;
    _position = position;
    notifyListeners();
    await PlayerService.seek(position, immediate: immediate);
  }

  Future<void> setSeeking(bool seeking) async {
    if (_isSeeking == seeking) return;
    _isSeeking = seeking;
    notifyListeners();
    if (seeking) {
      // Mark seek gesture start; playback continues while scrubbing.
      PlayerService.beginSeekGesture();
    } else {
      // Keep playback state stable after final seek position is applied.
      await PlayerService.endSeekGesture();
      // Refresh to actual player position when drag ends.
      _position = PlayerService.position;
      notifyListeners();
    }
  }

  Future<void> skipNext() async {
    _position = Duration.zero;
    notifyListeners();
    await PlayerService.skipNext();
    notifyListeners();
  }

  Future<void> skipPrevious() async {
    _position = Duration.zero;
    notifyListeners();
    await PlayerService.skipPrevious();
    notifyListeners();
  }

  Future<void> toggleShuffleMode() async {
    await PlayerService.setShuffleModeEnabled(!_shuffleModeEnabled);
    notifyListeners();
  }

  Future<void> toggleRepeatMode() async {
    final nextMode = switch (_loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await PlayerService.setLoopMode(nextMode);
    notifyListeners();
  }

  Future<void> setVideoPlaybackState({
    required bool isPlaying,
    String sourceId = 'default_video',
  }) async {
    await PlayerService.setVideoPlaybackState(
      isPlaying: isPlaying,
      sourceId: sourceId,
    );
  }

  Future<void> _initConnectivity() async {
    _isOffline = ConnectivityManager.isOffline;
    notifyListeners();

    _subscriptions.add(ConnectivityManager.statusStream.listen((status) {
      final wasOffline = _isOffline;
      _isOffline = status == ConnectionStatus.disconnected;
      if (wasOffline != _isOffline) {
        notifyListeners();
        if (wasOffline && !_isOffline) {
          reconnectListeners();
        }
      }
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    _loadingSafetyTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }
}
