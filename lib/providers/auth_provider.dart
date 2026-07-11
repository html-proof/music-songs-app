import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/download_service.dart';
import '../services/offline_service.dart';
import '../services/player_service.dart';

class AuthProvider extends ChangeNotifier {
  User? _user;
  bool _loading = true;
  StreamSubscription<User?>? _authSubscription;

  User? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    _user = AuthService.currentUser;
    _loading = false;
    notifyListeners();

    _authSubscription?.cancel();
    _authSubscription = AuthService.authStateChanges.listen((user) {
      _user = user;
      _loading = false;
      notifyListeners();
    });
  }

  Future<bool> signInWithGoogle() async {
    try {
      _loading = true;
      notifyListeners();
      final user = await AuthService.signInWithGoogle();
      _user = user;
      return user != null;
    } catch (e) {
      debugPrint('Sign in error: $e');
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> signInAnonymously() async {
    try {
      _loading = true;
      notifyListeners();
      final user = await AuthService.signInAnonymously();
      _user = user;
      return user != null;
    } catch (e) {
      debugPrint('Anonymous sign in error: $e');
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _loading = true;
    notifyListeners();
    final uid = _user?.uid;
    await PlayerService.persistAndStopForLogout();
    await DownloadService.persistAndStopForLogout(uid: uid);
    await OfflineService.persistAndStopForLogout();
    await AuthService.signOut();
    _user = null;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
