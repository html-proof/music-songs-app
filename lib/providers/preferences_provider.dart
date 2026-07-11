import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/user_preferences.dart';
import '../services/listening_safety_service.dart';
import '../services/player_service.dart';
import '../services/preferences_service.dart';
import '../utils/language_utils.dart';

class PreferencesProvider extends ChangeNotifier {
  User? _currentUser;
  UserPreferences? _preferences;
  bool _loading = true;
  int _version = 0;
  int _syncToken = 0;

  UserPreferences? get preferences => _preferences;
  bool get loading => _loading;
  int get version => _version;
  bool get hasCompletedOnboarding => _preferences?.onboardingComplete == true;
  List<String> get languages => _preferences?.languages ?? const [];
  List<Map<String, String>> get favoriteArtists =>
      _preferences?.favoriteArtists ?? const [];
  bool get breakReminderEnabled => ListeningSafetyService.breakReminderEnabled;
  bool get headphoneVolumeLimitEnabled =>
      ListeningSafetyService.headphoneVolumeLimitEnabled;
  bool get reminderHighVolumeGateEnabled =>
      ListeningSafetyService.reminderHighVolumeGateEnabled;
  bool get autoplayEnabled => _preferences?.autoplayEnabled ?? true;
  AudioQuality get audioQuality =>
      _preferences?.audioQuality ?? AudioQuality.high;
  AudioQuality get downloadQuality =>
      _preferences?.downloadQuality ?? AudioQuality.high;
  bool get mobileDataSaverEnabled =>
      _preferences?.mobileDataSaverEnabled ?? false;
  bool get dolbyEffectEnabled => _preferences?.dolbyEffectEnabled ?? false;
  SmartConversationAssistMode get smartConversationAssistMode =>
      _preferences?.smartConversationAssistMode ??
      SmartConversationAssistMode.off;
  int get conversationAssistReductionPercent =>
      _preferences?.conversationAssistReductionPercent ?? 30;
  int get conversationAssistAutoRestoreSeconds =>
      _preferences?.conversationAssistAutoRestoreSeconds ?? 60;
  bool get conversationAssistIgnoreSingleEarbud =>
      _preferences?.conversationAssistIgnoreSingleEarbud ?? false;
  bool get downloadWifiOnly => _preferences?.downloadWifiOnly ?? true;
  bool get autoDownloadPlayedSongs => _preferences?.autoDownloadPlayedSongs ?? false;
  bool get autoDownloadEnabled => _preferences?.autoDownloadEnabled ?? true;
  bool get autoDownloadNewPlaylistSongs => _preferences?.autoDownloadNewPlaylistSongs ?? true;
  bool get removeMissingPlaylistSongs => _preferences?.removeMissingPlaylistSongs ?? true;
  bool get downloadLyricsWithSongs => _preferences?.downloadLyricsWithSongs ?? true;
  bool get predictiveDownloadEnabled => _preferences?.predictiveDownloadEnabled ?? false;
  bool get sleepDownloadEnabled => _preferences?.sleepDownloadEnabled ?? false;
  bool get lowStorageProtectionEnabled => _preferences?.lowStorageProtectionEnabled ?? true;
  bool get batterySaverEnabled => _preferences?.batterySaverEnabled ?? false;
  bool get autoCleanCacheEnabled => _preferences?.autoCleanCacheEnabled ?? true;

  void syncWithAuth(User? user) {
    final nextUid = user?.uid;
    final currentUid = _currentUser?.uid;
    if (nextUid == currentUid && !_loading) return;
    _currentUser = user;
    _syncToken++;
    _loadCurrentUserPreferences(_syncToken);
  }

  Future<void> reload() async {
    _syncToken++;
    await _loadCurrentUserPreferences(_syncToken);
  }

  Future<void> _loadCurrentUserPreferences(int token) async {
    _loading = true;
    notifyListeners();

    final user = _currentUser;
    if (user == null) {
      if (token != _syncToken) return;
      _preferences = null;
      await PlayerService.setAudioQualityPreference(
        AudioQuality.high,
        applyNow: true,
      );
      await PlayerService.setMobileDataSaverEnabled(false, applyNow: true);
      await PlayerService.setDolbyEffectEnabled(false, applyNow: true);
      await PlayerService.setSmartConversationAssistConfig(
        mode: SmartConversationAssistMode.off,
        reductionPercent: 30,
        autoRestoreSeconds: 60,
        ignoreSingleEarbud: false,
      );
      _loading = false;
      _version++;
      notifyListeners();
      return;
    }

    final stored = await PreferencesService.getPreferences(user.uid);
    if (token != _syncToken) return;

    _preferences =
        stored ??
        UserPreferences(
          uid: user.uid,
          languages: const [],
          favoriteArtists: const [],
          displayName: user.displayName,
          email: user.email,
          onboardingComplete: false,
        );
    await PlayerService.setAudioQualityPreference(
      _preferences?.audioQuality ?? AudioQuality.high,
      applyNow: false,
    );
    await PlayerService.setMobileDataSaverEnabled(
      _preferences?.mobileDataSaverEnabled ?? false,
      applyNow: false,
    );
    await PlayerService.setDolbyEffectEnabled(
      _preferences?.dolbyEffectEnabled ?? false,
      applyNow: false,
    );
    await PlayerService.setSmartConversationAssistConfig(
      mode:
          _preferences?.smartConversationAssistMode ??
          SmartConversationAssistMode.off,
      reductionPercent: _preferences?.conversationAssistReductionPercent ?? 30,
      autoRestoreSeconds:
          _preferences?.conversationAssistAutoRestoreSeconds ?? 60,
      ignoreSingleEarbud:
          _preferences?.conversationAssistIgnoreSingleEarbud ?? false,
    );
    await PlayerService.applyPreferredAudioQuality();
    _loading = false;
    _version++;
    notifyListeners();
  }

  Future<void> savePreferences({
    required List<String> languages,
    required List<Map<String, String>> favoriteArtists,
    bool onboardingComplete = true,
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
  }) async {
    final user = _currentUser;
    if (user == null) return;

    final normalizedLanguages = LanguageUtils.normalizeLanguageList(languages);

    final normalizedArtists = favoriteArtists
        .map(
          (artist) => {
            'id': (artist['id'] ?? '').trim(),
            'name': (artist['name'] ?? '').trim(),
          },
        )
        .where(
          (artist) => artist['id']!.isNotEmpty || artist['name']!.isNotEmpty,
        )
        .toList();

    final updated = UserPreferences(
      uid: user.uid,
      languages: normalizedLanguages,
      favoriteArtists: normalizedArtists,
      displayName: user.displayName,
      email: user.email,
      onboardingComplete: onboardingComplete,
      autoplayEnabled: autoplayEnabled ?? _preferences?.autoplayEnabled ?? true,
      audioQuality:
          audioQuality ?? _preferences?.audioQuality ?? AudioQuality.high,
      downloadQuality:
          downloadQuality ?? _preferences?.downloadQuality ?? AudioQuality.high,
      mobileDataSaverEnabled:
          mobileDataSaverEnabled ??
          _preferences?.mobileDataSaverEnabled ??
          false,
      dolbyEffectEnabled:
          dolbyEffectEnabled ?? _preferences?.dolbyEffectEnabled ?? false,
      smartConversationAssistMode:
          smartConversationAssistMode ??
          _preferences?.smartConversationAssistMode ??
          SmartConversationAssistMode.off,
      conversationAssistReductionPercent:
          conversationAssistReductionPercent ??
          _preferences?.conversationAssistReductionPercent ??
          30,
      conversationAssistAutoRestoreSeconds:
          conversationAssistAutoRestoreSeconds ??
          _preferences?.conversationAssistAutoRestoreSeconds ??
          60,
      conversationAssistIgnoreSingleEarbud:
          conversationAssistIgnoreSingleEarbud ??
          _preferences?.conversationAssistIgnoreSingleEarbud ??
          false,
      downloadWifiOnly:
          downloadWifiOnly ?? _preferences?.downloadWifiOnly ?? true,
      autoDownloadPlayedSongs:
          autoDownloadPlayedSongs ?? _preferences?.autoDownloadPlayedSongs ?? false,
      autoDownloadEnabled:
          autoDownloadEnabled ?? _preferences?.autoDownloadEnabled ?? true,
      autoDownloadNewPlaylistSongs:
          autoDownloadNewPlaylistSongs ?? _preferences?.autoDownloadNewPlaylistSongs ?? true,
      removeMissingPlaylistSongs:
          removeMissingPlaylistSongs ?? _preferences?.removeMissingPlaylistSongs ?? true,
      downloadLyricsWithSongs:
          downloadLyricsWithSongs ?? _preferences?.downloadLyricsWithSongs ?? true,
      predictiveDownloadEnabled:
          predictiveDownloadEnabled ?? _preferences?.predictiveDownloadEnabled ?? false,
      sleepDownloadEnabled:
          sleepDownloadEnabled ?? _preferences?.sleepDownloadEnabled ?? false,
      lowStorageProtectionEnabled:
          lowStorageProtectionEnabled ?? _preferences?.lowStorageProtectionEnabled ?? true,
      batterySaverEnabled:
          batterySaverEnabled ?? _preferences?.batterySaverEnabled ?? false,
      autoCleanCacheEnabled:
          autoCleanCacheEnabled ?? _preferences?.autoCleanCacheEnabled ?? true,
    );

    await PreferencesService.savePreferences(updated);
    await PlayerService.setAudioQualityPreference(
      updated.audioQuality,
      applyNow: false,
    );
    await PlayerService.setMobileDataSaverEnabled(
      updated.mobileDataSaverEnabled,
      applyNow: false,
    );
    await PlayerService.setDolbyEffectEnabled(
      updated.dolbyEffectEnabled,
      applyNow: false,
    );
    await PlayerService.setSmartConversationAssistConfig(
      mode: updated.smartConversationAssistMode,
      reductionPercent: updated.conversationAssistReductionPercent,
      autoRestoreSeconds: updated.conversationAssistAutoRestoreSeconds,
      ignoreSingleEarbud: updated.conversationAssistIgnoreSingleEarbud,
    );
    _preferences = updated;
    _loading = false;
    _version++;
    notifyListeners();
  }

  Future<void> updateLanguages(List<String> languages) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
    );
  }

  Future<void> updateFavoriteArtists(
    List<Map<String, String>> favoriteArtists,
  ) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: favoriteArtists,
      onboardingComplete: true,
    );
  }

  Future<void> setBreakReminderEnabled(bool enabled) async {
    await ListeningSafetyService.setBreakReminderEnabled(enabled);
    _version++;
    notifyListeners();
  }

  Future<void> setHeadphoneVolumeLimitEnabled(bool enabled) async {
    await ListeningSafetyService.setHeadphoneVolumeLimitEnabled(enabled);
    _version++;
    notifyListeners();
  }

  Future<void> setReminderHighVolumeGateEnabled(bool enabled) async {
    await ListeningSafetyService.setReminderHighVolumeGateEnabled(enabled);
    _version++;
    notifyListeners();
  }

  Future<void> setAutoplayEnabled(bool enabled) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: enabled,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setAudioQuality(AudioQuality quality) async {
    await PlayerService.setAudioQualityPreference(quality, applyNow: true);
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: quality,
      downloadQuality: current.downloadQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setDownloadQuality(AudioQuality quality) async {
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      downloadQuality: quality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
      downloadWifiOnly: current.downloadWifiOnly,
    );
  }

  Future<void> setDownloadWifiOnly(bool value) async {
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      downloadQuality: current.downloadQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
      downloadWifiOnly: value,
    );
  }

  Future<void> setAutoDownloadPlayedSongs(bool value) async {
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      downloadQuality: current.downloadQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
      downloadWifiOnly: current.downloadWifiOnly,
      autoDownloadPlayedSongs: value,
    );
  }

  Future<void> setAutoDownloadEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      autoDownloadEnabled: value,
    );
  }

  Future<void> setAutoDownloadNewPlaylistSongs(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      autoDownloadNewPlaylistSongs: value,
    );
  }

  Future<void> setRemoveMissingPlaylistSongs(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      removeMissingPlaylistSongs: value,
    );
  }

  Future<void> setDownloadLyricsWithSongs(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      downloadLyricsWithSongs: value,
    );
  }

  Future<void> setPredictiveDownloadEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      predictiveDownloadEnabled: value,
    );
  }

  Future<void> setSleepDownloadEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      sleepDownloadEnabled: value,
    );
  }

  Future<void> setLowStorageProtectionEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      lowStorageProtectionEnabled: value,
    );
  }

  Future<void> setBatterySaverEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      batterySaverEnabled: value,
    );
  }

  Future<void> setAutoCleanCacheEnabled(bool value) async {
    final current = _preferences;
    if (current == null) return;
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      autoCleanCacheEnabled: value,
    );
  }

  Future<void> setMobileDataSaverEnabled(bool enabled) async {
    await PlayerService.setMobileDataSaverEnabled(enabled, applyNow: true);
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: enabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setDolbyEffectEnabled(bool enabled) async {
    await PlayerService.setDolbyEffectEnabled(enabled, applyNow: true);
    final current = _preferences;
    if (current == null) {
      _version++;
      notifyListeners();
      return;
    }

    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: enabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setSmartConversationAssistMode(
    SmartConversationAssistMode mode,
  ) async {
    final current = _preferences;
    if (current == null) return;
    await PlayerService.setSmartConversationAssistConfig(
      mode: mode,
      reductionPercent: current.conversationAssistReductionPercent,
      autoRestoreSeconds: current.conversationAssistAutoRestoreSeconds,
      ignoreSingleEarbud: current.conversationAssistIgnoreSingleEarbud,
    );
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: mode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setConversationAssistReductionPercent(int percent) async {
    final current = _preferences;
    if (current == null) return;
    final safe = percent.clamp(20, 80).toInt();
    await PlayerService.setSmartConversationAssistConfig(
      mode: current.smartConversationAssistMode,
      reductionPercent: safe,
      autoRestoreSeconds: current.conversationAssistAutoRestoreSeconds,
      ignoreSingleEarbud: current.conversationAssistIgnoreSingleEarbud,
    );
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent: safe,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setConversationAssistAutoRestoreSeconds(int seconds) async {
    final current = _preferences;
    if (current == null) return;
    final safe = seconds.clamp(15, 300).toInt();
    await PlayerService.setSmartConversationAssistConfig(
      mode: current.smartConversationAssistMode,
      reductionPercent: current.conversationAssistReductionPercent,
      autoRestoreSeconds: safe,
      ignoreSingleEarbud: current.conversationAssistIgnoreSingleEarbud,
    );
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds: safe,
      conversationAssistIgnoreSingleEarbud:
          current.conversationAssistIgnoreSingleEarbud,
    );
  }

  Future<void> setConversationAssistIgnoreSingleEarbud(bool ignore) async {
    final current = _preferences;
    if (current == null) return;
    await PlayerService.setSmartConversationAssistConfig(
      mode: current.smartConversationAssistMode,
      reductionPercent: current.conversationAssistReductionPercent,
      autoRestoreSeconds: current.conversationAssistAutoRestoreSeconds,
      ignoreSingleEarbud: ignore,
    );
    await savePreferences(
      languages: current.languages,
      favoriteArtists: current.favoriteArtists,
      onboardingComplete: true,
      autoplayEnabled: current.autoplayEnabled,
      audioQuality: current.audioQuality,
      mobileDataSaverEnabled: current.mobileDataSaverEnabled,
      dolbyEffectEnabled: current.dolbyEffectEnabled,
      smartConversationAssistMode: current.smartConversationAssistMode,
      conversationAssistReductionPercent:
          current.conversationAssistReductionPercent,
      conversationAssistAutoRestoreSeconds:
          current.conversationAssistAutoRestoreSeconds,
      conversationAssistIgnoreSingleEarbud: ignore,
    );
  }
}
