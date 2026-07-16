import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'package:audio_session/audio_session.dart';
import 'connectivity_manager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'stability_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'search_coordinator.dart';
import '../models/playback_state.dart';
import '../models/user_preferences.dart';
import '../utils/content_filter.dart';
import '../utils/language_utils.dart';
import 'api_service.dart';
import 'audio_effects_service.dart';
import 'download_service.dart';
import 'listening_safety_service.dart';
import 'offline_service.dart';
import 'preferences_service.dart';
import 'session_state_service.dart';
import 'verification_engine.dart';
import 'background_learning_service.dart';
import 'playback_coordinator.dart';

enum PlaybackResumeResult {
  resumed,
  noPendingSession,
  offlineSongUnavailable,
  failed,
}

@immutable
class PlaybackResumeCandidate {
  final Song song;
  final Duration position;
  final DateTime savedAt;
  final bool wasPlaying;
  final AudioQuality audioQuality;
  final String outputDeviceName;
  final String outputDeviceType;
  final bool shouldAutoResume;

  // New fields for full playback restore
  final List<Song>? queue;
  final List<Song>? originalQueue;
  final int currentIndex;
  final bool shuffleModeEnabled;
  final LoopMode loopMode;
  final List<String>? playbackSourceKeys;

  const PlaybackResumeCandidate({
    required this.song,
    required this.position,
    required this.savedAt,
    required this.wasPlaying,
    required this.audioQuality,
    required this.outputDeviceName,
    required this.outputDeviceType,
    required this.shouldAutoResume,
    this.queue,
    this.originalQueue,
    this.currentIndex = 0,
    this.shuffleModeEnabled = false,
    this.loopMode = LoopMode.off,
    this.playbackSourceKeys,
  });
}

enum _ConversationActionType { pause, resume }

class _ConversationActionEvent {
  final _ConversationActionType type;
  final DateTime at;

  const _ConversationActionEvent(this.type, this.at);
}

@immutable
class _QueueSessionSnapshot {
  final List<Song> queue;
  final int currentIndex;
  final String currentSongId;
  final Duration position;

  const _QueueSessionSnapshot({
    required this.queue,
    required this.currentIndex,
    required this.currentSongId,
    required this.position,
  });
}

@immutable
class _ResolvedPlaybackTarget {
  final AudioSource audioSource;
  final String sourceKey;

  const _ResolvedPlaybackTarget({
    required this.audioSource,
    required this.sourceKey,
  });
}

class PlayerService {
  static final CustomAudioPlayer _player = CustomAudioPlayer();
  static Song? _currentSong;
  static final List<Song> _queue = [];
  static List<Song> _originalQueue = [];
  static bool _shuffleModeEnabled = false;
  static final StreamController<bool> _shuffleModeController =
      StreamController<bool>.broadcast();
  static Stream<bool> get shuffleModeStream => _shuffleModeController.stream;
  static bool get shuffleModeEnabled => _shuffleModeEnabled;
  static final List<String> _queuePlaybackSourceKeys = <String>[];
  static int _currentIndex = -1;
  static final Map<String, int> _songRecoveryAttempts = {};
  static final Set<String> _activeVideoSources = <String>{};
  static bool _pausedByVideoPlayback = false;
  static bool _pausedByAudioInterruption = false;
  static bool _pausedByOutputDisconnect = false;
  static bool _wasPlayingBeforeNoisyPause = false;
  static Timer? _deviceConnectResumeTimer;
  static bool _pausedByNetworkLoss = false;
  static Timer? _bufferingWatchdogTimer;
  static Timer? _loadingWatchdogTimer;
  static Timer? _playLoadingTimeoutTimer;
  static StreamSubscription<PlayerState>? _playerStateSubscription;
  static bool _isNetworkAvailable = true;
  static bool _wasExternalOutputBeforeInterrupt = false;
  static bool _isInterruptionActive = false;
  static bool _hasAudioFocus = false;
  // Blocks automatic resumes after explicit user pause/stop actions.
  static bool _userPausedOrStoppedPlayback = false;
  static bool _interruptionResumeInProgress = false;
  static int _activeDuckInterruptions = 0;
  static int _volumeFadeGeneration = 0;
  static double _volumeBeforeDuck = 1.0;
  static const double _duckVolumeFactor = 0.25;
  static const Duration _duckFadeDuration = Duration(milliseconds: 250);
  static const Duration _duckPauseEscalationDelay = Duration(seconds: 8);
  static const int _duckFadeSteps = 6;
  static Timer? _duckPauseEscalationTimer;
  static final StreamController<bool> _interruptionActiveController =
      StreamController<bool>.broadcast();

  static bool _isInitialized = false;
  static Future<void>? _initFuture;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isMobile => _isAndroid || _isIOS;

  static DateTime _lastPersistedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _persistInterval = Duration(seconds: 5);
  static const Duration _maxPlaybackRestoreAge = Duration(hours: 24);
  static const Duration autoResumeWindow = Duration(minutes: 30);

  static StreamSubscription<Duration>? _positionSubscription;
  static StreamSubscription<Duration>? _playerRawPositionSubscription;
  static StreamSubscription<Duration?>? _playerRawDurationSubscription;
  static StreamSubscription<bool>? _playerPlayingSubscription;
  static StreamSubscription<ProcessingState>?
  _playerProcessingStateSubscription;
  static StreamSubscription<Duration>? _playerBufferedPositionSubscription;
  static StreamSubscription<int?>? _indexSubscription;
  static StreamSubscription<double>? _volumeSubscription;
  static StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  static StreamSubscription<void>? _becomingNoisySubscription;
  static StreamSubscription<PlayerException>? _errorSubscription;
  static StreamSubscription<AudioOutputRouteState>? _outputDeviceSubscription;
  static StreamSubscription<int?>? _androidAudioSessionIdSubscription;
  static StreamSubscription<ConnectivityEvent>? _connectivitySubscription;
  static Future<void> _sourceMutationTail = Future<void>.value();
  static int _sourceMutationDepth = 0;

  static String? _rateLimitSongId;
  static int _rateLimitRetryCount = 0;
  static bool _rateLimitRetryInProgress = false;
  static bool _offlineCacheRecoveryInProgress = false;
  // Prevents re-entry into _attemptOfflineFallbackForCurrentSong().
  static bool _offlineFallbackAttemptInProgress = false;
  // True while any source-mutating operation (offline switch, quality switch,
  // reload) is in progress. Used to gate skips and defer appendToQueue.
  static bool _isSwitchingSource = false;
  static final StreamController<bool> _sourceSwitchingController =
      StreamController<bool>.broadcast();
  static AudioQuality _selectedAudioQuality = AudioQuality.auto;
  static bool _dataSaverEnabled = false;
  static bool _dolbyEffectEnabled = false;
  static int? _temporaryAutoKbps;
  static const int _adaptiveLowKbps = 96;
  static const int _adaptiveMediumKbps = 160;
  static const int _adaptiveHighKbps = 320;
  static const double _slowNetworkThresholdMbps = 1.0;
  static const double _goodNetworkThresholdMbps = 3.0;
  static const Duration _networkSpeedCacheWindow = Duration(seconds: 90);
  static const Duration _networkSpeedProbeTimeout = Duration(seconds: 8);
  static const int _networkSpeedProbeBytes = 192 * 1024;
  static const String _defaultSpeedProbeUrl =
      'https://speed.cloudflare.com/__down?bytes=200000';
  static double? _cachedNetworkSpeedMbps;
  static DateTime? _lastNetworkSpeedProbeAt;
  static Timer? _autoQualityRecoveryTimer;
  static bool _qualityApplyInProgress = false;
  static bool _isQualitySwitching = false;
  static bool _fallbackSongResolved = false;
  static final StreamController<bool> _qualitySwitchingController =
      StreamController<bool>.broadcast();

  static final Map<String, _StreamUrlCacheEntry> _resolvedUrlCache = {};
  static http.Client? _activeHttpClient;
  static DateTime? _songPlayStartedAt;
  static String? _songPlayStartedId;

  static PlaybackState _playbackState = PlaybackState.idle;
  static final StreamController<PlaybackState> _playbackStateController =
      StreamController<PlaybackState>.broadcast();
  static Stream<PlaybackState> get playbackStateStream =>
      _playbackStateController.stream;
  static PlaybackState get playbackState => _playbackState;

  static void _updatePlaybackState(PlaybackState state) {
    if (_playbackState == state) return;
    _playbackState = state;
    _playbackStateController.add(state);
    StabilityLogger.info('PlaybackState', 'Transitioned to: $state');
  }

  static final StreamController<Song?> _resolvingSongController =
      StreamController<Song?>.broadcast();
  static Stream<Song?> get resolvingSongStream =>
      _resolvingSongController.stream;

  static final StreamController<Duration> _positionStreamController =
      StreamController<Duration>.broadcast();
  static final StreamController<Duration?> _durationStreamController =
      StreamController<Duration?>.broadcast();
  static final StreamController<Duration> _bufferedPositionStreamController =
      StreamController<Duration>.broadcast();
  static Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionStreamController.stream;

  static Timer? _progressTimer;
  static Duration _lastKnownPosition = Duration.zero;

  static Timer? _watchdogTimer;
  static int _frozenCounter = 0;
  static Duration _lastWatchdogPosition = Duration.zero;
  static Duration? _offlineSeekPosition;

  static bool get isPlaying => _player.playing;
  static Duration get position => _player.position;
  static Duration get bufferedPosition => _player.bufferedPosition;
  static Duration? get duration => _player.duration;
  static ProcessingState get processingState => _player.processingState;
  static PlayerState get playerState => _player.playerState;
  static int? get playerCurrentIndex => _player.currentIndex;
  static Stream<SequenceState?> get sequenceStateStream =>
      _player.sequenceStateStream;
  static Stream<int?> get currentIndexStream => _player.currentIndexStream;

  static void _updateProgressTimerState() {
    _progressTimer?.cancel();
    _progressTimer = null;

    final isPlaying = _player.playing;
    final isCompleted = _player.processingState == ProcessingState.completed;
    final isIdle = _player.processingState == ProcessingState.idle;

    if (isPlaying && !isCompleted && !isIdle) {
      _progressTimer = Timer.periodic(const Duration(milliseconds: 40), (
        timer,
      ) {
        _pollProgress();
      });
    }
  }

  static void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  static void _pollProgress() {
    if (_player.audioSource == null) return;

    final pos = _player.position;
    final dur = _player.duration;
    final buf = _player.bufferedPosition;

    if (pos > Duration.zero) {
      _lastKnownPosition = pos;
    }

    final activeTag = _player.sequenceState.currentSource?.tag;
    final String? activeId = activeTag is MediaItem ? activeTag.id : null;
    if (activeId != null &&
        _currentSong != null &&
        activeId != _currentSong!.id) {
      return;
    }

    _positionStreamController.add(pos);
    if (dur != null) {
      _durationStreamController.add(dur);
    }
    _bufferedPositionStreamController.add(buf);

    final now = DateTime.now();
    if (now.difference(_lastPersistedAt) >= _persistInterval &&
        _currentSong != null) {
      _lastPersistedAt = now;
      StabilityLogger.debug('Playback', 'Position update (timer): $pos');
      unawaited(
        OfflineService.recordPlaybackProgress(
          _currentSong!,
          pos,
          duration: dur,
        ),
      );
      _savePlaybackState();
    }
  }

  static void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _runWatchdogCheck();
    });
  }

  static void _runWatchdogCheck() {
    final isPlaying = _player.playing;
    final isConnected = _isNetworkAvailable;
    final currentPos = _player.position;
    final isCompleted = _player.processingState == ProcessingState.completed;
    final isIdle = _player.processingState == ProcessingState.idle;

    if (isPlaying && !isCompleted && !isIdle && _progressTimer == null) {
      debugPrint(
        'Watchdog: Progress timer was null during active playback. Restarting it.',
      );
      _updateProgressTimerState();
    }

    if (isPlaying &&
        isConnected &&
        currentPos == _lastWatchdogPosition &&
        !isCompleted &&
        !isIdle) {
      _frozenCounter++;
      debugPrint(
        'Watchdog: Position has not changed for $_frozenCounter seconds.',
      );
    } else {
      _frozenCounter = 0;
    }

    _lastWatchdogPosition = currentPos;

    if (_frozenCounter >= 3) {
      debugPrint(
        'Watchdog: Playback is frozen (stuck at $currentPos). Triggering recovery.',
      );
      _frozenCounter = 0;
      unawaited(_recoverPlayback());
    }
  }

  static Future<void> _recoverPlayback() async {
    final song = _currentSong;
    if (song == null) return;

    final savePosition = _lastKnownPosition > Duration.zero
        ? _lastKnownPosition
        : _player.position;
    StabilityLogger.info(
      'Playback',
      'Recovering playback for ${song.name} at position $savePosition',
    );

    // 1. Reestablish subscriptions
    _reestablishPlayerSubscriptions();

    // 2. Refresh stream URL
    final String? currentRequestId = PlaybackCoordinator.currentRequestId;
    final resolved = await _resolveSongForPlayback(
      song,
      forceRefresh: true,
      requestId: currentRequestId,
    );

    if (resolved != null) {
      _currentSong = resolved;
      if (_queue.isNotEmpty &&
          _currentIndex >= 0 &&
          _currentIndex < _queue.length) {
        _queue[_currentIndex] = resolved;
      }

      _setSourceSwitching(true);
      try {
        await _replaceCurrentAudioSource(
          updatedSong: resolved,
          index: _currentIndex,
          position: savePosition,
        );
      } finally {
        _setSourceSwitching(false);
      }
    }

    // 3. Seek and play
    await _player.seek(savePosition, index: _currentIndex);
    await _playEnsuringAudioFocus();
    _savePlaybackState();

    _positionStreamController.add(savePosition);
    _playbackStateController.add(
      _player.playing ? PlaybackState.playing : PlaybackState.paused,
    );
  }

  static void _setupPlayerSubscriptions() {
    _cancelPlayerSubscriptions();

    _updateProgressTimerState();

    _playerRawPositionSubscription = _player.positionStream.listen((pos) {
      if (_isSessionStale(null, _currentSong?.id ?? '') ||
          _isSwitchingSource ||
          _isLoadingNewSong ||
          _resolvingSong != null) {
        return;
      }
      _positionStreamController.add(pos);
    });

    _playerRawDurationSubscription = _player.durationStream.listen((dur) {
      if (_isSessionStale(null, _currentSong?.id ?? '') ||
          _isSwitchingSource ||
          _isLoadingNewSong ||
          _resolvingSong != null) {
        return;
      }
      _durationStreamController.add(dur);
    });

    _positionSubscription = _player.positionStream.listen((_) {
      if (!_player.playing || _currentSong == null) return;
      final now = DateTime.now();
      if (now.difference(_lastPersistedAt) >= _persistInterval) {
        _lastPersistedAt = now;
        StabilityLogger.debug(
          'Playback',
          'Position update: ${_player.position}',
        );
        unawaited(
          OfflineService.recordPlaybackProgress(
            _currentSong!,
            _player.position,
            duration: _player.duration,
          ),
        );
        _savePlaybackState();
      }
    });

    _playerPlayingSubscription = _player.playingStream.listen(
      (_) => _updateProgressTimerState(),
    );
    _playerProcessingStateSubscription = _player.processingStateStream.listen(
      (_) => _updateProgressTimerState(),
    );

    _playerBufferedPositionSubscription = _player.bufferedPositionStream.listen(
      (buf) {
        _bufferedPositionStreamController.add(buf);
      },
    );

    _indexSubscription = _player.currentIndexStream.listen((index) {
      if (index == null ||
          _queue.isEmpty ||
          index < 0 ||
          index >= _queue.length) {
        return;
      }
      _currentIndex = index;
      final nextSong = _queue[index];

      _positionStreamController.add(Duration.zero);
      _durationStreamController.add(
        nextSong.duration != null
            ? Duration(seconds: nextSong.duration!)
            : Duration.zero,
      );

      final isSideEffectOfLoading =
          _isLoadingNewSong || _isSwitchingSource || _resolvingSong != null;
      if (!isSideEffectOfLoading) {
        PlaybackCoordinator.newRequest(nextSong);
        final newSessionId = PlaybackCoordinator.currentIdentity!.sessionId;
        _activeLogger = _PlaybackSessionLogger(newSessionId, nextSong.name);
      }

      _currentSong = nextSong;
      _resetRateLimitStateForSong(_currentSong?.id);
      if (!_isSourceMutationInProgress) {
        _triggerAutoplayIfNeeded();
      }
      _savePlaybackState();
      _preloadUpcomingSongs(index);
    });

    _playerStateSubscription = _player.playerStateStream.listen((state) {
      StabilityLogger.info(
        'Playback',
        'PlayerState transition: playing=${state.playing}, processingState=${state.processingState}',
      );
      if (state.processingState == ProcessingState.completed) {
        StabilityLogger.info(
          'Playback',
          'Playback completed for song: ${_currentSong?.name}',
        );
      }

      if (_playbackState != PlaybackState.seeking && _playbackState != PlaybackState.buffering) {
        switch (state.processingState) {
          case ProcessingState.idle:
            _updatePlaybackState(PlaybackState.idle);
            break;
          case ProcessingState.loading:
            _updatePlaybackState(PlaybackState.preparingDecoder);
            break;
          case ProcessingState.buffering:
            _updatePlaybackState(PlaybackState.buffering);
            break;
          case ProcessingState.ready:
            if (state.playing) {
              _updatePlaybackState(PlaybackState.playing);
            } else {
              _updatePlaybackState(PlaybackState.paused);
            }
            break;
          case ProcessingState.completed:
            _updatePlaybackState(PlaybackState.idle);
            break;
        }
      }

      final isPlaying = state.playing;
      if (isPlaying) {
        _userPausedOrStoppedPlayback = false;
        _pausedByNetworkLoss = false;
        _pausedByAudioInterruption = false;
        _pausedByOutputDisconnect = false;
        _pausedByVideoPlayback = false;
      } else {
        if (!_pausedByAudioInterruption &&
            !_pausedByOutputDisconnect &&
            !_pausedByVideoPlayback &&
            !_pausedByNetworkLoss) {
          _userPausedOrStoppedPlayback = true;
        }
      }
      _savePlaybackState();
    });

    _errorSubscription = _player.errorStream.listen((error) {
      if (_isLoadingNewSong) {
        StabilityLogger.debug(
          'Playback',
          'Ignoring player error stream event during song loading: ${error.message}',
        );
        return;
      }
      unawaited(
        _handlePlayerError(error).catchError((Object e, StackTrace st) {
          debugPrint('Player error handler failed: $e');
        }),
      );
    });
  }

  static void _cancelPlayerSubscriptions() {
    _playerRawPositionSubscription?.cancel();
    _playerRawPositionSubscription = null;
    _playerRawDurationSubscription?.cancel();
    _playerRawDurationSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _playerPlayingSubscription?.cancel();
    _playerPlayingSubscription = null;
    _playerProcessingStateSubscription?.cancel();
    _playerProcessingStateSubscription = null;
    _playerBufferedPositionSubscription?.cancel();
    _playerBufferedPositionSubscription = null;
    _indexSubscription?.cancel();
    _indexSubscription = null;
    _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _errorSubscription?.cancel();
    _errorSubscription = null;
  }

  static void _reestablishPlayerSubscriptions() {
    _setupPlayerSubscriptions();
  }

  static Future<void> recoverPlayback() async {
    await _recoverPlayback();
  }

  static Song? _resolvingSong;
  static Song? get resolvingSong => _resolvingSong;

  static _PlaybackSessionLogger? _activeLogger;

  static const int _autoplayPrefetchThreshold = 1;
  static const int _autoplayBatchMin = 10;
  static const int _autoplayBatchMax = 20;
  static const int _autoplayAlbumHistoryLimit = 8;
  static const int _queueHistoryLimit = 12;
  static Timer? _pendingSeekTimer;
  static bool _externalSeeking = false;
  static bool _isSkipping = false; // Re-entrancy guard for skip operations
  static bool _isLoadingNewSong = false; // True during URL resolution in play()
  static String? _lastCompletedSongId;
  static DateTime? _lastCompletedTime;
  static String? _lastErrorSongId;
  static DateTime? _lastErrorTime;
  static DateTime? _lastErrorToastTime;
  static String? _lastErrorToastMsg;
  static final List<String> _recentAutoplayAlbumKeys = <String>[];
  static final List<_QueueSessionSnapshot> _queueHistoryStack =
      <_QueueSessionSnapshot>[];
  static final List<_QueueSessionSnapshot> _forwardQueueStack =
      <_QueueSessionSnapshot>[];

  /// Streams user-visible messages when quality is automatically adjusted.
  static final StreamController<String> _qualityAdjustmentMsgController =
      StreamController<String>.broadcast();
  static Stream<String> get qualityAdjustmentMessageStream =>
      _qualityAdjustmentMsgController.stream;
  static Timer? _networkReEvalTimer;
  static Timer? _networkDropGraceTimer;
  static Timer? _conversationRestoreTimer;
  static const Duration _conversationDoubleVolumeWindow = Duration(seconds: 2);
  static const Duration _conversationPausePatternWindow = Duration(seconds: 60);
  // Smart Conversation Assist (SCA)
  static SmartConversationAssistMode _conversationAssistMode =
      SmartConversationAssistMode.automatic; // Enabled by default
  static double _conversationAssistReductionLevel = 0.3; // 30% volume
  static Duration _conversationAssistAutoRestoreDelay = const Duration(
    seconds: 60,
  );
  static const double _conversationManualVolumeStep = 0.05;
  static bool _conversationAssistIgnoreSingleEarbud = false;
  static bool _conversationModeActive = false;
  static bool _conversationPausePatternLearned = false;
  static double _conversationStoredVolume = 1.0;
  static DateTime? _lastVolumeDownAt;
  static int _volumeDownBurstCount = 0;
  static double _lastObservedPlayerVolume = 1.0;
  static int _conversationManagedVolumeWrites = 0;
  static AudioOutputRouteState _lastConversationOutputState =
      AudioOutputRouteState.phoneSpeaker;
  static final List<_ConversationActionEvent> _conversationActions =
      <_ConversationActionEvent>[];
  static final StreamController<bool> _conversationModeController =
      StreamController<bool>.broadcast();
  static final StreamController<String> _conversationEventMsgController =
      StreamController<String>.broadcast();
  static bool get _isSourceMutationInProgress => _sourceMutationDepth > 0;

  static AudioPlayer get player => _player;
  static Song? get currentSong => _currentSong;
  static List<Song> get queue => _queue;
  static int get currentIndex => _currentIndex;
  static bool get isLoadingNewSong => _isLoadingNewSong;
  static bool get canSkipPrevious {
    if (_currentSong == null) return false;
    // The previous button always works: it either restarts the current
    // track (> 10s) or goes to the previous song (≤ 10s).
    return true;
  }

  static bool get canSkipNext {
    if (_currentSong == null) return false;
    if (_player.hasNext ||
        (_currentIndex >= 0 && _currentIndex < _queue.length - 1)) {
      return true;
    }
    return _forwardQueueStack.isNotEmpty;
  }

  static bool get hasAudioFocus => _hasAudioFocus;
  static bool get conversationModeActive => _conversationModeActive;

  static Stream<Duration> get positionStream =>
      _positionStreamController.stream;
  static Stream<Duration?> get durationStream =>
      _durationStreamController.stream;
  static Stream<bool> get playingStream => _player.playingStream;
  static Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  static LoopMode get loopMode => _player.loopMode;
  static Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  static Future<void> setLoopMode(LoopMode mode) async {
    try {
      await _player.setLoopMode(mode);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playback_loop_mode', mode.name);
      await _savePlaybackState();
    } catch (e) {
      debugPrint('Failed to set loop mode: $e');
    }
  }

  static Future<void> savePlaybackStateOnBackground() async {
    await _savePlaybackState();
  }

  static Stream<bool> get qualitySwitchingStream =>
      _qualitySwitchingController.stream;
  static bool get isQualitySwitching => _isQualitySwitching;
  static Stream<bool> get sourceSwitchingStream =>
      _sourceSwitchingController.stream;
  static bool get isSwitchingSource => _isSwitchingSource;
  static Stream<bool> get conversationModeStream =>
      _conversationModeController.stream;
  static Stream<String> get conversationEventMessageStream =>
      _conversationEventMsgController.stream;

  /// Whether playback is paused due to an audio interruption (e.g. phone call).
  static bool get isInterruptionActive => _isInterruptionActive;
  static Stream<bool> get interruptionActiveStream =>
      _interruptionActiveController.stream;

  /// Ensures [_currentSong] / queue metadata is available for UI surfaces
  /// (e.g. mini player) after lifecycle transitions.
  ///
  /// This does not mutate the active audio source. It only hydrates runtime
  /// metadata from the in-memory queue, active player sequence tags, or
  /// persisted playback session when metadata is missing.
  static Future<bool> syncRuntimeSongStateIfMissing() async {
    await init();
    if (_currentSong != null && _queue.isNotEmpty) return true;

    if (_hydrateRuntimeSongFromQueueSnapshot()) {
      return true;
    }

    if (_hydrateRuntimeSongFromActiveSequence()) {
      return true;
    }

    if (await _hydrateRuntimeSongFromPersistedSession()) {
      return true;
    }

    return false;
  }

  static bool _hydrateRuntimeSongFromQueueSnapshot() {
    if (_queue.isEmpty) return false;

    final playerIndex = _player.currentIndex;
    var effectiveIndex = playerIndex ?? _currentIndex;
    if (effectiveIndex < 0 || effectiveIndex >= _queue.length) {
      effectiveIndex = (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _currentIndex
          : 0;
    }

    _currentIndex = effectiveIndex;
    _currentSong = _queue[effectiveIndex];
    _resetRateLimitStateForSong(_currentSong?.id);
    return true;
  }

  static bool _hydrateRuntimeSongFromActiveSequence() {
    final sequence = _player.sequence;
    if (sequence.isEmpty) return false;

    final derivedQueue = <Song>[];
    for (final source in sequence) {
      final song = _songFromAudioSourceTag(source);
      if (song == null) continue;
      derivedQueue.add(song);
    }
    if (derivedQueue.isEmpty) return false;

    _queue
      ..clear()
      ..addAll(derivedQueue);

    var effectiveIndex = _player.currentIndex ?? _currentIndex;
    if (effectiveIndex < 0 || effectiveIndex >= _queue.length) {
      effectiveIndex = 0;
    }
    _currentIndex = effectiveIndex;
    _currentSong = _queue[effectiveIndex];
    _resetRateLimitStateForSong(_currentSong?.id);
    return true;
  }

  static Song? _songFromAudioSourceTag(IndexedAudioSource source) {
    final tag = source.tag;
    if (tag is! MediaItem) return null;

    final id = tag.id.trim();
    final name = tag.title.trim();
    if (id.isEmpty || name.isEmpty) return null;

    final uri = source is UriAudioSource ? source.uri.toString() : null;

    return Song(
      id: id,
      name: name,
      artist: tag.artist,
      album: tag.album,
      imageUrl: tag.artUri?.toString(),
      streamUrl: uri,
      duration: tag.duration?.inSeconds,
    );
  }

  static Future<bool> _hydrateRuntimeSongFromPersistedSession() async {
    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) return false;

    PlaybackResumeCandidate? candidate;

    final logoutState = await SessionStateService.readLogoutPlaybackState(uid);
    if (logoutState != null) {
      candidate = _toResumeCandidate(
        logoutState,
        autoWindow: _maxPlaybackRestoreAge,
      );
    }

    if (candidate == null) {
      final regularState = await SessionStateService.readPlaybackState(uid);
      if (regularState != null) {
        candidate = _toResumeCandidate(
          regularState,
          autoWindow: _maxPlaybackRestoreAge,
        );
      }
    }

    if (candidate == null) return false;

    final song = candidate.song;
    final existingIndex = _queue.indexWhere((item) => item.id == song.id);
    if (_queue.isEmpty) {
      _queue.add(song);
      _currentIndex = 0;
    } else if (existingIndex >= 0) {
      _currentIndex = existingIndex;
    } else {
      _queue.insert(0, song);
      _currentIndex = 0;
    }

    _currentSong = _queue[_currentIndex.clamp(0, _queue.length - 1)];
    _resetRateLimitStateForSong(_currentSong?.id);
    return true;
  }

  static void _setInterruptionActive(bool active) {
    if (_isInterruptionActive == active) return;
    _isInterruptionActive = active;
    _interruptionActiveController.add(active);
  }

  static Future<bool> _setAudioSessionActive(bool active) async {
    if (!_isMobile) {
      _hasAudioFocus = active;
      return true;
    }
    try {
      final session = await AudioSession.instance;
      final result = await session.setActive(active);
      if (active) {
        _hasAudioFocus = result;
        return result;
      }
      _hasAudioFocus = false;
      return true;
    } catch (e) {
      debugPrint('Audio session active=$active failed: $e');
      if (!active) {
        _hasAudioFocus = false;
        return true;
      }
      _hasAudioFocus = false;
      return false;
    }
  }

  /// Sets up the audio interruption listener.
  ///
  /// If a subscription already exists it is left in place so that events are
  /// never dropped by cancelling a listener from within its own callback.
  /// The subscription uses `cancelOnError: false` and an `onError` handler
  /// to ensure it survives any transient stream errors.
  static Future<void> _setupAudioFocusListener() async {
    if (_interruptionSubscription != null) return;
    if (!_isMobile) return;

    late final AudioSession session;
    try {
      session = await AudioSession.instance;
    } catch (e) {
      debugPrint('Audio session unavailable; skipping focus listener: $e');
      return;
    }
    _interruptionSubscription = session.interruptionEventStream.listen(
      (event) async {
        debugPrint(
          'AudioInterruption: begin=${event.begin}, type=${event.type}',
        );
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              await _handleDuckInterruptionBegin();
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Capture the playing state NOW. On many Android devices
              // just_audio / audio_service auto-pauses the player at the
              // native level *before* this Dart callback fires, so
              // _player.playing may already be false by the time we get
              // here. We therefore also accept the case where the player
              // was recently playing (i.e. currentSong is set and we
              // haven't marked any other pause reason).
              final wasPlaying =
                  _player.playing ||
                  (_currentSong != null &&
                      !_userPausedOrStoppedPlayback &&
                      !_pausedByVideoPlayback &&
                      !_pausedByOutputDisconnect &&
                      !_pausedByAudioInterruption);

              if (wasPlaying && _currentSong != null) {
                await _resetDuckState(restoreVolume: true);
                _wasExternalOutputBeforeInterrupt =
                    ListeningSafetyService.outputDeviceState.isExternal;
                _userPausedOrStoppedPlayback = false;
                _pausedByAudioInterruption = true;
                _pausedByOutputDisconnect = false;
                _hasAudioFocus = false;
                _setInterruptionActive(true);
                // Player may already be paused by the native layer;
                // calling pause() again is safe and idempotent.
                if (_player.playing) {
                  await _player.pause();
                }
                _savePlaybackState();
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              await _handleDuckInterruptionEnd();
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              final outputDisconnectedDuringInterrupt =
                  _wasExternalOutputBeforeInterrupt &&
                  !ListeningSafetyService.outputDeviceState.isExternal;

              final shouldResume =
                  _pausedByAudioInterruption &&
                  !_player.playing &&
                  _currentSong != null &&
                  !_pausedByVideoPlayback &&
                  !_pausedByOutputDisconnect &&
                  !_userPausedOrStoppedPlayback &&
                  !outputDisconnectedDuringInterrupt &&
                  !_interruptionResumeInProgress &&
                  _player.processingState != ProcessingState.completed;
              _pausedByAudioInterruption = false;
              _wasExternalOutputBeforeInterrupt = false;
              _setInterruptionActive(false);
              if (shouldResume) {
                _interruptionResumeInProgress = true;
                try {
                  if (!_player.playing &&
                      _currentSong != null &&
                      !_pausedByVideoPlayback &&
                      !_pausedByOutputDisconnect &&
                      _player.processingState != ProcessingState.completed) {
                    final resumed = await _playEnsuringAudioFocus();
                    if (resumed) {
                      _savePlaybackState();
                    }
                  }
                } finally {
                  _interruptionResumeInProgress = false;
                }
              }
              break;
          }
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('AudioInterruption stream error: $e');
        // Do NOT cancel - keep listening.
      },
      cancelOnError: false,
    );
  }

  /// Requests audio focus and starts playback.
  ///
  /// Forces a deactivate -> reactivate cycle to guarantee the OS re-registers
  /// our audio focus listener. On some Android devices/versions, calling
  /// `setActive(true)` when the session considers itself already active is a
  /// silent no-op that does NOT re-request audio focus from the OS, meaning
  /// subsequent focus-loss events are never delivered.
  ///
  /// The listener subscription is also verified here; if it was somehow lost
  /// (e.g. stream error, dispose/re-init race), it is re-created.
  static Future<bool> _playEnsuringAudioFocus() async {
    if (!_isMobile) {
      await _player.play();
      return true;
    }
    // Ensure interruption listener is alive.
    await _setupAudioFocusListener();

    if (_hasAudioFocus) {
      StabilityLogger.debug(
        'Playback',
        'Already has audio focus, proceeding to play.',
      );
      await _player.play();
      return true;
    }

    // Force a clean focus cycle only if we don't have focus
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {
      // Best-effort; proceed to re-request.
    }
    _hasAudioFocus = false;

    StabilityLogger.info('Playback', 'Requesting audio focus for playback.');
    final focusGranted = await _setAudioSessionActive(true);
    if (!focusGranted) {
      StabilityLogger.warning(
        'Playback',
        'Audio focus denied. Skipping playback start/resume.',
      );
      return false;
    }
    await _player.play();
    return true;
  }

  static Future<void> _fadeToVolume(double target) async {
    final clampedTarget = target.clamp(0.0, 1.0).toDouble();
    final start = _player.volume.clamp(0.0, 1.0).toDouble();
    if ((start - clampedTarget).abs() < 0.01) {
      await _player.setVolume(clampedTarget);
      return;
    }

    final generation = ++_volumeFadeGeneration;
    final stepMs = (_duckFadeDuration.inMilliseconds / _duckFadeSteps)
        .round()
        .clamp(1, 1000)
        .toInt();

    for (var step = 1; step <= _duckFadeSteps; step++) {
      if (generation != _volumeFadeGeneration) return;
      final progress = step / _duckFadeSteps;
      final volume = (start + ((clampedTarget - start) * progress)).clamp(
        0.0,
        1.0,
      );
      await _player.setVolume(volume.toDouble());
      if (step < _duckFadeSteps) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }
  }

  static Future<void> _resetDuckState({bool restoreVolume = false}) async {
    _duckPauseEscalationTimer?.cancel();
    _duckPauseEscalationTimer = null;
    final hadDuck = _activeDuckInterruptions > 0;
    _activeDuckInterruptions = 0;
    _volumeFadeGeneration++;
    final restoreTarget = _volumeBeforeDuck.clamp(0.0, 1.0).toDouble();
    _volumeBeforeDuck = 1.0;

    if (restoreVolume && hadDuck) {
      await _player.setVolume(restoreTarget);
    }
  }

  static Future<void> _handleDuckInterruptionBegin() async {
    if (!_player.playing) return;

    _activeDuckInterruptions += 1;
    if (_activeDuckInterruptions > 1) return;

    _volumeBeforeDuck = _player.volume.clamp(0.0, 1.0).toDouble();
    final target = (_volumeBeforeDuck * _duckVolumeFactor).clamp(0.0, 1.0);
    await _fadeToVolume(target.toDouble());

    if (!_isAndroid ||
        _currentSong == null ||
        _userPausedOrStoppedPlayback ||
        _pausedByVideoPlayback ||
        _pausedByOutputDisconnect ||
        _pausedByAudioInterruption) {
      return;
    }

    _duckPauseEscalationTimer?.cancel();
    _duckPauseEscalationTimer = Timer(_duckPauseEscalationDelay, () async {
      _duckPauseEscalationTimer = null;
      if (_activeDuckInterruptions <= 0 ||
          !_player.playing ||
          _currentSong == null ||
          _userPausedOrStoppedPlayback ||
          _pausedByVideoPlayback ||
          _pausedByOutputDisconnect ||
          _pausedByAudioInterruption) {
        return;
      }

      await _resetDuckState(restoreVolume: true);
      _wasExternalOutputBeforeInterrupt =
          ListeningSafetyService.outputDeviceState.isExternal;
      _userPausedOrStoppedPlayback = false;
      _pausedByAudioInterruption = true;
      _hasAudioFocus = false;
      _setInterruptionActive(true);
      await _player.pause();
      _savePlaybackState();
    });
  }

  static Future<void> _handleDuckInterruptionEnd() async {
    _duckPauseEscalationTimer?.cancel();
    _duckPauseEscalationTimer = null;

    if (_activeDuckInterruptions > 0) {
      _activeDuckInterruptions -= 1;
      if (_activeDuckInterruptions > 0) return;
    }

    final outputDisconnectedDuringInterrupt =
        _wasExternalOutputBeforeInterrupt &&
        !ListeningSafetyService.outputDeviceState.isExternal;
    final shouldResume =
        _pausedByAudioInterruption &&
        !_player.playing &&
        _currentSong != null &&
        !_pausedByVideoPlayback &&
        !_pausedByOutputDisconnect &&
        !_userPausedOrStoppedPlayback &&
        !outputDisconnectedDuringInterrupt &&
        !_interruptionResumeInProgress &&
        _player.processingState != ProcessingState.completed;

    if (_pausedByAudioInterruption) {
      _pausedByAudioInterruption = false;
      _wasExternalOutputBeforeInterrupt = false;
      _setInterruptionActive(false);

      if (shouldResume) {
        _interruptionResumeInProgress = true;
        try {
          final resumed = await _playEnsuringAudioFocus();
          if (resumed) {
            _savePlaybackState();
          }
        } finally {
          _interruptionResumeInProgress = false;
        }
      }
      return;
    }

    final restoreTarget = _volumeBeforeDuck.clamp(0.0, 1.0).toDouble();
    _volumeBeforeDuck = 1.0;
    await _fadeToVolume(restoreTarget);
  }

  static Future<T> _runSerializedSourceMutation<T>(
    Future<T> Function() operation,
  ) {
    if (_sourceMutationDepth > 0) {
      return operation();
    }
    final completer = Completer<T>();

    _sourceMutationTail = _sourceMutationTail.catchError((_) {}).then((
      _,
    ) async {
      _sourceMutationDepth += 1;
      try {
        final result = await operation();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      } finally {
        if (_sourceMutationDepth > 0) {
          _sourceMutationDepth -= 1;
        }
      }
    });

    return completer.future;
  }

  static bool _isLoadingInterruptedError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('loading interrupted') ||
        message.contains('playerinterruptedexception') ||
        message.contains('interrupted by another call');
  }

  /// Initialize the player service and audio sessions.
  static Future<void> init() {
    if (_isInitialized) return Future.value();
    _initFuture ??= _initializeInternal();
    return _initFuture!;
  }

  static Future<void> _initializeInternal() async {
    await BackgroundLearningService.init();
    try {
      final prefs = await SharedPreferences.getInstance();
      _shuffleModeEnabled = prefs.getBool('playback_shuffle_enabled') ?? false;
      _shuffleModeController.add(_shuffleModeEnabled);

      final loopModeName =
          prefs.getString('playback_loop_mode') ?? LoopMode.off.name;
      final savedLoopMode = LoopMode.values.firstWhere(
        (m) => m.name == loopModeName,
        orElse: () => LoopMode.off,
      );
      await _player.setLoopMode(savedLoopMode);
    } catch (e) {
      debugPrint('Failed to load shuffle or loop preference: $e');
    }

    AudioSession? session;
    if (_isMobile) {
      try {
        session = await AudioSession.instance;
        await session.configure(
          const AudioSessionConfiguration.music().copyWith(
            // Let duck events stay as volume reductions for short sounds
            // (notifications, message tones). Only full focus-loss (video
            // players, phone calls) will trigger pause/resume behaviour.
            androidWillPauseWhenDucked: false,
          ),
        );
      } catch (e) {
        debugPrint('Audio session init skipped: $e');
      }
    }
    _lastConversationOutputState = ListeningSafetyService.outputDeviceState;
    if (_isAndroid) {
      try {
        await _player.setAndroidAudioAttributes(
          const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
        );
      } catch (e) {
        debugPrint('Failed to set Android audio attributes: $e');
      }
    }

    _setupPlayerSubscriptions();

    if (_isAndroid) {
      _androidAudioSessionIdSubscription ??= _player.androidAudioSessionIdStream
          .listen((sessionId) {
            unawaited(AudioEffectsService.setAudioSessionId(sessionId));
          });
    }

    await _setupAudioFocusListener();

    if (_isAndroid && session != null) {
      _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen((
        _,
      ) async {
        // Headphone unplug/disconnect: mark output as disconnected even if the
        // player is already paused (e.g. during a phone call) so that the
        // interruption-end handler won't resume through the phone speaker.
        _pausedByOutputDisconnect = true;
        // Remember if music was actively playing before this noisy event paused
        // it. When a new external device connects shortly after (e.g. AirPods),
        // we use this flag to auto-resume instead of staying paused.
        _wasPlayingBeforeNoisyPause = _player.playing && _currentSong != null;
        if (!_player.playing || _currentSong == null) return;
        _userPausedOrStoppedPlayback = false;
        _pausedByAudioInterruption = false;
        await _player.pause();
        _savePlaybackState();
      });
    }

    _outputDeviceSubscription ??= ListeningSafetyService.outputDeviceStream.listen((
      outputState,
    ) async {
      await _handleConversationOutputRouteChange(outputState);

      // Cancel any pending resume from a previous connection event.
      _deviceConnectResumeTimer?.cancel();
      _deviceConnectResumeTimer = null;
      final connected = outputState.isExternal;

      if (!connected) {
        // Mark output disconnect even when already paused so that other
        // resume-handlers (interruption-end, video-end) won't accidentally
        // resume through the phone speaker.
        _pausedByOutputDisconnect = true;
        _wasPlayingBeforeNoisyPause = _player.playing && _currentSong != null;
        // Fallback for devices where becomingNoisy may not fire.
        if (_player.playing && _currentSong != null) {
          _userPausedOrStoppedPlayback = false;
          _pausedByAudioInterruption = false;
          await _player.pause();
          _savePlaybackState();
        }
        return;
      }

      // A new external device just connected. Resume playback if:
      //  - music was paused by a disconnect/noisy event, OR
      //  - music was actively playing before the audio route transition paused it
      final shouldResume =
          (_pausedByOutputDisconnect || _wasPlayingBeforeNoisyPause) &&
          !_player.playing &&
          _currentSong != null &&
          !_userPausedOrStoppedPlayback &&
          !_pausedByAudioInterruption &&
          !_pausedByVideoPlayback &&
          _player.processingState != ProcessingState.completed;

      _pausedByOutputDisconnect = false;

      if (shouldResume) {
        // Wait briefly for the audio route to fully establish before resuming.
        // This prevents audio glitches from playing through a half-connected
        // Bluetooth device.
        _deviceConnectResumeTimer = Timer(
          const Duration(milliseconds: 800),
          () async {
            _deviceConnectResumeTimer = null;
            // Re-check conditions after the delay - the user might have
            // manually interacted during the wait.
            if (_player.playing ||
                _currentSong == null ||
                _userPausedOrStoppedPlayback ||
                _pausedByAudioInterruption ||
                _pausedByVideoPlayback ||
                !ListeningSafetyService.outputDeviceState.isExternal ||
                _player.processingState == ProcessingState.completed) {
              return;
            }
            _wasPlayingBeforeNoisyPause = false;
            final resumed = await _playEnsuringAudioFocus();
            if (resumed) {
              _savePlaybackState();
            }
          },
        );
      } else {
        _wasPlayingBeforeNoisyPause = false;
      }
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onPlaybackCompleted();
      }

      if (state == ProcessingState.buffering && !_isNetworkAvailable) {
        // We've hit the end of our buffer and have no internet.
        // Attempt a seamless switch to a local copy if it exists.
        _attemptOfflineFallbackForCurrentSong();
      }

      // Buffering watchdog: detect stuck buffering state when offline.
      _handleBufferingWatchdog(state);
      // Loading watchdog: detect stuck loading/buffering state for remote streams.
      _handleLoadingWatchdog(state);
    });

    await _syncQualityPreferenceFromStorage();
    _lastObservedPlayerVolume = _player.volume.clamp(0.0, 1.0).toDouble();
    await _syncConversationAssistRuntimeBindings();
    await ConnectivityManager.init();
    _isNetworkAvailable = ConnectivityManager.isConnected;

    _connectivitySubscription ??= ConnectivityManager.eventStream.listen((
      event,
    ) {
      unawaited(_handleConnectivityChange(event));
    });

    _startWatchdog();
    _isInitialized = true;
  }

  static Future<void> _syncQualityPreferenceFromStorage() async {
    final uid = _currentUserUidSafely();
    if (uid == null) {
      _selectedAudioQuality = AudioQuality.auto;
      _dataSaverEnabled = false;
      _dolbyEffectEnabled = false;
      _conversationAssistMode = SmartConversationAssistMode.off;
      _conversationAssistReductionLevel = 0.30;
      _conversationAssistAutoRestoreDelay = const Duration(seconds: 60);
      _conversationAssistIgnoreSingleEarbud = false;
      _temporaryAutoKbps = null;
      _conversationPausePatternLearned = false;
      _conversationActions.clear();
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'preferences_cleared',
      );
      await _syncConversationAssistRuntimeBindings();
      await AudioEffectsService.setDolbyLikeEnabled(false);
      await _refreshResolvedPreferredQuality(applyNow: false, force: true);
      return;
    }

    final prefs = await PreferencesService.getPreferences(uid);
    _selectedAudioQuality = prefs?.audioQuality ?? AudioQuality.auto;
    _dataSaverEnabled = prefs?.dataSaverEnabled ?? false;
    _dolbyEffectEnabled = prefs?.dolbyEffectEnabled ?? false;
    _conversationAssistMode =
        prefs?.smartConversationAssistMode ?? SmartConversationAssistMode.off;
    _conversationAssistReductionLevel =
        (prefs?.conversationAssistReductionPercent ?? 30).clamp(20, 80) / 100.0;
    _conversationAssistAutoRestoreDelay = Duration(
      seconds: (prefs?.conversationAssistAutoRestoreSeconds ?? 60).clamp(
        15,
        300,
      ),
    );
    _conversationAssistIgnoreSingleEarbud =
        prefs?.conversationAssistIgnoreSingleEarbud ?? false;
    if (_conversationAssistMode == SmartConversationAssistMode.off) {
      _conversationPausePatternLearned = false;
      _conversationActions.clear();
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'assist_disabled',
      );
    }
    await _syncConversationAssistRuntimeBindings();
    _temporaryAutoKbps = null;
    await AudioEffectsService.setDolbyLikeEnabled(_dolbyEffectEnabled);
    await _refreshResolvedPreferredQuality(applyNow: false, force: true);
  }

  static Future<void> setAudioQualityPreference(
    AudioQuality quality, {
    bool applyNow = true,
  }) async {
    await init();
    _selectedAudioQuality = quality;
    _temporaryAutoKbps = null;
    await _refreshResolvedPreferredQuality(applyNow: applyNow, force: true);
  }

  static Future<void> setDataSaverEnabled(
    bool enabled, {
    bool applyNow = true,
  }) async {
    await init();
    _dataSaverEnabled = enabled;

    // Clear temporary adaptive downgrade so Auto mode can recalculate using
    // the latest Data Saver + network rules immediately.
    _temporaryAutoKbps = null;

    if (!applyNow) return;
    if (_selectedAudioQuality != AudioQuality.auto) return;

    await _refreshResolvedPreferredQuality(applyNow: true, force: true);
  }

  static Future<void> setDolbyEffectEnabled(
    bool enabled, {
    bool applyNow = true,
  }) async {
    await init();
    _dolbyEffectEnabled = enabled;
    if (!applyNow) return;
    await AudioEffectsService.setDolbyLikeEnabled(enabled);
  }

  static Future<void> setSmartConversationAssistConfig({
    required SmartConversationAssistMode mode,
    required int reductionPercent,
    required int autoRestoreSeconds,
    required bool ignoreSingleEarbud,
  }) async {
    await init();
    _conversationAssistMode = mode;
    _conversationAssistReductionLevel = reductionPercent.clamp(20, 80) / 100.0;
    _conversationAssistAutoRestoreDelay = Duration(
      seconds: autoRestoreSeconds.clamp(15, 300),
    );
    _conversationAssistIgnoreSingleEarbud = ignoreSingleEarbud;
    await _syncConversationAssistRuntimeBindings();

    if (mode == SmartConversationAssistMode.off) {
      _conversationPausePatternLearned = false;
      _conversationActions.clear();
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'assist_disabled',
      );
      return;
    }

    if (!_isConversationContextEligible()) {
      await _deactivateConversationMode(
        restoreVolume: false,
        reason: 'context_unavailable',
      );
    }
  }

  static Future<void> toggleConversationMode() async {
    await init();
    if (_conversationModeActive) {
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'manual_toggle',
      );
      return;
    }
    await _activateConversationMode(
      trigger: 'manual_toggle',
      allowManualOnly: true,
    );
  }

  static bool isConversationContextEligible() {
    return _isConversationContextEligible();
  }

  static Future<void> _syncConversationAssistRuntimeBindings() async {
    if (_conversationAssistMode == SmartConversationAssistMode.off) {
      await _volumeSubscription?.cancel();
      _volumeSubscription = null;
      _lastVolumeDownAt = null;
      _volumeDownBurstCount = 0;
      return;
    }

    _lastObservedPlayerVolume = _player.volume.clamp(0.0, 1.0).toDouble();
    _volumeSubscription ??= _player.volumeStream.listen((volume) {
      _handleConversationVolumeEvent(volume);
    });
  }

  static bool _isConversationContextEligible() {
    if (_conversationAssistMode == SmartConversationAssistMode.off) {
      return false;
    }
    if (!_player.playing) return false;
    if (_currentSong == null) return false;
    if (!ListeningSafetyService.outputDeviceState.isExternal) return false;
    if (!_conversationModeActive && _player.volume <= 0.25) return false;
    return true;
  }

  static bool _isConversationAutomationEnabled() {
    return _conversationAssistMode == SmartConversationAssistMode.automatic;
  }

  static bool _isConversationManualShortcutEnabled() {
    return _conversationAssistMode != SmartConversationAssistMode.off;
  }

  static Future<void> _setPlayerVolumeForConversation(
    double target, {
    bool smooth = true,
  }) async {
    _conversationManagedVolumeWrites += 1;
    try {
      if (smooth) {
        await _fadeToVolume(target);
      } else {
        await _player.setVolume(target.clamp(0.0, 1.0).toDouble());
      }
    } finally {
      if (_conversationManagedVolumeWrites > 0) {
        _conversationManagedVolumeWrites -= 1;
      }
    }
  }

  static void _scheduleConversationAutoRestore() {
    _conversationRestoreTimer?.cancel();
    if (!_conversationModeActive) return;
    _conversationRestoreTimer = Timer(_conversationAssistAutoRestoreDelay, () {
      unawaited(
        _deactivateConversationMode(
          restoreVolume: true,
          reason: 'auto_restore',
        ),
      );
    });
  }

  static Future<void> _activateConversationMode({
    required String trigger,
    bool allowManualOnly = false,
  }) async {
    final manualShortcut = allowManualOnly;
    if (manualShortcut) {
      if (!_isConversationManualShortcutEnabled()) return;
    } else if (!_isConversationAutomationEnabled()) {
      return;
    }
    if (!_isConversationContextEligible()) return;

    final currentVolume = _player.volume.clamp(0.0, 1.0).toDouble();
    if (!_conversationModeActive) {
      _conversationStoredVolume = currentVolume;
      _conversationModeActive = true;
      _conversationModeController.add(true);
      _conversationEventMsgController.add('Conversation mode enabled');
      _qualityAdjustmentMsgController.add('Conversation mode enabled');
    }

    final target =
        (_conversationStoredVolume * _conversationAssistReductionLevel).clamp(
          0.0,
          1.0,
        );
    if (target < currentVolume - 0.01) {
      await _setPlayerVolumeForConversation(target.toDouble(), smooth: true);
    }
    _scheduleConversationAutoRestore();
    debugPrint('Conversation mode trigger: $trigger');
  }

  static Future<void> _deactivateConversationMode({
    required bool restoreVolume,
    required String reason,
  }) async {
    _conversationRestoreTimer?.cancel();
    _conversationRestoreTimer = null;

    if (!_conversationModeActive) return;
    _conversationModeActive = false;
    _conversationModeController.add(false);
    _conversationEventMsgController.add('Conversation mode disabled');
    _qualityAdjustmentMsgController.add('Conversation mode disabled');

    if (restoreVolume) {
      final restoreTarget = _conversationStoredVolume.clamp(0.0, 1.0);
      await _setPlayerVolumeForConversation(
        restoreTarget.toDouble(),
        smooth: true,
      );
    }
    debugPrint('Conversation mode restore reason: $reason');
  }

  static Future<void> _handleConversationOutputRouteChange(
    AudioOutputRouteState outputState,
  ) async {
    final previous = _lastConversationOutputState;
    _lastConversationOutputState = outputState;

    if (_conversationModeActive && !outputState.isExternal) {
      await _deactivateConversationMode(
        restoreVolume: false,
        reason: 'output_disconnected',
      );
      return;
    }

    if (_conversationModeActive &&
        outputState.isHeadphones &&
        !previous.isHeadphones) {
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'headphones_reconnected',
      );
      return;
    }

    if (!_isConversationAutomationEnabled() ||
        _conversationAssistIgnoreSingleEarbud ||
        _conversationModeActive) {
      return;
    }

    // Heuristic for "earbud removed": output moves away from headphones
    // while still external (e.g. to a Bluetooth profile that doesn't report
    // as headphones, or just a route update) or any change that looks like
    // user intent to hear external surroundings.
    final looksLikeEarbudConversationIntent =
        previous.isHeadphones &&
        !outputState.isHeadphones &&
        outputState.isExternal;

    // Additional case: If the device name changed but stayed external,
    // it often means a switch from TWS Stereo to TWS Mono (one bud in case).
    final looksLikeTwsModeShift =
        previous.isExternal &&
        outputState.isExternal &&
        previous.name != outputState.name &&
        previous.isHeadphones;

    if (!looksLikeEarbudConversationIntent && !looksLikeTwsModeShift) return;

    debugPrint(
      'Conversation Trigger: Output Route Change detected (Intent=$looksLikeEarbudConversationIntent, Shift=$looksLikeTwsModeShift)',
    );

    await _activateConversationMode(
      trigger: 'headphone_route_change',
      allowManualOnly: false,
    );
  }

  static void _recordConversationUserAction(_ConversationActionType type) {
    if (!_isConversationAutomationEnabled()) return;

    final now = DateTime.now();
    _conversationActions.add(_ConversationActionEvent(type, now));
    _conversationActions.removeWhere(
      (event) => now.difference(event.at) > _conversationPausePatternWindow,
    );

    if (_conversationActions.length < 3) return;
    final a = _conversationActions[_conversationActions.length - 3];
    final b = _conversationActions[_conversationActions.length - 2];
    final c = _conversationActions[_conversationActions.length - 1];
    if (a.type == _ConversationActionType.pause &&
        b.type == _ConversationActionType.resume &&
        c.type == _ConversationActionType.pause) {
      _conversationPausePatternLearned = true;
      _conversationEventMsgController.add(
        'Smart Conversation Assist learned your pause pattern',
      );
    }
  }

  static bool _shouldConvertManualPauseToConversationMode() {
    if (!_conversationPausePatternLearned) return false;
    if (!_isConversationAutomationEnabled()) return false;
    if (_conversationModeActive) return false;
    return _isConversationContextEligible();
  }

  static void _handleConversationVolumeEvent(double volume) {
    final nextVolume = volume.clamp(0.0, 1.0).toDouble();
    final previousVolume = _lastObservedPlayerVolume;
    _lastObservedPlayerVolume = nextVolume;

    if (_conversationManagedVolumeWrites > 0) return;
    if (_activeDuckInterruptions > 0 || _isInterruptionActive) return;

    if (_conversationModeActive) {
      // User manually increased volume while conversation mode is active.
      final manualIncreaseDetected =
          nextVolume > previousVolume + _conversationManualVolumeStep ||
          nextVolume > (_conversationStoredVolume - 0.01);
      if (manualIncreaseDetected) {
        unawaited(
          _deactivateConversationMode(
            restoreVolume: false,
            reason: 'user_volume_increase',
          ),
        );
      } else {
        _scheduleConversationAutoRestore();
      }
    }

    if (!_isConversationManualShortcutEnabled()) {
      _volumeDownBurstCount = 0;
      _lastVolumeDownAt = null;
      return;
    }
    if (!_isConversationContextEligible()) return;
    if (_conversationModeActive) return;

    final drop = previousVolume - nextVolume;
    if (drop < _conversationManualVolumeStep) return;

    final now = DateTime.now();
    if (_lastVolumeDownAt != null &&
        now.difference(_lastVolumeDownAt!) <= _conversationDoubleVolumeWindow) {
      _volumeDownBurstCount += 1;
    } else {
      _volumeDownBurstCount = 1;
    }
    _lastVolumeDownAt = now;

    if (_volumeDownBurstCount >= 2) {
      _volumeDownBurstCount = 0;
      _lastVolumeDownAt = null;
      unawaited(
        _activateConversationMode(
          trigger: 'double_volume_down',
          allowManualOnly: true,
        ),
      );
    }
  }

  static Future<void> _handleConnectivityChange(ConnectivityEvent event) async {
    final isConnected = event != ConnectivityEvent.disconnected;
    _isNetworkAvailable = isConnected;

    if (!isConnected) {
      _networkReEvalTimer?.cancel();
      _networkDropGraceTimer?.cancel();
      _cachedNetworkSpeedMbps = null;
      _lastNetworkSpeedProbeAt = null;
      // Playback is buffer-first. We do NOT pause playback or trigger offline fallback
      // immediately upon losing network. The player will continue playing already buffered
      // audio. If and when the buffer is exhausted, ExoPlayer transitions to buffering,
      // which will trigger the offline fallback or pause as needed.
      return;
    }

    _networkDropGraceTimer?.cancel();
    _networkDropGraceTimer = null;

    if (event == ConnectivityEvent.restored) {
      unawaited(_runReconnectionSync());

      if (_pausedByNetworkLoss) {
        _pausedByNetworkLoss = false;
        _userPausedOrStoppedPlayback = false;

        // ── Stale Recovery Guard ──
        // If the user tapped a new song while offline, a new request is
        // already resolving. Resuming the OLD song would cause the race
        // condition: old request finishes → plays wrong song.
        // Only resume the paused song if no new request is in flight.
        if (_resolvingSong != null || _isLoadingNewSong) {
          StabilityLogger.info(
            'Playback',
            'Network restored but a new playback request is active. '
                'Skipping stale recovery for previous song.',
          );
          return;
        }

        final current = _currentSong;
        if (current != null && !_isSongUsingLocalSource(current)) {
          final lastPosition = _offlineSeekPosition ?? _player.position;
          _offlineSeekPosition = null; // Clear it after reading

          final String? currentRequestId = PlaybackCoordinator.currentRequestId;
          final resolved = await _resolveSongForPlayback(
            current,
            forceRefresh: true,
            requestId: currentRequestId,
          );

          // Re-check after the async gap: another tap may have occurred
          // while we were resolving the old song's stream.
          if (_resolvingSong != null || _isLoadingNewSong) {
            StabilityLogger.info(
              'Playback',
              'New playback request appeared during recovery resolve. '
                  'Aborting stale recovery.',
            );
            return;
          }

          if (resolved != null) {
            if (currentRequestId != null &&
                !PlaybackCoordinator.isValid(currentRequestId)) {
              return;
            }
            _currentSong = resolved;
            if (_queue.isNotEmpty &&
                _currentIndex >= 0 &&
                _currentIndex < _queue.length) {
              _queue[_currentIndex] = resolved;
            }

            _reestablishPlayerSubscriptions();

            await _replaceCurrentAudioSource(
              updatedSong: resolved,
              index: _currentIndex,
              position: lastPosition,
            );
          }
        }

        await _playEnsuringAudioFocus();
        _qualityAdjustmentMsgController.add(
          'Connection restored. Resuming playback.',
        );
      }
    }

    if (_isSongUsingLocalSource(_activeQueueSong())) {
      _networkReEvalTimer?.cancel();
      return;
    }

    final shouldReevaluateAuto = _selectedAudioQuality == AudioQuality.auto;
    final shouldUpgradeCachedCurrent =
        await _shouldAttemptOnlineUpgradeForCurrentSong();
    if (!shouldReevaluateAuto && !shouldUpgradeCachedCurrent) {
      _networkReEvalTimer?.cancel();
      return;
    }

    _networkReEvalTimer?.cancel();
    _networkReEvalTimer = Timer(const Duration(seconds: 2), () {
      _temporaryAutoKbps = null;
      if (shouldReevaluateAuto) {
        unawaited(
          _refreshResolvedPreferredQuality(
            applyNow: true,
            notifyUser: true,
            force: true,
          ),
        );
        return;
      }
      unawaited(applyPreferredAudioQuality());
    });
  }

  static Future<bool> _shouldAttemptOnlineUpgradeForCurrentSong() async {
    if (!_isNetworkAvailable) return false;
    final song = _activeQueueSong() ?? _currentSong;
    if (song == null) return false;
    if (_isSongUsingLocalSource(song)) return false;

    final currentUrl = (song.streamUrl ?? '').trim();
    final currentStreamBitrate = _extractBitrateFromUrl(currentUrl);
    if (currentUrl.isNotEmpty &&
        !_isLocalFilePath(currentUrl) &&
        currentStreamBitrate != null) {
      final targetBitrate = await _resolvePreferredStreamingKbps();
      return currentStreamBitrate < targetBitrate;
    }

    final cachedBitrate = _resolveCachedOfflineBitrateKbps(song.id);
    if (cachedBitrate == null || cachedBitrate <= 0) return false;

    final targetBitrate = await _resolvePreferredStreamingKbps();
    return targetBitrate > cachedBitrate;
  }

  static Future<void> _refreshResolvedPreferredQuality({
    bool applyNow = false,
    bool force = false,
    bool notifyUser = false,
  }) async {
    if (!_isNetworkAvailable && !force) return;
    final previousKbps = Song.preferredStreamingMaxKbps;
    final resolvedKbps = await _resolvePreferredStreamingKbps();
    if (!force && previousKbps == resolvedKbps) return;

    Song.setPreferredStreamingMaxKbps(resolvedKbps);

    // Set per-song data cap based on the active quality level.
    final resolvedMaxMb = _resolveStreamingTargetMaxMb(resolvedKbps);
    Song.setStreamingTargetMaxMb(resolvedMaxMb);

    // Emit user-visible message when Auto mode switches quality.
    if (notifyUser &&
        _selectedAudioQuality == AudioQuality.auto &&
        previousKbps != resolvedKbps &&
        _currentSong != null) {
      final direction = resolvedKbps > previousKbps ? 'Upgrading' : 'Reducing';
      final targetLabel = _labelForKbps(resolvedKbps);
      _qualityAdjustmentMsgController.add(
        '$direction audio quality to $targetLabel based on network...',
      );
    }

    if (applyNow) {
      await applyPreferredAudioQuality();
    }
  }

  /// Human-readable label for a resolved kbps value.
  static String _labelForKbps(int kbps) {
    if (kbps >= AudioQuality.veryHigh.kbps) return '320 kbps';
    if (kbps >= AudioQuality.high.kbps) return '160 kbps';
    if (kbps >= AudioQuality.normal.kbps) return '96 kbps';
    if (kbps >= AudioQuality.low.kbps) return '64 kbps';
    return '$kbps kbps';
  }

  /// Resolve the per-song data cap (MB) for the given bitrate.
  static double _resolveStreamingTargetMaxMb(int kbps) {
    // Manual quality: use its explicit cap.
    if (_selectedAudioQuality != AudioQuality.auto) {
      return _selectedAudioQuality.maxMb;
    }
    // Auto mode: pick the cap matching the resolved bitrate tier.
    if (kbps >= AudioQuality.veryHigh.kbps) return AudioQuality.veryHigh.maxMb;
    if (kbps >= AudioQuality.high.kbps) return AudioQuality.high.maxMb;
    if (kbps >= AudioQuality.normal.kbps) return AudioQuality.normal.maxMb;
    if (kbps >= AudioQuality.low.kbps) return AudioQuality.low.maxMb;
    return AudioQuality.dataSaver.maxMb;
  }

  static Future<int> _resolvePreferredStreamingKbps() async {
    int resolvedKbps;

    // Manual override: lock to selected bitrate, no auto-switching.
    if (_selectedAudioQuality != AudioQuality.auto) {
      resolvedKbps = _selectedAudioQuality.kbps
          .clamp(1, Song.streamingMaxKbps)
          .toInt();
    } else if (_temporaryAutoKbps != null) {
      resolvedKbps = _temporaryAutoKbps!
          .clamp(1, Song.streamingMaxKbps)
          .toInt();
    } else {
      final connectivity = await Connectivity().checkConnectivity();
      final hasConn = connectivity.any((r) => r != ConnectivityResult.none);
      if (!hasConn) {
        resolvedKbps = _adaptiveLowKbps;
      } else {
        final currentProbeUrl = (_currentSong?.streamUrl ?? '').trim();
        final probeUrl =
            currentProbeUrl.isNotEmpty && !_isLocalFilePath(currentProbeUrl)
            ? currentProbeUrl
            : _defaultSpeedProbeUrl;
        final speedMbps = await _measureNetworkSpeedMbps(
          connectivity: connectivity,
          probeUrl: probeUrl,
        );
        resolvedKbps = _adaptiveBitrateFromSpeed(speedMbps);
        if (_dataSaverEnabled &&
            connectivity.contains(ConnectivityResult.mobile)) {
          resolvedKbps = _adaptiveLowKbps;
        }
      }
    }

    // Apply strict cap if Data Saver is enabled (Normal/96 kbps or lower)
    if (_dataSaverEnabled && resolvedKbps > AudioQuality.normal.kbps) {
      resolvedKbps = AudioQuality.normal.kbps;
    }

    return resolvedKbps.clamp(1, Song.streamingMaxKbps).toInt();
  }

  static int _adaptiveBitrateFromSpeed(double speedMbps) {
    if (speedMbps > _goodNetworkThresholdMbps) return _adaptiveHighKbps;
    if (speedMbps > _slowNetworkThresholdMbps) return _adaptiveMediumKbps;
    return _adaptiveLowKbps;
  }

  static double _fallbackSpeedEstimateMbps(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.ethernet)) return 12.0;
    if (results.contains(ConnectivityResult.wifi)) return 4.0;
    if (results.contains(ConnectivityResult.mobile)) {
      return _dataSaverEnabled ? 0.9 : 1.6;
    }
    return 0.8;
  }

  static Future<double> _measureNetworkSpeedMbps({
    required List<ConnectivityResult> connectivity,
    String? probeUrl,
    bool force = false,
  }) async {
    final now = DateTime.now();
    final sampledAt = _lastNetworkSpeedProbeAt;
    if (!force &&
        _cachedNetworkSpeedMbps != null &&
        sampledAt != null &&
        now.difference(sampledAt) < _networkSpeedCacheWindow) {
      return _cachedNetworkSpeedMbps!;
    }

    if (!connectivity.any((r) => r != ConnectivityResult.none)) {
      _cachedNetworkSpeedMbps = 0.0;
      _lastNetworkSpeedProbeAt = now;
      return 0.0;
    }

    final rawUrl = (probeUrl ?? '').trim();
    final uri = Uri.tryParse(rawUrl);
    final hasValidProbeUri =
        uri != null &&
        (uri.scheme.toLowerCase() == 'http' ||
            uri.scheme.toLowerCase() == 'https');

    if (!hasValidProbeUri) {
      final fallback = _fallbackSpeedEstimateMbps(connectivity);
      _cachedNetworkSpeedMbps = fallback;
      _lastNetworkSpeedProbeAt = now;
      return fallback;
    }

    final client = ApiService.createSecureHttpClient(pinCertificates: false);
    final stopwatch = Stopwatch()..start();
    var receivedBytes = 0;

    try {
      final request = http.Request('GET', uri)
        ..headers['range'] = 'bytes=0-${_networkSpeedProbeBytes - 1}';
      final response = await client
          .send(request)
          .timeout(_networkSpeedProbeTimeout);

      await for (final chunk in response.stream.timeout(
        _networkSpeedProbeTimeout,
      )) {
        receivedBytes += chunk.length;
        if (receivedBytes >= _networkSpeedProbeBytes) {
          break;
        }
      }
    } catch (_) {
      final fallback = _fallbackSpeedEstimateMbps(connectivity);
      _cachedNetworkSpeedMbps = fallback;
      _lastNetworkSpeedProbeAt = now;
      return fallback;
    } finally {
      stopwatch.stop();
      client.close();
    }

    final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
    if (receivedBytes <= 0 || elapsedSeconds <= 0) {
      final fallback = _fallbackSpeedEstimateMbps(connectivity);
      _cachedNetworkSpeedMbps = fallback;
      _lastNetworkSpeedProbeAt = now;
      return fallback;
    }

    final measuredMbps = (receivedBytes * 8) / (elapsedSeconds * 1000 * 1000);
    final normalizedMbps = measuredMbps.clamp(0.1, 200.0).toDouble();
    _cachedNetworkSpeedMbps = normalizedMbps;
    _lastNetworkSpeedProbeAt = now;
    return normalizedMbps;
  }

  static Future<void> _temporarilyDowngradeAutoQuality() async {
    if (_selectedAudioQuality != AudioQuality.auto) return;

    final currentKbps = Song.preferredStreamingMaxKbps.clamp(
      1,
      Song.streamingMaxKbps,
    );
    final degradedKbps = _stepDownAdaptiveKbps(currentKbps);
    if (_temporaryAutoKbps == degradedKbps &&
        Song.preferredStreamingMaxKbps <= degradedKbps) {
      return;
    }

    _temporaryAutoKbps = degradedKbps;
    await _refreshResolvedPreferredQuality(
      applyNow: true,
      force: true,
      notifyUser: true,
    );

    // After 30 seconds, try recovering to the network-appropriate quality.
    _autoQualityRecoveryTimer?.cancel();
    _autoQualityRecoveryTimer = Timer(const Duration(seconds: 30), () {
      _temporaryAutoKbps = null;
      unawaited(
        _refreshResolvedPreferredQuality(
          applyNow: true,
          force: true,
          notifyUser: true,
        ),
      );
    });
  }

  static int _stepDownAdaptiveKbps(int currentKbps) {
    // 320 -> 160
    if (currentKbps > _adaptiveMediumKbps) {
      return _adaptiveMediumKbps;
    }
    // 160 -> 96
    if (currentKbps > _adaptiveLowKbps) {
      return _adaptiveLowKbps;
    }
    return _adaptiveLowKbps;
  }

  static void _setQualitySwitching(bool switching) {
    if (_isQualitySwitching == switching) return;
    _isQualitySwitching = switching;
    _qualitySwitchingController.add(switching);
  }

  static void _setSourceSwitching(bool switching) {
    if (_isSwitchingSource == switching) return;
    _isSwitchingSource = switching;
    _sourceSwitchingController.add(switching);
  }

  static bool _isSessionStale(String? requestId, String songId) {
    if (requestId != null) {
      if (requestId.startsWith('pre-resolve')) {
        // For background pre-resolution, only stale if the song is no longer in the queue
        return !_queue.any((s) => s.id == songId);
      }
      if (!PlaybackCoordinator.isValid(requestId)) {
        return true;
      }
    }
    final identity = PlaybackCoordinator.currentIdentity;
    if (identity != null && songId != identity.songId) {
      return true;
    }
    return false;
  }

  static void _checkSession(String requestId) {
    if (!PlaybackCoordinator.isValid(requestId)) {
      throw PlayerException(0, 'interrupted by another call', _currentIndex);
    }
  }

  static Future<void> play(
    Song song, {
    List<Song>? playlist,
    int? index,
  }) async {
    StabilityLogger.info(
      'Playback',
      'Play requested for song: ${song.name} (ID: ${song.id}). Playback initialization started.',
    );

    // If the same song is actively resolving, ignore the duplicate request
    if (_resolvingSong?.id == song.id) {
      StabilityLogger.debug(
        'Playback',
        'Play request ignored: Song ${song.name} is already resolving.',
      );
      return;
    }

    // If the same song is already the current song
    if (_currentSong?.id == song.id) {
      if (_player.playing) {
        StabilityLogger.debug(
          'Playback',
          'Play request ignored: Song ${song.name} is already playing.',
        );
        return;
      } else {
        StabilityLogger.info(
          'Playback',
          'Play request: Song ${song.name} is paused. Resuming instead of restarting.',
        );
        await resume();
        return;
      }
    }

    _checkAndRecordSkipTelemetry();
    await init();

    _activeHttpClient?.close();
    _activeHttpClient = ApiService.createSecureHttpClient(
      pinCertificates: false,
    );

    _updatePlaybackState(PlaybackState.resolvingSong);
    final String requestId = PlaybackCoordinator.newRequest(song);
    final sessionId = PlaybackCoordinator.currentIdentity!.sessionId;
    _activeLogger = _PlaybackSessionLogger(sessionId, song.name);
    _resolvingSong = song;
    _resolvingSongController.add(song);
    _isLoadingNewSong = true;

    // Reset playback state immediately on play request to prevent previous song's state from leaking
    _positionStreamController.add(Duration.zero);
    _durationStreamController.add(
      song.duration != null ? Duration(seconds: song.duration!) : Duration.zero,
    );

    // Global loading timeout: if the entire play() pipeline doesn't complete
    // within 15 seconds, force-cancel the loading state to prevent infinite
    // "Loading..." in the UI.
    _playLoadingTimeoutTimer?.cancel();
    _playLoadingTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!PlaybackCoordinator.isValid(requestId)) return;
      if (_resolvingSong == null && !_isLoadingNewSong) return;
      StabilityLogger.warning(
        'Playback',
        'Global loading timeout (15s) triggered for: ${song.name}. Force-clearing loading state.',
      );
      _resolvingSong = null;
      _resolvingSongController.add(null);
      _isLoadingNewSong = false;
      _updatePlaybackState(PlaybackState.idle);
      // Try to play if a source was loaded but focus acquisition hung
      if (_player.processingState == ProcessingState.ready &&
          !_player.playing) {
        unawaited(_player.play());
      }
    });

    try {
      try {
        await _player.stop();
      } catch (_) {}

      _checkSession(requestId);
      _fallbackSongResolved = false;
      _updatePlaybackState(PlaybackState.verifyingIdentity);
      final playableSong = await _resolveSongForPlayback(
        song,
        requestId: requestId,
        client: _activeHttpClient,
      );

      _checkSession(requestId);

      // Cancel remaining requests / tasks from this session
      _activeHttpClient?.close();
      _activeHttpClient = null;

      if (playableSong == null) {
        if (PlaybackCoordinator.isValid(requestId)) {
          _resolvingSong = null;
          _resolvingSongController.add(null);
          _isLoadingNewSong = false;
          _activeLogger?.logStep(
            'Playback started',
            false,
            detail: 'Resolution failed',
          );
          _activeLogger?.printReport(
            'FAILED: Toast displayed, queue unchanged',
          );
          _showThrottledToast(
            "Sorry, this song couldn't be played. Please try another version or search for it manually.",
            toastLength: Toast.LENGTH_LONG,
          );
        }
        return;
      }

      _checkSession(requestId);

      StabilityLogger.info(
        'Playback',
        'Source resolved for: ${playableSong.name}. Location: ${_isLocalFilePath(playableSong.streamUrl ?? "") ? "Local file" : "Remote stream URL"}.',
      );
      _activeLogger?.logStep(
        'Source resolved',
        true,
        detail: playableSong.streamUrl,
      );
      _activeLogger?.logStep('Playback started', true);
      _activeLogger?.printReport('SUCCESS');

      _resetRateLimitStateForSong(playableSong.id);
      _userPausedOrStoppedPlayback = false;
      _pausedByAudioInterruption = false;
      _pausedByOutputDisconnect = false;
      _interruptionResumeInProgress = false;
      await _resetDuckState(restoreVolume: true);
      _setInterruptionActive(false);
      _recentAutoplayAlbumKeys
        ..clear()
        ..addAll(
          _albumKey(playableSong.album).isEmpty
              ? const []
              : <String>[_albumKey(playableSong.album)],
        );

      _checkSession(requestId);

      final initialPos = null; // Always start fresh songs at 0:00
      StabilityLogger.info(
        'Playback',
        'Preparing player for: ${playableSong.name}',
      );

      if (playlist != null && playlist.isNotEmpty) {
        _originalQueue = List<Song>.from(playlist);
        List<Song> activePlaylist = List<Song>.from(playlist);
        int? activeIndex = index;

        if (_shuffleModeEnabled) {
          activePlaylist = _smartShuffle(activePlaylist, playableSong);
          activeIndex = 0;
        }

        _checkSession(requestId);

        _updatePlaybackState(PlaybackState.loadingStream);
        await _setQueueSource(
          playableSong,
          playlist: activePlaylist,
          index: activeIndex,
          initialPosition: initialPos,
          rememberCurrentQueueForHistory: true,
          clearForwardHistory: true,
        );
      } else {
        _originalQueue = [playableSong];

        _checkSession(requestId);

        _updatePlaybackState(PlaybackState.loadingStream);
        await _setSingleSource(
          playableSong,
          initialPosition: initialPos,
          rememberCurrentQueueForHistory: true,
          clearForwardHistory: true,
        );
      }

      _checkSession(requestId);

      // Clear the resolving state NOW — the audio source is loaded and ready.
      // This unblocks the UI (position stream, play/pause button) immediately
      // so the user isn't stuck in "Loading..." during audio focus acquisition.
      if (PlaybackCoordinator.isValid(requestId)) {
        _resolvingSong = null;
        _resolvingSongController.add(null);
        _isLoadingNewSong = false;
        _playLoadingTimeoutTimer?.cancel();
        _playLoadingTimeoutTimer = null;
      }

      StabilityLogger.info(
        'Playback',
        'Player preparation completed. Starting playback.',
      );
      final started = await _playEnsuringAudioFocus();

      _checkSession(requestId);

      if (!started) {
        StabilityLogger.warning(
          'Playback',
          'Playback failed to start for song: ${playableSong.name} (audio focus denied).',
        );
        if (PlaybackCoordinator.isValid(requestId)) {
          _userPausedOrStoppedPlayback = true;
          _savePlaybackState(wasPlayingOverride: false);
        }
        return;
      }

      if (PlaybackCoordinator.isValid(requestId)) {
        StabilityLogger.info(
          'Playback',
          'Playback started successfully. Final status: PLAYING.',
        );
        _songPlayStartedAt = DateTime.now();
        _songPlayStartedId = playableSong.id;
        _savePlaybackState();
      }

      unawaited(_triggerAutoplayIfNeeded());

      // Trigger Smart Offline Caching
      OfflineService.autoCache(playableSong);

      // Trigger Auto-download of played songs if option is enabled
      unawaited(() async {
        try {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            final prefs = await PreferencesService.getPreferences(user.uid);
            if (prefs != null && prefs.autoDownloadPlayedSongs) {
              await DownloadService.downloadSong(playableSong);
            }
          }
        } catch (e) {
          debugPrint('Auto-download played song failed: $e');
        }
      }());

      try {
        await ApiService.logActivity('play', {
          'songId': _currentSong?.id,
          'songName': _currentSong?.name,
          'artist': _currentSong?.artist ?? '',
          'totalDuration': _currentSong?.duration,
        });
      } catch (_) {}
    } catch (e) {
      if (PlaybackCoordinator.isValid(requestId)) {
        _resolvingSong = null;
        _resolvingSongController.add(null);
        _isLoadingNewSong = false;
        _playLoadingTimeoutTimer?.cancel();
        _playLoadingTimeoutTimer = null;
        _updatePlaybackState(PlaybackState.idle);
      }
      if (_isLoadingInterruptedError(e)) return;
      debugPrint('Playback error: $e');
      StabilityLogger.error(
        'Playback',
        'Playback failed for: ${song.name}. Initiating recovery flow.',
        e,
      );

      if (e is PlayerException) {
        unawaited(
          _handlePlayerError(e).catchError((Object err, StackTrace st) {
            debugPrint(
              'Player error handler failed during play error recovery: $err',
            );
          }),
        );
      } else {
        unawaited(
          _handlePlayerError(
            PlayerException(0, e.toString(), index ?? _currentIndex),
          ).catchError((Object err, StackTrace st) {
            debugPrint(
              'Player error handler failed during general play error recovery: $err',
            );
          }),
        );
      }
    }
  }

  static Future<void> _handlePlayerError(PlayerException error) async {
    final message = (error.message ?? '').toLowerCase();
    final activeSong = _currentSong;
    if (activeSong == null) return;
    if (message.contains('loading interrupted')) return;

    StabilityLogger.error(
      'Playback',
      'Player error triggered for song: ${activeSong.name} (Error: ${error.message})',
      error,
    );

    // 1. De-duplicate error events
    final songId = activeSong.id;
    final errorKey = '${songId}_${error.message}';
    final now = DateTime.now();
    if (_lastErrorSongId == errorKey &&
        _lastErrorTime != null &&
        now.difference(_lastErrorTime!) < const Duration(seconds: 2)) {
      debugPrint('Duplicate error event ignored: $errorKey');
      return;
    }
    _lastErrorSongId = errorKey;
    _lastErrorTime = now;

    // Cancel any active watchdogs so they don't interrupt our recovery
    _loadingWatchdogTimer?.cancel();
    _loadingWatchdogTimer = null;
    _bufferingWatchdogTimer?.cancel();
    _bufferingWatchdogTimer = null;

    _activeLogger?.logStep(
      'Playback error triggered',
      false,
      detail: error.message,
    );

    // Try recovering from offline cache first (if local downloaded file exists)
    try {
      if (await _tryRecoverFromOfflineCache(activeSong)) {
        StabilityLogger.info(
          'Playback',
          'Successfully recovered playback from offline cache/download for ${activeSong.name}',
        );
        return;
      }
    } catch (e) {
      debugPrint('Error during early offline cache recovery: $e');
    }

    if (message.contains('429')) {
      if (_rateLimitRetryInProgress) return;

      if (_rateLimitRetryCount >= 1) {
        debugPrint(
          'Rate limit exceeded retry limit. Enforcing playback failure.',
        );
        _activeLogger?.logStep('Rate limit retry count exceeded', false);
        _activeLogger?.printReport('FAILED: Toast displayed, queue unchanged');
        _showThrottledToast(
          "Sorry, this song couldn't be played. Please try another version or search for it manually.",
          toastLength: Toast.LENGTH_LONG,
        );
        // Do not skip automatically on failure
        return;
      }

      _rateLimitRetryInProgress = true;
      _rateLimitRetryCount += 1;
      final delaySeconds = _rateLimitRetryCount * 2;
      final shouldAutoPlayAfterRetry = _player.playing;

      debugPrint(
        'Stream returned 429. Retrying ${activeSong.id} in ${delaySeconds}s '
        '(attempt $_rateLimitRetryCount/1).',
      );

      try {
        final lastPosition = _lastKnownPosition > Duration.zero
            ? _lastKnownPosition
            : _player.position;
        await _player.pause(); // Spotify-like: pause, do not stop
        await Future.delayed(Duration(seconds: delaySeconds));

        _fallbackSongResolved = false;
        final refreshedSong = await _resolveSongForPlayback(
          activeSong,
          forceRefresh: true,
        );
        if (refreshedSong == null) {
          _activeLogger?.logStep(
            'Recovery search',
            false,
            detail: 'Resolution failed',
          );
          _activeLogger?.printReport(
            'FAILED: Toast displayed, queue unchanged',
          );
          _showThrottledToast(
            "Sorry, this song couldn't be played. Please try another version or search for it manually.",
            toastLength: Toast.LENGTH_LONG,
          );
          // Do not skip automatically on failure
          return;
        }

        _activeLogger?.logStep('Recovery search', true);

        final retrySong = _buildRetryVariant(
          refreshedSong,
          _rateLimitRetryCount,
        );

        final retryInitialPos =
            lastPosition; // Preserve user's position on error recovery
        await _replaceCurrentAudioSource(
          updatedSong: retrySong,
          index: _currentIndex,
          position: retryInitialPos,
        );

        if (shouldAutoPlayAfterRetry) {
          final resumed = await _playEnsuringAudioFocus();
          if (resumed) {
            _savePlaybackState();
          }
        }
        _activeLogger?.logStep('Playback started after recovery', true);
        _activeLogger?.printReport('SUCCESS (Recovered)');
      } catch (e) {
        debugPrint('429 retry failed: $e');
        _activeLogger?.logStep('Recovery search', false, detail: 'Error: $e');
        _activeLogger?.printReport('FAILED: Toast displayed, queue unchanged');
        _showThrottledToast(
          "Sorry, this song couldn't be played. Please try another version or search for it manually.",
          toastLength: Toast.LENGTH_LONG,
        );
        // Do not skip automatically on failure
      } finally {
        _rateLimitRetryInProgress = false;
      }
      return;
    }

    // Handle expired/forbidden URLs or timeouts
    final isTimeout =
        message.contains('timeout') ||
        message.contains('time out') ||
        error.message?.toLowerCase().contains('timeout') == true;
    final isDecoderError =
        message.contains('decode') ||
        message.contains('codec') ||
        message.contains('decoder') ||
        message.contains('format') ||
        message.contains('extractor') ||
        message.contains('demux');
    final isHttpError =
        message.contains('403') ||
        message.contains('404') ||
        message.contains('410') ||
        message.contains('415') ||
        message.contains('forbidden') ||
        message.contains('unauthorized') ||
        message.contains('expire') ||
        message.contains('unsupported');
    final isSourceError = message.contains('source error') || message.contains('player error');

    if (isHttpError || isDecoderError || isTimeout || (isSourceError && await _isNetworkConnected())) {
      final attempts = _songRecoveryAttempts[activeSong.id] ?? 0;
      if (attempts >= 1) {
        debugPrint(
          'Recovery attempts exceeded limit for song ${activeSong.id}. Enforcing playback failure.',
        );
        _updatePlaybackState(PlaybackState.idle);
        _showThrottledToast(
          "Sorry, this song couldn't be played. Please try another version or search for it manually.",
          toastLength: Toast.LENGTH_LONG,
        );
        return;
      }
      _songRecoveryAttempts[activeSong.id] = attempts + 1;

      debugPrint(
        'Stream failure detected. Triggering Production Recovery Pipeline for ${activeSong.id}...',
      );

      final lastPosition = _lastKnownPosition > Duration.zero
          ? _lastKnownPosition
          : _player.position;

      // Update state to buffering during recovery to freeze metadata display & show progress bar animation
      _updatePlaybackState(PlaybackState.buffering);

      final requestId = PlaybackCoordinator.newRequest(activeSong);

      try {
        await _player.pause();

        final recoveredSong = await SearchCoordinator.recoverSong(
          activeSong,
          sessionId: requestId,
        );

        if (PlaybackCoordinator.isValid(requestId)) {
          if (recoveredSong == null) {
            _updatePlaybackState(PlaybackState.idle);
            _showThrottledToast(
              "Sorry, this song couldn't be played. Please try another version or search for it manually.",
              toastLength: Toast.LENGTH_LONG,
            );
            return;
          }

          await _replaceCurrentAudioSource(
            updatedSong: recoveredSong,
            index: _currentIndex,
            position: lastPosition,
          );

          // Allow normal state tracking to take over
          _playbackState = PlaybackState.idle;

          await _playEnsuringAudioFocus();
          _savePlaybackState();
        }
      } catch (e) {
        debugPrint('Recovery pipeline failed: $e');
        _updatePlaybackState(PlaybackState.idle);
        _showThrottledToast(
          "Sorry, this song couldn't be played. Please try another version or search for it manually.",
          toastLength: Toast.LENGTH_LONG,
        );
      }
      return;
    }

    final connectivityIssue = await _isLikelyConnectivityIssue(message);
    if (connectivityIssue) {
      // Local/offline playback should never be altered by network transitions.
      if (_isSongUsingLocalSource(activeSong)) {
        debugPrint(
          'Ignoring connectivity recovery flow for local source: ${activeSong.id}',
        );
        return;
      }

      await _temporarilyDowngradeAutoQuality();
      await _handleNetworkDropDuringPlayback();
      return;
    }
  }

  static Future<bool> _tryRecoverFromOfflineCache(Song activeSong) async {
    if (_offlineCacheRecoveryInProgress) return false;

    // Check both offline storage systems for a local copy.
    var localPath = OfflineService.getLocalPath(activeSong.id);
    localPath ??= await DownloadService.getLocalPath(activeSong.id);
    if (localPath == null || localPath.isEmpty) return false;

    // Capture playback state before any async operation so our snapshot is
    // fresh when we eventually write to the player.
    final shouldResume =
        _player.playing ||
        (!_userPausedOrStoppedPlayback &&
            !_pausedByAudioInterruption &&
            !_pausedByOutputDisconnect &&
            !_pausedByVideoPlayback);
    final lastPosition = _player.position;
    final localSong = activeSong.copyWith(streamUrl: localPath);

    _offlineCacheRecoveryInProgress = true;
    _setSourceSwitching(true);
    try {
      if (_queue.length > 1) {
        final updatedQueue = _queue
            .map((song) => song.id == localSong.id ? localSong : song)
            .toList(growable: false);
        await _replaceCurrentAudioSource(
          updatedSong: localSong,
          index: _currentIndex,
          position: lastPosition,
          replacementQueue: updatedQueue,
        );
        _queue
          ..clear()
          ..addAll(updatedQueue);
      } else {
        await _setSingleSource(localSong);
      }

      if (lastPosition > Duration.zero) {
        await _player.seek(lastPosition, index: _currentIndex);
      }
      if (shouldResume) {
        await _playEnsuringAudioFocus();
      }
      _savePlaybackState();
      return true;
    } catch (e) {
      debugPrint('Offline cache recovery failed for ${activeSong.id}: $e');
      return false;
    } finally {
      _offlineCacheRecoveryInProgress = false;
      _setSourceSwitching(false);
    }
  }

  static Song _buildRetryVariant(Song song, int attempt) {
    final bitrateCap = switch (attempt) {
      1 => 48,
      2 => 12,
      _ => Song.streamingMaxKbps,
    };

    final optimized = Song.optimizeStreamUrlForData(
      song.streamUrl,
      maxKbps: bitrateCap,
      durationSeconds: song.duration,
    );
    final retryUrl = _appendRetryQueryParam(optimized, attempt);

    return song.copyWith(streamUrl: retryUrl);
  }

  static String? _appendRetryQueryParam(String? url, int attempt) {
    final value = (url ?? '').trim();
    if (value.isEmpty) return url;
    final separator = value.contains('?') ? '&' : '?';
    return '$value${separator}rl_retry=$attempt'
        '&ts=${DateTime.now().millisecondsSinceEpoch}';
  }

  static void _resetRateLimitStateForSong(String? songId) {
    if (songId == null || songId.isEmpty) {
      _rateLimitSongId = null;
      _rateLimitRetryCount = 0;
      _rateLimitRetryInProgress = false;
      _songRecoveryAttempts.clear();
      return;
    }

    if (_rateLimitSongId == songId) return;
    _rateLimitSongId = songId;
    _rateLimitRetryCount = 0;
    _rateLimitRetryInProgress = false;
    _songRecoveryAttempts.remove(songId);
  }

  static Future<void> _setQueueSource(
    Song selectedSong, {
    required List<Song> playlist,
    int? index,
    Duration? initialPosition,
    bool rememberCurrentQueueForHistory = false,
    bool clearForwardHistory = false,
  }) async {
    final playableQueue = <Song>[];
    for (final queuedSong in playlist) {
      final resolved = await _resolveLocalSongCopy(queuedSong);
      if (_hasStreamUrl(resolved)) {
        playableQueue.add(resolved);
      }
    }

    final requestedIndex = _sanitizeIndex(index, playlist.length);
    final insertionIndex = requestedIndex.clamp(0, playableQueue.length);

    final existingPlayableIndex = playableQueue.indexWhere(
      (s) => s.id == selectedSong.id,
    );
    if (existingPlayableIndex >= 0) {
      playableQueue[existingPlayableIndex] = selectedSong;
    } else {
      playableQueue.insert(insertionIndex, selectedSong);
    }

    if (playableQueue.isEmpty) return;

    if (clearForwardHistory) {
      _forwardQueueStack.clear();
    }

    if (rememberCurrentQueueForHistory) {
      _maybePushCurrentQueueSnapshot(nextQueue: playableQueue);
    }

    _queue
      ..clear()
      ..addAll(playableQueue);

    _currentIndex = playableQueue.indexWhere((s) => s.id == selectedSong.id);
    if (_currentIndex < 0) _currentIndex = 0;
    _currentSong = _queue[_currentIndex];

    final resolvedTargets = _resolvePlaybackTargets(_queue);
    final sources = resolvedTargets
        .map((target) => target.audioSource)
        .toList(growable: false);
    await _runSerializedSourceMutation(() async {
      await _player
          .setAudioSources(
            sources,
            initialIndex: _currentIndex,
            initialPosition: initialPosition ?? Duration.zero,
          )
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              throw TimeoutException(
                'Player preparation timed out after 12 seconds',
              );
            },
          );
    });
    // Guarantee start at 0:00 for fresh plays.
    if (initialPosition == null) {
      try {
        await _player.seek(Duration.zero, index: _currentIndex);
      } catch (_) {}
    }
    _updateTrackedPlaybackSourceKeys(resolvedTargets);
  }

  /// Returns the song with a local file path if available, otherwise unchanged.
  static Future<Song> _resolveLocalSongCopy(Song song) async {
    // Already a local file path - nothing to resolve.
    if (_hasStreamUrl(song) &&
        _isLocalFilePath((song.streamUrl ?? '').trim())) {
      return song;
    }

    // Check OfflineService auto-cache.
    final offlinePath = OfflineService.getLocalPath(song.id);
    if (offlinePath != null && offlinePath.isNotEmpty) {
      if (File(offlinePath).existsSync()) {
        return song.copyWith(streamUrl: offlinePath);
      }
    }

    // Check DownloadService manual downloads.
    final downloadPath = await DownloadService.getLocalPath(song.id);
    if (downloadPath != null && downloadPath.isNotEmpty) {
      if (File(downloadPath).existsSync()) {
        return song.copyWith(streamUrl: downloadPath);
      }
    }

    return song;
  }

  static Future<void> _setSingleSource(
    Song song, {
    Duration? initialPosition,
    bool rememberCurrentQueueForHistory = false,
    bool clearForwardHistory = false,
  }) async {
    if (clearForwardHistory) {
      _forwardQueueStack.clear();
    }

    if (rememberCurrentQueueForHistory) {
      _maybePushCurrentQueueSnapshot(nextQueue: <Song>[song]);
    }

    _queue
      ..clear()
      ..add(song);

    _currentSong = song;
    _currentIndex = 0;

    final resolvedTarget = _resolvePlaybackTarget(song);
    await _runSerializedSourceMutation(() async {
      await _player
          .setAudioSource(
            resolvedTarget.audioSource,
            initialPosition: initialPosition ?? Duration.zero,
          )
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              throw TimeoutException(
                'Player preparation timed out after 12 seconds',
              );
            },
          );
    });
    // Guarantee start at 0:00 — belt-and-suspenders guard against
    // just_audio carrying over a residual buffer position.
    if (initialPosition == null) {
      try {
        await _player.seek(Duration.zero);
      } catch (_) {}
    }
    _updateTrackedPlaybackSourceKeys(<_ResolvedPlaybackTarget>[resolvedTarget]);
  }

  static void _maybePushCurrentQueueSnapshot({required List<Song> nextQueue}) {
    if (_queue.isEmpty || _currentSong == null || nextQueue.isEmpty) return;
    if (_sameQueueBySongOrder(_queue, nextQueue)) return;

    final snapshot = _captureCurrentQueueSnapshot();
    if (snapshot == null) return;
    _pushSnapshotToStack(_queueHistoryStack, snapshot);
  }

  static _QueueSessionSnapshot? _captureCurrentQueueSnapshot() {
    if (_queue.isEmpty || _currentSong == null) return null;

    final safeIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _queue.length - 1).toInt();
    final activeSongId = _queue[safeIndex].id.trim();
    if (activeSongId.isEmpty) return null;

    return _QueueSessionSnapshot(
      queue: List<Song>.unmodifiable(_queue),
      currentIndex: safeIndex,
      currentSongId: activeSongId,
      position: _player.position,
    );
  }

  static void _pushSnapshotToStack(
    List<_QueueSessionSnapshot> stack,
    _QueueSessionSnapshot snapshot,
  ) {
    final previous = stack.isNotEmpty ? stack.last : null;
    if (previous != null &&
        previous.currentSongId == snapshot.currentSongId &&
        previous.currentIndex == snapshot.currentIndex &&
        _sameQueueBySongOrder(previous.queue, snapshot.queue)) {
      return;
    }

    stack.add(snapshot);
    if (stack.length > _queueHistoryLimit) {
      stack.removeAt(0);
    }
  }

  static bool _sameQueueBySongOrder(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  static _ResolvedPlaybackTarget _resolvePlaybackTarget(Song song) {
    final declaredStreamUrl = (song.streamUrl ?? '').trim();
    final declaredIsLocal =
        declaredStreamUrl.isNotEmpty && _isLocalFilePath(declaredStreamUrl);

    final isLocal = declaredIsLocal;
    final streamUrl = isLocal
        ? declaredStreamUrl
        : Song.optimizeStreamUrlForData(
            declaredStreamUrl,
            durationSeconds: song.duration,
          );

    if (streamUrl == null || streamUrl.trim().isEmpty) {
      throw StateError('Missing stream URL for song ${song.id}');
    }

    Uri? resolvedArtUri;
    try {
      final localDir = DownloadService.resolvedDownloadsDirPath;
      if (localDir != null && localDir.isNotEmpty) {
        final songArtFile = File('$localDir/songs/${song.id}/artwork.jpg');
        if (songArtFile.existsSync()) {
          resolvedArtUri = Uri.file(songArtFile.path);
        } else {
          final legacyArtFile = File('$localDir/${song.id}.jpg');
          if (legacyArtFile.existsSync()) {
            resolvedArtUri = Uri.file(legacyArtFile.path);
          } else if (song.albumId != null && song.albumId!.isNotEmpty) {
            final albumArtFile = File('$localDir/albums/${song.albumId}.jpg');
            if (albumArtFile.existsSync()) {
              resolvedArtUri = Uri.file(albumArtFile.path);
            }
          }
        }
      }
    } catch (_) {}

    if (resolvedArtUri == null &&
        song.imageUrl != null &&
        song.imageUrl!.isNotEmpty) {
      resolvedArtUri = Uri.parse(song.imageUrl!);
    }

    final sourceKey = isLocal ? 'file:$streamUrl' : streamUrl.trim();
    return _ResolvedPlaybackTarget(
      sourceKey: sourceKey,
      audioSource: AudioSource.uri(
        isLocal ? Uri.file(streamUrl) : Uri.parse(streamUrl),
        tag: MediaItem(
          id: song.id,
          album: song.album ?? 'Unknown Album',
          title: song.name,
          artist: song.artist ?? 'Unknown Artist',
          artUri: resolvedArtUri,
          duration: song.duration != null && song.duration! > 0
              ? Duration(seconds: song.duration!)
              : null,
        ),
      ),
    );
  }

  static List<_ResolvedPlaybackTarget> _resolvePlaybackTargets(
    Iterable<Song> songs,
  ) => songs.map(_resolvePlaybackTarget).toList(growable: false);

  static void _updateTrackedPlaybackSourceKeys(
    Iterable<_ResolvedPlaybackTarget> targets,
  ) {
    _queuePlaybackSourceKeys
      ..clear()
      ..addAll(targets.map((target) => target.sourceKey));
  }

  static String _activeLoadedPlaybackSourceKey() {
    final activeIndex = _player.currentIndex ?? _currentIndex;
    if (activeIndex < 0 || activeIndex >= _queuePlaybackSourceKeys.length) {
      return '';
    }
    return _queuePlaybackSourceKeys[activeIndex].trim();
  }

  /// Returns true when [path] looks like a local filesystem path rather than
  /// an HTTP/HTTPS URL.
  static bool _isLocalFilePath(String path) {
    if (path.startsWith('/') || path.startsWith('file://')) return true;
    // Windows-style absolute paths (e.g. C:\...  or D:\...)
    if (path.length >= 3 && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
      return true;
    }
    return false;
  }

  static int _sanitizeIndex(int? index, int length) {
    if (index == null || index < 0 || index >= length) return 0;
    return index;
  }

  static bool _hasStreamUrl(Song song) {
    return (song.streamUrl ?? '').trim().isNotEmpty;
  }

  static int? _resolveCachedOfflineBitrateKbps(String songId) {
    final bitrate = OfflineService.getCachedBitrateKbps(songId);
    if (bitrate == null || bitrate <= 0) return null;
    return bitrate;
  }

  static Future<Song?> fetchSongDetailsForPlaybackWithClientPublic(
    Song song,
    http.Client client,
  ) => _fetchSongDetailsForPlaybackWithClient(song, client);

  static Future<Song?> _resolveSongForPlayback(
    Song song, {
    bool forceRefresh = false,
    String? requestId,
    http.Client? client,
  }) async {
    if (_isSessionStale(requestId, song.id)) return null;

    final songId = song.id.trim();
    if (songId.isNotEmpty) {
      final isDownloadedDb = await DownloadService.isSongDownloadedInDb(songId);
      if (isDownloadedDb) {
        final downloadPath = await DownloadService.getLocalPath(songId);
        if (downloadPath != null && downloadPath.isNotEmpty) {
          StabilityLogger.info(
            'Playback',
            'Playback priority: playing manual download for $songId from $downloadPath',
          );
          return song.copyWith(streamUrl: downloadPath);
        } else {
          // Local file is missing! Check if streaming fallback is allowed.
          final isOfflineMode = ConnectivityManager.isOffline;
          final uid = _currentUserUidSafely();
          bool allowStreamingFallback = true;
          if (uid != null) {
            final prefs = await PreferencesService.getPreferences(uid);
            if (prefs != null) {
              allowStreamingFallback = prefs.allowStreamingFallback;
            }
          }
          if (isOfflineMode || !allowStreamingFallback) {
            StabilityLogger.warning(
              'Playback',
              'Downloaded file for $songId is missing and streaming fallback is not allowed or app is offline. Aborting playback.',
            );
            return null;
          }
          StabilityLogger.info(
            'Playback',
            'Downloaded file for $songId is missing. Falling back to online streaming.',
          );
        }
      } else {
        final offlinePath = OfflineService.getLocalPath(songId);
        if (offlinePath != null && offlinePath.isNotEmpty) {
          StabilityLogger.info(
            'Playback',
            'Playback priority: playing offline cache for $songId from $offlinePath',
          );
          return song.copyWith(streamUrl: offlinePath);
        }
      }
    }

    final localClient =
        client ?? ApiService.createSecureHttpClient(pinCertificates: false);
    try {
      var candidateSong = _optimizeRemoteStreamForCurrentQuality(song);
      final existingStreamUrl = (candidateSong.streamUrl ?? '').trim();
      final hasNetwork = await _isNetworkConnected();

      if (_isSessionStale(requestId, song.id)) return null;

      final explicitLocalPath = _isLocalFilePath(existingStreamUrl)
          ? existingStreamUrl
          : null;

      final localPath = explicitLocalPath;

      final hasLocalCopy = localPath != null && localPath.isNotEmpty;
      if (PlaybackCoordinator.isValid(requestId)) {
        _activeLogger?.logStep(
          'Offline cache',
          hasLocalCopy,
          detail: hasLocalCopy ? 'HIT: $localPath' : 'MISS',
        );
      }

      if (localPath != null && localPath.isNotEmpty) {
        if (!hasNetwork) {
          return candidateSong.copyWith(streamUrl: localPath);
        }

        if (explicitLocalPath != null) {
          return candidateSong.copyWith(streamUrl: localPath);
        }

        final targetBitrate = await _resolvePreferredStreamingKbps();
        if (_isSessionStale(requestId, song.id)) return null;

        final cachedBitrate =
            _resolveCachedOfflineBitrateKbps(songId) ??
            _extractBitrateFromUrl(existingStreamUrl) ??
            0;
        if (cachedBitrate >= targetBitrate && cachedBitrate > 0) {
          return candidateSong.copyWith(streamUrl: localPath);
        }

        try {
          final resolvedSong = await _fetchSongDetailsForPlaybackWithClient(
            candidateSong,
            localClient,
            forceRefresh: forceRefresh,
          );
          if (_isSessionStale(requestId, song.id)) return null;

          if (resolvedSong != null && _hasStreamUrl(resolvedSong)) {
            return _mergeSongWithResolvedStream(
              base: candidateSong,
              resolved: resolvedSong,
            );
          }
        } catch (e) {
          debugPrint('Error upgrading cached song quality for playback: $e');
        }

        return candidateSong.copyWith(streamUrl: localPath);
      }

      // Check memory Stream URL Cache first if not forcing refresh
      if (!forceRefresh && songId.isNotEmpty) {
        final cachedSong = _getCachedSongUrl(songId);
        final hasCache = cachedSong != null && _hasStreamUrl(cachedSong);
        if (PlaybackCoordinator.isValid(requestId)) {
          _activeLogger?.logStep(
            'Memory URL cache',
            hasCache,
            detail: hasCache ? 'HIT' : 'MISS',
          );
        }
        if (cachedSong != null && _hasStreamUrl(cachedSong)) {
          if (_isSessionStale(requestId, song.id)) return null;
          // Validate it fast
          final isValid = await _validateStreamUrl(
            cachedSong.streamUrl!,
            localClient,
          );
          if (_isSessionStale(requestId, song.id)) return null;

          if (PlaybackCoordinator.isValid(requestId)) {
            _activeLogger?.logStep(
              'Memory URL validation',
              isValid,
              detail: isValid ? 'SUCCESS' : 'FAILED',
            );
          }

          if (isValid) {
            debugPrint('Using cached validated stream URL for $songId.');
            return _mergeSongWithResolvedStream(
              base: candidateSong,
              resolved: cachedSong,
            );
          } else {
            debugPrint(
              'Cached stream URL for $songId was expired/invalid. Purging from cache.',
            );
            _resolvedUrlCache.remove(songId);
          }
        }
      }

      if (!forceRefresh &&
          _hasStreamUrl(candidateSong) &&
          !_shouldUpgradeStreamQuality(candidateSong)) {
        if (_isSessionStale(requestId, song.id)) return null;
        final isValid = await _validateStreamUrl(
          candidateSong.streamUrl!,
          localClient,
        );
        if (_isSessionStale(requestId, song.id)) return null;

        if (PlaybackCoordinator.isValid(requestId)) {
          _activeLogger?.logStep(
            'Existing URL validation',
            isValid,
            detail: isValid ? 'SUCCESS' : 'FAILED',
          );
        }

        if (isValid) {
          return candidateSong;
        }
      }

      // Skip resolution if offline; we can't upgrade or fetch details anyway.
      if (!hasNetwork) {
        if (_hasStreamUrl(candidateSong)) return candidateSong;
        final fallback = await SearchCoordinator.recoverSong(
          candidateSong,
          sessionId: requestId,
        );
        if (fallback != null) {
          return _mergeSongWithResolvedStream(
            base: candidateSong,
            resolved: fallback,
          );
        }
        return null;
      }

      Song? resolvedSong;
      try {
        resolvedSong = await _fetchSongDetailsForPlaybackWithClient(
          candidateSong,
          localClient,
          forceRefresh: forceRefresh,
        );
      } catch (e) {
        debugPrint('Error fetching song details for playback: $e.');
      }

      if (PlaybackCoordinator.isValid(requestId)) {
        _activeLogger?.logStep(
          'Main API resolve',
          resolvedSong != null,
          detail: resolvedSong != null ? 'SUCCESS' : 'FAILED',
        );
      }

      if (_isSessionStale(requestId, song.id)) return null;

      if (resolvedSong == null || !_hasStreamUrl(resolvedSong)) {
        debugPrint(
          'Song URL failed to fetch. Retrying 1 time immediately with 10 microseconds delay...',
        );
        await Future.delayed(const Duration(microseconds: 10));
        if (_isSessionStale(requestId, song.id)) return null;

        try {
          resolvedSong = await _fetchSongDetailsForPlaybackWithClient(
            candidateSong,
            localClient,
            forceRefresh: forceRefresh,
          );
        } catch (e2) {
          debugPrint('Retry fetching song details failed: $e2');
        }
      }

      if (_isSessionStale(requestId, song.id)) return null;

      if (resolvedSong != null && _hasStreamUrl(resolvedSong)) {
        final confidence = VerificationEngine.calculateConfidence(
          resolvedSong,
          song,
        );
        final isVerified = confidence >= VerificationEngine.threshold;

        if (PlaybackCoordinator.isValid(requestId)) {
          _activeLogger?.logStep(
            'Verification Engine',
            isVerified,
            detail: 'Score: $confidence%',
          );
        }

        if (isVerified) {
          final newUrl = (resolvedSong.streamUrl ?? '').trim();
          final isValid = await _validateStreamUrl(newUrl, localClient);
          if (_isSessionStale(requestId, song.id)) return null;

          if (PlaybackCoordinator.isValid(requestId)) {
            _activeLogger?.logStep(
              'URL validation',
              isValid,
              detail: isValid ? 'SUCCESS' : 'FAILED',
            );
          }

          if (isValid) {
            if (forceRefresh &&
                newUrl.isNotEmpty &&
                newUrl == existingStreamUrl) {
              debugPrint(
                'Resolved stream URL is identical to failed URL. Triggering search fallback...',
              );
              final fallback = await SearchCoordinator.recoverSong(
                candidateSong,
                sessionId: requestId,
              );
              if (fallback != null) {
                return _mergeSongWithResolvedStream(
                  base: candidateSong,
                  resolved: fallback,
                );
              }
            }

            _setCachedSongUrl(candidateSong, newUrl);
            return _mergeSongWithResolvedStream(
              base: candidateSong,
              resolved: resolvedSong,
            );
          }
        } else {
          debugPrint(
            'Resolved song failed verification (confidence: $confidence%). Rejecting candidate.',
          );
        }
      }

      // Fallbacks if resolution ultimately failed, returned invalid URL, or failed verification
      if (_hasStreamUrl(candidateSong)) {
        final confidence = VerificationEngine.calculateConfidence(
          candidateSong,
          song,
        );
        if (confidence >= VerificationEngine.threshold) {
          final isValid = await _validateStreamUrl(
            candidateSong.streamUrl!,
            localClient,
          );
          if (_isSessionStale(requestId, song.id)) return null;

          if (isValid) {
            if (forceRefresh) {
              final fallback = await SearchCoordinator.recoverSong(
                candidateSong,
                sessionId: requestId,
              );
              if (fallback != null) {
                return _mergeSongWithResolvedStream(
                  base: candidateSong,
                  resolved: fallback,
                );
              }
            }
            return candidateSong;
          }
        }
      }

      final fallback = await SearchCoordinator.recoverSong(
        candidateSong,
        sessionId: requestId,
      );
      if (fallback != null) {
        return _mergeSongWithResolvedStream(
          base: candidateSong,
          resolved: fallback,
        );
      }

      return null;
    } finally {
      if (client == null) {
        localClient.close();
      }
    }
  }

  static Song _optimizeRemoteStreamForCurrentQuality(Song song) {
    final streamUrl = (song.streamUrl ?? '').trim();
    if (streamUrl.isEmpty || _isLocalFilePath(streamUrl)) return song;

    final optimizedUrl = Song.optimizeStreamUrlForData(
      streamUrl,
      durationSeconds: song.duration,
    );
    final normalizedOptimized = (optimizedUrl ?? '').trim();
    if (normalizedOptimized.isEmpty || normalizedOptimized == streamUrl) {
      return song;
    }

    return song.copyWith(streamUrl: normalizedOptimized);
  }

  static bool _shouldUpgradeStreamQuality(Song song) {
    final localPath = OfflineService.getLocalPath(song.id);
    if (localPath != null && localPath.isNotEmpty) return false;

    final streamBitrate = _extractBitrateFromUrl(song.streamUrl);
    if (streamBitrate == null) return false;
    return streamBitrate < Song.preferredStreamingMaxKbps;
  }

  static int? _extractBitrateFromUrl(String? url) {
    final value = (url ?? '').trim();
    if (value.isEmpty) return null;

    // Robust regex to find bitrates like _320, /320/, 320.mp4, or _320_v4.
    // Matches the same pattern as Song.optimizeStreamUrlForData.
    final match = RegExp(r'([/_])(\d{2,3})(?=[_/\.]|$)').firstMatch(value);

    return int.tryParse(match?.group(2) ?? '');
  }

  static Song _mergeSongWithResolvedStream({
    required Song base,
    required Song resolved,
  }) {
    return base.copyWith(
      id: base.id.trim().isNotEmpty ? base.id : resolved.id,
      name: base.name.trim().isNotEmpty ? base.name : resolved.name,
      album: (base.album ?? '').trim().isNotEmpty ? base.album : resolved.album,
      albumId: (base.albumId ?? '').trim().isNotEmpty
          ? base.albumId
          : resolved.albumId,
      sourceAlbumId: (base.sourceAlbumId ?? '').trim().isNotEmpty
          ? base.sourceAlbumId
          : resolved.sourceAlbumId,
      sourceAlbumName: (base.sourceAlbumName ?? '').trim().isNotEmpty
          ? base.sourceAlbumName
          : resolved.sourceAlbumName,
      sourceAlbumArtist: (base.sourceAlbumArtist ?? '').trim().isNotEmpty
          ? base.sourceAlbumArtist
          : resolved.sourceAlbumArtist,
      sourceAlbumImageUrl: (base.sourceAlbumImageUrl ?? '').trim().isNotEmpty
          ? base.sourceAlbumImageUrl
          : resolved.sourceAlbumImageUrl,
      artist: (base.artist ?? '').trim().isNotEmpty
          ? base.artist
          : resolved.artist,
      imageUrl: (base.imageUrl ?? '').trim().isNotEmpty
          ? base.imageUrl
          : resolved.imageUrl,
      streamUrl: resolved.streamUrl ?? base.streamUrl,
      language: (base.language ?? '').trim().isNotEmpty
          ? base.language
          : resolved.language,
      duration: base.duration ?? resolved.duration,
      recommendationScore:
          base.recommendationScore ?? resolved.recommendationScore,
    );
  }

  /// Pause playback (user-initiated).
  ///
  /// Like Spotify, we do **not** abandon the audio session on pause. This
  /// keeps the media notification controls alive, allows instant resume
  /// without re-negotiating audio focus with the OS, and ensures the
  /// interruption listener stays active for subsequent events.
  static Future<void> pause() async {
    await init();
    if (_playbackState == PlaybackState.buffering) {
      PlaybackCoordinator.reset();
      _activeHttpClient?.close();
      _activeHttpClient = null;
      _resolvingSong = null;
      _resolvingSongController.add(null);
      _isLoadingNewSong = false;
    }
    if (_shouldConvertManualPauseToConversationMode()) {
      _recordConversationUserAction(_ConversationActionType.pause);
      await _activateConversationMode(
        trigger: 'pause_pattern',
        allowManualOnly: false,
      );
      _userPausedOrStoppedPlayback = false;
      _savePlaybackState();
      return;
    }

    if (_conversationModeActive) {
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'manual_pause',
      );
    }
    _userPausedOrStoppedPlayback = true;
    _pausedByAudioInterruption = false;
    _pausedByOutputDisconnect = false;
    _pausedByVideoPlayback = false;
    _interruptionResumeInProgress = false;
    _wasPlayingBeforeNoisyPause = false;
    _deviceConnectResumeTimer?.cancel();
    _deviceConnectResumeTimer = null;
    await _resetDuckState(restoreVolume: true);
    _setInterruptionActive(false);
    StabilityLogger.info('Playback', 'Playback paused by user.');
    await _player.pause();
    // NOTE: We intentionally do NOT call _setAudioSessionActive(false) here.
    // Keeping the session active mirrors Spotify behavior: resume is instant,
    // the notification stays, and the OS keeps delivering focus events.
    _recordConversationUserAction(_ConversationActionType.pause);
    _savePlaybackState();
  }

  /// Resume playback (user-initiated).
  ///
  /// Clears all blocking flags first to ensure a clean slate, then re-requests
  /// audio focus and starts playback. Because we keep the audio session alive
  /// on pause, this is nearly instant - just like Spotify.
  ///
  /// If the player source is in an error or idle state (e.g. stream died from
  /// a network drop), we re-resolve the source (offline cache or fresh stream)
  /// before attempting to play, preventing a silent no-op.
  static Future<void> resume() async {
    await init();
    final wasPausedByNetworkLoss = _pausedByNetworkLoss;
    // If the user explicitly resumes, clear any stuck "call" interruption states.
    if (_isInterruptionActive) {
      debugPrint(
        'User manually resumed during an active interruption. Clearing interruption state.',
      );
    }

    // Clear every blocking flag up front so stale state from a previous
    // interruption / disconnect / video pause can never prevent resume.
    _userPausedOrStoppedPlayback = false;
    _pausedByAudioInterruption = false;
    _pausedByOutputDisconnect = false;
    _pausedByVideoPlayback = false;
    _interruptionResumeInProgress = false;
    _wasPlayingBeforeNoisyPause = false;
    _deviceConnectResumeTimer?.cancel();
    _deviceConnectResumeTimer = null;
    _setInterruptionActive(false);
    await _resetDuckState(restoreVolume: true);

    // If the player's source is dead (error / idle after network loss),
    // re-resolve the audio source before trying to play.
    final activeSong = _activeQueueSong() ?? _currentSong;
    final needsSourceReload =
        _player.processingState == ProcessingState.idle ||
        (_player.processingState == ProcessingState.loading &&
            !_isNetworkAvailable) ||
        (_player.processingState == ProcessingState.buffering &&
            !_isNetworkAvailable) ||
        (wasPausedByNetworkLoss &&
            activeSong != null &&
            !_isSongUsingLocalSource(activeSong));
    if (needsSourceReload && _currentSong != null) {
      debugPrint(
        'Player source is dead (state=${_player.processingState}). '
        'Re-resolving source for ${_currentSong!.id}...',
      );
      final recovered = await _reloadSourceForCurrentSong();
      if (!recovered) {
        _userPausedOrStoppedPlayback = true;
        _savePlaybackState(wasPlayingOverride: false);
        _qualityAdjustmentMsgController.add(
          'Connect to the internet to play this song.',
        );
        _showThrottledToast('Connect to the internet to play this song.');
        return;
      }
    }

    final resumed = await _playEnsuringAudioFocus();
    if (!resumed) {
      _userPausedOrStoppedPlayback = true;
      _savePlaybackState(wasPlayingOverride: false);
      return;
    }
    StabilityLogger.info('Playback', 'Playback resumed by coordinator.');
    _pausedByNetworkLoss = false;
    _recordConversationUserAction(_ConversationActionType.resume);
    _savePlaybackState();
  }

  /// Sync song playback with short-form/background video playback.
  ///
  /// Use a stable [sourceId] per video player instance and call:
  /// - `isPlaying: true` when video starts
  /// - `isPlaying: false` when video stops/disposes
  ///
  /// The song resumes only if this service paused it for video playback.
  static Future<void> setVideoPlaybackState({
    required bool isPlaying,
    String sourceId = 'default_video',
  }) async {
    await init();

    final normalizedSourceId = sourceId.trim().isEmpty
        ? 'default_video'
        : sourceId.trim();

    if (isPlaying) {
      _activeVideoSources.add(normalizedSourceId);
      if (_player.playing) {
        await _resetDuckState(restoreVolume: true);
        _userPausedOrStoppedPlayback = false;
        _pausedByVideoPlayback = true;
        await _player.pause();
        _savePlaybackState();
      }
      return;
    }

    _activeVideoSources.remove(normalizedSourceId);
    if (_activeVideoSources.isNotEmpty) return;

    final shouldResume =
        _pausedByVideoPlayback &&
        !_player.playing &&
        _currentSong != null &&
        !_userPausedOrStoppedPlayback &&
        !_pausedByAudioInterruption &&
        !_pausedByOutputDisconnect &&
        _player.processingState != ProcessingState.completed;

    _pausedByVideoPlayback = false;
    if (shouldResume) {
      final resumed = await _playEnsuringAudioFocus();
      if (resumed) {
        _savePlaybackState();
      }
    }
  }

  /// Whether the player was actively playing before a drag-seek started.
  static bool _wasPlayingBeforeSeek = false;

  /// Mark start of a user seek gesture.
  /// Playback is intentionally not paused so backward seeks stay smooth.
  static void beginSeekGesture() {
    _pendingSeekTimer?.cancel();
    _externalSeeking = true;
    _wasPlayingBeforeSeek = _player.playing;
    _updatePlaybackState(PlaybackState.seeking);
  }

  /// Mark end of a user seek gesture and preserve pre-seek play state.
  static Future<void> endSeekGesture() async {
    _externalSeeking = false;
    if (_wasPlayingBeforeSeek &&
        !_player.playing &&
        _currentSong != null &&
        !_userPausedOrStoppedPlayback &&
        !_pausedByAudioInterruption &&
        !_pausedByOutputDisconnect &&
        !_pausedByVideoPlayback &&
        (!_pausedByNetworkLoss || _isNetworkAvailable) &&
        _player.processingState != ProcessingState.completed) {
      if (_pausedByNetworkLoss && _isNetworkAvailable) {
        _pausedByNetworkLoss = false;
      }
      await _playEnsuringAudioFocus();
    }
    _wasPlayingBeforeSeek = false;

    // Restore state based on processingState
    final state = _player.playerState;
    switch (state.processingState) {
      case ProcessingState.idle:
        _updatePlaybackState(PlaybackState.idle);
        break;
      case ProcessingState.loading:
        _updatePlaybackState(PlaybackState.preparingDecoder);
        break;
      case ProcessingState.buffering:
        _updatePlaybackState(PlaybackState.buffering);
        break;
      case ProcessingState.ready:
        if (state.playing) {
          _updatePlaybackState(PlaybackState.playing);
        } else {
          _updatePlaybackState(PlaybackState.paused);
        }
        break;
      case ProcessingState.completed:
        _updatePlaybackState(PlaybackState.idle);
        break;
    }
    _savePlaybackState();
  }

  static Future<void> seek(Duration position, {bool immediate = false}) async {
    await init();
    if (_isLoadingNewSong ||
        _player.processingState == ProcessingState.loading) {
      return;
    }
    final normalized = position < Duration.zero ? Duration.zero : position;

    // Buffer-first offline seek restriction: remote tracks cannot seek past buffered data offline.
    final activeSong = _currentSong;
    if (activeSong != null &&
        !_isSongUsingLocalSource(activeSong) &&
        !_isNetworkAvailable) {
      final buffered = _player.bufferedPosition;
      if (normalized > buffered) {
        _offlineSeekPosition = normalized; // Store intended position
        _showThrottledToast(
          "This part of the song hasn't been buffered yet. Reconnect to continue.",
          toastLength: Toast.LENGTH_LONG,
        );
        return;
      }
    }

    // Cancel any previous pending seek: only the latest drag position matters.
    _pendingSeekTimer?.cancel();

    Future<void> applySeek() async {
      try {
        final wasPlaying = _player.playing;
        await _player
            .seek(normalized, index: _currentIndex)
            .timeout(const Duration(seconds: 4));
        if (_externalSeeking &&
            _wasPlayingBeforeSeek &&
            !_player.playing &&
            wasPlaying &&
            _currentSong != null) {
          await _playEnsuringAudioFocus();
        }
        _lastPersistedAt = DateTime.now();
        _savePlaybackState();
      } catch (e) {
        debugPrint('Seek error: $e');
      }
    }

    if (immediate) {
      await applySeek();
      return;
    }

    _pendingSeekTimer = Timer(const Duration(milliseconds: 70), () {
      unawaited(applySeek());
    });
  }

  static Future<void> togglePlayPause() async {
    if (_playbackState == PlaybackState.buffering) {
      StabilityLogger.info(
        'Playback',
        'Play/Pause toggled while recovering. Cancelling recovery.',
      );
      _userPausedOrStoppedPlayback = true;
      PlaybackCoordinator.reset();
      _activeHttpClient?.close();
      _activeHttpClient = null;
      _resolvingSong = null;
      _resolvingSongController.add(null);
      _isLoadingNewSong = false;
      _updatePlaybackState(PlaybackState.paused);
      try {
        await _player.pause();
      } catch (_) {}
      return;
    }
    if (_isLoadingNewSong) {
      StabilityLogger.info(
        'Playback',
        'Play/Pause toggled while loading. Cancelling loading.',
      );
      _userPausedOrStoppedPlayback = true;
      PlaybackCoordinator.reset();
      _activeHttpClient?.close();
      _activeHttpClient = null;
      _resolvingSong = null;
      _resolvingSongController.add(null);
      _isLoadingNewSong = false;
      try {
        await _player.stop();
      } catch (_) {}
      return;
    }
    if (_player.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  static Future<void> skipNext() async {
    await init();
    // Drop re-entrant taps and taps while a new song is still resolving or
    // a source switch (offline ↔ online) is in progress.
    if (_isSkipping || _isLoadingNewSong || _isSwitchingSource) return;
    _isSkipping = true;
    try {
      try {
        if (_currentSong != null) {
          unawaited(
            ApiService.logActivity('skip', {
              'songId': _currentSong!.id,
              'songName': _currentSong!.name,
              'artist': _currentSong!.artist ?? '',
              'skipTime': _player.position.inSeconds,
              'totalDuration': _currentSong!.duration,
            }),
          );
        }
      } catch (_) {}
      _pausedByNetworkLoss = false;
      await _advanceQueue(isUserTriggered: true);
    } finally {
      _isSkipping = false;
    }
  }

  static Future<void> _advanceQueue({required bool isUserTriggered}) async {
    _checkAndRecordSkipTelemetry();
    final wasPlaying =
        _player.playing ||
        (!_userPausedOrStoppedPlayback &&
            !_pausedByAudioInterruption &&
            !_pausedByOutputDisconnect &&
            !_pausedByVideoPlayback &&
            _currentSong != null);

    // If there is next item in sequence/queue
    if (_currentIndex < _queue.length - 1) {
      if (!_isNetworkAvailable) {
        await _advanceQueueOffline(wasPlaying);
      } else {
        // Online: advance natively using superSeekToNext
        if (_player.hasNext) {
          await _player.superSeekToNext();
          try {
            await _player.seek(Duration.zero);
          } catch (_) {}
        } else {
          // Fallback if sequence is out of sync
          _currentIndex += 1;
          _currentSong = _queue[_currentIndex];
          final resolved = await _resolveSongForPlayback(_currentSong!);
          if (resolved != null) {
            await _setSingleSource(resolved);
            if (wasPlaying) {
              await _playEnsuringAudioFocus();
            }
          }
        }
        _savePlaybackState();
      }
      return;
    }

    // End of queue: try forward history restoration first (user-triggered Next only)
    if (isUserTriggered &&
        await _restoreForwardQueueFromHistory(resumePlayback: wasPlaying)) {
      return;
    }

    // End of queue: Autoplay Radio (append similar songs)
    final autoplayEnabled = await _isAutoplayEnabled();
    if (autoplayEnabled) {
      await _fetchAndAppendAutoplaySongs(
        minCount: _autoplayBatchMin,
        forceOfflineOnly: !_isNetworkAvailable,
      );

      // If new songs were successfully appended, advance to the first appended song
      if (_currentIndex < _queue.length - 1) {
        if (!_isNetworkAvailable) {
          await _advanceQueueOffline(wasPlaying);
        } else {
          if (_player.hasNext) {
            await _player.superSeekToNext();
            try {
              await _player.seek(Duration.zero);
            } catch (_) {}
          } else {
            _currentIndex += 1;
            _currentSong = _queue[_currentIndex];
            final resolved = await _resolveSongForPlayback(_currentSong!);
            if (resolved != null) {
              await _setSingleSource(resolved);
              if (wasPlaying) {
                await _playEnsuringAudioFocus();
              }
            }
          }
          _savePlaybackState();
        }
        return;
      }
    }

    // No progression possible: stop at end of queue
    await _stopAtQueueEndAfterSkipNext();
  }

  static Future<void> skipPrevious() async {
    _checkAndRecordSkipTelemetry();
    await init();
    // Drop re-entrant taps and taps while a new song is still resolving or
    // a source switch (offline ↔ online) is in progress.
    if (_isSkipping || _isLoadingNewSong || _isSwitchingSource) return;
    _isSkipping = true;
    try {
      try {
        if (_currentSong != null) {
          unawaited(
            ApiService.logActivity('skip', {
              'songId': _currentSong!.id,
              'songName': _currentSong!.name,
              'artist': _currentSong!.artist ?? '',
              'skipTime': _player.position.inSeconds,
              'totalDuration': _currentSong!.duration,
            }),
          );
        }
      } catch (_) {}
      _pausedByNetworkLoss = false;
      final wasPlaying =
          _player.playing ||
          (!_userPausedOrStoppedPlayback &&
              !_pausedByAudioInterruption &&
              !_pausedByOutputDisconnect &&
              !_pausedByVideoPlayback &&
              _currentSong != null);
      if (_player.position > const Duration(seconds: 10)) {
        // Restart current track — if source is dead, reload it.
        final activeSong = _activeQueueSong() ?? _currentSong;
        if (!_isNetworkAvailable &&
            activeSong != null &&
            !_isSongUsingLocalSource(activeSong)) {
          await _handleNetworkDropDuringPlayback();
          _savePlaybackState();
          return;
        }
        if (_player.processingState == ProcessingState.idle) {
          await _reloadSourceForCurrentSong();
        }
        await _player.seek(Duration.zero);
      } else {
        // Play previous song from 0:00 (<= 10 seconds)
        if (_player.hasPrevious) {
          if (!_isNetworkAvailable) {
            final previousReady = await _prepareOfflineSourceForQueueIndex(
              _currentIndex - 1,
            );
            if (!previousReady) {
              _qualityAdjustmentMsgController.add(
                'Previous track is not downloaded.',
              );
              await _handleNetworkDropDuringPlayback();
              _savePlaybackState();
              return;
            }
          }
          await _player.superSeekToPrevious();
          try {
            await _player.seek(Duration.zero);
          } catch (_) {}
        } else if (await _restorePreviousQueueFromHistory(
          resumePlayback: false, // Don't resume saved position, play from 0:00
        )) {
          try {
            await _player.seek(Duration.zero);
          } catch (_) {}
        } else {
          // If there is no previous track, restart current track.
          final activeSong = _activeQueueSong() ?? _currentSong;
          if (!_isNetworkAvailable &&
              activeSong != null &&
              !_isSongUsingLocalSource(activeSong)) {
            await _handleNetworkDropDuringPlayback();
            _savePlaybackState();
            return;
          }
          if (_player.processingState == ProcessingState.idle) {
            await _reloadSourceForCurrentSong();
          }
          await _player.seek(Duration.zero);
        }
      }
      if (wasPlaying && !_player.playing && !_userPausedOrStoppedPlayback) {
        await _playEnsuringAudioFocus();
      }
      _savePlaybackState();
    } finally {
      _isSkipping = false;
    }
  }

  static Future<bool> _restorePreviousQueueFromHistory({
    required bool resumePlayback,
  }) async {
    while (_queueHistoryStack.isNotEmpty) {
      final snapshot = _queueHistoryStack.removeLast();
      if (snapshot.queue.isEmpty) continue;

      final restoredQueue = <Song>[];
      Song? selectedSong;

      for (final snapshotSong in snapshot.queue) {
        final resolved = await _resolveLocalSongCopy(snapshotSong);
        if (!_hasStreamUrl(resolved)) continue;
        restoredQueue.add(resolved);
        if (selectedSong == null && resolved.id == snapshot.currentSongId) {
          selectedSong = resolved;
        }
      }

      if (restoredQueue.isEmpty) {
        continue;
      }

      selectedSong ??=
          restoredQueue[snapshot.currentIndex.clamp(
            0,
            restoredQueue.length - 1,
          )];
      final selectedIndex = restoredQueue.indexWhere(
        (song) => song.id == selectedSong!.id,
      );
      final initialPosition = Duration.zero;
      final currentSnapshot = _captureCurrentQueueSnapshot();

      try {
        await _setQueueSource(
          selectedSong,
          playlist: restoredQueue,
          index: selectedIndex < 0 ? 0 : selectedIndex,
          initialPosition: initialPosition,
        );

        if (currentSnapshot != null) {
          _pushSnapshotToStack(_forwardQueueStack, currentSnapshot);
        }
        if (resumePlayback) {
          _userPausedOrStoppedPlayback = false;
          await _playEnsuringAudioFocus();
        }
        _savePlaybackState(wasPlayingOverride: resumePlayback ? null : false);
        return true;
      } catch (e) {
        if (_isLoadingInterruptedError(e)) {
          continue;
        }
        debugPrint('Previous queue restore failed: $e');
      }
    }
    return false;
  }

  static Future<bool> _restoreForwardQueueFromHistory({
    required bool resumePlayback,
  }) async {
    while (_forwardQueueStack.isNotEmpty) {
      final snapshot = _forwardQueueStack.removeLast();
      if (snapshot.queue.isEmpty) continue;

      final restoredQueue = <Song>[];
      Song? selectedSong;

      for (final snapshotSong in snapshot.queue) {
        final resolved = await _resolveLocalSongCopy(snapshotSong);
        if (!_hasStreamUrl(resolved)) continue;
        restoredQueue.add(resolved);
        if (selectedSong == null && resolved.id == snapshot.currentSongId) {
          selectedSong = resolved;
        }
      }

      if (restoredQueue.isEmpty) {
        continue;
      }

      selectedSong ??=
          restoredQueue[snapshot.currentIndex.clamp(
            0,
            restoredQueue.length - 1,
          )];
      final selectedIndex = restoredQueue.indexWhere(
        (song) => song.id == selectedSong!.id,
      );
      final initialPosition = Duration.zero;
      final currentSnapshot = _captureCurrentQueueSnapshot();

      try {
        await _setQueueSource(
          selectedSong,
          playlist: restoredQueue,
          index: selectedIndex < 0 ? 0 : selectedIndex,
          initialPosition: initialPosition,
        );

        if (currentSnapshot != null) {
          _pushSnapshotToStack(_queueHistoryStack, currentSnapshot);
        }
        if (resumePlayback) {
          _userPausedOrStoppedPlayback = false;
          await _playEnsuringAudioFocus();
        }
        _savePlaybackState(wasPlayingOverride: resumePlayback ? null : false);
        return true;
      } catch (e) {
        if (_isLoadingInterruptedError(e)) {
          continue;
        }
        debugPrint('Forward queue restore failed: $e');
      }
    }
    return false;
  }

  static Future<void> _stopAtQueueEndAfterSkipNext() async {
    _userPausedOrStoppedPlayback = true;
    _pausedByAudioInterruption = false;
    _pausedByOutputDisconnect = false;
    _pausedByVideoPlayback = false;
    _interruptionResumeInProgress = false;
    _wasPlayingBeforeNoisyPause = false;
    _deviceConnectResumeTimer?.cancel();
    _deviceConnectResumeTimer = null;
    await _resetDuckState(restoreVolume: true);
    _setInterruptionActive(false);

    final endPosition = _player.duration;
    if (endPosition != null && endPosition > Duration.zero) {
      await _player.seek(endPosition);
    }
    await _player.pause();
  }

  static Future<void> applyPreferredAudioQuality() async {
    await init();
    if (_qualityApplyInProgress) return;

    // Never switch quality while offline.
    if (!_isNetworkAvailable) return;

    _qualityApplyInProgress = true;

    try {
      if (_queue.isEmpty || _currentSong == null) return;
      final safeIndex = _currentIndex < 0
          ? 0
          : _currentIndex.clamp(0, _queue.length - 1).toInt();
      final activeSong = _queue[safeIndex];
      if (_isSongUsingLocalSource(activeSong)) return;
      final resolvedSong = await _resolveSongForPlayback(activeSong);
      final nextSong = resolvedSong ?? activeSong;
      if (!_hasStreamUrl(nextSong)) return;

      final currentSourceKey = _activeLoadedPlaybackSourceKey();
      final nextSourceKey = _playbackSourceKey(nextSong);
      if (currentSourceKey.isNotEmpty && currentSourceKey == nextSourceKey) {
        return;
      }

      _setQualitySwitching(true);
      _setSourceSwitching(true);
      final wasPlaying = _player.playing;
      final currentPosition = _player.position;
      final indexBeforeSwitch = _player.currentIndex ?? _currentIndex;
      final processingStateBeforeSwitch = _player.playerState.processingState;
      final shouldPauseBeforeSwitch =
          wasPlaying ||
          processingStateBeforeSwitch == ProcessingState.buffering ||
          processingStateBeforeSwitch == ProcessingState.loading;
      final replacementQueue = List<Song>.from(_queue);
      replacementQueue[safeIndex] = nextSong;
      var sourceReplaced = false;

      try {
        if (shouldPauseBeforeSwitch) {
          await _player.pause();
        }

        await _replaceCurrentAudioSource(
          updatedSong: nextSong,
          index: safeIndex,
          position: currentPosition,
          replacementQueue: replacementQueue,
        );
        sourceReplaced = true;
        _queue
          ..clear()
          ..addAll(replacementQueue);
        _currentIndex = safeIndex;
        _currentSong = nextSong;
        _resetRateLimitStateForSong(nextSong.id);

        final indexAfterSwitch = _player.currentIndex ?? _currentIndex;
        debugPrint(
          'Quality switch index: before=$indexBeforeSwitch after=$indexAfterSwitch',
        );

        if (wasPlaying && !_player.playing) {
          await _playEnsuringAudioFocus();
        }
        _savePlaybackState();

        final activeUrl = (nextSong.streamUrl ?? '').trim();
        if (activeUrl.isNotEmpty && !_isLocalFilePath(activeUrl)) {
          // Keep offline cache upgraded when we successfully switch to
          // higher-quality streaming.
          unawaited(OfflineService.autoCache(nextSong, force: true));
        }
      } catch (e) {
        if (!sourceReplaced) {
          _currentIndex = safeIndex;
          _currentSong = activeSong;
          try {
            await _replaceCurrentAudioSource(
              updatedSong: activeSong,
              index: safeIndex,
              position: currentPosition,
              replacementQueue: List<Song>.from(_queue),
            );
          } catch (restoreError) {
            debugPrint(
              'Failed to restore source after quality switch error: $restoreError',
            );
          }
        }

        if (wasPlaying && !_player.playing && _currentSong != null) {
          await _playEnsuringAudioFocus();
        }
        if (_isLoadingInterruptedError(e)) return;
        debugPrint('Failed to apply preferred audio quality: $e');
      }
    } finally {
      _setQualitySwitching(false);
      _setSourceSwitching(false);
      _qualityApplyInProgress = false;
    }
  }

  static void _showThrottledToast(
    String msg, {
    Toast toastLength = Toast.LENGTH_LONG,
  }) {
    final now = DateTime.now();
    if (_lastErrorToastMsg == msg &&
        _lastErrorToastTime != null &&
        now.difference(_lastErrorToastTime!) < const Duration(seconds: 5)) {
      return;
    }
    _lastErrorToastMsg = msg;
    _lastErrorToastTime = now;
    Fluttertoast.showToast(msg: msg, toastLength: toastLength);
  }

  static Song? _activeQueueSong() {
    if (_queue.isEmpty) return null;
    final safeIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _queue.length - 1).toInt();
    if (safeIndex < 0 || safeIndex >= _queue.length) return null;
    return _queue[safeIndex];
  }

  static bool _isSongUsingLocalSource(Song? song) {
    if (song == null) return false;
    final streamUrl = (song.streamUrl ?? '').trim();
    return streamUrl.isNotEmpty && _isLocalFilePath(streamUrl);
  }

  static String _playbackSourceKey(Song song) {
    try {
      return _resolvePlaybackTarget(song).sourceKey;
    } on StateError {
      return '';
    }
  }

  static Future<void> _replaceCurrentAudioSource({
    required Song updatedSong,
    required int index,
    required Duration position,
    List<Song>? replacementQueue,
  }) async {
    final queueForRebuild = List<Song>.from(replacementQueue ?? _queue);
    final normalizedIndex = queueForRebuild.isEmpty
        ? 0
        : index.clamp(0, queueForRebuild.length - 1).toInt();
    if (queueForRebuild.isNotEmpty) {
      queueForRebuild[normalizedIndex] = updatedSong;
    }
    if (replacementQueue == null) {
      if (normalizedIndex < _queue.length) {
        _queue[normalizedIndex] = updatedSong;
      }
    } else {
      _queue
        ..clear()
        ..addAll(queueForRebuild);
    }

    final origIdx = _originalQueue.indexWhere((s) => s.id == updatedSong.id);
    if (origIdx != -1) {
      _originalQueue[origIdx] = updatedSong;
    }

    final resolvedTargets = _resolvePlaybackTargets(queueForRebuild);
    final rebuiltSources = resolvedTargets
        .map((target) => target.audioSource)
        .toList(growable: false);

    if (_queue.length > 1) {
      await _runSerializedSourceMutation(() async {
        final activeIndex = _player.currentIndex ?? _currentIndex;
        if (activeIndex == normalizedIndex && _player.audioSource != null) {
          final replacementSource =
              resolvedTargets[normalizedIndex].audioSource;
          await _player.insertAudioSource(normalizedIndex, replacementSource);
          try {
            await _player
                .seek(position, index: normalizedIndex)
                .timeout(const Duration(seconds: 4));
            // Wait for player to be ready before returning, so `play()` works correctly.
            await _player.processingStateStream
                .firstWhere(
                  (state) =>
                      state == ProcessingState.ready ||
                      state == ProcessingState.idle,
                )
                .timeout(const Duration(seconds: 4));
          } catch (e) {
            debugPrint('Replace Source Seek Error: $e');
          }
          await _player.removeAudioSourceAt(normalizedIndex + 1);
          return;
        }

        await _player.setAudioSources(
          rebuiltSources,
          initialIndex: normalizedIndex,
          initialPosition: position,
        );
      });
      _updateTrackedPlaybackSourceKeys(resolvedTargets);
      return;
    }

    // If it's a single-song queue, we just set the audio source directly.
    if (_queue.length == 1) {
      await _runSerializedSourceMutation(() async {
        final replacementSource = resolvedTargets[normalizedIndex].audioSource;
        await _player.insertAudioSource(0, replacementSource);
        try {
          await _player
              .seek(position, index: 0)
              .timeout(const Duration(seconds: 4));
          // Wait for player to be ready before returning, so `play()` works correctly.
          await _player.processingStateStream
              .firstWhere(
                (state) =>
                    state == ProcessingState.ready ||
                    state == ProcessingState.idle,
              )
              .timeout(const Duration(seconds: 4));
        } catch (e) {
          debugPrint('Replace Single Source Seek Error: $e');
        }
        await _player.removeAudioSourceAt(1);
      });
      _updateTrackedPlaybackSourceKeys(resolvedTargets);
      return;
    }

    await _runSerializedSourceMutation(() async {
      await _player.setAudioSources(
        rebuiltSources,
        initialIndex: normalizedIndex,
        initialPosition: position,
      );
    });
    _updateTrackedPlaybackSourceKeys(resolvedTargets);
  }

  static Future<void> stop() async {
    await init();
    if (_playbackState == PlaybackState.buffering) {
      PlaybackCoordinator.reset();
      _activeHttpClient?.close();
      _activeHttpClient = null;
      _resolvingSong = null;
      _resolvingSongController.add(null);
      _isLoadingNewSong = false;
    }
    if (_conversationModeActive) {
      await _deactivateConversationMode(
        restoreVolume: true,
        reason: 'manual_stop',
      );
    }
    _userPausedOrStoppedPlayback = true;
    await _resetDuckState(restoreVolume: true);
    await _player.stop();
    await _setAudioSessionActive(false);
    _resetRuntimePlaybackState();
    await _clearPlaybackState();
  }

  static Future<void> persistAndStopForLogout() async {
    await init();

    final uid = _currentUserUidSafely();
    final hadSong = _currentSong != null;
    final wasPlaying = _player.playing;
    if (hadSong && uid != null && uid.isNotEmpty) {
      await _savePlaybackState(wasPlayingOverride: wasPlaying);
      final state = _buildPlaybackState(wasPlayingOverride: wasPlaying);
      if (state != null) {
        state['loggedOutAt'] = DateTime.now().millisecondsSinceEpoch;
        await SessionStateService.saveLogoutPlaybackState(
          uid: uid,
          state: state,
        );
      }
    }

    try {
      await _resetDuckState(restoreVolume: true);
      await _player.stop();
      await _setAudioSessionActive(false);
    } catch (e) {
      debugPrint('Failed to stop player during logout: $e');
    }

    _resetRuntimePlaybackState();
  }

  static Future<PlaybackResumeCandidate?> getPendingPlaybackResumeCandidate({
    Duration autoWindow = autoResumeWindow,
  }) async {
    await init();
    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) return null;

    // First check logout-specific state.
    final logoutState = await SessionStateService.readLogoutPlaybackState(uid);
    if (logoutState != null) {
      final candidate = _toResumeCandidate(logoutState, autoWindow: autoWindow);
      if (candidate != null) return candidate;
      await SessionStateService.clearLogoutPlaybackState(uid);
    }

    // Fall back to the regular playback state (saved periodically while
    // playing). This covers the case where the app was killed / swiped
    // away without a graceful logout.
    final regularState = await SessionStateService.readPlaybackState(uid);
    if (regularState != null) {
      final candidate = _toResumeCandidate(
        regularState,
        autoWindow: autoWindow,
      );
      if (candidate != null) return candidate;
      await SessionStateService.clearPlaybackState(uid);
    }

    return null;
  }

  static Future<void> discardPendingPlaybackAfterLogin() async {
    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) return;
    await SessionStateService.clearLogoutPlaybackState(uid);
  }

  static Future<PlaybackResumeResult> resumePendingPlaybackAfterLogin() async {
    await init();
    if (_currentSong != null && _queue.isNotEmpty) {
      return PlaybackResumeResult.resumed;
    }

    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) {
      return PlaybackResumeResult.noPendingSession;
    }

    // Try logout-specific state first.
    final logoutState = await SessionStateService.readLogoutPlaybackState(uid);
    if (logoutState != null) {
      final candidate = _toResumeCandidate(
        logoutState,
        autoWindow: autoResumeWindow,
      );
      if (candidate != null) {
        final outcome = await _restoreFromCandidate(candidate);
        if (outcome == PlaybackResumeResult.resumed) {
          await SessionStateService.clearLogoutPlaybackState(uid);
          await SessionStateService.clearPlaybackState(uid);
        }
        return outcome;
      }
      await SessionStateService.clearLogoutPlaybackState(uid);
    }

    // Fall back to the regular playback state (app killed / swiped away).
    final regularState = await SessionStateService.readPlaybackState(uid);
    if (regularState != null) {
      final candidate = _toResumeCandidate(
        regularState,
        autoWindow: autoResumeWindow,
      );
      if (candidate != null) {
        final outcome = await _restoreFromCandidate(candidate);
        if (outcome == PlaybackResumeResult.resumed) {
          await SessionStateService.clearPlaybackState(uid);
        }
        return outcome;
      }
      await SessionStateService.clearPlaybackState(uid);
    }

    return PlaybackResumeResult.noPendingSession;
  }

  static Future<void> restorePlaybackAfterLogin() async {
    await resumePendingPlaybackAfterLogin();
  }

  static Future<void> _savePlaybackState({bool? wasPlayingOverride}) async {
    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) return;

    final state = _buildPlaybackState(wasPlayingOverride: wasPlayingOverride);
    if (state == null) return;
    await SessionStateService.savePlaybackState(uid: uid, state: state);
  }

  static Map<String, dynamic>? _buildPlaybackState({bool? wasPlayingOverride}) {
    if (_currentSong == null) return null;
    final output = ListeningSafetyService.outputDeviceState;
    return {
      'songId': _currentSong!.id,
      'songName': _currentSong!.name,
      'artist': _currentSong!.artist,
      'imageUrl': _currentSong!.imageUrl,
      'streamUrl': _currentSong!.streamUrl,
      'album': _currentSong!.album,
      'albumId': _currentSong!.albumId,
      'sourceAlbumId': _currentSong!.sourceAlbumId,
      'sourceAlbumName': _currentSong!.sourceAlbumName,
      'sourceAlbumArtist': _currentSong!.sourceAlbumArtist,
      'sourceAlbumImageUrl': _currentSong!.sourceAlbumImageUrl,
      'duration': _currentSong!.duration,
      'position': _player.position.inMilliseconds,
      'wasPlaying': wasPlayingOverride ?? _player.playing,
      'audioQuality': _selectedAudioQuality.name,
      'outputDeviceType': output.type.name,
      'outputDeviceName': output.name,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'queue': _queue.map((s) => s.toJson()).toList(),
      'originalQueue': _originalQueue.map((s) => s.toJson()).toList(),
      'currentIndex': _currentIndex,
      'shuffleModeEnabled': _shuffleModeEnabled,
      'loopMode': _player.loopMode.name,
      'playbackSourceKeys': _queuePlaybackSourceKeys,
    };
  }

  static PlaybackResumeCandidate? _toResumeCandidate(
    Map<String, dynamic> stateMap, {
    required Duration autoWindow,
  }) {
    final timestampMs = _parseInt(stateMap['timestamp']);
    if (timestampMs <= 0) return null;

    final savedAt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final age = DateTime.now().difference(savedAt);
    if (age > _maxPlaybackRestoreAge) return null;

    final durationSeconds = _parseNullableInt(stateMap['duration']);
    final positionMs = _parseInt(stateMap['position']).clamp(0, 1 << 31);
    final song = Song(
      id: stateMap['songId']?.toString() ?? '',
      name: stateMap['songName']?.toString() ?? '',
      artist: stateMap['artist']?.toString(),
      imageUrl: stateMap['imageUrl']?.toString(),
      streamUrl: stateMap['streamUrl']?.toString(),
      album: stateMap['album']?.toString(),
      albumId: stateMap['albumId']?.toString(),
      sourceAlbumId: stateMap['sourceAlbumId']?.toString(),
      sourceAlbumName: stateMap['sourceAlbumName']?.toString(),
      sourceAlbumArtist: stateMap['sourceAlbumArtist']?.toString(),
      sourceAlbumImageUrl: stateMap['sourceAlbumImageUrl']?.toString(),
      duration: durationSeconds,
    );
    if (song.id.trim().isEmpty || !_hasStreamUrl(song)) return null;

    final loopModeName = stateMap['loopMode']?.toString() ?? 'off';
    final loopMode = LoopMode.values.firstWhere(
      (m) => m.name == loopModeName,
      orElse: () => LoopMode.off,
    );

    final queue = <Song>[];
    if (stateMap['queue'] is List) {
      for (final sJson in stateMap['queue'] as List) {
        if (sJson is Map) {
          queue.add(Song.fromJson(Map<String, dynamic>.from(sJson)));
        }
      }
    }

    final originalQueue = <Song>[];
    if (stateMap['originalQueue'] is List) {
      for (final sJson in stateMap['originalQueue'] as List) {
        if (sJson is Map) {
          originalQueue.add(Song.fromJson(Map<String, dynamic>.from(sJson)));
        }
      }
    }

    final playbackSourceKeys = (stateMap['playbackSourceKeys'] as List?)
        ?.map((k) => k.toString())
        .toList();

    return PlaybackResumeCandidate(
      song: song,
      position: Duration(milliseconds: positionMs),
      savedAt: savedAt,
      wasPlaying:
          stateMap['wasPlaying'] == true || stateMap['isPlaying'] == true,
      audioQuality: _audioQualityFromStoredValue(stateMap['audioQuality']),
      outputDeviceName: (stateMap['outputDeviceName'] ?? '').toString().trim(),
      outputDeviceType: (stateMap['outputDeviceType'] ?? '').toString().trim(),
      shouldAutoResume: age <= autoWindow,
      queue: queue.isNotEmpty ? queue : null,
      originalQueue: originalQueue.isNotEmpty ? originalQueue : null,
      currentIndex: _parseInt(stateMap['currentIndex']),
      shuffleModeEnabled: stateMap['shuffleModeEnabled'] == true,
      loopMode: loopMode,
      playbackSourceKeys: playbackSourceKeys,
    );
  }

  static Future<PlaybackResumeResult> _restoreFromCandidate(
    PlaybackResumeCandidate candidate,
  ) async {
    try {
      final isOffline = ConnectivityManager.isOffline;
      var songToRestore = candidate.song;

      final client = ApiService.createSecureHttpClient(pinCertificates: false);
      try {
        if (isOffline) {
          final downloadedPath = await DownloadService.getLocalPath(
            songToRestore.id,
          );
          final cachedPath =
              downloadedPath ?? OfflineService.getLocalPath(songToRestore.id);
          if (cachedPath == null || cachedPath.trim().isEmpty) {
            // Song missing offline! Search offline database for same song title
            final downloadedSongs = await DownloadService.getDownloadedSongs();
            Song? fallbackSong;
            for (final ds in downloadedSongs) {
              if (ds.name.trim().toLowerCase() ==
                  songToRestore.name.trim().toLowerCase()) {
                fallbackSong = ds;
                break;
              }
            }
            if (fallbackSong != null) {
              final path =
                  await DownloadService.getLocalPath(fallbackSong.id) ??
                  OfflineService.getLocalPath(fallbackSong.id);
              if (path != null && path.trim().isNotEmpty) {
                songToRestore = fallbackSong.copyWith(streamUrl: path);
              } else {
                _showThrottledToast("Song unavailable.");
                return PlaybackResumeResult.offlineSongUnavailable;
              }
            } else {
              _showThrottledToast("Song unavailable.");
              return PlaybackResumeResult.offlineSongUnavailable;
            }
          } else {
            songToRestore = songToRestore.copyWith(streamUrl: cachedPath);
          }
        } else {
          // Online: Verify/refresh stream URL
          final resolvedSong = await _resolveSongForPlayback(
            songToRestore,
            forceRefresh: false,
            requestId: PlaybackCoordinator.newRequest(songToRestore),
            client: client,
          );
          if (resolvedSong != null && _hasStreamUrl(resolvedSong)) {
            songToRestore = resolvedSong;
          } else {
            // Stream URL invalid/expired/missing! Search API for same song title
            try {
              final searchPayload = await ApiService.globalSearch(
                songToRestore.name,
              );
              final results = searchPayload['songs'] ?? [];
              Song? fallbackSong;
              for (final res in results) {
                final parsed = Song.fromJson(res);
                if (parsed.name.trim().toLowerCase() ==
                        songToRestore.name.trim().toLowerCase() &&
                    _hasStreamUrl(parsed)) {
                  fallbackSong = parsed;
                  break;
                }
              }
              if (fallbackSong != null) {
                final resolvedFallback = await _resolveSongForPlayback(
                  fallbackSong,
                  forceRefresh: true,
                  requestId: PlaybackCoordinator.newRequest(fallbackSong),
                  client: client,
                );
                if (resolvedFallback != null &&
                    _hasStreamUrl(resolvedFallback)) {
                  songToRestore = resolvedFallback;
                } else {
                  _showThrottledToast("Song unavailable.");
                  return PlaybackResumeResult.offlineSongUnavailable;
                }
              } else {
                _showThrottledToast("Song unavailable.");
                return PlaybackResumeResult.offlineSongUnavailable;
              }
            } catch (_) {
              _showThrottledToast("Song unavailable.");
              return PlaybackResumeResult.offlineSongUnavailable;
            }
          }
        }
      } finally {
        client.close();
      }

      _selectedAudioQuality = candidate.audioQuality;
      _temporaryAutoKbps = null;
      await _refreshResolvedPreferredQuality(applyNow: false, force: true);

      final queueToRestore = candidate.queue ?? <Song>[songToRestore];
      final originalQueueToRestore = candidate.originalQueue ?? queueToRestore;
      var restoreIndex = candidate.currentIndex;
      if (restoreIndex < 0 || restoreIndex >= queueToRestore.length) {
        restoreIndex = 0;
      }

      // Update the song at restoreIndex in queue
      if (restoreIndex >= 0 && restoreIndex < queueToRestore.length) {
        queueToRestore[restoreIndex] = songToRestore;
      }

      _currentSong = songToRestore;
      _queue
        ..clear()
        ..addAll(queueToRestore);
      _originalQueue
        ..clear()
        ..addAll(originalQueueToRestore);
      _currentIndex = restoreIndex;

      // Restore shuffle and loopMode
      _shuffleModeEnabled = candidate.shuffleModeEnabled;
      _shuffleModeController.add(_shuffleModeEnabled);
      await _player.setLoopMode(candidate.loopMode);

      final resolvedTargets = _resolvePlaybackTargets(_queue);
      final sources = resolvedTargets
          .map((target) => target.audioSource)
          .toList(growable: false);

      await _runSerializedSourceMutation(() async {
        await _player
            .setAudioSources(
              sources,
              initialIndex: _currentIndex,
              initialPosition: candidate.position,
            )
            .timeout(
              const Duration(seconds: 12),
              onTimeout: () {
                throw TimeoutException(
                  'Player preparation timed out after 12 seconds',
                );
              },
            );
      });

      _updateTrackedPlaybackSourceKeys(resolvedTargets);
      _resetRateLimitStateForSong(_currentSong?.id);

      if (candidate.wasPlaying) {
        final started = await _playEnsuringAudioFocus();
        if (started) {
          _songPlayStartedAt = DateTime.now();
          _songPlayStartedId = songToRestore.id;
          await _savePlaybackState();
        } else {
          await _savePlaybackState(wasPlayingOverride: false);
        }
      } else {
        await _savePlaybackState(wasPlayingOverride: false);
      }

      unawaited(_triggerAutoplayIfNeeded());
      return PlaybackResumeResult.resumed;
    } on TimeoutException {
      _resetRuntimePlaybackState();
      return PlaybackResumeResult.failed;
    } catch (e) {
      if (_isLoadingInterruptedError(e)) {
        return PlaybackResumeResult.failed;
      }
      debugPrint('Restore session error: $e');
      return PlaybackResumeResult.failed;
    }
  }

  static AudioQuality _audioQualityFromStoredValue(dynamic raw) {
    final value = (raw ?? '').toString().trim().toLowerCase();
    for (final quality in AudioQuality.values) {
      if (quality.name.toLowerCase() == value) return quality;
    }
    return AudioQuality.high;
  }

  static int _parseInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int? _parseNullableInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static Future<void> _clearPlaybackState() async {
    final uid = _currentUserUidSafely();
    if (uid == null || uid.isEmpty) return;
    await SessionStateService.clearPlaybackState(uid);
  }

  static void _resetRuntimePlaybackState() {
    _currentSong = null;
    _queue.clear();
    _queuePlaybackSourceKeys.clear();
    _currentIndex = -1;
    _queueHistoryStack.clear();
    _forwardQueueStack.clear();
    _resetRateLimitStateForSong(null);
    _activeVideoSources.clear();
    _recentAutoplayAlbumKeys.clear();
    _offlineCacheRecoveryInProgress = false;
    _offlineFallbackAttemptInProgress = false;
    _isSwitchingSource = false;
    _hasAudioFocus = false;
    _userPausedOrStoppedPlayback = true;
    _pausedByAudioInterruption = false;
    _pausedByOutputDisconnect = false;
    _pausedByVideoPlayback = false;
    _wasExternalOutputBeforeInterrupt = false;
    _interruptionResumeInProgress = false;
    _activeDuckInterruptions = 0;
    _volumeFadeGeneration = 0;
    _volumeBeforeDuck = 1.0;
    _duckPauseEscalationTimer?.cancel();
    _duckPauseEscalationTimer = null;
    _setInterruptionActive(false);
  }

  static String? _currentUserUidSafely() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // Firebase may not be initialized during early app startup.
      return null;
    }
  }

  static Future<void> _triggerAutoplayIfNeeded() async {
    if (_isSourceMutationInProgress) return;
    if (_currentIndex < 0 || _queue.isEmpty) return;
    final remaining = _queue.length - _currentIndex - 1;
    if (remaining > _autoplayPrefetchThreshold) return;
    if (!await _isAutoplayEnabled()) return;

    _fetchAndAppendAutoplaySongs(minCount: _autoplayBatchMin);
  }

  static Future<bool> _isAutoplayEnabled() async {
    final uid = _currentUserUidSafely();
    if (uid == null) return true;

    final prefs = await PreferencesService.getPreferences(uid);
    return prefs?.autoplayEnabled ?? true;
  }

  static bool _isFetchingAutoplay = false;
  static Future<void> _fetchAndAppendAutoplaySongs({
    int minCount = _autoplayBatchMin,
    bool forceOfflineOnly = false,
  }) async {
    if (_isFetchingAutoplay) return;
    if (_queue.isEmpty) return;

    _isFetchingAutoplay = true;

    try {
      final targetCount = minCount
          .clamp(_autoplayBatchMin, _autoplayBatchMax)
          .toInt();
      final activeSong = (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : _queue.last;
      final uid = _currentUserUidSafely();
      final UserPreferences? prefs = uid != null
          ? await PreferencesService.getPreferences(uid)
          : null;
      final isConnected = forceOfflineOnly
          ? false
          : await _isNetworkConnected();
      final queuedSongIds = _queue.map((song) => song.id.trim()).toSet();
      final queuedLookupKeys = _queue
          .map((song) => _canonicalSongKey(song))
          .toSet();
      final batchAlbumCounts = <String, int>{};
      final stagedSongs = <Song>[];

      void addCandidates(
        Iterable<Song> candidates, {
        bool avoidRecentAlbums = true,
      }) {
        final preferred = <Song>[];
        final fallback = <Song>[];

        for (final song in candidates) {
          final id = song.id.trim();
          final key = _canonicalSongKey(song);
          if (id.isEmpty ||
              queuedSongIds.contains(id) ||
              queuedLookupKeys.contains(key) ||
              !_hasStreamUrl(song)) {
            continue;
          }

          final albumKey = _albumKey(song.album);
          if (albumKey.isNotEmpty && (batchAlbumCounts[albumKey] ?? 0) >= 3) {
            continue;
          }

          final recentlyUsed =
              avoidRecentAlbums &&
              albumKey.isNotEmpty &&
              _recentAutoplayAlbumKeys.contains(albumKey);

          if (recentlyUsed) {
            fallback.add(song);
          } else {
            preferred.add(song);
          }
        }

        for (final song in [...preferred, ...fallback]) {
          if (stagedSongs.length >= targetCount) return;

          final id = song.id.trim();
          final key = _canonicalSongKey(song);
          if (!queuedSongIds.add(id)) continue;
          queuedLookupKeys.add(key);
          stagedSongs.add(song);

          final albumKey = _albumKey(song.album);
          if (albumKey.isNotEmpty) {
            batchAlbumCounts[albumKey] = (batchAlbumCounts[albumKey] ?? 0) + 1;
          }
        }
      }

      if (isConnected) {
        // Step 1: Continue within the same album when possible.
        addCandidates(
          await _fetchAlbumContinuationSongs(
            activeSong,
            limit: _autoplayBatchMax,
          ),
          avoidRecentAlbums: false,
        );

        // Step 2: Move to another album by the same artist.
        if (stagedSongs.length < targetCount) {
          addCandidates(
            await _fetchSameArtistSongs(activeSong, limit: _autoplayBatchMax),
          );
        }

        // Step 3: Use play history.
        if (stagedSongs.length < targetCount) {
          addCandidates(await _fetchHistorySongs(limit: _autoplayBatchMax));
        }
      }

      // Step 4: Offline fallback (always available, especially when offline).
      if (stagedSongs.length < targetCount) {
        addCandidates(
          await OfflineService.getOfflineSongs(),
          avoidRecentAlbums: false,
        );
      }

      if (isConnected && stagedSongs.length < targetCount) {
        // Step 5: Personalized recommendations + trending.
        addCandidates(
          await _fetchRecommendationSongs(
            preferences: prefs,
            limit: _autoplayBatchMax,
          ),
        );

        if (stagedSongs.length < targetCount) {
          addCandidates(
            await _fetchTrendingSongs(
              preferences: prefs,
              limit: _autoplayBatchMax,
            ),
          );
        }
      }

      if (stagedSongs.isNotEmpty) {
        await appendToQueue(stagedSongs);
        _rememberAutoplayAlbums(stagedSongs);
      } else if (_queue.length <= 1) {
        debugPrint('Autoplay: No songs available offline.');
      }
    } catch (e) {
      if (_isLoadingInterruptedError(e)) return;
      debugPrint('Autoplay fetch error: $e');
    } finally {
      _isFetchingAutoplay = false;
    }
  }

  static Future<void> appendToQueue(List<Song> songs) async {
    final existingIds = _queue.map((song) => song.id.trim()).toSet();
    final playable = <Song>[];
    for (final song in songs) {
      final id = song.id.trim();
      if (id.isEmpty || !_hasStreamUrl(song) || existingIds.contains(id)) {
        continue;
      }
      existingIds.add(id);
      playable.add(song);
    }

    if (playable.isEmpty) return;

    int retries = 0;
    while (_isSwitchingSource && retries < 3) {
      await Future.delayed(const Duration(milliseconds: 100));
      retries++;
    }

    _queue.addAll(playable);

    final shouldResume = _player.playing;
    await _runSerializedSourceMutation(() async {
      final safeCurrentIndex = _currentIndex < 0
          ? 0
          : _currentIndex.clamp(0, _queue.length - 1).toInt();
      final resolvedTargets = _resolvePlaybackTargets(_queue);
      await _player.setAudioSources(
        resolvedTargets
            .map((target) => target.audioSource)
            .toList(growable: false),
        initialIndex: safeCurrentIndex,
        initialPosition: _player.position,
      );
      _updateTrackedPlaybackSourceKeys(resolvedTargets);
    });

    if (shouldResume && !_player.playing) {
      await _playEnsuringAudioFocus();
    }
  }

  static Future<void> _onPlaybackCompleted() async {
    // 1. Natural Completion Check
    final duration =
        _player.duration ?? Duration(seconds: _currentSong?.duration ?? 0);
    final position = _player.position;
    final finishedNaturally =
        duration != Duration.zero &&
        position.inSeconds >= duration.inSeconds - 2;

    if (!finishedNaturally) {
      debugPrint(
        'Playback completed event fired, but track did not finish naturally. Position: $position, Duration: $duration. Ignoring automatic skip.',
      );
      return;
    }

    if (_currentSong != null) {
      unawaited(
        BackgroundLearningService.recordReplay(songId: _currentSong!.id),
      );
      unawaited(
        OfflineService.recordPlaybackProgress(
          _currentSong!,
          duration,
          duration: duration,
        ),
      );
    }

    // 2. De-duplicate completion events
    final songId = _currentSong?.id;
    if (songId == null) return;
    final now = DateTime.now();
    if (_lastCompletedSongId == songId &&
        _lastCompletedTime != null &&
        now.difference(_lastCompletedTime!) < const Duration(seconds: 2)) {
      debugPrint('Duplicate song completed event ignored for $songId');
      return;
    }
    _lastCompletedSongId = songId;
    _lastCompletedTime = now;

    // 3. Centralized Queue progression
    await _advanceQueue(isUserTriggered: false);
  }

  static void _checkAndRecordSkipTelemetry() {
    if (_songPlayStartedAt != null && _songPlayStartedId != null) {
      final elapsed = DateTime.now().difference(_songPlayStartedAt!);
      if (elapsed.inSeconds < 5) {
        unawaited(
          BackgroundLearningService.recordImmediateSkip(
            songId: _songPlayStartedId!,
          ),
        );
      }
      _songPlayStartedAt = null;
      _songPlayStartedId = null;
    }
  }

  static Future<bool> _isLikelyConnectivityIssue(String message) async {
    if (message.contains('source error')) {
      return !await _isNetworkConnected();
    }
    if (message.contains('network') ||
        message.contains('socket') ||
        message.contains('timed out') ||
        message.contains('connection')) {
      return true;
    }

    return !await _isNetworkConnected();
  }

  static Future<bool> _isNetworkConnected() async {
    return ConnectivityManager.isConnected;
  }

  static Future<Map<String, bool>> _getOfflinePlaybackPreferences() async {
    final uid = _currentUserUidSafely();
    if (uid == null) {
      return {'offlinePlaybackEnabled': true, 'skipUnavailableOffline': true};
    }
    final prefs = await PreferencesService.getPreferences(uid);
    if (prefs == null) {
      return {'offlinePlaybackEnabled': true, 'skipUnavailableOffline': true};
    }
    return {
      'offlinePlaybackEnabled': prefs.offlinePlaybackEnabled,
      'skipUnavailableOffline': prefs.skipUnavailableOffline,
    };
  }

  static Future<void> _runReconnectionSync() async {
    try {
      if (_queue.isEmpty) return;

      // 1. Refresh future songs in the queue
      for (int i = 0; i < _queue.length; i++) {
        if (i == _currentIndex) continue; // Skip currently playing song
        final song = _queue[i];
        if (_isSongUsingLocalSource(song)) {
          continue; // Keep local downloads local
        }

        final resolved = await _resolveSongForPlayback(
          song,
          forceRefresh: true,
        );
        if (resolved != null) {
          _queue[i] = resolved;
          if (_player.audioSource != null && i < _player.sequence.length) {
            final target = _resolvePlaybackTarget(resolved);
            await _runSerializedSourceMutation(() async {
              try {
                await _player.insertAudioSource(i, target.audioSource);
                await _player.removeAudioSourceAt(i + 1);
              } catch (e) {
                StabilityLogger.warning(
                  'Playback',
                  'Failed to update background queue source at index $i: $e',
                );
              }
            });
          }
        }
      }
    } catch (e) {
      StabilityLogger.error(
        'Playback',
        'Reconnection background sync error',
        e,
      );
    }
  }

  static Future<void> _advanceQueueOffline(bool wasPlaying) async {
    final nextSongIndex = _currentIndex + 1;
    if (nextSongIndex >= _queue.length) return;

    final immediateNextSong = _queue[nextSongIndex];
    final resolvedImmediateNext = await _resolveLocalSongCopy(
      immediateNextSong,
    );
    final isImmediateNextDownloaded = _isSongUsingLocalSource(
      resolvedImmediateNext,
    );

    if (isImmediateNextDownloaded) {
      await _resolveOfflineSourceForQueueIndex(nextSongIndex);
      _currentIndex = nextSongIndex;
      _currentSong = _queue[_currentIndex];
      if (_player.audioSource != null &&
          nextSongIndex < _player.sequence.length) {
        await _player.seek(Duration.zero, index: nextSongIndex);
        if (wasPlaying) {
          await _playEnsuringAudioFocus();
        }
      } else {
        final localSong = await _resolveLocalSongCopy(_currentSong!);
        await _setSingleSource(localSong);
        if (wasPlaying) {
          await _playEnsuringAudioFocus();
        }
      }
      _savePlaybackState();
    } else {
      final prefs = await _getOfflinePlaybackPreferences();
      final skipUnavailable = prefs['skipUnavailableOffline'] ?? true;
      if (skipUnavailable) {
        int? nextDownloadedIndex;
        for (int i = nextSongIndex; i < _queue.length; i++) {
          final resolved = await _resolveLocalSongCopy(_queue[i]);
          if (_isSongUsingLocalSource(resolved)) {
            nextDownloadedIndex = i;
            break;
          }
        }
        if (nextDownloadedIndex != null) {
          await _resolveOfflineSourceForQueueIndex(nextDownloadedIndex);
          _currentIndex = nextDownloadedIndex;
          _currentSong = _queue[_currentIndex];
          if (_player.audioSource != null &&
              nextDownloadedIndex < _player.sequence.length) {
            await _player.seek(Duration.zero, index: nextDownloadedIndex);
            if (wasPlaying) {
              await _playEnsuringAudioFocus();
            }
          } else {
            final localSong = await _resolveLocalSongCopy(_currentSong!);
            await _setSingleSource(localSong);
            if (wasPlaying) {
              await _playEnsuringAudioFocus();
            }
          }
          _savePlaybackState();
        } else {
          _qualityAdjustmentMsgController.add('No more downloaded tracks.');
          await _handleNetworkDropDuringPlayback();
          _savePlaybackState();
        }
      } else {
        _currentIndex = nextSongIndex;
        _currentSong = _queue[_currentIndex];
        _qualityAdjustmentMsgController.add('Song unavailable offline.');
        _pausedByNetworkLoss = true;
        _userPausedOrStoppedPlayback = true;
        await _player.pause();
        _savePlaybackState();
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Network-drop recovery helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Attempt to switch to a local copy if internet is lost while buffering.
  static Future<void> _attemptOfflineFallbackForCurrentSong() async {
    // Guard against concurrent invocations from rapid buffering events.
    if (_offlineFallbackAttemptInProgress) return;
    final song = _currentSong;
    if (song == null) return;
    if (_isSongUsingLocalSource(song)) return;

    _offlineFallbackAttemptInProgress = true;
    try {
      final resolved = await _resolveLocalSongCopy(song);
      if (_isSongUsingLocalSource(resolved)) {
        debugPrint('Found offline copy for ${song.id}. Switching seamlessly.');
        // Capture state before the async write so the snapshot is always fresh.
        final wasPlaying = _player.playing;
        final position = _offlineSeekPosition ?? _player.position;
        _offlineSeekPosition = null;
        final index = _player.currentIndex ?? _currentIndex;

        _setSourceSwitching(true);
        try {
          await _replaceCurrentAudioSource(
            updatedSong: resolved,
            index: index,
            position: position,
          );

          if (wasPlaying) {
            await _player.play();
          }
        } finally {
          _setSourceSwitching(false);
        }
        _qualityAdjustmentMsgController.add(
          'Offline mode active. Continuing playback.',
        );
        return;
      }

      // Truly stuck without network and no offline copy.
      await _handleNetworkDropDuringPlayback();
    } finally {
      _offlineFallbackAttemptInProgress = false;
    }
  }

  /// Called when connectivity drops while the player may be streaming.
  ///
  /// Priority:
  ///   1. If a local copy (downloaded or cached) exists → switch to it and
  ///      keep playing from the same timestamp. No interruption to the user.
  ///   2. No local copy → pause and wait for explicit user action.
  static Future<void> _handleNetworkDropDuringPlayback() async {
    final song = _currentSong;
    if (song == null) return;

    // If already playing from local file, nothing to do.
    if (_isSongUsingLocalSource(song)) return;

    // Only act if the player is actively playing or has been playing
    // (user didn't manually pause).
    final wasActive =
        _player.playing ||
        (!_userPausedOrStoppedPlayback &&
            !_pausedByAudioInterruption &&
            !_pausedByOutputDisconnect &&
            !_pausedByVideoPlayback);
    if (!wasActive) return;

    // ─── Step 1: Try a seamless switch to a local file. ───────────────────
    // Capture state before any async work so snapshots are always fresh.
    final wasPlaying = _player.playing;
    final lastPosition = _lastKnownPosition > Duration.zero
        ? _lastKnownPosition
        : _player.position;

    var localPath = OfflineService.getLocalPath(song.id);
    localPath ??= await DownloadService.getLocalPath(song.id);

    if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      debugPrint(
        'Network dropped for ${song.id} but a local copy exists. '
        'Switching seamlessly to local file.',
      );
      final localSong = song.copyWith(streamUrl: localPath);

      _setSourceSwitching(true);
      try {
        if (_queue.length > 1) {
          final updatedQueue = _queue
              .map((s) => s.id == localSong.id ? localSong : s)
              .toList(growable: false);
          await _replaceCurrentAudioSource(
            updatedSong: localSong,
            index: _currentIndex,
            position: lastPosition,
            replacementQueue: updatedQueue,
          );
          _queue
            ..clear()
            ..addAll(updatedQueue);
        } else {
          await _setSingleSource(localSong);
        }

        if (lastPosition > Duration.zero) {
          await _player.seek(lastPosition, index: _currentIndex);
        }
        if (wasPlaying) {
          await _playEnsuringAudioFocus();
        }
        _savePlaybackState();
        _qualityAdjustmentMsgController.add(
          'Offline mode active. Continuing playback.',
        );
        debugPrint(
          'Seamlessly switched ${song.id} to local file on network loss.',
        );
        return;
      } catch (e) {
        debugPrint('Seamless local-file switch failed for ${song.id}: $e');
        // Fall through to the stop-and-wait path below.
      } finally {
        _setSourceSwitching(false);
      }
    }

    // ─── Step 2: No local file available → stop and wait. ─────────────────
    debugPrint(
      'Network dropped during active playback of ${song.id}. '
      'No local copy found. Stopping playback until user action.',
    );
    _pausedByNetworkLoss = true;
    _userPausedOrStoppedPlayback = true;
    try {
      await _player.pause();
    } catch (_) {}
    _savePlaybackState();
    _qualityAdjustmentMsgController.add('No internet. Playback stopped.');
    debugPrint('Playback stopped for ${song.id} due to network loss.');
  }

  /// Buffering watchdog: when the player is stuck in BUFFERING or LOADING
  /// for more than 10 seconds without network, trigger offline recovery.
  static void _handleBufferingWatchdog(ProcessingState state) {
    _bufferingWatchdogTimer?.cancel();
    _bufferingWatchdogTimer = null;

    final isStuckState =
        state == ProcessingState.buffering || state == ProcessingState.loading;
    if (!isStuckState || _isNetworkAvailable) return;

    final song = _currentSong;
    if (song == null) return;
    if (_isSongUsingLocalSource(song)) return;

    _bufferingWatchdogTimer = Timer(const Duration(seconds: 10), () async {
      // Re-check conditions after the delay.
      if (_isNetworkAvailable) return;
      if (_currentSong?.id != song.id) return;
      final currentState = _player.processingState;
      if (currentState != ProcessingState.buffering &&
          currentState != ProcessingState.loading) {
        return;
      }

      debugPrint(
        'Buffering watchdog triggered for ${song.id} — '
        'stuck ${currentState.name} without network for 10s.',
      );
      await _handleNetworkDropDuringPlayback();
    });
  }

  static void _handleLoadingWatchdog(ProcessingState state) {
    _loadingWatchdogTimer?.cancel();
    _loadingWatchdogTimer = null;

    final isStuckState =
        state == ProcessingState.loading || state == ProcessingState.buffering;
    if (!isStuckState) return;

    final song = _currentSong;
    if (song == null) return;
    if (_isSongUsingLocalSource(song)) return;

    _loadingWatchdogTimer = Timer(const Duration(seconds: 8), () async {
      if (_currentSong?.id != song.id) return;
      final currentState = _player.processingState;
      if (currentState != ProcessingState.loading &&
          currentState != ProcessingState.buffering) {
        return;
      }

      debugPrint(
        'Loading watchdog triggered for ${song.id} — '
        'stuck ${currentState.name} for 10s.',
      );
      try {
        await _player.stop();
      } catch (_) {}
      unawaited(
        _handlePlayerError(
          PlayerException(404, 'loading timeout / 404', _currentIndex),
        ),
      );
    });
  }

  /// Re-resolve and reload the audio source for the current song.
  /// Used when the player's source is dead (idle/error after network loss)
  /// and the user manually resumes or seeks.
  /// Returns true if a playable source was loaded.
  static Future<bool> _reloadSourceForCurrentSong() async {
    final song = _currentSong;
    if (song == null) return false;
    // Capture position before async resolution so it doesn't drift.
    final lastPosition =
        _offlineSeekPosition ??
        (_lastKnownPosition > Duration.zero
            ? _lastKnownPosition
            : _player.position);
    _offlineSeekPosition = null; // Clear it after reading

    // Prefer offline cache.
    var localPath = OfflineService.getLocalPath(song.id);
    localPath ??= await DownloadService.getLocalPath(song.id);

    Song playableSong;
    _fallbackSongResolved = false;
    if (localPath != null && localPath.isNotEmpty) {
      if (File(localPath).existsSync()) {
        playableSong = song.copyWith(streamUrl: localPath);
      } else if (_isNetworkAvailable) {
        final resolved = await _resolveSongForPlayback(
          song,
          forceRefresh: true,
        );
        if (resolved == null) return false;
        playableSong = resolved;
      } else {
        return false;
      }
    } else if (_isNetworkAvailable) {
      // Network is back — try resolving a fresh stream URL.
      final resolved = await _resolveSongForPlayback(song, forceRefresh: true);
      if (resolved == null) return false;
      playableSong = resolved;
    } else {
      return false;
    }

    final reloadInitialPos =
        lastPosition; // Always restore the user's last position on reload

    _setSourceSwitching(true);
    try {
      if (_player.audioSource != null && _queue.length > 1) {
        final updatedQueue = _queue
            .map((s) => s.id == playableSong.id ? playableSong : s)
            .toList(growable: false);
        await _replaceCurrentAudioSource(
          updatedSong: playableSong,
          index: _currentIndex,
          position: reloadInitialPos,
          replacementQueue: updatedQueue,
        );
        _queue
          ..clear()
          ..addAll(updatedQueue);
      } else {
        await _setSingleSource(playableSong, initialPosition: reloadInitialPos);
      }

      if (!_fallbackSongResolved && lastPosition > Duration.zero) {
        await _player.seek(lastPosition, index: _currentIndex);
      }
      return true;
    } catch (e) {
      debugPrint('_reloadSourceForCurrentSong failed: $e');
      return false;
    } finally {
      _setSourceSwitching(false);
    }
  }

  /// Resolve offline source for a specific queue index so that seeking
  /// to it when offline doesn't attempt a dead stream URL.
  static Future<void> _resolveOfflineSourceForQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final song = _queue[index];
    if (_isSongUsingLocalSource(song)) return;

    var localPath = OfflineService.getLocalPath(song.id);
    localPath ??= await DownloadService.getLocalPath(song.id);
    if (localPath == null || localPath.isEmpty || !File(localPath).existsSync()) {
      return;
    }

    final offlineSong = song.copyWith(streamUrl: localPath);
    _queue[index] = offlineSong;

    try {
      if (index == _currentIndex) {
        final wasPlaying = _player.playing;
        final currentPosition = _offlineSeekPosition ?? _player.position;
        _offlineSeekPosition = null;
        await _replaceCurrentAudioSource(
          updatedSong: offlineSong,
          index: index,
          position: currentPosition,
        );
        if (wasPlaying) {
          await _player.play();
        }
      } else {
        final resolvedTarget = _resolvePlaybackTarget(offlineSong);
        await _runSerializedSourceMutation(() async {
          final currentSequence = _player.sequence;
          if (_player.audioSource != null && index < currentSequence.length) {
            final currentItem = currentSequence[index].tag;
            if (currentItem is MediaItem && currentItem.id == song.id) {
              await _player.insertAudioSource(
                index,
                resolvedTarget.audioSource,
              );
              await _player.removeAudioSourceAt(index + 1);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('_resolveOfflineSourceForQueueIndex($index) failed: $e');
    }
  }

  static Future<bool> _prepareOfflineSourceForQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return false;
    if (_isSongUsingLocalSource(_queue[index])) return true;
    await _resolveOfflineSourceForQueueIndex(index);
    if (index < 0 || index >= _queue.length) return false;
    return _isSongUsingLocalSource(_queue[index]);
  }

  static String _normalizeLookup(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _albumKey(String? albumName) {
    return _normalizeLookup(albumName ?? '');
  }

  static String _canonicalSongKey(Song song) {
    final name = (song.name).toLowerCase();
    final artist = (song.artist ?? '').toLowerCase().split(',').first.trim();

    // Simple cleaning of common suffixes like (From "Movie") or [Official Video]
    final cleanName = name
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(remix|version|live|slowed|reverb|karaoke|instrumental|lofi|cover)\b',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return '$cleanName|$artist';
  }

  static void _rememberAutoplayAlbums(Iterable<Song> songs) {
    for (final song in songs) {
      final key = _albumKey(song.album);
      if (key.isEmpty) continue;

      _recentAutoplayAlbumKeys.remove(key);
      _recentAutoplayAlbumKeys.add(key);
      if (_recentAutoplayAlbumKeys.length > _autoplayAlbumHistoryLimit) {
        _recentAutoplayAlbumKeys.removeAt(0);
      }
    }
  }

  static List<dynamic> _extractSongResultsFromPayload(dynamic payload) {
    if (payload is! Map) return const [];
    final data = payload['data'];

    if (data is Map) {
      if (data['songs'] is List) return data['songs'] as List<dynamic>;
      if (data['results'] is List) return data['results'] as List<dynamic>;
    }

    if (data is List) return data;
    if (payload['songs'] is List) return payload['songs'] as List<dynamic>;
    if (payload['results'] is List) return payload['results'] as List<dynamic>;
    return const [];
  }

  static List<dynamic> _extractAlbumResultsFromPayload(dynamic payload) {
    if (payload is! Map) return const [];
    final data = payload['data'];

    if (data is Map && data['results'] is List) {
      return data['results'] as List<dynamic>;
    }
    if (data is List) return data;
    if (payload['results'] is List) return payload['results'] as List<dynamic>;
    return const [];
  }

  static List<Song> _toSongs(Iterable<dynamic> rawSongs, {int? limit}) {
    final songs = <Song>[];
    for (final entry in rawSongs) {
      if (limit != null && songs.length >= limit) break;
      if (entry is! Map) continue;

      final title = (entry['name'] ?? entry['title'] ?? '').toString();
      if (!ContentFilter.isAllowedSongTitle(title)) continue;

      final song = Song.fromJson(Map<String, dynamic>.from(entry));
      if (song.id.trim().isEmpty || !_hasStreamUrl(song)) continue;
      songs.add(song);
    }
    return songs;
  }

  static Map<String, dynamic>? _extractFirstSongMap(dynamic payload) {
    final songs = _extractSongResultsFromPayload(payload);
    if (songs.isEmpty) return null;
    final first = songs.first;
    if (first is! Map) return null;
    return Map<String, dynamic>.from(first);
  }

  static Future<List<Song>> _fetchAlbumContinuationSongs(
    Song currentSong, {
    int limit = _autoplayBatchMax,
  }) async {
    final albumName = (currentSong.album ?? '').trim();
    if (albumName.isEmpty) return const [];

    try {
      final searchPayload = await ApiService.getAlbums(query: albumName);
      final albumResults = _extractAlbumResultsFromPayload(searchPayload);
      if (albumResults.isEmpty) return const [];

      final normalizedTarget = _normalizeLookup(albumName);
      String? albumId;

      for (final entry in albumResults) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final candidateId = (map['id'] ?? '').toString().trim();
        if (candidateId.isEmpty) continue;

        final candidateName = _normalizeLookup(
          (map['name'] ?? map['title'] ?? '').toString(),
        );
        if (candidateName.isEmpty) continue;

        if (candidateName == normalizedTarget ||
            candidateName.contains(normalizedTarget) ||
            normalizedTarget.contains(candidateName)) {
          albumId = candidateId;
          break;
        }
      }

      albumId ??= (albumResults.first is Map)
          ? (albumResults.first['id'] ?? '').toString().trim()
          : '';
      if (albumId.isEmpty) return const [];

      final detailPayload = await ApiService.getAlbums(id: albumId);
      final albumSongs = _toSongs(
        _extractSongResultsFromPayload(detailPayload),
        limit: limit,
      );
      if (albumSongs.isEmpty) return const [];

      var currentIndex = albumSongs.indexWhere(
        (song) => song.id == currentSong.id,
      );
      if (currentIndex < 0) {
        final normalizedCurrentName = _normalizeLookup(currentSong.name);
        currentIndex = albumSongs.indexWhere(
          (song) => _normalizeLookup(song.name) == normalizedCurrentName,
        );
      }

      if (currentIndex >= 0 && currentIndex < albumSongs.length - 1) {
        return [
          ...albumSongs.skip(currentIndex + 1),
          ...albumSongs.take(currentIndex),
        ];
      }
      return albumSongs;
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Song>> _fetchSameArtistSongs(
    Song currentSong, {
    int limit = _autoplayBatchMax,
  }) async {
    final artistName = (currentSong.artist ?? '').split(',').first.trim();
    if (artistName.isEmpty) return const [];

    final normalizedArtist = _normalizeLookup(artistName);
    final currentAlbumKey = _albumKey(currentSong.album);
    final songs = <Song>[];

    try {
      final albums = await ApiService.getArtistAlbums(
        '',
        artistName: artistName,
        limit: 12,
      );

      var fetchedAlbums = 0;
      for (final album in albums) {
        if (songs.length >= limit || fetchedAlbums >= 4) break;
        if (album is! Map) continue;

        final map = Map<String, dynamic>.from(album);
        final albumId = (map['id'] ?? '').toString().trim();
        if (albumId.isEmpty) continue;

        final candidateAlbumKey = _albumKey(
          (map['name'] ?? map['title'] ?? '').toString(),
        );
        if (candidateAlbumKey.isNotEmpty &&
            candidateAlbumKey == currentAlbumKey) {
          continue;
        }

        fetchedAlbums += 1;
        try {
          final payload = await ApiService.getAlbums(id: albumId);
          songs.addAll(_toSongs(_extractSongResultsFromPayload(payload)));
        } catch (_) {}
      }
    } catch (_) {}

    if (songs.isNotEmpty) {
      return songs.take(limit).toList(growable: false);
    }

    try {
      final searchRes = await ApiService.globalSearch(artistName);
      final fallbackSongs = _toSongs(searchRes['songs'] ?? const []);
      final filtered = fallbackSongs.where((song) {
        final songArtist = _normalizeLookup(song.artist ?? '');
        if (songArtist.isEmpty) return false;
        return songArtist.contains(normalizedArtist) ||
            normalizedArtist.contains(songArtist);
      }).toList();
      return filtered.take(limit).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Song>> _fetchHistorySongs({
    int limit = _autoplayBatchMax,
  }) async {
    try {
      final historyData = await ApiService.getHistory(type: 'play', limit: 30);
      final songIds = <String>{};

      for (final item in historyData) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = (map['songId'] ?? map['song_id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        songIds.add(id);
        if (songIds.length >= limit * 2) break;
      }

      final songs = <Song>[];
      for (final id in songIds) {
        if (songs.length >= limit) break;
        try {
          final songData = await ApiService.getSong(id);
          final songJson = _extractFirstSongMap(songData);
          if (songJson == null) continue;
          final song = Song.fromJson(songJson);
          if (_hasStreamUrl(song)) songs.add(song);
        } catch (_) {}
      }

      return songs;
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Song>> _fetchRecommendationSongs({
    required UserPreferences? preferences,
    int limit = _autoplayBatchMax,
  }) async {
    final languages = preferences?.languages ?? const <String>[];
    final favoriteArtists =
        preferences?.favoriteArtists ?? const <Map<String, String>>[];

    try {
      final personalized = await ApiService.getPersonalizedRecommendations(
        languages: languages,
        favoriteArtists: favoriteArtists,
        limit: limit,
      );
      final songs = _filterSongsByLanguagePreferences(
        _toSongs(personalized, limit: limit),
        languages,
      );
      if (songs.isNotEmpty) return songs;
    } catch (_) {}

    try {
      return _filterSongsByLanguagePreferences(
        _toSongs(
          await ApiService.getRecommendations(limit: limit),
          limit: limit,
        ),
        languages,
      );
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Song>> _fetchTrendingSongs({
    required UserPreferences? preferences,
    int limit = _autoplayBatchMax,
  }) async {
    final languages = preferences?.languages ?? const <String>[];

    try {
      final trending = await ApiService.getTrendingSongs(
        languages: languages,
        limit: limit,
      );
      return _filterSongsByLanguagePreferences(
        _toSongs(trending, limit: limit),
        languages,
      );
    } catch (_) {
      return const [];
    }
  }

  static List<Song> _filterSongsByLanguagePreferences(
    List<Song> songs,
    List<String> preferredLanguages,
  ) {
    final preferred = LanguageUtils.normalizeLanguageSet(preferredLanguages);
    if (preferred.isEmpty) return songs;
    return songs
        .where(
          (song) =>
              LanguageUtils.matchesPreferredLanguages(song.language, preferred),
        )
        .toList(growable: false);
  }

  static Future<void> dispose() async {
    _stopProgressTimer();
    await _positionSubscription?.cancel();
    await _volumeSubscription?.cancel();
    await _indexSubscription?.cancel();
    await _playerStateSubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _errorSubscription?.cancel();
    await _outputDeviceSubscription?.cancel();
    await _androidAudioSessionIdSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    _autoQualityRecoveryTimer?.cancel();
    _networkReEvalTimer?.cancel();
    _conversationRestoreTimer?.cancel();
    _duckPauseEscalationTimer?.cancel();
    _watchdogTimer?.cancel();

    _positionSubscription = null;
    _volumeSubscription = null;
    _indexSubscription = null;
    _playerStateSubscription = null;
    _interruptionSubscription = null;
    _becomingNoisySubscription = null;
    _errorSubscription = null;
    _outputDeviceSubscription = null;
    _androidAudioSessionIdSubscription = null;
    _connectivitySubscription = null;
    _autoQualityRecoveryTimer = null;
    _networkReEvalTimer = null;
    _conversationRestoreTimer = null;
    _duckPauseEscalationTimer = null;
    _watchdogTimer = null;
    _frozenCounter = 0;
    _temporaryAutoKbps = null;
    _cachedNetworkSpeedMbps = null;
    _lastNetworkSpeedProbeAt = null;
    _qualityApplyInProgress = false;
    _sourceMutationTail = Future<void>.value();
    _sourceMutationDepth = 0;
    _setQualitySwitching(false);
    _setSourceSwitching(false);

    _isInitialized = false;
    _initFuture = null;
    _resetRateLimitStateForSong(null);
    _activeVideoSources.clear();
    _recentAutoplayAlbumKeys.clear();
    _queueHistoryStack.clear();
    _forwardQueueStack.clear();
    _offlineCacheRecoveryInProgress = false;
    _offlineFallbackAttemptInProgress = false;
    _dolbyEffectEnabled = false;
    _conversationAssistMode = SmartConversationAssistMode.off;
    _conversationAssistReductionLevel = 0.30;
    _conversationAssistAutoRestoreDelay = const Duration(seconds: 60);
    _conversationAssistIgnoreSingleEarbud = false;
    _conversationModeActive = false;
    _conversationPausePatternLearned = false;
    _conversationStoredVolume = 1.0;
    _lastVolumeDownAt = null;
    _volumeDownBurstCount = 0;
    _lastObservedPlayerVolume = 1.0;
    _conversationManagedVolumeWrites = 0;
    _lastConversationOutputState = AudioOutputRouteState.phoneSpeaker;
    _conversationActions.clear();
    _conversationModeController.add(false);
    _hasAudioFocus = false;
    _userPausedOrStoppedPlayback = true;
    _pausedByAudioInterruption = false;
    _pausedByOutputDisconnect = false;
    _pausedByVideoPlayback = false;
    _wasExternalOutputBeforeInterrupt = false;
    _interruptionResumeInProgress = false;
    _activeDuckInterruptions = 0;
    _volumeFadeGeneration = 0;
    _volumeBeforeDuck = 1.0;
    _wasPlayingBeforeNoisyPause = false;
    _deviceConnectResumeTimer?.cancel();
    _deviceConnectResumeTimer = null;
    _setInterruptionActive(false);

    await AudioEffectsService.dispose();
    await _setAudioSessionActive(false);
    await _player.dispose();
  }

  static Future<bool> _validateStreamUrl(String url, http.Client client) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return false;
    if (_isLocalFilePath(cleanUrl)) {
      try {
        final file = File(cleanUrl);
        if (!file.existsSync()) return false;
        final length = file.lengthSync();
        if (length <= 0) return false;
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      final uri = Uri.parse(cleanUrl);
      var response = await client
          .head(uri)
          .timeout(const Duration(milliseconds: 1500));

      // If HEAD returns 405 Method Not Allowed or 403 Forbidden or 501/500, we fallback to a GET with a tiny byte range.
      if (response.statusCode != 200) {
        final request = http.Request('GET', uri);
        request.headers['Range'] = 'bytes=0-1'; // Request first 2 bytes
        final streamedResponse = await client
            .send(request)
            .timeout(const Duration(milliseconds: 1500));
        if (streamedResponse.statusCode == 200 ||
            streamedResponse.statusCode == 206) {
          final contentType = (streamedResponse.headers['content-type'] ?? '')
              .toLowerCase();
          if (contentType.isNotEmpty) {
            return true; // We received a partial content or full content response from media server
          }
        }
        return false;
      }

      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      final contentLengthStr = response.headers['content-length'] ?? '0';
      final contentLength = int.tryParse(contentLengthStr) ?? 0;

      if (contentType.contains('audio') ||
          contentType.contains('mpeg') ||
          contentType.contains('octet-stream') ||
          contentType.contains('video') ||
          contentType.contains('application/x-mpegurl')) {
        return true;
      }
      if (contentLength > 0) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Stream validation failed for $cleanUrl: $e');
      return false;
    }
  }

  static Song? _getCachedSongUrl(String songId) {
    final entry = SearchCoordinator.getCacheEntry(songId);
    if (entry != null) {
      return entry.song.copyWith(streamUrl: entry.streamUrl);
    }
    return null;
  }

  static void _setCachedSongUrl(Song song, String streamUrl) {
    final songId = song.id.trim();
    if (songId.isEmpty || streamUrl.trim().isEmpty) return;

    SearchCoordinator.cacheStream(
      songId: songId,
      song: song,
      streamUrl: streamUrl,
      isValidated: true,
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
      provider: 'player_service',
      bitrate: 0,
    );
  }

  static void _preloadUpcomingSongs(int currentIndex) {
    _isNetworkConnected().then((hasNetwork) {
      if (!hasNetwork) return;

      final indicesToPreload = <int>[];
      if (currentIndex > 0) indicesToPreload.add(currentIndex - 1);
      for (int i = 1; i <= 3; i++) {
        final nextIndex = currentIndex + i;
        if (nextIndex < _queue.length) indicesToPreload.add(nextIndex);
      }

      Future<void> updatePreloadedSource(
        int indexToPreload,
        Song resolvedSong,
        String songId,
      ) async {
        if (indexToPreload < _queue.length &&
            _queue[indexToPreload].id == songId) {
          _queue[indexToPreload] = resolvedSong;

          final resolvedTarget = _resolvePlaybackTarget(resolvedSong);
          await _runSerializedSourceMutation(() async {
            final currentSequence = _player.sequence;
            if (_player.audioSource != null &&
                indexToPreload < currentSequence.length) {
              final currentItem = currentSequence[indexToPreload].tag;
              if (currentItem is MediaItem && currentItem.id == songId) {
                debugPrint(
                  'Preloading completed: replacing source at index $indexToPreload for ${resolvedSong.name}',
                );
                await _player.insertAudioSource(
                  indexToPreload,
                  resolvedTarget.audioSource,
                );
                await _player.removeAudioSourceAt(indexToPreload + 1);
              }
            }
          });
        }
      }

      for (final indexToPreload in indicesToPreload) {
        final song = _queue[indexToPreload];
        final songId = song.id.trim();
        if (songId.isEmpty) continue;

        // Skip if it's already a local file path
        if (_hasStreamUrl(song) && _isLocalFilePath(song.streamUrl!)) continue;

        // Check if we already have it cached
        final cached = _getCachedSongUrl(songId);
        if (cached != null && _hasStreamUrl(cached)) {
          if (cached.streamUrl != song.streamUrl) {
            unawaited(updatePreloadedSource(indexToPreload, cached, songId));
          }
          continue;
        }

        // Resolve in background (unawaited)
        unawaited(
          _resolveSongForPlayback(song, requestId: 'pre-resolve-$songId')
              .then((resolvedSong) async {
                if (resolvedSong != null &&
                    _hasStreamUrl(resolvedSong) &&
                    resolvedSong.streamUrl != song.streamUrl) {
                  await updatePreloadedSource(
                    indexToPreload,
                    resolvedSong,
                    songId,
                  );
                }
              })
              .catchError((e) {
                debugPrint('Preload failed for song ${song.name}: $e');
              }),
        );
      }
    });
  }



  static Future<Song?> _fetchSongDetailsForPlaybackWithClient(
    Song song,
    http.Client client, {
    bool forceRefresh = false,
  }) async {
    final songId = song.id.trim();
    if (songId.isEmpty) return null;

    final baseUrl = ApiService.baseUrl;
    try {
      final res = await client
          .get(Uri.parse('$baseUrl/api/songs/$songId'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final songData = jsonDecode(res.body);
        dynamic payload = songData['data'];
        if (payload is List && payload.isNotEmpty) payload = payload.first;
        if (payload is Map) {
          final resolvedSong = Song.fromJson(
            Map<String, dynamic>.from(payload),
          );
          if (_hasStreamUrl(resolvedSong)) return resolvedSong;
        }
      }
    } catch (_) {}

    try {
      final res = await client
          .get(Uri.parse('https://saavn.dev/api/songs?ids=$songId'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final parsed = jsonDecode(res.body);
        dynamic payload = parsed['data'];
        if (payload is List && payload.isNotEmpty) payload = payload.first;
        if (payload is Map) {
          final resolvedSong = Song.fromJson(
            Map<String, dynamic>.from(payload),
          );
          if (_hasStreamUrl(resolvedSong)) return resolvedSong;
        }
      }
    } catch (_) {}

    return null;
  }

  static Future<void> setShuffleModeEnabled(bool enabled) async {
    if (_shuffleModeEnabled == enabled) return;
    _shuffleModeEnabled = enabled;
    _shuffleModeController.add(enabled);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('playback_shuffle_enabled', enabled);
    } catch (e) {
      debugPrint('Failed to save shuffle preference: $e');
    }

    await _realignQueueForShuffleState();
  }

  static List<Song> _smartShuffle(List<Song> songs, Song currentSong) {
    if (songs.length <= 1) return List<Song>.from(songs);

    final remaining = songs.where((s) => s.id != currentSong.id).toList();
    if (remaining.isEmpty) return [currentSong];

    remaining.shuffle();

    for (int i = 1; i < remaining.length - 1; i++) {
      final prev = remaining[i - 1];
      final curr = remaining[i];

      if (_isSameArtistOrAlbum(prev, curr)) {
        int swapIndex = -1;
        for (int j = i + 1; j < remaining.length; j++) {
          if (!_isSameArtistOrAlbum(prev, remaining[j]) &&
              !_isSameArtistOrAlbum(
                remaining[j],
                remaining[i + 1 == j ? i : i + 1],
              )) {
            swapIndex = j;
            break;
          }
        }
        if (swapIndex != -1) {
          final temp = remaining[i];
          remaining[i] = remaining[swapIndex];
          remaining[swapIndex] = temp;
        }
      }
    }

    return [currentSong, ...remaining];
  }

  static bool _isSameArtistOrAlbum(Song a, Song b) {
    final aArtist = (a.artist ?? '').trim().toLowerCase();
    final bArtist = (b.artist ?? '').trim().toLowerCase();
    if (aArtist.isNotEmpty && aArtist == bArtist) return true;

    final aAlbum = (a.album ?? '').trim().toLowerCase();
    final bAlbum = (b.album ?? '').trim().toLowerCase();
    if (aAlbum.isNotEmpty && aAlbum == bAlbum) return true;

    return false;
  }

  static Future<void> _realignQueueForShuffleState() async {
    if (_queue.isEmpty || _currentSong == null) return;

    final activeSong = _currentSong!;
    final currentPos = _player.position;

    if (_shuffleModeEnabled) {
      if (_originalQueue.isEmpty) {
        _originalQueue = List<Song>.from(_queue);
      }
      final shuffled = _smartShuffle(_originalQueue, activeSong);
      _queue
        ..clear()
        ..addAll(shuffled);
      _currentIndex = 0;
      _currentSong = _queue[_currentIndex];
    } else {
      if (_originalQueue.isNotEmpty) {
        _queue
          ..clear()
          ..addAll(_originalQueue);
      }
      _currentIndex = _queue.indexWhere((s) => s.id == activeSong.id);
      if (_currentIndex < 0) _currentIndex = 0;
      _currentSong = _queue[_currentIndex];
    }

    final resolvedTargets = _resolvePlaybackTargets(_queue);
    final sources = resolvedTargets
        .map((target) => target.audioSource)
        .toList(growable: false);

    await _runSerializedSourceMutation(() async {
      await _player.setAudioSources(
        sources,
        initialIndex: _currentIndex,
        initialPosition: currentPos,
      );
    });

    _updateTrackedPlaybackSourceKeys(resolvedTargets);
  }
}

class _StreamUrlCacheEntry {
  final Song song;
  final String streamUrl;
  final DateTime expirationTime;

  _StreamUrlCacheEntry({
    required this.song,
    required this.streamUrl,
    required this.expirationTime,
  });

  bool get isExpired => DateTime.now().isAfter(expirationTime);
}

class _PlaybackSessionLogger {
  final int sessionId;
  final String songName;
  final List<String> steps = [];

  _PlaybackSessionLogger(this.sessionId, this.songName);

  void logStep(String step, bool success, {String? detail}) {
    final marker = success ? '✓' : '✗';
    final detailStr = detail != null ? ' ($detail)' : '';
    steps.add('$marker $step$detailStr');
  }

  void printReport(String result) {
    final buffer = StringBuffer();
    buffer.writeln('\n========================================');
    buffer.writeln('Playback Session: $sessionId ($songName)');
    buffer.writeln('----------------------------------------');
    for (final step in steps) {
      buffer.writeln(step);
    }
    buffer.writeln('----------------------------------------');
    buffer.writeln('Result: $result');
    buffer.writeln('========================================\n');
    debugPrint(buffer.toString());
  }
}

class CustomAudioPlayer extends AudioPlayer {
  bool _isInternal = false;

  CustomAudioPlayer()
    : super(
        audioLoadConfiguration: const AudioLoadConfiguration(
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: Duration(seconds: 20),
            maxBufferDuration: Duration(seconds: 90),
            bufferForPlaybackDuration: Duration(seconds: 3),
            bufferForPlaybackAfterRebufferDuration: Duration(seconds: 6),
            backBufferDuration: Duration(seconds: 10),
          ),
        ),
      );

  @override
  Future<void> seekToPrevious() async {
    if (_isInternal) {
      await super.seekToPrevious();
    } else {
      await PlayerService.skipPrevious();
    }
  }

  @override
  Future<void> seekToNext() async {
    if (_isInternal) {
      await super.seekToNext();
    } else {
      await PlayerService.skipNext();
    }
  }

  Future<void> superSeekToPrevious() async {
    _isInternal = true;
    try {
      await seekToPrevious();
    } finally {
      _isInternal = false;
    }
  }

  Future<void> superSeekToNext() async {
    _isInternal = true;
    try {
      await seekToNext();
    } finally {
      _isInternal = false;
    }
  }
}
