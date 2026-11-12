import 'package:flutter/services.dart';

/// Bridge to Android WorkManager. Scheduled items are deliberately reminders
/// only; arbitrary unattended device actions are not exposed.
class LucyRoutineScheduler {
  static const MethodChannel _channel =
      MethodChannel('com.poc.screen_aware_ai/routines');

  static Future<void> scheduleReminder({
    required String id,
    required String title,
    required String body,
    required int delayMinutes,
  }) async {
    if (id.isEmpty || title.trim().isEmpty ||
        delayMinutes < 1 || delayMinutes > 525600) {
      throw ArgumentError('Invalid reminder details.');
    }
    final scheduled = await _channel.invokeMethod<bool>('scheduleReminder', {
      'id': id,
      'title': title.trim(),
      'body': body.trim(),
      'delayMinutes': delayMinutes,
    });
    if (scheduled != true) {
      throw StateError('Android did not confirm the reminder schedule.');
    }
  }

  static Future<void> cancelReminder(String id) async {
    await _channel.invokeMethod<bool>('cancelReminder', {'id': id});
  }
}
