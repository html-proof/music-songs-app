import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/language_utils.dart';
import '../home_screen.dart';

class ArtistScreen extends StatefulWidget {
  final List<String> selectedLanguages;
  final bool isEditing;

  const ArtistScreen({
    super.key,
    required this.selectedLanguages,
    this.isEditing = false,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  final Set<String> _selectedIds = {};
  final Map<String, Map<String, dynamic>> _artistMap = {};
  bool _loading = true;
  bool _saving = false;
  bool _initializedSelection = false;
  bool _hadFetchError = false;

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedSelection) return;
    final selectedArtistIds = context
        .read<PreferencesProvider>()
        .favoriteArtists
        .map((artist) => artist['id'] ?? '')
        .where((id) => id.isNotEmpty);
    _selectedIds.addAll(selectedArtistIds);
    _initializedSelection = true;
  }

  Future<void> _loadArtists() async {
    final normalizedLanguages = LanguageUtils.normalizeLanguageList(
      widget.selectedLanguages,
    );

    var hadError = false;
    try {
      await Future.wait(
        normalizedLanguages.map((lang) async {
          try {
            final artists = await ApiService.getArtistsByLanguage(lang);
            for (final artist in artists) {
              if (artist is! Map) continue;
              final artistMap = Map<String, dynamic>.from(artist);
              final id = (artistMap['id'] ?? '').toString().trim();
              if (id.isEmpty) continue;
              _artistMap[id] = artistMap;
            }
          } catch (e) {
            hadError = true;
            debugPrint('Load artists error ($lang): $e');
          }
        }),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _hadFetchError = hadError;
        });
      }
    }
  }

  Future<void> _saveAndContinue() async {
    setState(() => _saving = true);
    try {
      final existingFavorites = context
          .read<PreferencesProvider>()
          .favoriteArtists;
      final existingById = {
        for (final artist in existingFavorites)
          if ((artist['id'] ?? '').isNotEmpty) artist['id']!: artist,
      };

      final favoriteArtists = _selectedIds.map((id) {
        final artist = _artistMap[id];
        final fallback = existingById[id];
        return {
          'id': id,
          'name': artist?['name']?.toString() ?? fallback?['name'] ?? '',
        };
      }).toList();
      final normalizedLanguages = LanguageUtils.normalizeLanguageList(
        widget.selectedLanguages,
      );

      await context.read<PreferencesProvider>().savePreferences(
        languages: normalizedLanguages,
        favoriteArtists: favoriteArtists,
      );

      if (mounted) {
        if (widget.isEditing) {
          Navigator.pop(context, true);
        } else {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const HomeScreen()),
            (_) => false,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final artists = _artistMap.values.toList();

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
                  'Pick Your\nFavorite Artists',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Selected: ${_selectedIds.length} artists',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                if (_hadFetchError)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Some artists could not be loaded. Showing available results.',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.accentPurple,
                          ),
                        )
                      : artists.isEmpty
                      ? const Center(
                          child: Text(
                            'No artists found.\nTry different languages.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        )
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                childAspectRatio: 0.75,
                              ),
                          itemCount: artists.length,
                          itemBuilder: (context, index) {
                            final artist = artists[index];
                            final id = artist['id'].toString();
                            final isSelected = _selectedIds.contains(id);
                            final name = artist['name'] ?? 'Unknown';

                            String? imageUrl;
                            if (artist['image'] is List &&
                                (artist['image'] as List).isNotEmpty) {
                              imageUrl =
                                  (artist['image'] as List).last['url'] ??
                                  (artist['image'] as List).last['link'];
                            }

                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedIds.remove(id);
                                  } else {
                                    _selectedIds.add(id);
                                  }
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                decoration: BoxDecoration(
                                  color: AppTheme.surfaceDark,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isSelected
                                        ? AppTheme.accentPurple
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: AppTheme.accentPurple
                                                .withValues(alpha: 0.3),
                                            blurRadius: 12,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 32,
                                      backgroundColor: AppTheme.cardDark,
                                      backgroundImage: imageUrl != null
                                          ? CachedNetworkImageProvider(imageUrl)
                                          : null,
                                      child: imageUrl == null
                                          ? const Icon(
                                              Icons.person,
                                              color: AppTheme.textMuted,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(height: 8),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: Text(
                                        name,
                                        style: TextStyle(
                                          color: isSelected
                                              ? AppTheme.accentPurple
                                              : AppTheme.textSecondary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 11,
                                        ),
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isSelected)
                                      const Padding(
                                        padding: EdgeInsets.only(top: 4),
                                        child: Icon(
                                          Icons.check_circle,
                                          color: AppTheme.accentPurple,
                                          size: 18,
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
                    onPressed: _saving ? null : _saveAndContinue,
                    child: _saving
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(_selectedIds.isEmpty ? 'Skip' : 'Continue'),
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
