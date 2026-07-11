import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_service.dart';

enum AudioOutputRouteType {
  phoneSpeaker,
  wiredHeadphones,
  bluetoothHeadphones,
  bluetoothSpeaker,
  carAudio,
  externalSpeaker,
  unknown,
}

@immutable
class AudioOutputRouteState {
  final AudioOutputRouteType type;
  final String name;
  final bool isExternal;
  final bool isBluetooth;
  final bool isHeadphones;

  const AudioOutputRouteState({
    required this.type,
    required this.name,
    required this.isExternal,
    required this.isBluetooth,
    required this.isHeadphones,
  });

  static const AudioOutputRouteState phoneSpeaker = AudioOutputRouteState(
    type: AudioOutputRouteType.phoneSpeaker,
    name: 'Phone Speaker',
    isExternal: false,
    isBluetooth: false,
    isHeadphones: false,
  );

  @override
  bool operator ==(Object other) {
    return other is AudioOutputRouteState &&
        other.type == type &&
        other.name == name &&
        other.isExternal == isExternal &&
        other.isBluetooth == isBluetooth &&
        other.isHeadphones == isHeadphones;
  }

  @override
  int get hashCode =>
      Object.hash(type, name, isExternal, isBluetooth, isHeadphones);
}

class ListeningSafetyService {
  static const String _breakReminderPrefKey =
      'listening_safety_break_reminder_enabled';
  static const String _headphoneLimitPrefKey =
      'listening_safety_headphone_limit_enabled';
  static const String _reminderHighVolumeGatePrefKey =
      'listening_safety_reminder_high_volume_gate_enabled';
  static const String _accumulatedListeningPrefKey =
      'listening_safety_accumulated_duration_ms';
  static const String _lastSyncTimestampPrefKey =
      'listening_safety_last_sync_timestamp';

  static const Duration _breakReminderAfter = Duration(minutes: 60);
  static const double _maxHeadphoneVolume = 0.5;
  static const double _reminderHighVolumeThreshold = 0.6;
  static const int _breakReminderNotificationId = 61001;

  static const String _notificationChannelId = 'listening_safety_channel';
  static const String _notificationChannelName = 'Listening Safety';
  static const String _notificationChannelDescription =
      'Listening break reminders after long playback sessions';

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final Set<AudioDeviceType> _headphoneOutputTypes = {
    AudioDeviceType.wiredHeadphones,
    AudioDeviceType.wiredHeadset,
    AudioDeviceType.bluetoothA2dp,
    AudioDeviceType.bluetoothSco,
    AudioDeviceType.bluetoothLe,
    AudioDeviceType.hearingAid,
  };

  static final Set<AudioDeviceType> _bluetoothOutputTypes = {
    AudioDeviceType.bluetoothA2dp,
    AudioDeviceType.bluetoothSco,
    AudioDeviceType.bluetoothLe,
  };

  static bool _initialized = false;
  static Future<void>? _initFuture;

  static bool _breakReminderEnabled = true;
  static bool _headphoneVolumeLimitEnabled = true;
  static bool _reminderHighVolumeGateEnabled = false;
  static bool _headphonesConnected = false;
  static String? _headphoneDeviceName;
  static bool _bluetoothHeadsetConnected = false;
  static String? _bluetoothDeviceName;
  static AudioOutputRouteState _outputDeviceState =
      AudioOutputRouteState.phoneSpeaker;

  static Duration _continuousListeningDuration = Duration.zero;
  static Duration? _lastPositionSample;
  static DateTime? _lastPositionSampleAt;
  static int _lastPersistCompleteAtTs = 0;

  static StreamSubscription<AudioDevicesChangedEvent>? _devicesSubscription;
  static StreamSubscription<double>? _volumeSubscription;
  static StreamSubscription<bool>? _playingSubscription;
  static StreamSubscription<Duration>? _positionSubscription;

  static bool get breakReminderEnabled => _breakReminderEnabled;
  static bool get headphoneVolumeLimitEnabled => _headphoneVolumeLimitEnabled;
  static bool get reminderHighVolumeGateEnabled =>
      _reminderHighVolumeGateEnabled;
  static bool get headphonesConnected => _headphonesConnected;
  static String? get headphoneDeviceName => _headphoneDeviceName;
  static bool get bluetoothHeadsetConnected => _bluetoothHeadsetConnected;
  static String? get bluetoothDeviceName => _bluetoothDeviceName;
  static AudioOutputRouteState get outputDeviceState => _outputDeviceState;
  static bool get _isReminderOutputActive => _outputDeviceState.isExternal;

  static final StreamController<bool> _headphoneStreamController =
      StreamController<bool>.broadcast();
  static Stream<bool> get headphoneStream => _headphoneStreamController.stream;
  static final StreamController<AudioOutputRouteState>
  _outputDeviceStreamController =
      StreamController<AudioOutputRouteState>.broadcast();
  static Stream<AudioOutputRouteState> get outputDeviceStream =>
      _outputDeviceStreamController.stream;

  static Future<void> init() {
    if (_initialized) return Future.value();
    _initFuture ??= _initializeInternal();
    return _initFuture!;
  }

  static Future<void> _initializeInternal() async {
    await _initializeNotifications();
    await _loadPreferences();

    final session = await AudioSession.instance;
    await _syncHeadphoneState(session);

    _devicesSubscription ??= session.devicesChangedEventStream.listen((_) {
      _syncHeadphoneState(session);
    });

    _volumeSubscription ??= PlayerService.player.volumeStream.listen((volume) {
      if (_headphonesConnected &&
          _headphoneVolumeLimitEnabled &&
          volume > _maxHeadphoneVolume) {
        unawaited(PlayerService.player.setVolume(_maxHeadphoneVolume));
      }
      _evaluateBreakReminderEligibility();
    });

    _playingSubscription ??= PlayerService.playingStream.listen((playing) {
      if (playing) {
        if (_isReminderOutputActive) {
          _startListeningTicker();
          _evaluateBreakReminderEligibility();
        }
      } else {
        _stopListeningTicker();
      }
    });
    _positionSubscription ??= PlayerService.positionStream.listen(
      _handlePositionTick,
    );

    if (PlayerService.player.playing && _isReminderOutputActive) {
      _startListeningTicker();
      _evaluateBreakReminderEligibility();
    }

    // Explicitly create the high-importance channel for Android
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _notificationChannelId,
            _notificationChannelName,
            description: _notificationChannelDescription,
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

    _initialized = true;
  }

  static Future<void> _initializeNotifications() async {
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const androidIconCandidates = <String>[
      // Prefer explicitly provided drawable icons.
      'ic_notification_mono',
      'ic_notification',
      // Fallbacks for devices/build variants where custom drawables are pruned.
      'launcher_icon',
      'ic_launcher',
    ];

    Object? lastError;
    for (final icon in androidIconCandidates) {
      try {
        final settings = InitializationSettings(
          android: AndroidInitializationSettings(icon),
          iOS: darwinSettings,
          macOS: darwinSettings,
        );
        await _notifications.initialize(settings: settings);
        await _requestNotificationPermission();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('Notification init failed with icon "$icon": $e');
      }
    }

    // Do not block app startup if notifications cannot initialize on a device.
    debugPrint(
      'Notifications disabled due to initialization failure: $lastError',
    );
  }

  static Future<void> _requestNotificationPermission() async {
    try {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();

      await _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);

      await _notifications
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }

  static Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _breakReminderEnabled = prefs.getBool(_breakReminderPrefKey) ?? true;
    _headphoneVolumeLimitEnabled =
        prefs.getBool(_headphoneLimitPrefKey) ?? true;
    _reminderHighVolumeGateEnabled =
        prefs.getBool(_reminderHighVolumeGatePrefKey) ?? false;

    final savedDurationMs = prefs.getInt(_accumulatedListeningPrefKey) ?? 0;
    final lastSyncTs = prefs.getInt(_lastSyncTimestampPrefKey) ?? 0;

    // Only restore if the last sync was within the last 2 hours (to avoid
    // resuming a session from yesterday).
    final nowTs = DateTime.now().millisecondsSinceEpoch;
    if (nowTs - lastSyncTs < const Duration(hours: 2).inMilliseconds) {
      _continuousListeningDuration = Duration(milliseconds: savedDurationMs);
    } else {
      _continuousListeningDuration = Duration.zero;
    }
  }

  static Future<void> setBreakReminderEnabled(bool enabled) async {
    await init();
    _breakReminderEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_breakReminderPrefKey, enabled);

    if (!enabled) {
      _stopListeningTicker(resetAccumulatedListening: true);
      return;
    }

    await _requestNotificationPermission();
    if (PlayerService.player.playing) {
      _startListeningTicker();
      _evaluateBreakReminderEligibility();
    }
  }

  static Future<void> setHeadphoneVolumeLimitEnabled(bool enabled) async {
    await init();
    _headphoneVolumeLimitEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_headphoneLimitPrefKey, enabled);

    if (_headphonesConnected) {
      if (enabled) {
        await _applyHeadphoneVolumeLimit();
      } else {
        await _removeHeadphoneVolumeLimit();
      }
    }
  }

  static Future<void> setReminderHighVolumeGateEnabled(bool enabled) async {
    await init();
    _reminderHighVolumeGateEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reminderHighVolumeGatePrefKey, enabled);

    if (enabled && PlayerService.player.playing) {
      _evaluateBreakReminderEligibility();
    }
  }

  static Future<void> _syncHeadphoneState(AudioSession session) async {
    try {
      final devices = await session.getDevices(
        includeInputs: false,
        includeOutputs: true,
      );

      final outputs = devices.where((device) => device.isOutput).toList();
      final headphoneDevices = outputs
          .where((device) => _headphoneOutputTypes.contains(device.type))
          .toList();
      final bluetoothDevices = outputs
          .where((device) => _bluetoothOutputTypes.contains(device.type))
          .toList();

      final nextHeadphonesConnected = headphoneDevices.isNotEmpty;
      final nextHeadphoneDeviceName = nextHeadphonesConnected
          ? headphoneDevices.first.name
          : null;
      final nextBluetoothConnected = bluetoothDevices.isNotEmpty;
      final nextBluetoothDeviceName = nextBluetoothConnected
          ? bluetoothDevices.first.name
          : null;
      final nextOutputState = _resolveOutputDeviceState(outputs);

      final shouldNotifyHeadphones =
          nextHeadphonesConnected != _headphonesConnected ||
          nextHeadphoneDeviceName != _headphoneDeviceName ||
          nextBluetoothConnected != _bluetoothHeadsetConnected ||
          nextBluetoothDeviceName != _bluetoothDeviceName;
      final previousOutputState = _outputDeviceState;
      final shouldNotifyOutputDevice = nextOutputState != previousOutputState;

      _headphonesConnected = nextHeadphonesConnected;
      _headphoneDeviceName = nextHeadphoneDeviceName;
      _bluetoothHeadsetConnected = nextBluetoothConnected;
      _bluetoothDeviceName = nextBluetoothDeviceName;
      _outputDeviceState = nextOutputState;

      if (shouldNotifyHeadphones) {
        _headphoneStreamController.add(_headphonesConnected);
      }
      if (shouldNotifyOutputDevice) {
        _outputDeviceStreamController.add(_outputDeviceState);
        _onOutputRouteChangedForReminder(previousOutputState, nextOutputState);
      }

      if (_headphonesConnected && _headphoneVolumeLimitEnabled) {
        await _applyHeadphoneVolumeLimit();
      } else if (!_headphonesConnected && _headphoneVolumeLimitEnabled) {
        await _removeHeadphoneVolumeLimit();
      }

      if (!_isReminderOutputActive) {
        _stopListeningTicker(resetAccumulatedListening: true);
      } else if (PlayerService.player.playing) {
        _startListeningTicker();
        _evaluateBreakReminderEligibility();
      }
    } catch (e) {
      debugPrint('Failed to evaluate output device state: $e');
    }
  }

  static void _startListeningTicker() {
    if (!_breakReminderEnabled || !_isReminderOutputActive) return;
    if (_lastPositionSampleAt != null) return;
    _lastPositionSample = PlayerService.player.position;
    _lastPositionSampleAt = DateTime.now();
  }

  static void _onOutputRouteChangedForReminder(
    AudioOutputRouteState previous,
    AudioOutputRouteState next,
  ) {
    final startedNewExternalSession = !previous.isExternal && next.isExternal;
    // Only reset if device type or external status actually changed.
    // Avoid resets on minor name fluctuations for the same connection.
    final switchedBetweenExternalDevices =
        previous.isExternal &&
        next.isExternal &&
        (previous.type != next.type || previous.isBluetooth != next.isBluetooth);

    if (!startedNewExternalSession && !switchedBetweenExternalDevices) return;

    // Reminder must represent the current external-device listening session.
    _continuousListeningDuration = Duration.zero;
    _lastPositionSample = PlayerService.player.position;
    _lastPositionSampleAt = DateTime.now();
    unawaited(_persistListeningDuration());
  }

  static void _stopListeningTicker({bool resetAccumulatedListening = false}) {
    _lastPositionSample = null;
    _lastPositionSampleAt = null;

    if (resetAccumulatedListening) {
      _continuousListeningDuration = Duration.zero;
      unawaited(_persistListeningDuration());
    }
  }

  static void _handlePositionTick(Duration position) {
    if (!_breakReminderEnabled ||
        !PlayerService.player.playing ||
        !_isReminderOutputActive) {
      _lastPositionSample = position;
      _lastPositionSampleAt = DateTime.now();
      return;
    }

    final previousPosition = _lastPositionSample;
    final previousAt = _lastPositionSampleAt;
    final now = DateTime.now();
    _lastPositionSample = position;
    _lastPositionSampleAt = now;

    if (previousPosition == null || previousAt == null) return;

    final positionDeltaMs =
        position.inMilliseconds - previousPosition.inMilliseconds;
    if (positionDeltaMs <= 0) return;

    final wallDeltaMs = now.difference(previousAt).inMilliseconds;
    if (wallDeltaMs <= 0) return;

    // Count only real listening time while protecting against seek jumps.
    final creditedMs = positionDeltaMs > wallDeltaMs + 1500
        ? wallDeltaMs + 1500
        : positionDeltaMs;
    if (creditedMs > 0) {
      _continuousListeningDuration += Duration(milliseconds: creditedMs);
    }

    _evaluateBreakReminderEligibility();

    // Persist to disk at most once per minute to save battery.
    final nowTs = now.millisecondsSinceEpoch;
    if (nowTs - _lastPersistCompleteAtTs >= 60000) {
      _lastPersistCompleteAtTs = nowTs;
      unawaited(_persistListeningDuration());
    }
  }

  static Future<void> _persistListeningDuration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _accumulatedListeningPrefKey,
        _continuousListeningDuration.inMilliseconds,
      );
      await prefs.setInt(
        _lastSyncTimestampPrefKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static void _evaluateBreakReminderEligibility() {
    if (!_breakReminderEnabled ||
        !PlayerService.player.playing ||
        !_isReminderOutputActive) {
      return;
    }
    if (_continuousListeningDuration < _breakReminderAfter) return;

    final currentVolume = PlayerService.player.volume;
    var gateThreshold = _reminderHighVolumeThreshold;
    if (_headphonesConnected &&
        _headphoneVolumeLimitEnabled &&
        gateThreshold > _maxHeadphoneVolume) {
      // Avoid impossible config: a 60% gate with a 50% headphone cap.
      gateThreshold = _maxHeadphoneVolume;
    }
    if (_reminderHighVolumeGateEnabled && currentVolume < gateThreshold) {
      return;
    }

    _continuousListeningDuration = Duration.zero;
    _lastPositionSample = PlayerService.player.position;
    _lastPositionSampleAt = DateTime.now();
    unawaited(_showBreakReminderNotification());
  }

  static Future<void> _showBreakReminderNotification() async {
    if (!_breakReminderEnabled) return;
    final permissionGranted = await _ensureNotificationPermission();
    if (!permissionGranted) {
      debugPrint(
        'Listening safety notification skipped: notification permission denied.',
      );
      return;
    }

    final outputLabel = _outputDeviceState.name.trim();
    final hasOutputName = outputLabel.isNotEmpty;
    final title = 'Time for an ear break';
    final body = hasOutputName
        ? 'You have listened for about 60 minutes on $outputLabel. '
              'Please rest for 10-20 minutes.'
        : 'You have listened for about 60 minutes. Please rest for 10-20 '
              'minutes.';

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        _notificationChannelId,
        _notificationChannelName,
        channelDescription: _notificationChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    try {
      await _notifications.show(
        id: _breakReminderNotificationId,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
      );
    } catch (e) {
      debugPrint('Failed to show listening safety notification: $e');
    }
  }

  static Future<bool> _ensureNotificationPermission() async {
    try {
      final androidNotifications = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidNotifications != null) {
        final enabled = await androidNotifications.areNotificationsEnabled();
        if (enabled == true) return true;
        final granted = await androidNotifications
            .requestNotificationsPermission();
        return granted == true;
      }
      return true;
    } catch (e) {
      debugPrint('Notification permission availability check failed: $e');
      return true;
    }
  }

  static Future<void> _applyHeadphoneVolumeLimit() async {
    final currentVolume = PlayerService.player.volume;
    if (currentVolume <= _maxHeadphoneVolume) return;
    await PlayerService.player.setVolume(_maxHeadphoneVolume);
  }

  static Future<void> _removeHeadphoneVolumeLimit() async {
    if (PlayerService.player.volume >= 1.0) return;
    await PlayerService.player.setVolume(1.0);
  }

  static Future<void> dispose() async {
    await _devicesSubscription?.cancel();
    await _volumeSubscription?.cancel();
    await _playingSubscription?.cancel();
    await _positionSubscription?.cancel();
    _devicesSubscription = null;
    _volumeSubscription = null;
    _playingSubscription = null;
    _positionSubscription = null;
    _stopListeningTicker(resetAccumulatedListening: true);

    _headphonesConnected = false;
    _headphoneDeviceName = null;
    _bluetoothHeadsetConnected = false;
    _bluetoothDeviceName = null;
    _outputDeviceState = AudioOutputRouteState.phoneSpeaker;

    _initialized = false;
    _initFuture = null;
  }

  static AudioOutputRouteState _resolveOutputDeviceState(
    List<AudioDevice> outputs,
  ) {
    if (outputs.isEmpty) return AudioOutputRouteState.phoneSpeaker;

    final carDevice = _firstDevice(outputs, _isCarOutput);
    if (carDevice != null) {
      return _buildOutputState(
        carDevice,
        type: AudioOutputRouteType.carAudio,
        fallbackName: 'Car Audio',
        isExternal: true,
        isBluetooth: _isBluetoothOutput(carDevice),
        isHeadphones: false,
      );
    }

    final bluetoothHeadphones = _firstDevice(
      outputs,
      (device) => _isBluetoothOutput(device) && _isHeadphoneOutput(device),
    );
    if (bluetoothHeadphones != null) {
      return _buildOutputState(
        bluetoothHeadphones,
        type: AudioOutputRouteType.bluetoothHeadphones,
        fallbackName: 'Bluetooth Headphones',
        isExternal: true,
        isBluetooth: true,
        isHeadphones: true,
      );
    }

    final wiredHeadphones = _firstDevice(
      outputs,
      (device) => !_isBluetoothOutput(device) && _isHeadphoneOutput(device),
    );
    if (wiredHeadphones != null) {
      return _buildOutputState(
        wiredHeadphones,
        type: AudioOutputRouteType.wiredHeadphones,
        fallbackName: 'Wired Headphones',
        isExternal: true,
        isBluetooth: false,
        isHeadphones: true,
      );
    }

    final bluetoothSpeaker = _firstDevice(
      outputs,
      (device) =>
          _isBluetoothOutput(device) &&
          !_isHeadphoneOutput(device) &&
          !_isCarOutput(device),
    );
    if (bluetoothSpeaker != null) {
      return _buildOutputState(
        bluetoothSpeaker,
        type: AudioOutputRouteType.bluetoothSpeaker,
        fallbackName: 'Bluetooth Speaker',
        isExternal: true,
        isBluetooth: true,
        isHeadphones: false,
      );
    }

    final externalSpeaker = _firstDevice(outputs, _isExternalSpeakerOutput);
    if (externalSpeaker != null) {
      return _buildOutputState(
        externalSpeaker,
        type: AudioOutputRouteType.externalSpeaker,
        fallbackName: 'External Speaker',
        isExternal: true,
        isBluetooth: _isBluetoothOutput(externalSpeaker),
        isHeadphones: false,
      );
    }

    final phoneSpeaker = _firstDevice(outputs, _isPhoneSpeakerOutput);
    if (phoneSpeaker != null) {
      return _buildOutputState(
        phoneSpeaker,
        type: AudioOutputRouteType.phoneSpeaker,
        fallbackName: 'Phone Speaker',
        isExternal: false,
        isBluetooth: false,
        isHeadphones: false,
      );
    }

    return _buildOutputState(
      outputs.first,
      type: AudioOutputRouteType.unknown,
      fallbackName: 'Audio Output',
      isExternal: true,
      isBluetooth: _isBluetoothOutput(outputs.first),
      isHeadphones: false,
    );
  }

  static AudioOutputRouteState _buildOutputState(
    AudioDevice device, {
    required AudioOutputRouteType type,
    required String fallbackName,
    required bool isExternal,
    required bool isBluetooth,
    required bool isHeadphones,
  }) {
    final cleanedName = _cleanDeviceName(device.name);
    return AudioOutputRouteState(
      type: type,
      name: cleanedName.isEmpty ? fallbackName : cleanedName,
      isExternal: isExternal,
      isBluetooth: isBluetooth,
      isHeadphones: isHeadphones,
    );
  }

  static AudioDevice? _firstDevice(
    List<AudioDevice> outputs,
    bool Function(AudioDevice) predicate,
  ) {
    for (final device in outputs) {
      if (predicate(device)) return device;
    }
    return null;
  }

  static bool _isBluetoothOutput(AudioDevice device) {
    return _bluetoothOutputTypes.contains(device.type) ||
        device.type.name.toLowerCase().contains('bluetooth');
  }

  static bool _isHeadphoneOutput(AudioDevice device) {
    if (device.type == AudioDeviceType.wiredHeadphones ||
        device.type == AudioDeviceType.wiredHeadset ||
        device.type == AudioDeviceType.hearingAid) {
      return true;
    }
    final descriptor = _deviceDescriptor(device);
    return _containsAny(descriptor, const [
      'headphone',
      'headset',
      'earbud',
      'earphone',
      'airpod',
      'buds',
      'hearing aid',
      'iems',
      'iem',
    ]);
  }

  static bool _isCarOutput(AudioDevice device) {
    final descriptor = _deviceDescriptor(device);
    return _containsAny(descriptor, const [
      'car',
      'automotive',
      'android auto',
      'carplay',
      'vehicle',
      'handsfree',
      'hands-free',
    ]);
  }

  static bool _isPhoneSpeakerOutput(AudioDevice device) {
    final descriptor = _deviceDescriptor(device);
    return _containsAny(descriptor, const [
      'built in',
      'builtin',
      'phone speaker',
      'speakerphone',
      'receiver',
      'earpiece',
      'handset',
    ]);
  }

  static bool _isExternalSpeakerOutput(AudioDevice device) {
    if (_isHeadphoneOutput(device) ||
        _isCarOutput(device) ||
        _isPhoneSpeakerOutput(device)) {
      return false;
    }
    final descriptor = _deviceDescriptor(device);
    return _containsAny(descriptor, const [
      'speaker',
      'soundbar',
      'homepod',
      'echo',
      'nest',
      'boombox',
      'sonos',
      'tv',
      'chromecast',
      'cast',
      'airplay',
      'dock',
      'hdmi',
      'usb',
      'line out',
      'lineout',
      'aux',
    ]);
  }

  static String _cleanDeviceName(String? name) {
    final normalized = (name ?? '').trim();
    final lower = normalized.toLowerCase();
    if (lower.isEmpty || lower == 'unknown') return '';
    return normalized;
  }

  static String _deviceDescriptor(AudioDevice device) {
    final name = _cleanDeviceName(device.name).toLowerCase();
    final typeName = device.type.name.toLowerCase();
    if (name.isEmpty) return typeName;
    return '$name $typeName';
  }

  static bool _containsAny(String value, List<String> needles) {
    for (final needle in needles) {
      if (value.contains(needle)) return true;
    }
    return false;
  }
}
