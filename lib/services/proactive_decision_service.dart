import 'package:flutter/services.dart';

class LucyProactiveStatus {
  final bool enabled;
  final int quietStartHour;
  final int quietEndHour;
  final int dailyLimit;
  final int cooldownMinutes;
  final String? lastSuggestion;
  final String? lastReason;
  final String? lastRisk;
  final double? lastConfidence;
  final DateTime? lastSuggestedAt;

  const LucyProactiveStatus({
    required this.enabled,
    required this.quietStartHour,
    required this.quietEndHour,
    required this.dailyLimit,
    required this.cooldownMinutes,
    this.lastSuggestion,
    this.lastReason,
    this.lastRisk,
    this.lastConfidence,
    this.lastSuggestedAt,
  });

  factory LucyProactiveStatus.fromMap(Map<String, dynamic> map) {
    final timestamp = map['lastSuggestionAt'];
    return LucyProactiveStatus(
      enabled: map['enabled'] == true,
      quietStartHour: (map['quietStartHour'] as num?)?.toInt() ?? 22,
      quietEndHour: (map['quietEndHour'] as num?)?.toInt() ?? 8,
      dailyLimit: (map['dailyLimit'] as num?)?.toInt() ?? 3,
      cooldownMinutes: (map['cooldownMinutes'] as num?)?.toInt() ?? 120,
      lastSuggestion: map['lastSuggestion']?.toString(),
      lastReason: map['lastReason']?.toString(),
      lastRisk: map['lastRisk']?.toString(),
      lastConfidence: (map['lastConfidence'] as num?)?.toDouble(),
      lastSuggestedAt: timestamp is num && timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
          : null,
    );
  }
}

class LucyProactiveService {
  static const MethodChannel _channel = MethodChannel(
    'com.poc.screen_aware_ai/proactive',
  );

  Future<bool> configure({
    required bool enabled,
    int quietStartHour = 22,
    int quietEndHour = 8,
    int dailyLimit = 3,
    int cooldownMinutes = 120,
  }) async {
    if (quietStartHour < 0 ||
        quietStartHour > 23 ||
        quietEndHour < 0 ||
        quietEndHour > 23 ||
        dailyLimit < 1 ||
        dailyLimit > 10 ||
        cooldownMinutes < 15 ||
        cooldownMinutes > 1440) {
      throw ArgumentError('Invalid proactive suggestion settings.');
    }
    try {
      return await _channel.invokeMethod<bool>('configure', {
            'enabled': enabled,
            'quietStartHour': quietStartHour,
            'quietEndHour': quietEndHour,
            'dailyLimit': dailyLimit,
            'cooldownMinutes': cooldownMinutes,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<LucyProactiveStatus> readStatus() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('status');
      return LucyProactiveStatus.fromMap(map ?? const <String, dynamic>{});
    } on PlatformException {
      return const LucyProactiveStatus(
        enabled: false,
        quietStartHour: 22,
        quietEndHour: 8,
        dailyLimit: 3,
        cooldownMinutes: 120,
      );
    } on MissingPluginException {
      return const LucyProactiveStatus(
        enabled: false,
        quietStartHour: 22,
        quietEndHour: 8,
        dailyLimit: 3,
        cooldownMinutes: 120,
      );
    }
  }

  Future<bool> clearData() async {
    try {
      return await _channel.invokeMethod<bool>('clearData') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> runEvaluationNow() async {
    try {
      return await _channel.invokeMethod<bool>('runEvaluationNow') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String?> explainLastSuggestion() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('explain');
      final reason = map?['reason']?.toString().trim();
      if (reason == null || reason.isEmpty) return null;
      final confidence = (map?['confidence'] as num?)?.toDouble();
      final risk = map?['risk']?.toString() ?? 'low';
      final confidenceText = confidence == null
          ? 'not available'
          : '${(confidence * 100).round()}%';
      return '$reason Confidence: $confidenceText. Risk: $risk.';
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
