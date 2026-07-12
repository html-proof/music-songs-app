import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user_preferences.dart';
import '../providers/player_provider.dart';
import '../providers/preferences_provider.dart';
import '../theme/app_theme.dart';
import '../utils/language_utils.dart';
import 'onboarding/artist_screen.dart';
import 'onboarding/language_screen.dart';
import '../services/download_service.dart';
import '../services/offline_service.dart';

class PreferencesScreen extends StatelessWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<PreferencesProvider>();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Preferences',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _PreferenceCard(
                      title: 'Languages',
                      subtitle:
                          'Used to shape your recommendations and home feed',
                      chips: preferences.languages
                          .map(LanguageUtils.displayLabel)
                          .toList(growable: false),
                      actionText: 'Change Language',
                      onTap: () async {
                        await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const LanguageScreen(isEditing: true),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _PreferenceCard(
                      title: 'Favorite Artists',
                      subtitle: 'Used to personalize recommendations',
                      chips: preferences.favoriteArtists
                          .map((artist) => artist['name'] ?? '')
                          .where((name) => name.isNotEmpty)
                          .toList(),
                      actionText: 'Change Favorite Artists',
                      onTap: () async {
                        final languages = preferences.languages;
                        if (languages.isEmpty) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Please select languages first before changing artists.',
                              ),
                            ),
                          );
                          return;
                        }

                        await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ArtistScreen(
                              selectedLanguages: languages,
                              isEditing: true,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _ListeningSafetyCard(
                      breakReminderEnabled: preferences.breakReminderEnabled,
                      reminderHighVolumeGateEnabled:
                          preferences.reminderHighVolumeGateEnabled,
                      volumeLimitEnabled:
                          preferences.headphoneVolumeLimitEnabled,
                      onBreakReminderChanged: (enabled) async {
                        await preferences.setBreakReminderEnabled(enabled);
                      },
                      onReminderHighVolumeGateChanged: (enabled) async {
                        await preferences.setReminderHighVolumeGateEnabled(
                          enabled,
                        );
                      },
                      onVolumeLimitChanged: (enabled) async {
                        await preferences.setHeadphoneVolumeLimitEnabled(
                          enabled,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _PlaybackSettingsCard(
                      autoplayEnabled: preferences.autoplayEnabled,
                      audioQuality: preferences.audioQuality,
                      downloadQuality: preferences.downloadQuality,
                      dolbyEffectEnabled: preferences.dolbyEffectEnabled,
                      smartConversationAssistMode:
                          preferences.smartConversationAssistMode,
                      conversationAssistReductionPercent:
                          preferences.conversationAssistReductionPercent,
                      conversationAssistAutoRestoreSeconds:
                          preferences.conversationAssistAutoRestoreSeconds,
                      conversationAssistIgnoreSingleEarbud:
                          preferences.conversationAssistIgnoreSingleEarbud,
                      onAutoplayChanged: (enabled) async {
                        await preferences.setAutoplayEnabled(enabled);
                      },
                      onAudioQualityChanged: (quality) async {
                        await preferences.setAudioQuality(quality);
                      },
                      onDownloadQualityChanged: (quality) async {
                        await preferences.setDownloadQuality(quality);
                      },
                      onDolbyEffectChanged: (enabled) async {
                        await preferences.setDolbyEffectEnabled(enabled);
                      },
                      onSmartConversationAssistModeChanged: (mode) async {
                        await preferences.setSmartConversationAssistMode(mode);
                      },
                      onConversationAssistReductionChanged: (percent) async {
                        await preferences.setConversationAssistReductionPercent(
                          percent,
                        );
                      },
                      onConversationAssistAutoRestoreChanged: (seconds) async {
                        await preferences
                            .setConversationAssistAutoRestoreSeconds(seconds);
                      },
                      onConversationAssistIgnoreSingleEarbudChanged:
                          (enabled) async {
                            await preferences
                                .setConversationAssistIgnoreSingleEarbud(
                                  enabled,
                                );
                          },
                    ),
                    const SizedBox(height: 16),
                    const _OfflineStorageCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Playback Settings ─────────────────────────────────────────────────────

class _PlaybackSettingsCard extends StatelessWidget {
  /// Streaming quality options (includes Auto).
  static const List<AudioQuality> _streamingQualityOptions = [
    AudioQuality.auto,
    AudioQuality.dataSaver,
    AudioQuality.low,
    AudioQuality.normal,
    AudioQuality.high,
    AudioQuality.veryHigh,
  ];

  /// Download quality options (no Auto — user picks a fixed tier).
  static const List<AudioQuality> _downloadQualityOptions = [
    AudioQuality.dataSaver,
    AudioQuality.low,
    AudioQuality.normal,
    AudioQuality.high,
    AudioQuality.veryHigh,
  ];

  static const List<SmartConversationAssistMode> _conversationModes = [
    SmartConversationAssistMode.off,
    SmartConversationAssistMode.manualOnly,
    SmartConversationAssistMode.automatic,
  ];

  final bool autoplayEnabled;
  final AudioQuality audioQuality;
  final AudioQuality downloadQuality;
  final bool dolbyEffectEnabled;
  final SmartConversationAssistMode smartConversationAssistMode;
  final int conversationAssistReductionPercent;
  final int conversationAssistAutoRestoreSeconds;
  final bool conversationAssistIgnoreSingleEarbud;
  final ValueChanged<bool> onAutoplayChanged;
  final ValueChanged<AudioQuality> onAudioQualityChanged;
  final ValueChanged<AudioQuality> onDownloadQualityChanged;
  final ValueChanged<bool> onDolbyEffectChanged;
  final ValueChanged<SmartConversationAssistMode>
  onSmartConversationAssistModeChanged;
  final ValueChanged<int> onConversationAssistReductionChanged;
  final ValueChanged<int> onConversationAssistAutoRestoreChanged;
  final ValueChanged<bool> onConversationAssistIgnoreSingleEarbudChanged;

  const _PlaybackSettingsCard({
    required this.autoplayEnabled,
    required this.audioQuality,
    required this.downloadQuality,
    required this.dolbyEffectEnabled,
    required this.smartConversationAssistMode,
    required this.conversationAssistReductionPercent,
    required this.conversationAssistAutoRestoreSeconds,
    required this.conversationAssistIgnoreSingleEarbud,
    required this.onAutoplayChanged,
    required this.onAudioQualityChanged,
    required this.onDownloadQualityChanged,
    required this.onDolbyEffectChanged,
    required this.onSmartConversationAssistModeChanged,
    required this.onConversationAssistReductionChanged,
    required this.onConversationAssistAutoRestoreChanged,
    required this.onConversationAssistIgnoreSingleEarbudChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isQualityChanging = context
        .select<PlayerProvider, bool>((p) => p.isQualitySwitching);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Playback',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            value: autoplayEnabled,
            activeThumbColor: AppTheme.accentPurple,
            title: const Text(
              'Autoplay next songs',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            subtitle: const Text(
              'Keep the music playing when your queue or album ends.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            onChanged: onAutoplayChanged,
          ),
          const Divider(height: 1, color: AppTheme.cardDark),

          // ── Streaming Quality ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DropdownButtonFormField<AudioQuality>(
              initialValue: audioQuality,
              dropdownColor: AppTheme.cardDark,
              decoration: const InputDecoration(
                labelText: 'Streaming Quality',
                labelStyle: TextStyle(color: AppTheme.textMuted),
                helperText:
                    'Auto: Wi-Fi → 320 kbps, Mobile → 96 kbps, Weak → 64 kbps',
                helperStyle: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
              items: _streamingQualityOptions
                  .map(
                    (quality) => DropdownMenuItem<AudioQuality>(
                      value: quality,
                      child: Text(quality.label),
                    ),
                  )
                  .toList(),
              onChanged: isQualityChanging
                  ? null
                  : (selected) {
                      if (selected != null) {
                        onAudioQualityChanged(selected);
                      }
                    },
            ),
          ),

          // ── Download Quality ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: DropdownButtonFormField<AudioQuality>(
              initialValue: downloadQuality,
              dropdownColor: AppTheme.cardDark,
              decoration: const InputDecoration(
                labelText: 'Download Quality',
                labelStyle: TextStyle(color: AppTheme.textMuted),
                helperText:
                    'Quality used when saving songs for offline playback.',
                helperStyle: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
              items: _downloadQualityOptions
                  .map(
                    (quality) => DropdownMenuItem<AudioQuality>(
                      value: quality,
                      child: Text(quality.label),
                    ),
                  )
                  .toList(),
              onChanged: (selected) {
                if (selected != null) {
                  onDownloadQualityChanged(selected);
                }
              },
            ),
          ),
          const Divider(height: 1, color: AppTheme.cardDark),

          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            value: dolbyEffectEnabled,
            activeThumbColor: AppTheme.accentPurple,
            title: const Text(
              'Dolby-like enhancer (Android)',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            subtitle: const Text(
              'Boosts bass and spatial depth on supported Android devices.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            onChanged: onDolbyEffectChanged,
          ),
          const Divider(height: 1, color: AppTheme.cardDark),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: DropdownButtonFormField<SmartConversationAssistMode>(
              initialValue: smartConversationAssistMode,
              dropdownColor: AppTheme.cardDark,
              decoration: const InputDecoration(
                labelText: 'Smart Conversation Assist',
                labelStyle: TextStyle(color: AppTheme.textMuted),
                helperText:
                    'Event-based volume ducking with no microphone access.',
                helperStyle: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
              items: _conversationModes
                  .map(
                    (mode) => DropdownMenuItem<SmartConversationAssistMode>(
                      value: mode,
                      child: Text(_conversationModeLabel(mode)),
                    ),
                  )
                  .toList(),
              onChanged: (selected) {
                if (selected != null) {
                  onSmartConversationAssistModeChanged(selected);
                }
              },
            ),
          ),
          if (smartConversationAssistMode != SmartConversationAssistMode.off)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Volume reduction: $conversationAssistReductionPercent%',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  Slider(
                    value: conversationAssistReductionPercent.toDouble(),
                    min: 20,
                    max: 80,
                    divisions: 12,
                    label: '$conversationAssistReductionPercent%',
                    onChanged: (value) {
                      onConversationAssistReductionChanged(value.round());
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Auto restore: ${conversationAssistAutoRestoreSeconds}s',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  Slider(
                    value: conversationAssistAutoRestoreSeconds.toDouble(),
                    min: 15,
                    max: 300,
                    divisions: 19,
                    label: '${conversationAssistAutoRestoreSeconds}s',
                    onChanged: (value) {
                      onConversationAssistAutoRestoreChanged(value.round());
                    },
                  ),
                  if (smartConversationAssistMode ==
                      SmartConversationAssistMode.automatic)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: conversationAssistIgnoreSingleEarbud,
                      activeThumbColor: AppTheme.accentPurple,
                      title: const Text(
                        'Ignore earbud route changes',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: const Text(
                        'Use this if you listen with one earbud regularly.',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      onChanged: onConversationAssistIgnoreSingleEarbudChanged,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  String _conversationModeLabel(SmartConversationAssistMode mode) {
    switch (mode) {
      case SmartConversationAssistMode.off:
        return 'Off';
      case SmartConversationAssistMode.manualOnly:
        return 'Manual Only (double volume down)';
      case SmartConversationAssistMode.automatic:
        return 'Automatic';
    }
  }
}

// ─── Listening Safety ──────────────────────────────────────────────────────

class _ListeningSafetyCard extends StatelessWidget {
  final bool breakReminderEnabled;
  final bool reminderHighVolumeGateEnabled;
  final bool volumeLimitEnabled;
  final ValueChanged<bool> onBreakReminderChanged;
  final ValueChanged<bool> onReminderHighVolumeGateChanged;
  final ValueChanged<bool> onVolumeLimitChanged;

  const _ListeningSafetyCard({
    required this.breakReminderEnabled,
    required this.reminderHighVolumeGateEnabled,
    required this.volumeLimitEnabled,
    required this.onBreakReminderChanged,
    required this.onReminderHighVolumeGateChanged,
    required this.onVolumeLimitChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Listening Safety',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            value: breakReminderEnabled,
            activeThumbColor: AppTheme.accentPurple,
            title: const Text(
              'Listening reminder',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            subtitle: const Text(
              'Reminds you after 60 minutes of continuous listening on any output device.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            onChanged: onBreakReminderChanged,
          ),
          const Divider(height: 1, color: AppTheme.cardDark),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            value: reminderHighVolumeGateEnabled,
            activeThumbColor: AppTheme.accentPurple,
            title: const Text(
              'Only remind at 60%+ volume',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            subtitle: const Text(
              'Advanced: Sends reminders only when listening volume is at least 60%.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            onChanged: onReminderHighVolumeGateChanged,
          ),
          const Divider(height: 1, color: AppTheme.cardDark),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            value: volumeLimitEnabled,
            activeThumbColor: AppTheme.accentPurple,
            title: const Text(
              'Limit headphone volume to 50%',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            subtitle: const Text(
              'Prevents this app from playing louder than 50% on headphones.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            onChanged: onVolumeLimitChanged,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Reusable Preference Card ──────────────────────────────────────────────

class _PreferenceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<String> chips;
  final String actionText;
  final VoidCallback onTap;

  const _PreferenceCard({
    required this.title,
    required this.subtitle,
    required this.chips,
    required this.actionText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (chips.isEmpty)
            const Text(
              'No selections yet',
              style: TextStyle(color: AppTheme.textMuted),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: chips
                  .map(
                    (chip) => Chip(
                      label: Text(chip),
                      backgroundColor: AppTheme.cardDark,
                      labelStyle: const TextStyle(color: AppTheme.textPrimary),
                      side: BorderSide.none,
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accentPurple),
                foregroundColor: AppTheme.accentPurple,
              ),
              child: Text(actionText),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Data & Downloads Card ─────────────────────────────────────────────────

class _OfflineStorageCard extends StatefulWidget {
  const _OfflineStorageCard();

  @override
  State<_OfflineStorageCard> createState() => _OfflineStorageCardState();
}

class _OfflineStorageCardState extends State<_OfflineStorageCard>
    with SingleTickerProviderStateMixin {
  late int _storageLimit;
  bool _wifiUpgradeEnabled = true;
  bool _loadingOfflineSettings = true;
  int _usedStorageBytes = 0;
  late final AnimationController _expandController;
  late final Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _storageLimit = OfflineService.getStorageLimit();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeInOut,
    );
    _loadOfflineSettings();
  }

  @override
  void dispose() {
    _expandController.dispose();
    super.dispose();
  }

  Future<void> _loadOfflineSettings() async {
    await OfflineService.init();
    final usedBytes = await DownloadService.getTotalSize();
    if (!mounted) return;
    setState(() {
      _storageLimit = OfflineService.getStorageLimit();
      _wifiUpgradeEnabled = OfflineService.wifiUpgradeEnabled;
      _loadingOfflineSettings = false;
      _usedStorageBytes = usedBytes;
    });
  }

  Future<void> _setWifiUpgradeEnabled(bool enabled) async {
    setState(() {
      _wifiUpgradeEnabled = enabled;
    });
    await OfflineService.setWifiUpgradeEnabled(enabled);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double _storageUsedFraction() {
    if (_storageLimit <= 0) return 0.0;
    final limitBytes = _storageLimit * 1024 * 1024;
    return (_usedStorageBytes / limitBytes).clamp(0.0, 1.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final prefs = context.read<PreferencesProvider>();
    if (prefs.smartDownloadEnabled) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<PreferencesProvider>();
    final downloadQuality = preferences.downloadQuality;
    final smartOn = preferences.smartDownloadEnabled;
    final dataSaverOn = preferences.dataSaverEnabled;

    // Drive expand animation whenever smartOn changes
    if (smartOn) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: dataSaverOn
              ? Colors.orangeAccent.withValues(alpha: 0.4)
              : smartOn
                  ? AppTheme.accentPurple.withValues(alpha: 0.35)
                  : AppTheme.divider,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: dataSaverOn
                        ? const LinearGradient(
                            colors: [Color(0xFFFF9800), Color(0xFFF57C00)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : smartOn
                            ? const LinearGradient(
                                colors: [Color(0xFF1ED760), Color(0xFF17A349)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : null,
                    color: (dataSaverOn || smartOn) ? null : AppTheme.cardDark,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    dataSaverOn
                        ? Icons.data_saver_on_rounded
                        : Icons.download_for_offline_rounded,
                    color: (dataSaverOn || smartOn)
                        ? Colors.black
                        : AppTheme.textMuted,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Data & Downloads',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        dataSaverOn
                            ? 'Data Saver is active'
                            : smartOn
                                ? 'Smart downloading is active'
                                : 'Manual downloads only',
                        style: TextStyle(
                          color: dataSaverOn
                              ? Colors.orangeAccent
                              : smartOn
                                  ? AppTheme.accentPurple
                                  : AppTheme.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Storage bar ─────────────────────────────────────────
          if (!_loadingOfflineSettings && _storageLimit > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Used: ${_formatBytes(_usedStorageBytes)}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        'Limit: ${_formatBytes(_storageLimit * 1024 * 1024)}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _storageUsedFraction(),
                      minHeight: 5,
                      backgroundColor: AppTheme.cardDark,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _storageUsedFraction() > 0.85
                            ? Colors.redAccent
                            : _storageUsedFraction() > 0.65
                                ? Colors.orangeAccent
                                : AppTheme.accentPurple,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 4),

          // ── Data Saver ──────────────────────────────────────────
          _buildSubSection(
            icon: Icons.data_saver_on_rounded,
            iconColor: Colors.orangeAccent,
            title: 'Data Saver',
            children: [
              SwitchListTile.adaptive(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                value: dataSaverOn,
                activeThumbColor: Colors.orangeAccent,
                title: const Text(
                  'Data Saver',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Disables background downloads, prefetch, playlist sync, and caps streaming to 96 kbps.',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                onChanged: (enabled) async {
                  await preferences.setDataSaverEnabled(enabled);
                },
              ),
            ],
          ),

          // ── Background Downloads ────────────────────────────────
          _buildSubSection(
            icon: Icons.wifi_rounded,
            iconColor: const Color(0xFF4A90E2),
            title: 'Background Downloads',
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: DropdownButtonFormField<BackgroundDownloadMode>(
                  initialValue: preferences.backgroundDownloadMode,
                  dropdownColor: AppTheme.cardDark,
                  decoration: InputDecoration(
                    labelText: 'Background Downloads',
                    labelStyle: const TextStyle(color: AppTheme.textMuted),
                    helperText: dataSaverOn
                        ? 'Disabled by Data Saver'
                        : preferences.backgroundDownloadMode.description,
                    helperStyle: TextStyle(
                      color: dataSaverOn
                          ? Colors.orangeAccent
                          : AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: AppTheme.textPrimary),
                  items: BackgroundDownloadMode.values
                      .map(
                        (mode) =>
                            DropdownMenuItem<BackgroundDownloadMode>(
                              value: mode,
                              child: Text(mode.label),
                            ),
                      )
                      .toList(),
                  onChanged: dataSaverOn
                      ? null
                      : (selected) async {
                          if (selected != null) {
                            await preferences
                                .setBackgroundDownloadMode(selected);
                          }
                        },
                ),
              ),
            ],
          ),

          // ── Smart Download (master toggle + sub-settings) ───────
          _buildSubSection(
            icon: Icons.auto_awesome_rounded,
            iconColor: const Color(0xFF9B59B6),
            title: 'Smart Download',
            children: [
              SwitchListTile.adaptive(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                value: smartOn,
                activeThumbColor: AppTheme.accentPurple,
                title: const Text(
                  'Smart Download',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Automatically download playlists, liked songs, and update offline content.',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                onChanged: dataSaverOn
                    ? null
                    : (enabled) async {
                        await preferences.setSmartDownloadEnabled(enabled);
                      },
              ),
            ],
          ),

          // ── Smart Download sub-settings (expanded when Smart Download ON) ─
          SizeTransition(
            sizeFactor: _expandAnimation,
            axisAlignment: -1,
            child: Column(
              children: [
                _buildSubSection(
                  icon: Icons.playlist_add_check_rounded,
                  iconColor: const Color(0xFF9B59B6),
                  title: 'Playlist Sync',
                  children: [
                    _buildToggleRow(
                      value: preferences.autoDownloadNewPlaylistSongs,
                      title: 'Auto Download New Playlist Songs',
                      subtitle:
                          'New songs added to downloaded playlists are downloaded automatically.',
                      onChanged: (v) async =>
                          preferences.setAutoDownloadNewPlaylistSongs(v),
                    ),
                    _buildToggleRow(
                      value: preferences.removeMissingPlaylistSongs,
                      title: 'Remove Missing Playlist Songs',
                      subtitle:
                          'Remove local copies when songs are removed from the playlist.',
                      onChanged: (v) async =>
                          preferences.setRemoveMissingPlaylistSongs(v),
                    ),
                  ],
                ),
                _buildSubSection(
                  icon: Icons.lyrics_rounded,
                  iconColor: const Color(0xFF1ED760),
                  title: 'Offline Extras',
                  children: [
                    _buildToggleRow(
                      value: preferences.downloadLyricsWithSongs,
                      title: 'Download Lyrics with Songs',
                      subtitle:
                          'Saves synchronized lyrics locally so the lyric screen works fully offline.',
                      onChanged: (v) async =>
                          preferences.setDownloadLyricsWithSongs(v),
                    ),
                    _buildToggleRow(
                      value: preferences.autoDownloadPlayedSongs,
                      title: 'Auto-download Played Songs',
                      subtitle:
                          'Automatically save songs to your library as you play them.',
                      onChanged: (v) async =>
                          preferences.setAutoDownloadPlayedSongs(v),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Playback Optimization ──────────────────────────────
          _buildSubSection(
            icon: Icons.speed_rounded,
            iconColor: const Color(0xFF00BCD4),
            title: 'Playback Optimization',
            children: [
              _buildToggleRow(
                value: preferences.prefetchNextSongEnabled,
                title: 'Prefetch Next Song',
                subtitle:
                    'Pre-buffer the next track for gapless playback.',
                onChanged: dataSaverOn
                    ? null
                    : (v) async =>
                        preferences.setPrefetchNextSongEnabled(v),
              ),
            ],
          ),

          // ── Smart Features ──────────────────────────────────────
          _buildSubSection(
            icon: Icons.auto_fix_high_rounded,
            iconColor: const Color(0xFFF39C12),
            title: 'Smart Features',
            children: [
              _buildToggleRow(
                value: preferences.predictiveDownloadEnabled,
                title: 'Predictive Download',
                subtitle: 'Automatically download songs you repeat often.',
                onChanged: (v) async =>
                    preferences.setPredictiveDownloadEnabled(v),
              ),
              _buildToggleRow(
                value: preferences.sleepDownloadEnabled,
                title: 'Sleep Download',
                subtitle: 'Only run large downloads while device is charging.',
                onChanged: (v) async =>
                    preferences.setSleepDownloadEnabled(v),
              ),
              _buildToggleRow(
                value: preferences.lowStorageProtectionEnabled,
                title: 'Low Storage Protection',
                subtitle:
                    'Pause auto downloads when free space is below threshold.',
                onChanged: (v) async =>
                    preferences.setLowStorageProtectionEnabled(v),
              ),
              _buildToggleRow(
                value: preferences.batterySaverEnabled,
                title: 'Battery Saver',
                subtitle:
                    'Reduce parallel background downloads on low battery.',
                onChanged: (v) async =>
                    preferences.setBatterySaverEnabled(v),
              ),
              _buildToggleRow(
                value: preferences.autoCleanCacheEnabled,
                title: 'Auto-clean Cache',
                subtitle:
                    'Remove temporary streaming files but keep downloaded songs.',
                onChanged: (v) async =>
                    preferences.setAutoCleanCacheEnabled(v),
              ),
            ],
          ),

          // ── Limits & Quality ────────────────────────────────────
          _buildSubSection(
            icon: Icons.tune_rounded,
            iconColor: const Color(0xFFE74C3C),
            title: 'Limits & Quality',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: DropdownButtonFormField<int>(
                  initialValue: _storageLimit,
                  dropdownColor: AppTheme.cardDark,
                  decoration: const InputDecoration(
                    labelText: 'Storage Limit',
                    labelStyle: TextStyle(color: AppTheme.textMuted),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: AppTheme.textPrimary),
                  items: const [
                    DropdownMenuItem(value: -1, child: Text('Unlimited')),
                    DropdownMenuItem(value: 500, child: Text('500 MB')),
                    DropdownMenuItem(value: 1024, child: Text('1 GB')),
                    DropdownMenuItem(value: 2048, child: Text('2 GB')),
                    DropdownMenuItem(value: 5120, child: Text('5 GB')),
                    DropdownMenuItem(value: 10240, child: Text('10 GB')),
                  ],
                  onChanged: (val) async {
                    if (val != null) {
                      setState(() => _storageLimit = val);
                      await OfflineService.setStorageLimit(val);
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              _buildToggleRow(
                value: _wifiUpgradeEnabled,
                title: 'Upgrade cached songs on Wi-Fi only',
                subtitle: _loadingOfflineSettings
                    ? 'Loading offline storage settings...'
                    : 'Keep low-quality copy on mobile data and upgrade to ${downloadQuality.label} on Wi-Fi.',
                onChanged: _loadingOfflineSettings
                    ? null
                    : (v) => _setWifiUpgradeEnabled(v),
              ),
            ],
          ),

          // ── Danger zone ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppTheme.cardDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      title: const Text(
                        'Clear Cache?',
                        style: TextStyle(color: AppTheme.textPrimary),
                      ),
                      content: const Text(
                        'All saved offline music will be deleted. This cannot be undone.',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text(
                            'CANCEL',
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text(
                            'CLEAR ALL',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await OfflineService.clearCache();
                    if (mounted) {
                      setState(() => _usedStorageBytes = 0);
                    }
                  }
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent, width: 1),
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text(
                  'Clear Offline Cache',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubSection({
    required IconData icon,
    required Color iconColor,
    required String title,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: iconColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: children),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildToggleRow({
    required bool value,
    required String title,
    required String subtitle,
    required ValueChanged<bool>? onChanged,
  }) {
    return SwitchListTile.adaptive(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      value: value,
      activeThumbColor: AppTheme.accentPurple,
      title: Text(
        title,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
      ),
      onChanged: onChanged,
    );
  }
}
