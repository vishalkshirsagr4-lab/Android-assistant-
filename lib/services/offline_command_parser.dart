/// Deterministic parser for short phone communication commands.
///
/// This parser only extracts the user's explicit recipient and message. It
/// never guesses a recipient or message body; unresolved contacts are handled
/// by the native contact matcher and ambiguous results are returned to Lucy.
class OfflineCommunicationCommand {
  const OfflineCommunicationCommand({
    required this.action,
    required this.target,
    this.message,
  });

  final String action;
  final String target;
  final String? message;

  static OfflineCommunicationCommand? parse(String input) {
    final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return null;

    final smsPatterns = <RegExp>[
      RegExp(
        r'^(?:please\s+)?send\s+(?:an?\s+)?(?:sms|text|message)\s+to\s+(.+?)\s*[:,]\s*(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:please\s+)?(?:sms|text|message)\s+to\s+(.+?)\s*[:,]\s*(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(.+?)\s+(?:ko|को)\s+(?:sms|message|मैसेज|संदेश)\s+(?:bhejo|भेजो|ಕಳುಹಿಸು)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(.+?)\s+(?:ಗೆ)\s+(?:sms|ಸಂದೇಶ)\s+(?:ಕಳುಹಿಸು)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:sms|message|मैसेज)\s+(.+?)\s+(?:ko|को)\s+(.+?)\s+(?:bhejo|भेजो|ಕಳುಹಿಸು)$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in smsPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final target = match.group(1)?.trim() ?? '';
        final message = match.group(2)?.trim() ?? '';
        if (target.isNotEmpty && message.isNotEmpty) {
          return OfflineCommunicationCommand(
            action: 'send_sms',
            target: target,
            message: message,
          );
        }
      }
    }

    final callPatterns = <RegExp>[
      RegExp(
        r'^(?:please\s+)?(?:call|dial|phone)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(.+?)\s+(?:ko|को)\s+(?:call|कॉल|phone|फोन)\s*(?:karo|करो|lagao|लगाओ|ಮಾಡು)?$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:कॉल करो|फोन करो)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(.+?)\s+(?:ಗೆ)\s+(?:ಕರೆಮಾಡು|ಕರೆ ಮಾಡಿ)$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in callPatterns) {
      final match = pattern.firstMatch(text);
      final target = match?.group(1)?.trim();
      if (target != null && target.isNotEmpty) {
        return OfflineCommunicationCommand(
          action: 'place_call',
          target: target,
        );
      }
    }
    return null;
  }
}


/// Deterministic parser for direct app-launch requests.
/// The app name is resolved against installed Android launcher activities.
class OfflineAppCommand {
  const OfflineAppCommand({required this.appName});

  final String appName;

  static OfflineAppCommand? parse(String input) {
    final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return null;

    final match = RegExp(
      r'^(?:please\s+)?(?:open|launch|start|खोलो|खोल|शुरू\s*करो|ಶುರುಮಾಡು|ತೆರೆ|ತೆರೆಯಿರಿ|開いて|افتح)\s+(.+?)$|^(.+?)\s+(?:kholo|khol\s+do|खोलो|खोल\s+दो|ತೆರೆ|ತೆರೆಯಿರಿ)$',
      caseSensitive: false,
    ).firstMatch(text);
    final appName = (match?.group(1) ?? match?.group(2))\n        ?.replaceAll(RegExp(r'[.!?,।]+
    if (appName == null || appName.isEmpty) return null;

    final normalized = appName.toLowerCase();
    const settingsNames = {
      'settings', 'setting', 'ಸೆಟ್ಟಿಂಗ್ಸ್', 'ಸೆಟ್ಟಿಂಗ್', 'सेटिंग्स',
      'सेटिंग', 'wifi settings', 'wi-fi settings', 'bluetooth settings',
      'display settings', 'sound settings', 'accessibility settings',
      'location settings', 'battery settings', 'wireless settings',
    };
    if (settingsNames.contains(normalized)) return null;
    return OfflineAppCommand(appName: appName);
  }
}
), '')\n        .trim();
    if (appName == null || appName.isEmpty) return null;

    final normalized = appName.toLowerCase();
    const settingsNames = {
      'settings', 'setting', 'ಸೆಟ್ಟಿಂಗ್ಸ್', 'ಸೆಟ್ಟಿಂಗ್', 'सेटिंग्स',
      'सेटिंग', 'wifi settings', 'wi-fi settings', 'bluetooth settings',
      'display settings', 'sound settings', 'accessibility settings',
      'location settings', 'battery settings', 'wireless settings',
    };
    if (settingsNames.contains(normalized)) return null;
    return OfflineAppCommand(appName: appName);
  }
}
