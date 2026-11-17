/// Local action-risk policy. Model metadata can only increase, never reduce, risk.
class LucyActionApprovalPolicy {
  static const Set<String> _sensitiveTapLabels = {
    'send', 'send message', 'send now', 'post', 'publish', 'share',
    'send money', 'transfer money', 'delete', 'delete permanently',
    'remove', 'buy', 'purchase', 'pay', 'checkout', 'confirm payment',
    'submit order', 'uninstall', 'call', 'video call', 'place call',
    'make call', 'start call', 'dial', 'confirm', 'submit', 'transfer',
    'install', 'allow', 'grant', 'enable administrator',
  };

  static const Set<String> _messagingPackages = {
    'com.whatsapp',
    'org.telegram.messenger',
    'com.google.android.apps.messaging',
    'com.facebook.orca',
    'com.instagram.android',
    'com.android.dialer',
    'com.google.android.dialer',
    'com.android.contacts',
  };

  static const Set<String> _sensitivePackageMarkers = {
    'bank',
    'wallet',
    'payment',
    'upi',
    'finance',
  };

  static const Set<String> _lowRiskActions = {
    'open_app',
    'type',
    'swipe',
    'back',
    'home',
    'wait',
    'schedule_reminder',
    'set_alarm',
    'set_timer',
    'open_url',
    'start_navigation',
    'music_search',
    'set_flashlight',
    'set_volume',
    'set_brightness',
    'get_device_status',
  };

  /// Computes risk locally. A model may raise risk, but cannot lower it.
  ///
  /// [sensitiveInput] is true when the focused accessibility field is a
  /// password field. Financial-app text entry is also treated as high risk.
  static String effectiveRisk(
    String action, {
    String? targetLabel,
    String? packageName,
    String? modelRisk,
    double? confidence,
    bool sensitiveInput = false,
  }) {
    final package = (packageName ?? '').toLowerCase();
    final sensitivePackage = _sensitivePackageMarkers.any(package.contains);
    var localRisk = 'high';

    if (action == 'type') {
      localRisk = sensitiveInput || sensitivePackage ? 'high' : 'low';
    } else if (_lowRiskActions.contains(action)) {
      localRisk = 'low';
    } else if (action == 'place_call' ||
        action == 'send_sms' ||
        action == 'share_text') {
      localRisk = 'high';
    } else if (action == 'read_contact' ||
        action == 'create_calendar_event' ||
        action == 'take_photo') {
      localRisk = 'medium';
    } else if (action == 'open_settings') {
      final page = (targetLabel ?? '').toLowerCase();
      localRisk = page.contains('security') ||
              page.contains('account') ||
              page.contains('password') ||
              page.contains('privacy') ||
              page.contains('developer')
          ? 'high'
          : 'medium';
    } else if (action == 'tap') {
      final label = (targetLabel ?? '').trim().toLowerCase();
      if (sensitivePackage ||
          _sensitiveTapLabels.any(label.contains) ||
          (label.isEmpty && _messagingPackages.contains(package))) {
        localRisk = 'high';
      } else if (label.isEmpty) {
        localRisk = 'medium';
      } else {
        localRisk = 'low';
      }
    }

    var rank = _rank(localRisk);
    final modelRank = _rank(_normalizeRisk(modelRisk));
    if (modelRank > rank) rank = modelRank;
    if (confidence != null && confidence < 0.55 && rank < 1) {
      rank = 1;
    }
    return rank == 0 ? 'low' : rank == 1 ? 'medium' : 'high';
  }

  static bool requiresApproval(
    String action, {
    String? targetLabel,
    String? packageName,
    String? modelRisk,
    double? confidence,
    bool sensitiveInput = false,
  }) {
    return effectiveRisk(
          action,
          targetLabel: targetLabel,
          packageName: packageName,
          modelRisk: modelRisk,
          confidence: confidence,
          sensitiveInput: sensitiveInput,
        ) !=
        'low';
  }

  static int _rank(String risk) {
    switch (risk) {
      case 'low':
        return 0;
      case 'medium':
        return 1;
      default:
        return 2;
    }
  }

  static String _normalizeRisk(String? risk) {
    if (risk == null || risk.trim().isEmpty) return 'low';
    switch (risk.toLowerCase()) {
      case 'low':
        return 'low';
      case 'medium':
        return 'medium';
      case 'high':
      default:
        // Unknown metadata fails closed rather than silently becoming low.
        return 'high';
    }
  }
}
