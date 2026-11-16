import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds a small, on-demand device context block for Lucy's AI requests.
///
/// Optional sources are returned by Android only when their matching access
/// has been granted. The service does not poll or upload anything in the
/// background.
class LucyContextBuilder {
  static const MethodChannel _channel = MethodChannel(
    'com.poc.screen_aware_ai/context',
  );

  Future<Map<String, dynamic>> readStatus() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getContextSnapshot',
      );
      return status ?? <String, dynamic>{};
    } on PlatformException {
      return <String, dynamic>{};
    } on MissingPluginException {
      return <String, dynamic>{};
    }
  }

  Future<bool> _requestPermission(String permission) async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestPermission',
            <String, dynamic>{'permission': permission},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> requestCalendarAccess() =>
      _requestPermission('android.permission.READ_CALENDAR');

  Future<bool> openNotificationAccessSettings() async =>
      _invokeBoolean('openNotificationAccessSettings');

  Future<bool> openUsageAccessSettings() async =>
      _invokeBoolean('openUsageAccessSettings');

  Future<bool> setNotificationContextEnabled(bool enabled) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setNotificationContextEnabled',
            <String, dynamic>{'enabled': enabled},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> clearNotificationHistory() async =>
      _invokeBoolean('clearNotificationHistory');

  Future<bool> enableApproximateLocation() async {
    final granted = await _requestPermission(
      'android.permission.ACCESS_COARSE_LOCATION',
    );
    if (!granted) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setLocationContextEnabled',
            <String, dynamic>{'enabled': true},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> setCalendarContextEnabled(bool enabled) async {
    try {
      final saved = await _channel.invokeMethod<bool>(
            'setCalendarContextEnabled',
            <String, dynamic>{'enabled': enabled},
          ) ??
          false;
      if (saved) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('lucy_context_calendar_enabled', enabled);
      }
      return saved;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> disableApproximateLocation() async {
    try {
      return await _channel.invokeMethod<bool>(
            'setLocationContextEnabled',
            <String, dynamic>{'enabled': false},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _invokeBoolean(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Produces a compact block. Only this returned text is attached to an
  /// AI request; raw notification history is never sent as a separate feed.
  Future<String> buildPromptContext() async {
    final now = DateTime.now();
    final status = await readStatus();
    final prefs = await SharedPreferences.getInstance();
    final calendarEnabled = prefs.getBool('lucy_context_calendar_enabled') ?? false;
    final lines = <String>[
      'Local time: ${_weekday(now.weekday)}, ${now.toIso8601String()} (${now.timeZoneName}).',
    ];

    final battery = status['batteryPercent'];
    if (battery is num) {
      lines.add(
        'Battery: ${battery.round()}%, ${status['charging'] == true ? 'charging' : 'not charging'}.',
      );
    }

    final network = status['network'];
    if (network is String && network.isNotEmpty) {
      lines.add('Network: ${_clean(network, 60)}.');
    }

    final foregroundApp = status['foregroundApp'];
    if (foregroundApp is String && foregroundApp.isNotEmpty) {
      lines.add('Foreground app: ${_clean(foregroundApp, 60)}.');
    }

    final notifications = status['notificationContextEnabled'] == true
        ? status['notifications']
        : null;
    if (notifications is List && notifications.isNotEmpty) {
      final counts = <String, int>{};
      for (final raw in notifications) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final sender = _clean(item['sender']?.toString() ?? '', 40);
        final app = _clean(item['app']?.toString() ?? 'App', 40);
        final label = sender.isNotEmpty ? sender : app;
        counts.update(label, (count) => count + 1, ifAbsent: () => 1);
      }
      if (counts.isNotEmpty) {
        final summary = counts.entries
            .take(6)
            .map((entry) => '${entry.value} from ${entry.key}')
            .join('; ');
        lines.add('Notification summary (last 24 hours): $summary.');
      }
      lines.add('Recent notification details (up to 5; locally cached):');
      for (final raw in notifications.take(5)) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final app = _clean(item['app']?.toString() ?? 'App', 40);
        final sender = _clean(item['sender']?.toString() ?? '', 40);
        final title = _clean(item['title']?.toString() ?? '', 70);
        final body = _clean(item['text']?.toString() ?? '', 150);
        final timestamp = item['timestamp'];
        final age = timestamp is num
            ? _relativeTime(
                now,
                DateTime.fromMillisecondsSinceEpoch(timestamp.toInt()),
              )
            : '';
        final parts = <String>[
          app,
          if (sender.isNotEmpty) 'from $sender',
          if (title.isNotEmpty) title,
          if (body.isNotEmpty) body,
          if (age.isNotEmpty) age,
        ];
        lines.add('- ${parts.join(' · ')}');
      }
    }

    final events = calendarEnabled ? status['calendarEvents'] : null;
    if (events is List && events.isNotEmpty) {
      lines.add('Upcoming calendar events (next 6 hours):');
      for (final raw in events.take(4)) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final title = _clean(item['title']?.toString() ?? 'Untitled event', 80);
        final start = item['startTimeMillis'];
        final location = _clean(item['location']?.toString() ?? '', 60);
        final startText = start is num
            ? DateTime.fromMillisecondsSinceEpoch(
                start.toInt(),
              ).toLocal().toString()
            : 'time unavailable';
        lines.add(
          '- $title at $startText${location.isEmpty ? '' : ' · $location'}',
        );
      }
    }

    final location = status['approximateLocation'];
    if (location is Map) {
      final latitude = location['latitude'];
      final longitude = location['longitude'];
      if (latitude is num && longitude is num) {
        lines.add(
          'Approximate location (rounded): ${latitude.toStringAsFixed(2)}, ${longitude.toStringAsFixed(2)}.',
        );
      }
    }

    return '[DEVICE_CONTEXT]\n${lines.join('\n')}\n[/DEVICE_CONTEXT]';
  }

  static String _weekday(int weekday) {
    const names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[weekday - 1];
  }

  static String _relativeTime(DateTime now, DateTime timestamp) {
    final difference = now.difference(timestamp);
    if (difference.inMinutes < 1 && !difference.isNegative) return 'just now';
    if (difference.inMinutes < 60 && !difference.isNegative) {
      return '${difference.inMinutes}m ago';
    }
    if (difference.inHours < 24 && !difference.isNegative) {
      return '${difference.inHours}h ago';
    }
    return '';
  }

  static String _clean(String value, int maxLength) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength - 1)}…';
  }
}
