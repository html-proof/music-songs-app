import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/connectivity_manager.dart';
import '../theme/app_theme.dart';
import '../screens/home_screen.dart';
import '../providers/preferences_provider.dart';

class NavigatorHolder {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
}

class AppReconnectionListener extends StatefulWidget {
  final Widget child;
  const AppReconnectionListener({super.key, required this.child});

  @override
  State<AppReconnectionListener> createState() => _AppReconnectionListenerState();
}

class _AppReconnectionListenerState extends State<AppReconnectionListener>
    with SingleTickerProviderStateMixin {
  StreamSubscription<ConnectivityEvent>? _subscription;
  bool _showBanner = false;
  Timer? _dismissTimer;
  Timer? _debounceTimer;
  late AnimationController _animationController;
  late Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation = Tween<double>(begin: -120.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack),
    );

    // Listen for reconnection events
    _subscription = ConnectivityManager.eventStream.listen((event) {
      if (event == ConnectivityEvent.restored) {
        _debounceTimer?.cancel();
        _debounceTimer = Timer(const Duration(milliseconds: 1500), () {
          if (ConnectivityManager.isConnected) {
            _triggerBanner();
          }
        });
      } else if (event == ConnectivityEvent.disconnected) {
        _debounceTimer?.cancel();
        _debounceTimer = null;
        _dismissBanner();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _dismissTimer?.cancel();
    _debounceTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _triggerBanner() {
    if (!mounted) return;
    if (ConnectivityManager.isOffline) return;

    // Check auth and onboarding states
    final context = NavigatorHolder.navigatorKey.currentContext;
    if (context == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final preferences = context.read<PreferencesProvider>();
      if (!preferences.hasCompletedOnboarding) return;
    } catch (_) {
      // If PreferencesProvider is not registered or throws, skip
      return;
    }

    // Inspect the top-most route
    Route<dynamic>? topRoute;
    NavigatorHolder.navigatorKey.currentState?.popUntil((route) {
      topRoute = route;
      return true;
    });

    final name = topRoute?.settings.name;
    final isHome = name == '/home' || name == 'home';
    if (isHome) {
      // Already on home, do not display banner
      return;
    }

    // Display banner
    _dismissTimer?.cancel();
    setState(() {
      _showBanner = true;
    });
    _animationController.forward();

    // Dismiss automatically after 4 seconds
    _dismissTimer = Timer(const Duration(seconds: 4), () {
      _dismissBanner();
    });
  }

  void _dismissBanner() {
    if (!mounted || !_showBanner) return;
    _animationController.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showBanner = false;
        });
      }
    });
  }

  void _onBannerTapped() {
    _dismissBanner();
    NavigatorHolder.navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const HomeScreen(),
        settings: const RouteSettings(name: '/home'),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_showBanner)
          AnimatedBuilder(
            animation: _slideAnimation,
            builder: (context, child) {
              return Positioned(
                top: MediaQuery.of(context).padding.top + 12 + _slideAnimation.value,
                left: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: child,
                ),
              );
            },
            child: GestureDetector(
              onTap: _onBannerTapped,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1A2D).withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppTheme.accentPurple.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.accentPurple.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.wifi_rounded,
                        color: AppTheme.accentPurple,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "You're back online",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            "Tap to go Home",
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: AppTheme.textMuted,
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
