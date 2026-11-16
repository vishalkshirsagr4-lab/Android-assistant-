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

  static const Map<String, bool> defaults = <String, bool>{
    voiceInput: true,
    voiceOutput: true,
    screenAutomation: true,
    aiScreenSharing: true,
    directPhoneActions: true,
    memory: true,
    scheduledReminders: true,
  };

  Future<bool> isEnabled(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? defaults[key] ?? false;
  }

  Future<void> setEnabled(String key, bool enabled) async {
    if (!defaults.containsKey(key)) {
      throw ArgumentError.value(key, 'key', 'Unknown Lucy capability');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, enabled);
  }

  Future<Map<String, bool>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return <String, bool>{
      for (final entry in defaults.entries)
        entry.key: prefs.getBool(entry.key) ?? entry.value,
    };
  }
}
