import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/preferences_provider.dart';
import '../theme/app_theme.dart';
import 'onboarding/language_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnim;

  final List<String> _collageImages = const [
    'https://c.saavncdn.com/191/Ajuni-Hindi-2023-20230811124437-500x500.jpg',
    'https://c.saavncdn.com/026/Aashiqui-2-Hindi-2013-500x500.jpg',
    'https://c.saavncdn.com/488/Kabir-Singh-Hindi-2019-20190614135003-500x500.jpg',
    'https://c.saavncdn.com/152/Animal-Hindi-2023-20231124191036-500x500.jpg',
    'https://c.saavncdn.com/590/Lofi-Session-Vol-1-Hindi-2023-20230303120147-500x500.jpg',
    'https://c.saavncdn.com/262/Vikram-Tamil-2022-20220515162452-500x500.jpg',
    'https://c.saavncdn.com/092/Leo-Tamil-2023-20231019213123-500x500.jpg',
    'https://c.saavncdn.com/973/Jawan-Tamil-2023-20230907151045-500x500.jpg',
    'https://c.saavncdn.com/291/Pathaan-Hindi-2022-20221222104158-500x500.jpg',
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeIn),
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // 1. Collage Background
          Positioned.fill(
            child: Opacity(
              opacity: 0.22,
              child: Transform.scale(
                scale: 1.15,
                child: Transform.rotate(
                  angle: -math.pi / 12,
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: _collageImages.length * 2,
                    itemBuilder: (context, index) {
                      final imgUrl = _collageImages[index % _collageImages.length];
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: imgUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(color: AppTheme.cardDark),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          // 2. Faded Gradient Overlay
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.background.withValues(alpha: 0.3),
                    AppTheme.background.withValues(alpha: 0.8),
                    AppTheme.background,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          // 3. Login Content
          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 3),
                    // App Logo
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.accentPurple.withValues(alpha: 0.3),
                            blurRadius: 32,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.music_note_rounded,
                        size: 48,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Music Hub',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Music For Everyone',
                      style: TextStyle(
                        fontSize: 15,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(flex: 4),
                    // Action Buttons
                    Consumer<AuthProvider>(
                      builder: (context, auth, _) {
                        return Column(
                          children: [
                            // Google Button
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black87,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28),
                                  ),
                                ),
                                icon: auth.loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(Colors.black87),
                                        ),
                                      )
                                    : Image.network(
                                        'https://www.google.com/favicon.ico',
                                        width: 22,
                                        height: 22,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.g_mobiledata, size: 22),
                                      ),
                                label: const Text(
                                  'Continue with Google',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: auth.loading
                                    ? null
                                    : () async {
                                        final success = await auth.signInWithGoogle();
                                        if (success && context.mounted) {
                                          final preferences = context.read<PreferencesProvider>();
                                          preferences.syncWithAuth(auth.user);
                                          await preferences.reload();
                                          if (!context.mounted) return;

                                          Navigator.pushReplacement(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => preferences.hasCompletedOnboarding
                                                  ? const HomeScreen()
                                                  : const LanguageScreen(),
                                            ),
                                          );
                                        }
                                      },
                              ),
                            ),
                            const SizedBox(height: 14),
                            // Continue as Guest Button
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white24, width: 1.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28),
                                  ),
                                  foregroundColor: AppTheme.textPrimary,
                                ),
                                onPressed: auth.loading
                                    ? null
                                    : () async {
                                        final success = await auth.signInAnonymously();
                                        if (success && context.mounted) {
                                          final preferences = context.read<PreferencesProvider>();
                                          preferences.syncWithAuth(auth.user);
                                          await preferences.reload();
                                          if (!context.mounted) return;

                                          Navigator.pushReplacement(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => preferences.hasCompletedOnboarding
                                                  ? const HomeScreen()
                                                  : const LanguageScreen(),
                                            ),
                                          );
                                        }
                                      },
                                child: const Text(
                                  'Continue as Guest',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'By continuing, you agree to our Privacy Policy & Terms of Service',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
