import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/preferences_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/language_utils.dart';
import 'artist_screen.dart';

class LanguageScreen extends StatefulWidget {
  final bool isEditing;

  const LanguageScreen({super.key, this.isEditing = false});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  final Set<String> _selected = {};
  bool _initialized = false;

  final List<Map<String, String>> _languages = [
    {'value': 'hindi', 'label': 'Hindi', 'icon': 'HI'},
    {'value': 'english', 'label': 'English', 'icon': 'EN'},
    {'value': 'malayalam', 'label': 'Malayalam', 'icon': 'ML'},
    {'value': 'tamil', 'label': 'Tamil', 'icon': 'TA'},
    {'value': 'telugu', 'label': 'Telugu', 'icon': 'TE'},
    {'value': 'kannada', 'label': 'Kannada', 'icon': 'KA'},
    {'value': 'bengali', 'label': 'Bengali', 'icon': 'BN'},
    {'value': 'punjabi', 'label': 'Punjabi', 'icon': 'PA'},
    {'value': 'marathi', 'label': 'Marathi', 'icon': 'MR'},
    {'value': 'gujarati', 'label': 'Gujarati', 'icon': 'GU'},
    {'value': 'bhojpuri', 'label': 'Bhojpuri', 'icon': 'BH'},
    {'value': 'urdu', 'label': 'Urdu', 'icon': 'UR'},
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _selected.addAll(
      LanguageUtils.normalizeLanguageList(
        context.read<PreferencesProvider>().languages,
      ),
    );
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                const Text(
                  'Choose Your\nLanguages',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Select the languages you want to listen to',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 32),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.1,
                        ),
                    itemCount: _languages.length,
                    itemBuilder: (context, index) {
                      final lang = _languages[index];
                      final value = lang['value']!;
                      final label = lang['label']!;
                      final isSelected = _selected.contains(value);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selected.remove(value);
                            } else {
                              _selected.add(value);
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            gradient: isSelected
                                ? AppTheme.primaryGradient
                                : null,
                            color: isSelected ? null : AppTheme.surfaceDark,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? AppTheme.accentPurple
                                  : AppTheme.textMuted.withValues(alpha: 0.2),
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppTheme.accentPurple.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 12,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                lang['icon']!,
                                style: const TextStyle(fontSize: 28),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () async {
                            final selectedLanguages = _languages
                                .map((entry) => entry['value']!)
                                .where(_selected.contains)
                                .toList(growable: false);
                            final updated = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ArtistScreen(
                                  selectedLanguages: selectedLanguages,
                                  isEditing: widget.isEditing,
                                ),
                              ),
                            );

                            if (!mounted || !widget.isEditing) return;
                            if (updated == true) {
                              Navigator.pop(context, true);
                            }
                          },
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
