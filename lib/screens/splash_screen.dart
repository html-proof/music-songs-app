import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/preferences_provider.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'offline_library_screen.dart';
import 'onboarding/language_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _introController;
  late AnimationController _pulseController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  late Animation<double> _logoScaleAnim;
  late DateTime _startedAt;
  bool _navigationStarted = false;
  static const Duration _minimumSplashDuration = Duration(milliseconds: 3);

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _introController, curve: Curves.easeOutCubic),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.045), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _introController, curve: Curves.easeOutCubic),
        );
    _logoScaleAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _introController, curve: Curves.easeOutBack),
    );
    _introController.forward();
    _pulseController.repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigate();
    });
  }

  Future<void> _navigate() async {
    if (_navigationStarted) return;
    _navigationStarted = true;
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final preferences = context.read<PreferencesProvider>();
    final connectivityResult = await Connectivity().checkConnectivity();
    final isOffline = !connectivityResult.any(
      (result) => result != ConnectivityResult.none,
    );

    int timeout = 0;
    while ((auth.loading || preferences.loading) && timeout < 60) {
      await Future.delayed(const Duration(milliseconds: 100));
      timeout++;
    }

    final elapsed = DateTime.now().difference(_startedAt);
    if (elapsed < _minimumSplashDuration) {
      await Future.delayed(_minimumSplashDuration - elapsed);
    }

    if (!mounted) return;

    Widget destination;
    if (!auth.isLoggedIn) {
      destination = const LoginScreen();
    } else if (isOffline) {
      destination = const OfflineLibraryScreen();
    } else if (!preferences.hasCompletedOnboarding) {
      destination = const LanguageScreen();
    } else {
      destination = const HomeScreen();
    }

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, anim, __, child) {
          final offsetAnim = Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(position: offsetAnim, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 50),
      ),
    );
  }

  @override
  void dispose() {
    _introController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: AppTheme.backgroundGradient,
            ),
          ),
          Positioned(
            top: -120,
            right: -80,
            child: _GlowOrb(
              size: 260,
              color: AppTheme.accentPurple.withValues(alpha: 0.20),
            ),
          ),
          Positioned(
            bottom: -90,
            left: -50,
            child: _GlowOrb(
              size: 220,
              color: AppTheme.accentPurple.withValues(alpha: 0.16),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        final pulse = 1.0 + (_pulseController.value * 0.028);
                        return Transform.scale(
                          scale: pulse,
                          child: ScaleTransition(
                            scale: _logoScaleAnim,
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        width: 108,
                        height: 108,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: const LinearGradient(
                            colors: [AppTheme.accentPurple, AppTheme.accentPurple],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accentPurple.withValues(
                                alpha: 0.30,
                              ),
                              blurRadius: 28,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/icon_foreground.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Music Hub',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.9,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Preparing your music experience',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary.withValues(alpha: 0.9),
                        letterSpacing: 0.25,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: SizedBox(
                        width: 150,
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          color: AppTheme.accentPurple,
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
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

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}
