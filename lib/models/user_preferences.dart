import '../utils/language_utils.dart';

enum AudioQuality {
  dataSaver('data_saver', 32, 'Data Saver (32 kbps)', 1.0),
  low('low', 64, 'Low (64 kbps)', 2.0),
  normal('normal', 96, 'Normal (96 kbps)', 3.0),
  high('high', 160, 'High (160 kbps)', 5.0),
  veryHigh('very_high', 320, 'Very High (320 kbps)', 10.0),
  auto('auto', 0, 'Auto (Smart Adaptive)', 0.0);

  const AudioQuality(this.storageKey, this.kbps, this.label, this.maxMb);

  final String storageKey;
  final int kbps;
  final String label;

  /// Maximum data usage per song in MB. 0.0 = no cap (auto chooses dynamically).
  final double maxMb;

  /// Short description of when each quality level is used.
  String get description {
    switch (this) {
      case AudioQuality.dataSaver:
        return 'Minimal data, about 1 MB per song';
      case AudioQuality.low:
        return 'Low quality, about 2 MB per song';
      case AudioQuality.normal:
        return 'Balanced quality, about 3 MB per song';
      case AudioQuality.high:
        return 'Clearer audio, about 5 MB per song';
      case AudioQuality.veryHigh:
        return 'Highest quality, about 9-10 MB per song';
      case AudioQuality.auto:
        return 'Adapts automatically based on your network';
    }
  }

  /// Migrate from legacy storage keys to new enum values.
  static AudioQuality fromStorageKey(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    switch (key) {
      // New keys
      case 'data_saver':
      case 'datasaver':
        return AudioQuality.dataSaver;
      case 'low':
        return AudioQuality.low;
      case 'normal':
        return AudioQuality.normal;
      case 'high':
        return AudioQuality.high;
      case 'very_high':
      case 'veryhigh':
        return AudioQuality.veryHigh;
      case 'auto':
        return AudioQuality.auto;
      // Legacy migration keys
      case 'lower':
        return AudioQuality.low; // 48 kbps → 64 kbps (closest tier)
      case 'medium':
        return AudioQuality.normal; // 96 kbps → 96 kbps
      case 'good':
        return AudioQuality.high; // → 160 kbps
      case 'lossless':
        return AudioQuality.veryHigh; // 320 kbps → 320 kbps
      case 'ultra':
      case 'hires':
      case 'hi_res':
      case '480':
      case '480kbps':
        return AudioQuality.veryHigh; // 480 kbps → 320 kbps (capped)
      default:
        return AudioQuality.high;
    }
  }
}

/// Controls when background downloads are allowed.
enum BackgroundDownloadMode {
  alwaysOn('always_on', 'Always On'),
  wifiOnly('wifi_only', 'Wi-Fi Only'),
  onlyWhileCharging('only_while_charging', 'Only While Charging'),
  disabled('disabled', 'Disabled');

  const BackgroundDownloadMode(this.storageKey, this.label);

  final String storageKey;
  final String label;

  String get description {
    switch (this) {
      case BackgroundDownloadMode.alwaysOn:
        return 'Downloads run in the background over any network';
      case BackgroundDownloadMode.wifiOnly:
        return 'Downloads only when connected to Wi-Fi';
      case BackgroundDownloadMode.onlyWhileCharging:
        return 'Downloads only when the device is charging';
      case BackgroundDownloadMode.disabled:
        return 'Downloads pause when the app is in the background';
    }
  }

  static BackgroundDownloadMode fromStorageKey(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    switch (key) {
      case 'always_on':
      case 'alwayson':
        return BackgroundDownloadMode.alwaysOn;
      case 'wifi_only':
      case 'wifionly':
        return BackgroundDownloadMode.wifiOnly;
      case 'only_while_charging':
      case 'onlywhilecharging':
      case 'charging':
        return BackgroundDownloadMode.onlyWhileCharging;
      case 'disabled':
      case 'off':
        return BackgroundDownloadMode.disabled;
      default:
        return BackgroundDownloadMode.wifiOnly;
    }
  }
}

enum SmartConversationAssistMode {
  off('off', 'Off'),
  manualOnly('manual_only', 'Manual Only'),
  automatic('automatic', 'Automatic');

  const SmartConversationAssistMode(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static SmartConversationAssistMode fromStorageKey(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    switch (key) {
      case 'manual':
      case 'manual_only':
      case 'manualonly':
        return SmartConversationAssistMode.manualOnly;
      case 'auto':
      case 'automatic':
        return SmartConversationAssistMode.automatic;
      case 'off':
      default:
        return SmartConversationAssistMode.off;
    }
  }
}

class UserPreferences {
  final String uid;
  final List<String> languages;
  final List<Map<String, String>> favoriteArtists;
  final String? displayName;
  final String? email;
  final bool onboardingComplete;
  final bool autoplayEnabled;
  final AudioQuality audioQuality;
  final AudioQuality downloadQuality;
  final bool dataSaverEnabled;
  final bool dolbyEffectEnabled;
  final SmartConversationAssistMode smartConversationAssistMode;
  final int conversationAssistReductionPercent;
  final int conversationAssistAutoRestoreSeconds;
  final bool conversationAssistIgnoreSingleEarbud;
  final BackgroundDownloadMode backgroundDownloadMode;
  final bool smartDownloadEnabled;
  final bool prefetchNextSongEnabled;
  final bool autoDownloadPlayedSongs;
  final bool autoDownloadNewPlaylistSongs;
  final bool removeMissingPlaylistSongs;
  final bool downloadLyricsWithSongs;
  final bool predictiveDownloadEnabled;
  final bool sleepDownloadEnabled;
  final bool lowStorageProtectionEnabled;
  final bool batterySaverEnabled;
  final bool autoCleanCacheEnabled;
  final bool offlinePlaybackEnabled;
  final bool skipUnavailableOffline;
  final bool allowStreamingFallback;

  UserPreferences({
    required this.uid,
    this.languages = const [],
    this.favoriteArtists = const [],
    this.displayName,
    this.email,
    this.onboardingComplete = false,
    this.autoplayEnabled = true,
    this.audioQuality = AudioQuality.auto,
    this.downloadQuality = AudioQuality.high,
    this.dataSaverEnabled = false,
    this.dolbyEffectEnabled = false,
    this.smartConversationAssistMode = SmartConversationAssistMode.off,
    this.conversationAssistReductionPercent = 30,
    this.conversationAssistAutoRestoreSeconds = 60,
    this.conversationAssistIgnoreSingleEarbud = false,
    this.backgroundDownloadMode = BackgroundDownloadMode.wifiOnly,
    this.smartDownloadEnabled = false,
    this.prefetchNextSongEnabled = true,
    this.autoDownloadPlayedSongs = false,
    this.autoDownloadNewPlaylistSongs = true,
    this.removeMissingPlaylistSongs = true,
    this.downloadLyricsWithSongs = true,
    this.predictiveDownloadEnabled = false,
    this.sleepDownloadEnabled = false,
    this.lowStorageProtectionEnabled = true,
    this.batterySaverEnabled = false,
    this.autoCleanCacheEnabled = true,
    this.offlinePlaybackEnabled = true,
    this.skipUnavailableOffline = true,
    this.allowStreamingFallback = true,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    final rawArtists = json['favoriteArtists'] as List? ?? const [];

    // --- Migrate legacy background download fields ---
    // Old field: downloadWifiOnly (bool) → new: backgroundDownloadMode enum
    // Old field: autoDownloadEnabled (bool) → new: smartDownloadEnabled
    BackgroundDownloadMode bgMode;
    if (json.containsKey('backgroundDownloadMode')) {
      bgMode = BackgroundDownloadMode.fromStorageKey(
        json['backgroundDownloadMode']?.toString(),
      );
    } else if (json.containsKey('downloadWifiOnly')) {
      // Legacy migration: downloadWifiOnly=true → wifiOnly, false → alwaysOn
      bgMode = json['downloadWifiOnly'] == true
          ? BackgroundDownloadMode.wifiOnly
          : BackgroundDownloadMode.alwaysOn;
    } else {
      bgMode = BackgroundDownloadMode.wifiOnly;
    }

    // Migrate smartDownloadEnabled from old autoDownloadEnabled
    final smartDownload = json['smartDownloadEnabled'] ??
        json['autoDownloadEnabled'] ??
        false;

    // Migrate dataSaverEnabled from old mobileDataSaverEnabled
    final dataSaver = json['dataSaverEnabled'] == true ||
        json['mobileDataSaverEnabled'] == true;

    return UserPreferences(
      uid: json['uid'] ?? '',
      languages: LanguageUtils.normalizeLanguageList(
        List<String>.from(json['languages'] ?? const []),
      ),
      favoriteArtists: rawArtists
          .whereType<Map>()
          .map(
            (artist) => {
              'id': artist['id']?.toString() ?? '',
              'name': artist['name']?.toString() ?? '',
            },
          )
          .where(
            (artist) => artist['id']!.isNotEmpty || artist['name']!.isNotEmpty,
          )
          .toList(),
      displayName: json['displayName'],
      email: json['email'],
      onboardingComplete: json['onboardingComplete'] == true,
      autoplayEnabled: json['autoplayEnabled'] ?? true,
      audioQuality: AudioQuality.fromStorageKey(
        json['audioQuality']?.toString(),
      ),
      downloadQuality: AudioQuality.fromStorageKey(
        json['downloadQuality']?.toString(),
      ),
      dataSaverEnabled: dataSaver,
      dolbyEffectEnabled:
          json['dolbyEffectEnabled'] == true ||
          json['dolbyLikeEffectEnabled'] == true ||
          json['spatialAudioEnabled'] == true,
      smartConversationAssistMode: SmartConversationAssistMode.fromStorageKey(
        json['smartConversationAssistMode']?.toString() ??
            json['conversationAssistMode']?.toString(),
      ),
      conversationAssistReductionPercent: _clampInt(
        json['conversationAssistReductionPercent'] ??
            json['conversationAssistVolumePercent'],
        defaultValue: 30,
        min: 20,
        max: 80,
      ),
      conversationAssistAutoRestoreSeconds: _clampInt(
        json['conversationAssistAutoRestoreSeconds'] ??
            json['conversationAssistRestoreSeconds'],
        defaultValue: 60,
        min: 15,
        max: 300,
      ),
      conversationAssistIgnoreSingleEarbud:
          json['conversationAssistIgnoreSingleEarbud'] == true,
      backgroundDownloadMode: bgMode,
      smartDownloadEnabled: smartDownload == true,
      prefetchNextSongEnabled: json['prefetchNextSongEnabled'] != false,
      autoDownloadPlayedSongs: json['autoDownloadPlayedSongs'] == true || json['autoDownload'] == true,
      autoDownloadNewPlaylistSongs: json['autoDownloadNewPlaylistSongs'] != false,
      removeMissingPlaylistSongs: json['removeMissingPlaylistSongs'] != false,
      downloadLyricsWithSongs: json['downloadLyricsWithSongs'] != false,
      predictiveDownloadEnabled: json['predictiveDownloadEnabled'] == true,
      sleepDownloadEnabled: json['sleepDownloadEnabled'] == true,
      lowStorageProtectionEnabled: json['lowStorageProtectionEnabled'] != false,
      batterySaverEnabled: json['batterySaverEnabled'] == true,
      autoCleanCacheEnabled: json['autoCleanCacheEnabled'] != false,
      offlinePlaybackEnabled: json['offlinePlaybackEnabled'] ?? true,
      skipUnavailableOffline: json['skipUnavailableOffline'] ?? true,
      allowStreamingFallback: json['allowStreamingFallback'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'languages': LanguageUtils.normalizeLanguageList(languages),
      'favoriteArtists': favoriteArtists,
      'displayName': displayName,
      'email': email,
      'onboardingComplete': onboardingComplete,
      'autoplayEnabled': autoplayEnabled,
      'audioQuality': audioQuality.storageKey,
      'downloadQuality': downloadQuality.storageKey,
      'dataSaverEnabled': dataSaverEnabled,
      'dolbyEffectEnabled': dolbyEffectEnabled,
      'smartConversationAssistMode': smartConversationAssistMode.storageKey,
      'conversationAssistReductionPercent': conversationAssistReductionPercent,
      'conversationAssistAutoRestoreSeconds':
          conversationAssistAutoRestoreSeconds,
      'conversationAssistIgnoreSingleEarbud':
          conversationAssistIgnoreSingleEarbud,
      'backgroundDownloadMode': backgroundDownloadMode.storageKey,
      'smartDownloadEnabled': smartDownloadEnabled,
      'prefetchNextSongEnabled': prefetchNextSongEnabled,
      'autoDownloadPlayedSongs': autoDownloadPlayedSongs,
      'autoDownloadNewPlaylistSongs': autoDownloadNewPlaylistSongs,
      'removeMissingPlaylistSongs': removeMissingPlaylistSongs,
      'downloadLyricsWithSongs': downloadLyricsWithSongs,
      'predictiveDownloadEnabled': predictiveDownloadEnabled,
      'sleepDownloadEnabled': sleepDownloadEnabled,
      'lowStorageProtectionEnabled': lowStorageProtectionEnabled,
      'batterySaverEnabled': batterySaverEnabled,
      'autoCleanCacheEnabled': autoCleanCacheEnabled,
      'offlinePlaybackEnabled': offlinePlaybackEnabled,
      'skipUnavailableOffline': skipUnavailableOffline,
      'allowStreamingFallback': allowStreamingFallback,
    };
  }

  UserPreferences copyWith({
    List<String>? languages,
    List<Map<String, String>>? favoriteArtists,
    String? displayName,
    String? email,
    bool? onboardingComplete,
    bool? autoplayEnabled,
    AudioQuality? audioQuality,
    AudioQuality? downloadQuality,
    bool? dataSaverEnabled,
    bool? dolbyEffectEnabled,
    SmartConversationAssistMode? smartConversationAssistMode,
    int? conversationAssistReductionPercent,
    int? conversationAssistAutoRestoreSeconds,
    bool? conversationAssistIgnoreSingleEarbud,
    BackgroundDownloadMode? backgroundDownloadMode,
    bool? smartDownloadEnabled,
    bool? prefetchNextSongEnabled,
    bool? autoDownloadPlayedSongs,
    bool? autoDownloadNewPlaylistSongs,
    bool? removeMissingPlaylistSongs,
    bool? downloadLyricsWithSongs,
    bool? predictiveDownloadEnabled,
    bool? sleepDownloadEnabled,
    bool? lowStorageProtectionEnabled,
    bool? batterySaverEnabled,
    bool? autoCleanCacheEnabled,
    bool? offlinePlaybackEnabled,
    bool? skipUnavailableOffline,
    bool? allowStreamingFallback,
  }) {
    return UserPreferences(
      uid: uid,
      languages: LanguageUtils.normalizeLanguageList(
        languages ?? this.languages,
      ),
      favoriteArtists: favoriteArtists ?? this.favoriteArtists,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      autoplayEnabled: autoplayEnabled ?? this.autoplayEnabled,
      audioQuality: audioQuality ?? this.audioQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      dataSaverEnabled:
          dataSaverEnabled ?? this.dataSaverEnabled,
      dolbyEffectEnabled: dolbyEffectEnabled ?? this.dolbyEffectEnabled,
      smartConversationAssistMode:
          smartConversationAssistMode ?? this.smartConversationAssistMode,
      conversationAssistReductionPercent:
          (conversationAssistReductionPercent ??
                  this.conversationAssistReductionPercent)
              .clamp(20, 80)
              .toInt(),
      conversationAssistAutoRestoreSeconds:
          (conversationAssistAutoRestoreSeconds ??
                  this.conversationAssistAutoRestoreSeconds)
              .clamp(15, 300)
              .toInt(),
      conversationAssistIgnoreSingleEarbud:
          conversationAssistIgnoreSingleEarbud ??
          this.conversationAssistIgnoreSingleEarbud,
      backgroundDownloadMode:
          backgroundDownloadMode ?? this.backgroundDownloadMode,
      smartDownloadEnabled:
          smartDownloadEnabled ?? this.smartDownloadEnabled,
      prefetchNextSongEnabled:
          prefetchNextSongEnabled ?? this.prefetchNextSongEnabled,
      autoDownloadPlayedSongs:
          autoDownloadPlayedSongs ?? this.autoDownloadPlayedSongs,
      autoDownloadNewPlaylistSongs:
          autoDownloadNewPlaylistSongs ?? this.autoDownloadNewPlaylistSongs,
      removeMissingPlaylistSongs:
          removeMissingPlaylistSongs ?? this.removeMissingPlaylistSongs,
      downloadLyricsWithSongs:
          downloadLyricsWithSongs ?? this.downloadLyricsWithSongs,
      predictiveDownloadEnabled:
          predictiveDownloadEnabled ?? this.predictiveDownloadEnabled,
      sleepDownloadEnabled: sleepDownloadEnabled ?? this.sleepDownloadEnabled,
      lowStorageProtectionEnabled:
          lowStorageProtectionEnabled ?? this.lowStorageProtectionEnabled,
      batterySaverEnabled: batterySaverEnabled ?? this.batterySaverEnabled,
      autoCleanCacheEnabled:
          autoCleanCacheEnabled ?? this.autoCleanCacheEnabled,
      offlinePlaybackEnabled:
          offlinePlaybackEnabled ?? this.offlinePlaybackEnabled,
      skipUnavailableOffline:
          skipUnavailableOffline ?? this.skipUnavailableOffline,
      allowStreamingFallback:
          allowStreamingFallback ?? this.allowStreamingFallback,
    );
  }

  static int _clampInt(
    dynamic value, {
    required int defaultValue,
    required int min,
    required int max,
  }) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null) return defaultValue;
    return parsed.clamp(min, max).toInt();
  }
}
