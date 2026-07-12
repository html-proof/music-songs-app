import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackgroundLearningService {
  static const String _prefKey = 'search_playback_learning_data_v2';
  static Map<String, dynamic> _learningData = {};

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dataStr = prefs.getString(_prefKey);
      if (dataStr != null) {
        _learningData = json.decode(dataStr) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Failed to load telemetry learning data: $e');
    }
  }

  static Future<void> recordUserSelection({required String query, required String songId}) async {
    final cleanQuery = query.toLowerCase().trim();
    if (cleanQuery.isEmpty || songId.isEmpty) return;

    final key = 'query_boost:$cleanQuery';
    final current = Map<String, dynamic>.from(_learningData[key] as Map? ?? {});
    final count = current[songId] as int? ?? 0;
    current[songId] = count + 1;
    _learningData[key] = current;
    await _save();
  }

  static Future<void> recordImmediateSkip({required String songId}) async {
    if (songId.isEmpty) return;
    final key = 'skip_penalty:$songId';
    final currentCount = _learningData[key] as int? ?? 0;
    _learningData[key] = currentCount + 1;
    await _save();
  }

  static Future<void> recordReplay({required String songId}) async {
    if (songId.isEmpty) return;
    final key = 'replay_boost:$songId';
    final currentCount = _learningData[key] as int? ?? 0;
    _learningData[key] = currentCount + 1;
    await _save();
  }

  static double getBiasBoost(String songId, {String? query}) {
    if (songId.isEmpty) return 0.0;
    double boost = 0.0;

    // 1. Global replay boost
    final replayKey = 'replay_boost:$songId';
    final replayCount = _learningData[replayKey] as int? ?? 0;
    boost += replayCount * 3.0;

    // 2. Global skip penalty (heavier weight to prevent repeating errors)
    final skipKey = 'skip_penalty:$songId';
    final skipCount = _learningData[skipKey] as int? ?? 0;
    boost -= skipCount * 5.0;

    // 3. Query specific selection boost
    if (query != null) {
      final cleanQuery = query.toLowerCase().trim();
      if (cleanQuery.isNotEmpty) {
        final queryKey = 'query_boost:$cleanQuery';
        final queryMap = _learningData[queryKey] as Map?;
        if (queryMap != null) {
          final selectionCount = queryMap[songId] as int? ?? 0;
          boost += selectionCount * 12.0;
        }
      }
    }

    return boost;
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, json.encode(_learningData));
    } catch (e) {
      debugPrint('Failed to save telemetry learning data: $e');
    }
  }
}
