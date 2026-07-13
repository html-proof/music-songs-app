import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_service.dart';
import 'stability_logger.dart';

enum ConnectionStatus {
  connected,
  disconnected,
  weak,
}

enum ConnectivityEvent {
  connected,
  disconnected,
  weak,
  restored,
}

class ConnectivityManager {
  static final ConnectivityManager _instance = ConnectivityManager._internal();
  factory ConnectivityManager() => _instance;
  ConnectivityManager._internal();

  static const String _probeUrl = 'https://www.google.com';
  static const Duration _probeTimeout = Duration(seconds: 2);

  static ConnectionStatus _currentStatus = ConnectionStatus.connected;
  static ConnectionStatus get currentStatus => _currentStatus;

  static bool get isConnected => _currentStatus != ConnectionStatus.disconnected;
  static bool get isOffline => _currentStatus == ConnectionStatus.disconnected;
  static bool get isWeak => _currentStatus == ConnectionStatus.weak;

  static Future<bool> isOnWifiOrEthernet() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
  }

  static final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();
  static Stream<ConnectionStatus> get statusStream => _statusController.stream;

  static final StreamController<ConnectivityEvent> _eventController =
      StreamController<ConnectivityEvent>.broadcast();
  static Stream<ConnectivityEvent> get eventStream => _eventController.stream;

  static StreamSubscription<List<ConnectivityResult>>? _subscription;
  static bool _isInitialized = false;

  static Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    final connectivity = Connectivity();
    final initialResults = await connectivity.checkConnectivity();
    await _updateState(initialResults, isInitial: true);

    _subscription = connectivity.onConnectivityChanged.listen((results) {
      _updateState(results);
    });
  }

  static Future<void> _updateState(List<ConnectivityResult> results, {bool isInitial = false}) async {
    final previousStatus = _currentStatus;
    final hasConnection = results.any((r) => r != ConnectivityResult.none);

    ConnectionStatus nextStatus;
    if (!hasConnection) {
      nextStatus = ConnectionStatus.disconnected;
    } else {
      // Check if connection is weak. If it's wifi/ethernet, assume strong.
      // If it's mobile, do a quick latency/ping check.
      final isWifiOrEthernet = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn);

      if (isWifiOrEthernet) {
        nextStatus = ConnectionStatus.connected;
      } else {
        // Mobile connection: test latency/reachability
        final isFast = await _checkLatency();
        nextStatus = isFast ? ConnectionStatus.connected : ConnectionStatus.weak;
      }
    }

    _currentStatus = nextStatus;

    if (isInitial || previousStatus != nextStatus) {
      _statusController.add(nextStatus);

      // Determine Event
      if (nextStatus == ConnectionStatus.disconnected) {
        _eventController.add(ConnectivityEvent.disconnected);
      } else if (nextStatus == ConnectionStatus.weak) {
        _eventController.add(ConnectivityEvent.weak);
      } else {
        // Status is connected
        if (previousStatus == ConnectionStatus.disconnected ||
            previousStatus == ConnectionStatus.weak) {
          _eventController.add(ConnectivityEvent.restored);
        } else {
          _eventController.add(ConnectivityEvent.connected);
        }
      }
      StabilityLogger.info('Connectivity', 'State changed from $previousStatus to $nextStatus');
    }
  }

  static Future<bool> _checkLatency() async {
    try {
      final client = ApiService.createSecureHttpClient(pinCertificates: false);
      final stopwatch = Stopwatch()..start();
      final response = await client
          .head(Uri.parse(_probeUrl))
          .timeout(_probeTimeout);
      stopwatch.stop();
      client.close();

      if (response.statusCode >= 200 && response.statusCode < 400) {
        // Latency threshold for "weak" connection: 800ms
        return stopwatch.elapsedMilliseconds < 800;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _isInitialized = false;
  }
}
