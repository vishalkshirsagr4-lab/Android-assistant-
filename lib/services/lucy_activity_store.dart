import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local-only activity history. Screenshots and credentials are never stored.
class LucyActivityStore {
  static const _eventsKey = 'lucy_activity_events_v1';
  static const _routinesKey = 'lucy_automation_templates_v1';
  static const _maxEvents = 300;

  Future<void> seedDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_routinesKey)) {
      await prefs.setString(
        _routinesKey,
        jsonEncode([
          {'id': 'morning_brief', 'name': 'Morning briefing', 'enabled': false, 'requiresApproval': true},
          {'id': 'focus_mode', 'name': 'Focus session', 'enabled': false, 'requiresApproval': true},
          {'id': 'quick_notes', 'name': 'Quick note capture', 'enabled': false, 'requiresApproval': true},
        ]),
      );
    }
  }

  Future<void> record(String type, String summary) async {
    final prefs = await SharedPreferences.getInstance();
    final events = await readEvents();
    events.add({
      'time': DateTime.now().toIso8601String(),
      'type': type,
      'summary': _safeSummary(summary),
    });
    final bounded = events.length > _maxEvents
        ? events.sublist(events.length - _maxEvents)
        : events;
    await prefs.setString(_eventsKey, jsonEncode(bounded));
  }

  Future<List<Map<String, dynamic>>> readEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_eventsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> readAutomationTemplates() async {
    await seedDefaults();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_routinesKey) ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> clearEvents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_eventsKey);
  }

  String _safeSummary(String value) {
    var cleaned = value.replaceAll(RegExp(r'\\s+'), ' ').trim();

    // Redact common credential, authentication and one-time-code formats.
    final sensitivePatterns = <RegExp>[
      RegExp(r'(?i)(password|passwd|passcode|otp|pin|api[_ -]?key|token|secret)\\s*[:=]\\s*[^\\s,;]+'),
      RegExp(r'(?i)bearer\\s+[a-z0-9._~+/-]+=*'),
      RegExp(r'AIza[0-9A-Za-z_-]{20,}', caseSensitive: false),
      RegExp(r'xai-[0-9A-Za-z_-]{12,}', caseSensitive: false),
      RegExp(r'\\b\\d{4,8}\\b'),
    ];
    for (final pattern in sensitivePatterns) {
      cleaned = cleaned.replaceAll(pattern, '[redacted]');
    }

    if (cleaned.length <= 180) return cleaned;
    return '${cleaned.substring(0, 177)}...';
  }
}
