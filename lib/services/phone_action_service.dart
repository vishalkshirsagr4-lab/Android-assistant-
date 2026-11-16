import 'package:flutter/services.dart';

/// Bridge to native Android intents and device APIs for fast, direct actions.
class PhoneActionService {
  static const MethodChannel _channel =
      MethodChannel('com.poc.screen_aware_ai/phone_actions');

  static const Set<String> supportedActions = {
    'set_alarm',
    'set_timer',
    'place_call',
    'send_sms',
    'open_url',
    'start_navigation',
    'music_search',
    'set_flashlight',
    'set_volume',
    'set_brightness',
    'get_device_status',
    'read_contact',
    'create_calendar_event',
    'open_settings',
    'take_photo',
    'share_text',
  };

  Future<dynamic> execute(
    String action,
    Map<String, dynamic> params,
  ) async {
    if (!supportedActions.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported phone action');
    }

    try {
      return await _invoke(action, params);
    } on PlatformException catch (error) {
      if (error.code != 'PERMISSION_REQUIRED') rethrow;
      final permission = error.message;
      if (permission == null || permission.isEmpty) rethrow;

      final granted = await _channel.invokeMethod<bool>(
        'requestPermission',
        <String, dynamic>{'permission': permission},
      );
      if (granted != true) return false;
      return _invoke(action, params);
    }
  }

  Future<dynamic> _invoke(
    String action,
    Map<String, dynamic> params,
  ) {
    return _channel.invokeMethod<dynamic>(
      action,
      Map<String, dynamic>.from(params),
    );
  }
}
