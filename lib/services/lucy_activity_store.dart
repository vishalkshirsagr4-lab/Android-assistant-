import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local-only activity history. Screenshots and credentials are never stored.
class LucyActivityStore {
  static const _eventsKey = 'lucy_activity_events_v1';
  static const _routinesKey = 'lucy_automation_templates_v1';
  static const _maxEvents = 300;
  static const _privacyVersionKey = 'lucy_activity_privacy_version';

  Future<void> seedDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getInt(_privacyVersionKey) ?? 0) < 2) {
      await prefs.remove(_eventsKey);
      await prefs.setInt(_privacyVersionKey, 2);
    }
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

  Future<void> record(String type) async {
    final prefs = await SharedPreferences.getInstance();
    final events = await readEvents();
    events.add({
      'time': DateTime.now().toIso8601String(),
      'type': type,
      'summary': _safeSummary(type),
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

  String _safeSummary(String type) {
    // Store metadata only. Never persist chat text, screenshots, UI labels or typed values.
    switch (type) {
      case 'user_message': return 'User message received';
      case 'assistant_message': return 'Lucy response generated';
      default: return 'Activity event';
    }
  }}
