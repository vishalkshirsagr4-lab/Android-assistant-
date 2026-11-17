import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Emits structured diagnostics without accepting prompt text, screenshots,
/// API keys, notification bodies, phone numbers or arbitrary exception text.
class LucyReliabilityLog {
  LucyReliabilityLog._();

  static void event(
    String name, {
    String? provider,
    String? action,
    int? step,
    int? attempt,
    int? elapsedMs,
    bool? success,
    String? errorType,
    bool? cacheHit,
  }) {
    if (!kDebugMode) return;
    final record = <String, Object?>{
      'component': 'LucyReliability',
      'event': name,
      'at': DateTime.now().toUtc().toIso8601String(),
      if (provider != null) 'provider': _safeToken(provider),
      if (action != null) 'action': _safeToken(action),
      if (step != null) 'step': step,
      if (attempt != null) 'attempt': attempt,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (success != null) 'success': success,
      if (errorType != null) 'errorType': _safeToken(errorType),
      if (cacheHit != null) 'cacheHit': cacheHit,
    };
    debugPrint(jsonEncode(record));
  }

  static String _safeToken(String value) {
    final normalized = value.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '');
    return normalized.length > 48
        ? normalized.substring(0, 48)
        : normalized;
  }
}

/// Detects repeated attempts against an unchanged screen. It never repeats an
/// action itself: it asks the model to re-plan, and limits re-plans per task.
class LucyAgentLoopGuard {
  LucyAgentLoopGuard({this.maxReplans = 2});

  final int maxReplans;
  final Map<String, int> _actionAttempts = <String, int>{};
  final Map<String, Set<String>> _actionsPerScreen =
      <String, Set<String>>{};
  final Map<String, int> _attemptsPerScreen = <String, int>{};
  int _replans = 0;

  int get replans => _replans;
  bool get canReplan => _replans < maxReplans;

  bool shouldReplan({
    required String actionType,
    required String? packageName,
    required String uiSignature,
  }) {
    final screenKey = '${packageName ?? ''}|${uiSignature.hashCode}';
    final actionKey = '$screenKey|${actionType.toLowerCase()}';
    final actionCount = (_actionAttempts[actionKey] ?? 0) + 1;
    _actionAttempts[actionKey] = actionCount;
    final screenCount = (_attemptsPerScreen[screenKey] ?? 0) + 1;
    _attemptsPerScreen[screenKey] = screenCount;
    _actionsPerScreen.putIfAbsent(screenKey, () => <String>{})
      ..add(actionType.toLowerCase());

    return actionCount >= 2 ||
        (screenCount >= 3 && _actionsPerScreen[screenKey]!.length >= 3);
  }

  void markReplanned() {
    _replans++;
    _actionAttempts.clear();
    _actionsPerScreen.clear();
    _attemptsPerScreen.clear();
  }

  void reset() {
    _actionAttempts.clear();
    _actionsPerScreen.clear();
    _attemptsPerScreen.clear();
    _replans = 0;
  }
}
