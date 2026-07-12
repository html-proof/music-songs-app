import 'dart:async';

import 'package:flutter/material.dart';
import '../services/connectivity_manager.dart';
import 'package:just_audio/just_audio.dart';
import '../services/listening_safety_service.dart';
import '../models/song.dart';
import '../services/player_service.dart';
import '../services/stability_logger.dart';

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  Song? get currentSong => PlayerService.currentSong;
  List<Song> get queue => PlayerService.queue;
  int get currentIndex => PlayerService.currentIndex;
  bool get canSkipPrevious => !isBuffering && !PlayerService.isLoadingNewSong && !isSwitchingSource && PlayerService.canSkipPrevious;
  bool get canSkipNext => !isBuffering && !PlayerService.isLoadingNewSong && !isSwitchingSource && PlayerService.canSkipNext;

  /// The song the UI should display. During loading, this is the song the user
  /// just tapped (resolvingSong). Once loaded, it falls back to currentSong.
  /// This ensures artwork, title, and artist update instantly on tap.
  Song? get activeSong => _resolvingSong ?? currentSong;

  /// True while PlayerService is resolving a new song's stream URL.
  bool get isLoadingNewSong => _resolvingSong != null;

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
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

  final List<StreamSubscription> _subscriptions = [];
  DateTime _lastPositionUpdate = DateTime.now();
  Timer? _watchdogTimer;

  Song? get resolvingSong => _resolvingSong;
  bool get isPlaying => _isPlaying;
  bool get shuffleModeEnabled => _shuffleModeEnabled;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isOffline => _isOffline;
  bool get isWeakConnection => ConnectivityManager.isWeak;
  bool get isBuffering => _isBuffering || _resolvingSong != null;
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
  }

  void _bindListeners() {
    _subscriptions.add(PlayerService.playingStream.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
      if (playing) {
        unawaited(_hydrateSongStateIfMissing());
      }
    }));

    int lastNotifiedMs = -1;
    _subscriptions.add(PlayerService.positionStream.listen((pos) {
      _lastPositionUpdate = DateTime.now();

      if (_ignorePositionUntilZero) {
        final state = PlayerService.player.processingState;
        final playing = PlayerService.player.playing;
        if (pos == Duration.zero ||
            pos.inMilliseconds < 300 ||
            state == ProcessingState.ready ||
            playing) {
          _ignorePositionUntilZero = false;
        } else {
          return;
        }
      }
      if (!_isSeeking && _resolvingSong == null && !_isSwitchingSource && !_isQualitySwitching) {
        _position = pos;
        final currentMs = pos.inMilliseconds;
        if ((currentMs - lastNotifiedMs).abs() >= 240 || currentMs < 1000) {
          lastNotifiedMs = currentMs;
          notifyListeners();
        }
      }
    }));

    _subscriptions.add(PlayerService.durationStream.listen((dur) {
      if (_isSwitchingSource || _isQualitySwitching) return;
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

    _subscriptions.add(PlayerService.player.currentIndexStream.listen((index) {
      if (_isSwitchingSource || _isQualitySwitching) return;
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
      } else {
        _position = Duration.zero;
        _ignorePositionUntilZero = true;
      }
      notifyListeners();
    }));

    _subscriptions.add(PlayerService.shuffleModeStream.listen((enabled) {
      _shuffleModeEnabled = enabled;
      notifyListeners();
    }));
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isPlaying && !_isSeeking && !_isBuffering && !_isSwitchingSource && !_isQualitySwitching) {
        final timeSinceLastUpdate = DateTime.now().difference(_lastPositionUpdate);
        if (timeSinceLastUpdate > const Duration(seconds: 3)) {
          StabilityLogger.warning('Playback', 'Watchdog detected stuck position stream (last update: ${timeSinceLastUpdate.inSeconds}s ago). Reconnecting listeners.');
          reconnectListeners();
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
    if (state != AppLifecycleState.resumed) return;
    _syncRuntimeSnapshot();
    unawaited(_hydrateSongStateIfMissing(force: true));
  }

  Future<void> _hydrateSongStateIfMissing({bool force = false}) async {
    if (_hydrationInProgress) return;

    final hasSong = currentSong != null;
    final playerState = PlayerService.player.playerState;
    final hasActiveSession =
        PlayerService.player.playing ||
        playerState.processingState != ProcessingState.idle ||
        PlayerService.player.currentIndex != null ||
        (PlayerService.player.duration?.inMilliseconds ?? 0) > 0;

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
    _isPlaying = PlayerService.player.playing;
    _position = PlayerService.player.position;
    final dur = PlayerService.player.duration;
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
    final state = PlayerService.player.playerState.processingState;
    _isBuffering =
        state == ProcessingState.buffering || state == ProcessingState.loading;
    _isQualitySwitching = PlayerService.isQualitySwitching;
    _isSwitchingSource = PlayerService.isSwitchingSource;
    _isInterruptionActive = PlayerService.isInterruptionActive;
    _isConversationMode = PlayerService.conversationModeActive;
    _outputDeviceState = ListeningSafetyService.outputDeviceState;
    _shuffleModeEnabled = PlayerService.shuffleModeEnabled;
    if (notify) notifyListeners();
  }

  Future<void> play(Song song, {List<Song>? playlist, int? index}) async {
    _position = Duration.zero;
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
      _position = PlayerService.player.position;
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
      }
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }
}
