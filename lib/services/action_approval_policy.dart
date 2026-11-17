/// Local action-risk policy. Consequential actions require a deliberate
/// user confirmation. Routine navigation and ordinary phone tasks do not.
class LucyActionApprovalPolicy {
  /// Only explicitly requested local memory operations remain available when
  /// Autopilot is disabled. All phone/UI actions are blocked at the executor,
  /// not merely discouraged in the model prompt.
  static const Set<String> _memoryOnlyActions = {
    'remember',
    'forget',
    'recall_memories',
  };

  static bool allowedWhenAutopilotDisabled(String action) =>
      _memoryOnlyActions.contains(action);

  /// Recognizes Android runtime permission prompts across the app's supported
  /// languages. The controller must pause before asking the model to act.
  static bool isPermissionPromptText(String visibleText) {
    final text = visibleText.toLowerCase();
    const permissionContextTerms = <String>[
      'permission',
      'while using the app',
      'only this time',
      'allow lucy',
      'अनुमति',
      'ऐप इस्तेमाल करते समय',
      'केवल इस बार',
      'ಅನುಮತಿ',
      'ಅಪ್ಲಿಕೇಶನ್ ಬಳಸುವಾಗ',
      'ಈ ಬಾರಿ ಮಾತ್ರ',
      '権限',
      'アプリの使用中',
      '今回のみ',
      'إذن',
      'أثناء استخدام التطبيق',
      'هذه المرة فقط',
    ];
    const permissionChoiceTerms = <String>[
      'allow',
      "don't allow",
      'deny',
      'अनुमति दें',
      'अनुमति न दें',
      'ಅನುಮತಿಸಿ',
      'ಅನುಮತಿಸಬೇಡಿ',
      '許可',
      '許可しない',
      'السماح',
      'عدم السماح',
    ];
    return permissionContextTerms.any(text.contains) &&
        permissionChoiceTerms.any(text.contains);
  }

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
    'install',
    'install app',
    'install now',
    'uninstall',
    'password',
    'passcode',
    'recovery',
    'recovery email',
    'recovery phone',
    'two-factor',
    '2fa',
    'security key',
    'factory reset',
    'reset account',
    'change password',
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
    'paisa',
    'phonepe',
    'paytm',
    'bhim',
    'mobikwik',
    'freecharge',
    'netbanking',
    'sbi',
    'hdfc',
    'icici',
    'axis',
    'kotak',
    'dreamplug',
    'gpay',
    'googlepay',
    'cred',
    'packageinstaller',
    'permissioncontroller',
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
