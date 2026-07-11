import '../utils/language_utils.dart';

enum AudioQuality {
  lower('lower', 48, 'Low (Data Saver)', 2.0),
  medium('medium', 96, 'Medium', 4.0),
  high('high', 160, 'High', 7.0),
  lossless('lossless', 320, 'Very High', 12.0),
  ultra('ultra', 480, 'Ultra', 18.0),
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
      case AudioQuality.lower:
        return 'Lowest storage use, about 1-2 MB per song';
      case AudioQuality.medium:
        return 'Balanced quality, about 2-4 MB per song';
      case AudioQuality.high:
        return 'Clearer audio, about 4-7 MB per song';
      case AudioQuality.lossless:
        return 'Highest standard AAC quality, about 8-12 MB per song';
      case AudioQuality.ultra:
        return 'Requests 480 kbps when available, about 12-18 MB per song';
      case AudioQuality.auto:
        return 'Adapts automatically based on your network';
    }
  }

  static AudioQuality fromStorageKey(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    switch (key) {
      case 'low':
      case 'lower':
        return AudioQuality.lower;
      case 'medium':
        return AudioQuality.medium;
      case 'good':
      case 'high':
        return AudioQuality.high;
      case 'lossless':
        return AudioQuality.lossless;
      case 'ultra':
      case 'hires':
      case 'hi_res':
      case '480':
      case '480kbps':
        return AudioQuality.ultra;
      case 'auto':
        return AudioQuality.auto;
      default:
        return AudioQuality.high;
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
  final bool mobileDataSaverEnabled;
  final bool dolbyEffectEnabled;
  final SmartConversationAssistMode smartConversationAssistMode;
  final int conversationAssistReductionPercent;
  final int conversationAssistAutoRestoreSeconds;
  final bool conversationAssistIgnoreSingleEarbud;
  final bool downloadWifiOnly;
  final bool autoDownloadPlayedSongs;
  final bool autoDownloadEnabled;
  final bool autoDownloadNewPlaylistSongs;
  final bool removeMissingPlaylistSongs;
  final bool downloadLyricsWithSongs;
  final bool predictiveDownloadEnabled;
  final bool sleepDownloadEnabled;
  final bool lowStorageProtectionEnabled;
  final bool batterySaverEnabled;
  final bool autoCleanCacheEnabled;

  UserPreferences({
    required this.uid,
    this.languages = const [],
    this.favoriteArtists = const [],
    this.displayName,
    this.email,
    this.onboardingComplete = false,
    this.autoplayEnabled = true,
    this.audioQuality = AudioQuality.high,
    this.downloadQuality = AudioQuality.high,
    this.mobileDataSaverEnabled = false,
    this.dolbyEffectEnabled = false,
    this.smartConversationAssistMode = SmartConversationAssistMode.off,
    this.conversationAssistReductionPercent = 30,
    this.conversationAssistAutoRestoreSeconds = 60,
    this.conversationAssistIgnoreSingleEarbud = false,
    this.downloadWifiOnly = true,
    this.autoDownloadPlayedSongs = false,
    this.autoDownloadEnabled = true,
    this.autoDownloadNewPlaylistSongs = true,
    this.removeMissingPlaylistSongs = true,
    this.downloadLyricsWithSongs = true,
    this.predictiveDownloadEnabled = false,
    this.sleepDownloadEnabled = false,
    this.lowStorageProtectionEnabled = true,
    this.batterySaverEnabled = false,
    this.autoCleanCacheEnabled = true,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    final rawArtists = json['favoriteArtists'] as List? ?? const [];
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
      mobileDataSaverEnabled:
          json['mobileDataSaverEnabled'] == true ||
          json['dataSaverEnabled'] == true,
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
      downloadWifiOnly: json['downloadWifiOnly'] != false,
      autoDownloadPlayedSongs: json['autoDownloadPlayedSongs'] == true || json['autoDownload'] == true,
      autoDownloadEnabled: json['autoDownloadEnabled'] != false,
      autoDownloadNewPlaylistSongs: json['autoDownloadNewPlaylistSongs'] != false,
      removeMissingPlaylistSongs: json['removeMissingPlaylistSongs'] != false,
      downloadLyricsWithSongs: json['downloadLyricsWithSongs'] != false,
      predictiveDownloadEnabled: json['predictiveDownloadEnabled'] == true,
      sleepDownloadEnabled: json['sleepDownloadEnabled'] == true,
      lowStorageProtectionEnabled: json['lowStorageProtectionEnabled'] != false,
      batterySaverEnabled: json['batterySaverEnabled'] == true,
      autoCleanCacheEnabled: json['autoCleanCacheEnabled'] != false,
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
      'mobileDataSaverEnabled': mobileDataSaverEnabled,
      'dolbyEffectEnabled': dolbyEffectEnabled,
      'smartConversationAssistMode': smartConversationAssistMode.storageKey,
      'conversationAssistReductionPercent': conversationAssistReductionPercent,
      'conversationAssistAutoRestoreSeconds':
          conversationAssistAutoRestoreSeconds,
      'conversationAssistIgnoreSingleEarbud':
          conversationAssistIgnoreSingleEarbud,
      'downloadWifiOnly': downloadWifiOnly,
      'autoDownloadPlayedSongs': autoDownloadPlayedSongs,
      'autoDownloadEnabled': autoDownloadEnabled,
      'autoDownloadNewPlaylistSongs': autoDownloadNewPlaylistSongs,
      'removeMissingPlaylistSongs': removeMissingPlaylistSongs,
      'downloadLyricsWithSongs': downloadLyricsWithSongs,
      'predictiveDownloadEnabled': predictiveDownloadEnabled,
      'sleepDownloadEnabled': sleepDownloadEnabled,
      'lowStorageProtectionEnabled': lowStorageProtectionEnabled,
      'batterySaverEnabled': batterySaverEnabled,
      'autoCleanCacheEnabled': autoCleanCacheEnabled,
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
    bool? mobileDataSaverEnabled,
    bool? dolbyEffectEnabled,
    SmartConversationAssistMode? smartConversationAssistMode,
    int? conversationAssistReductionPercent,
    int? conversationAssistAutoRestoreSeconds,
    bool? conversationAssistIgnoreSingleEarbud,
    bool? downloadWifiOnly,
    bool? autoDownloadPlayedSongs,
    bool? autoDownloadEnabled,
    bool? autoDownloadNewPlaylistSongs,
    bool? removeMissingPlaylistSongs,
    bool? downloadLyricsWithSongs,
    bool? predictiveDownloadEnabled,
    bool? sleepDownloadEnabled,
    bool? lowStorageProtectionEnabled,
    bool? batterySaverEnabled,
    bool? autoCleanCacheEnabled,
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
      mobileDataSaverEnabled:
          mobileDataSaverEnabled ?? this.mobileDataSaverEnabled,
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
      downloadWifiOnly: downloadWifiOnly ?? this.downloadWifiOnly,
      autoDownloadPlayedSongs:
          autoDownloadPlayedSongs ?? this.autoDownloadPlayedSongs,
      autoDownloadEnabled: autoDownloadEnabled ?? this.autoDownloadEnabled,
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
