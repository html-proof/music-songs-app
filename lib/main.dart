import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:path_provider/path_provider.dart';
import 'firebase_options.dart';
import 'package:provider/provider.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'providers/auth_provider.dart';
import 'providers/preferences_provider.dart';
import 'providers/player_provider.dart';
import 'providers/search_provider.dart';
import 'providers/download_provider.dart';
import 'services/api_service.dart';
import 'services/listening_safety_service.dart';
import 'services/playlist_service.dart';
import 'services/player_service.dart';
import 'services/preferences_service.dart';
import 'services/offline_service.dart';
import 'services/session_state_service.dart';
import 'services/download_service.dart';
import 'services/connectivity_manager.dart';
import 'services/lyrics_cache.dart';
import 'services/lyrics_manager.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'providers/playlist_provider.dart';
import 'widgets/app_reconnection_listener.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MusicHubBootstrapApp());
}

const int _maxAndroidSharedPrefsFileBytes = 4 * 1024 * 1024;

Future<void> _cleanupOversizedSharedPrefsOnAndroid() async {
  if (!Platform.isAndroid) return;
  try {
    final supportDir = await getApplicationSupportDirectory();
    final appDir = Directory(supportDir.path).parent;
    final sharedPrefsDir = Directory(
      '${appDir.path}${Platform.pathSeparator}shared_prefs',
    );
    if (!await sharedPrefsDir.exists()) return;

    final prefsFile = File(
      '${sharedPrefsDir.path}${Platform.pathSeparator}FlutterSharedPreferences.xml',
    );
    if (!await prefsFile.exists()) return;

    final sizeBytes = await prefsFile.length();
    if (sizeBytes <= _maxAndroidSharedPrefsFileBytes) return;

    await prefsFile.delete();
    final backup = File('${prefsFile.path}.bak');
    if (await backup.exists()) {
      await backup.delete();
    }

    debugPrint(
      '[Startup] Removed oversized FlutterSharedPreferences.xml (${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB)',
    );
  } catch (e) {
    debugPrint('[Startup] SharedPreferences cleanup skipped: $e');
  }
}

Future<void> _initializeAppServices() async {
  await _cleanupOversizedSharedPrefsOnAndroid();

  // Fire backend warm-up immediately (non-blocking).
  unawaited(ApiService.warmUpBackend());

  await Future.wait([
    ConnectivityManager.init(),
    PreferencesService.init(),
    SessionStateService.init(),
    DownloadService.getDownloadsDirPath(),
    LyricsCache.init(),
  ]);

  // Background audio + notification + firebase initialization.
  //
  // Desktop platforms don't use `just_audio_background` (Android foreground
  // service / iOS background audio session), so skip it there.
  final initTasks = <Future<void>>[
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
  ];
  if (Platform.isAndroid || Platform.isIOS) {
    initTasks.add(
      JustAudioBackground.init(
        androidNotificationChannelId: 'com.jio.music_hub.audio',
        androidNotificationChannelName: 'Music Hub Playback',
        androidNotificationChannelDescription: 'Playback controls for Music Hub',
        notificationColor: const Color(0xFF12161F),
        androidNotificationIcon: 'drawable/ic_notification_mono',
      ),
    );
  }
  await Future.wait(initTasks);

  // Once Firebase is ready, start pre-fetching home data for the current user.
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser != null) {
    unawaited(
      PreferencesService.getPreferences(currentUser.uid).then((prefs) {
        if (prefs != null && prefs.onboardingComplete) {
          ApiService.preFetchHomeData(
            languages: prefs.languages,
            favoriteArtists: prefs.favoriteArtists,
          );
        }
      }),
    );
  }

  // Keep playback/offline services ready.
  await Future.wait([OfflineService.init(), PlayerService.init()]);

  // Non-critical services background sync.
  unawaited(_initializeDeferredServices());
}

Future<void> _initializeDeferredServices() async {
  await Future.wait([ListeningSafetyService.init(), PlaylistService.init()]);
}

class MusicHubBootstrapApp extends StatelessWidget {
  const MusicHubBootstrapApp({super.key});

  static final Future<void> _bootstrapFuture = _initializeAppServices();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: _BootstrapLoadingView(),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'App startup failed:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textPrimary),
                  ),
                ),
              ),
            ),
          );
        }

        return const MusicHubApp();
      },
    );
  }
}

class _BootstrapLoadingView extends StatelessWidget {
  const _BootstrapLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppTheme.primaryDark,
        alignment: Alignment.center,
        child: Image.asset(
          'assets/icon_foreground.png',
          width: 128,
          height: 128,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class MusicHubApp extends StatelessWidget {
  const MusicHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProxyProvider<AuthProvider, PreferencesProvider>(
          create: (_) => PreferencesProvider(),
          update: (_, auth, preferences) {
            final provider = preferences ?? PreferencesProvider();
            provider.syncWithAuth(auth.user);
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProxyProvider<PreferencesProvider, SearchProvider>(
          create: (_) => SearchProvider(),
          update: (_, prefs, search) {
            final provider = search ?? SearchProvider();
            provider.updatePreferredLanguages(prefs.languages);
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, DownloadProvider>(
          create: (_) => DownloadProvider(),
          update: (_, auth, downloads) {
            final provider = downloads ?? DownloadProvider();
            provider.syncWithAuth(auth.user);
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()),
        ChangeNotifierProvider(create: (_) => LyricsManager()),
      ],
      child: MaterialApp(
        title: 'Music Hub',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        navigatorKey: NavigatorHolder.navigatorKey,
        home: const SplashScreen(),
        builder: (context, child) {
          return AppReconnectionListener(child: child!);
        },
      ),
    );
  }
}
