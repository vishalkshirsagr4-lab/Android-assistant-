/// Local action-risk policy. Consequential actions require a deliberate
/// user confirmation. Routine navigation and ordinary phone tasks do not.
class LucyActionApprovalPolicy {
  static const Set<String> _sensitiveTapLabels = {
    'send',
    'send message',
    'send now',
    'post',
    'publish',
    'share',
    'share text',
    'send money',
    'transfer money',
    'transfer',
    'delete',
    'delete permanently',
    'remove',
    'buy',
    'purchase',
    'pay',
    'checkout',
    'confirm payment',
    'submit order',
    'uninstall',
    'call',
    'video call',
    'place call',
    'make call',
    'start call',
    'dial',
  };

  static const Set<String> _sensitivePackageMarkers = {
    'bank',
    'wallet',
    'payment',
    'upi',
    'finance',
  };

  static const Set<String> _knownActions = {
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
    'remember',
    'forget',
    'recall_memories',
    'scroll_to_end',
    'scroll_to_top',
    'read_all',
    'open_each',
    'place_call',
    'send_sms',
    'share_text',
    'read_contact',
    'create_calendar_event',
    'take_photo',
    'open_settings',
    'tap',
    'batch',
    'run_skill',
  };

  /// Computes risk locally. Model-provided risk/confidence cannot turn a
  /// routine action into an approval prompt; only local sensitive-action
  /// checks decide whether approval is required.
  static String effectiveRisk(
    String action, {
    String? targetLabel,
    String? packageName,
    String? modelRisk,
    double? confidence,
    bool sensitiveInput = false,
  }) {
    if (!_knownActions.contains(action)) return 'high';

    final package = (packageName ?? '').toLowerCase();
    final sensitivePackage = _sensitivePackageMarkers.any(package.contains);

    if (action == 'place_call' || action == 'send_sms' ||
        action == 'share_text') {
      return 'high';
    }

    if (action == 'type') {
      return sensitiveInput || sensitivePackage ? 'high' : 'low';
    }

    if (action == 'open_settings') {
      final page = (targetLabel ?? '').toLowerCase();
      return page.contains('security') ||
              page.contains('account') ||
              page.contains('password') ||
              page.contains('privacy') ||
              page.contains('developer')
          ? 'high'
          : 'low';
    }

    if (action == 'tap') {
      final label = (targetLabel ?? '').trim().toLowerCase();
      if (sensitivePackage ||
          _sensitiveTapLabels.any((term) => label.contains(term))) {
        return 'high';
      }
      return 'low';
    }

    return 'low';
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
}
