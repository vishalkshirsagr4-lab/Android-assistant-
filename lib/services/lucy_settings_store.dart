import 'package:shared_preferences/shared_preferences.dart';

/// On-device capability switches. A missing value uses the safe default.
class LucySettingsStore {
  static const voiceInput = 'lucy_cap_voice_input';
  static const voiceOutput = 'lucy_cap_voice_output';
  static const screenAutomation = 'lucy_cap_screen_automation';
  static const aiScreenSharing = 'lucy_cap_ai_screen_sharing';
  static const directPhoneActions = 'lucy_cap_direct_phone_actions';
  static const memory = 'lucy_cap_memory';
  static const scheduledReminders = 'lucy_cap_scheduled_reminders';
  static const aiRequests = 'lucy_cap_ai_requests';
  static const providerFallback = 'lucy_cap_provider_fallback';
  static const foregroundAppContext = 'lucy_context_foreground_app_enabled';
  static const autopilot = 'lucy_autopilot_low_risk';
  static const safetyStop = 'lucy_safety_stop';
  static const askBeforeSending = 'lucy_ask_before_sending';
  static const screenWatcher = 'lucy_screen_watcher_enabled';
  static const autoSkipAds = 'lucy_auto_skip_ads';
  static const autoDismissPopups = 'lucy_auto_dismiss_popups';

  static const Map<String, bool> defaults = <String, bool>{
    voiceInput: true,
    voiceOutput: true,
    screenAutomation: true,
    aiScreenSharing: true,
    directPhoneActions: true,
    memory: true,
    scheduledReminders: true,
    aiRequests: true,
    providerFallback: true,
    foregroundAppContext: true,
    autopilot: true,
    safetyStop: true,
    askBeforeSending: true,
    screenWatcher: true,
    autoSkipAds: true,
    autoDismissPopups: true,
  };

  /// These controls are intentionally non-disableable: they protect users
  /// from unattended external actions and security-sensitive changes.
  static const Set<String> mandatorySafetyControls = <String>{
    safetyStop,
    askBeforeSending,
  };

  Future<bool> isEnabled(String key) async {
    if (mandatorySafetyControls.contains(key)) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? defaults[key] ?? false;
  }

  Future<void> setEnabled(String key, bool enabled) async {
    if (!defaults.containsKey(key)) {
      throw ArgumentError.value(key, 'key', 'Unknown Lucy capability');
    }
    if (mandatorySafetyControls.contains(key) && !enabled) {
      throw StateError('This safety control cannot be disabled.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, enabled);
  }

  Future<Map<String, bool>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return <String, bool>{
      for (final entry in defaults.entries)
        entry.key: mandatorySafetyControls.contains(entry.key)
            ? true
            : prefs.getBool(entry.key) ?? entry.value,
    };
  }
}
