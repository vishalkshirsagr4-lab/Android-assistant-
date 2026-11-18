import 'dart:convert';
import 'package:flutter/services.dart';

/// Loads only the hint document for the foreground package, keeping provider
/// prompts small and avoiding one giant app-specific instruction block.
class LucyAppHintCatalog {
  static const Map<String, String> _packages = {
    'com.google.android.gm': 'gmail',
    'com.whatsapp': 'whatsapp',
    'com.whatsapp.w4b': 'whatsapp',
    'com.android.chrome': 'chrome',
    'com.google.android.youtube': 'youtube',
    'com.instagram.android': 'instagram',
    'org.telegram.messenger': 'telegram',
    'com.google.android.apps.maps': 'maps',
    'com.android.settings': 'settings',
    'com.google.android.calendar': 'calendar',
    'com.google.android.keep': 'notes',
    'com.google.android.apps.nbu.files': 'files',
  };

  final Map<String, Map<String, dynamic>> _cache = {};

  Future<Map<String, dynamic>> loadForPackage(String? packageName) async {
    final key = _packages[packageName] ?? '';
    if (key.isEmpty) return const {};
    final cached = _cache[key];
    if (cached != null) return Map<String, dynamic>.unmodifiable(cached);
    try {
      final raw = await rootBundle.loadString('assets/app_hints/$key.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final value = Map<String, dynamic>.from(decoded);
        _cache[key] = value;
        return Map<String, dynamic>.unmodifiable(value);
      }
    } catch (_) {
      // Missing/invalid hint files simply fall back to generic screen logic.
    }
    return const {};
  }
}
