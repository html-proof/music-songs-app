import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:just_audio/just_audio.dart';
import '../services/listening_safety_service.dart';
import '../models/song.dart';
import '../services/player_service.dart';

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

  Song? get resolvingSong => _resolvingSong;
  bool get isPlaying => _isPlaying;
  bool get shuffleModeEnabled => _shuffleModeEnabled;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isOffline => _isOffline;
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
    _initConnectivity();
    _syncRuntimeSnapshot(notify: false);
    unawaited(_hydrateSongStateIfMissing(force: true));

    PlayerService.playingStream.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
      if (playing) {
        unawaited(_hydrateSongStateIfMissing());
      }
    });

    int lastNotifiedMs = -1;
    PlayerService.positionStream.listen((pos) {
      if (_ignorePositionUntilZero) {
        // Only clear the guard once the player confirms it is genuinely at/near
        // the start of the new track. 300ms is tight enough to distinguish a
        // true fresh start from a stale audio-buffer position carried over from
        // the previous song (which typically shows up as 5–15 seconds).
        //
        // Fallback: If the player is already in ready state or actively playing,
        // it means the transition has finished and we must not ignore the position.
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
      if (!_isSeeking && _resolvingSong == null) {
        _position = pos;
        final currentMs = pos.inMilliseconds;
        // Synced lyrics require higher frequency updates than once per second.
        // We notify at 240ms intervals (~4.1Hz) which provides a good balance
        // of UI fluidity and battery efficiency.
        if ((currentMs - lastNotifiedMs).abs() >= 240 || currentMs < 1000) {
          lastNotifiedMs = currentMs;
          notifyListeners();
        }
      }
    });

    PlayerService.durationStream.listen((dur) {
      _duration = dur ?? Duration.zero;
      notifyListeners();
    });

    PlayerService.player.currentIndexStream.listen((index) {
      final song = PlayerService.currentSong;
      if (song != null) {
        _position = Duration.zero;
        _duration = Duration(seconds: song.duration ?? 0);
        _ignorePositionUntilZero = true;
      }
      notifyListeners();
      unawaited(_hydrateSongStateIfMissing());
    });

    PlayerService.playerStateStream.listen((state) {
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
    });

    PlayerService.qualitySwitchingStream.listen((switching) {
      _isQualitySwitching = switching;
      notifyListeners();
    });

    PlayerService.sourceSwitchingStream.listen((switching) {
      _isSwitchingSource = switching;
      notifyListeners();
    });

    PlayerService.interruptionActiveStream.listen((active) {
      _isInterruptionActive = active;
      notifyListeners();
    });

    PlayerService.conversationModeStream.listen((active) {
      _isConversationMode = active;
      notifyListeners();
    });

    ListeningSafetyService.headphoneStream.listen((connected) {
      _headphonesConnected = connected;
      _headphoneDeviceName = ListeningSafetyService.headphoneDeviceName;
      _bluetoothHeadsetConnected =
          ListeningSafetyService.bluetoothHeadsetConnected;
      _bluetoothDeviceName = ListeningSafetyService.bluetoothDeviceName;
      notifyListeners();
    });
    ListeningSafetyService.outputDeviceStream.listen((outputState) {
      _outputDeviceState = outputState;
      notifyListeners();
    });

    PlayerService.qualityAdjustmentMessageStream.listen((message) {
      _qualityAdjustmentMessage = message;
      notifyListeners();
    });

    PlayerService.resolvingSongStream.listen((song) {
      _resolvingSong = song;
      if (song != null) {
        // A new song is being resolved — force position to 0:00 and block any
        // position stream events from the old audio buffer.
        _position = Duration.zero;
        _ignorePositionUntilZero = true;
      } else {
        // Resolution finished (song → null). Keep the guard active and hold
        // position at 0:00 until positionStream confirms the player is truly
        // at/near zero. Without this, the stale buffer position from the
        // previous song can slip through in the brief gap between this event
        // and the first tick of the new track's positionStream.
        _position = Duration.zero;
        _ignorePositionUntilZero = true;
      }
      notifyListeners();
    });

    PlayerService.shuffleModeStream.listen((enabled) {
      _shuffleModeEnabled = enabled;
      notifyListeners();
    });

    // Initial state
    _headphonesConnected = ListeningSafetyService.headphonesConnected;
    _headphoneDeviceName = ListeningSafetyService.headphoneDeviceName;
    _bluetoothHeadsetConnected =
        ListeningSafetyService.bluetoothHeadsetConnected;
    _bluetoothDeviceName = ListeningSafetyService.bluetoothDeviceName;
    _outputDeviceState = ListeningSafetyService.outputDeviceState;
    _isConversationMode = PlayerService.conversationModeActive;
    _shuffleModeEnabled = PlayerService.shuffleModeEnabled;
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
    _duration = PlayerService.player.duration ?? Duration.zero;
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
    final connectivity = Connectivity();
    final result = await connectivity.checkConnectivity();
    _isOffline = !_hasConnectivity(result);
    notifyListeners();

    connectivity.onConnectivityChanged.listen((results) {
      final wasOffline = _isOffline;
      _isOffline = !_hasConnectivity(results);
      if (wasOffline != _isOffline) {
        notifyListeners();
      }
    });
  }

  bool _hasConnectivity(List<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
