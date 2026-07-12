import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

class StabilityLogger {
  static LogLevel currentLogLevel = LogLevel.debug;

  static void log(
    LogLevel level,
    String category,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (level.index < currentLogLevel.index) return;

    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase();
    final logMessage = '[$timestamp] [$levelStr] [$category] $message';

    if (error != null) {
      debugPrint('$logMessage | Error: $error');
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    } else {
      debugPrint(logMessage);
    }
  }

  static void debug(String category, String message) =>
      log(LogLevel.debug, category, message);

  static void info(String category, String message) =>
      log(LogLevel.info, category, message);

  static void warning(String category, String message, [Object? error]) =>
      log(LogLevel.warning, category, message, error);

  static void error(
    String category,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) => log(LogLevel.error, category, message, error, stackTrace);
}
