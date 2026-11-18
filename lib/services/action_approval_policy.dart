/// Local action-risk policy. Only financial and UPI operations require
/// Lucy's additional confirmation. Android-owned permission and system dialogs
/// remain controlled by Android.
class LucyActionApprovalPolicy {
  /// Only explicitly requested local memory operations remain available when
  /// Autopilot is disabled. All phone/UI actions are blocked at the executor.
  static const Set<String> _memoryOnlyActions = {
    'remember',
    'forget',
    'recall_memories',
    'forget_skill',
    'forget_app_layout',
  };

  static bool allowedWhenAutopilotDisabled(String action) =>
      _memoryOnlyActions.contains(action);

  static bool isPermissionPromptText(String visibleText) {
    final text = visibleText.toLowerCase();
    const permissionContextTerms = <String>[
      'permission', 'while using the app', 'only this time', 'allow lucy',
      'send you notifications', 'take pictures', 'record audio',
      'access your location', 'access your contacts', 'access the camera',
      'अनुमति', 'ऐप इस्तेमाल करते समय', 'केवल इस बार', 'ಅನುಮತಿ',
      'ಅಪ್ಲಿಕೇಶನ್ ಬಳಸುವಾಗ', 'ಈ ಬಾರಿ ಮಾತ್ರ', '権限', 'アプリの使用中',
      '今回のみ', 'إذن', 'السماح للتطبيق', 'أثناء استخدام التطبيق',
      'هذه المرة فقط',
    ];
    const permissionChoiceTerms = <String>[
      'allow', "don't allow", 'deny', 'अनुमति दें', 'अनुमति न दें',
      'ಅನುಮತಿಸಿ', 'ಅನುಮತಿಸಬೇಡಿ', '許可', '許可しない', 'السماح',
      'عدم السماح',
    ];
    return permissionContextTerms.any(text.contains) &&
        permissionChoiceTerms.any(text.contains);
  }

  static const Set<String> _financialTapLabels = {
    'pay',
    'payment',
    'upi',
    'send money',
    'transfer money',
    'confirm payment',
    'pay now',
    'checkout',
    'purchase',
    'buy now',
    'submit order',
  };

  static const Set<String> _financialPackageMarkers = {
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
  };

  static const Set<String> _knownActions = {
    'open_app', 'type', 'swipe', 'back', 'home', 'wait',
    'schedule_reminder', 'set_alarm', 'set_timer', 'open_url',
    'start_navigation', 'music_search', 'set_flashlight', 'set_volume',
    'set_brightness', 'get_device_status', 'remember', 'forget',
    'recall_memories', 'scroll_to_end', 'scroll_to_top', 'read_all',
    'open_each', 'place_call', 'send_sms', 'share_text', 'read_contact',
    'create_calendar_event', 'take_photo', 'open_settings', 'tap', 'batch',
    'run_skill',
  };

  /// Risk is decided locally. Model metadata cannot add prompts to routine
  /// actions or downgrade a financial action.
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
    final label = (targetLabel ?? '').trim().toLowerCase();
    final financialPackage =
        _financialPackageMarkers.any(package.contains);
    final financialLabel =
        _financialTapLabels.any((term) => label.contains(term));

    // Any interaction inside a recognised bank, wallet or UPI app is gated.
    if (financialPackage) return 'high';

    // Outside financial apps, only an explicit payment/UPI action is gated.
    if (action == 'tap' && financialLabel) return 'high';

    // All other supported actions, including scroll/swipe, delete, send,
    // share, calling, messaging, reading and password-field typing, do not
    // trigger Lucy's extra approval prompt.
    return 'low';
  }

  static bool requiresApproval(
    String action, {
    String? targetLabel,
    String? packageName,
    String? modelRisk,
    double? confidence,
    bool sensitiveInput = false,
  }) =>
      effectiveRisk(
        action,
        targetLabel: targetLabel,
        packageName: packageName,
        modelRisk: modelRisk,
        confidence: confidence,
        sensitiveInput: sensitiveInput,
      ) != 'low';
}
