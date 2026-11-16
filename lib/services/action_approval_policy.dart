/// Approval is reserved for consequential actions, not ordinary navigation.
class LucyActionApprovalPolicy {
  static const Set<String> _sensitiveTapLabels = {
    'send', 'send message', 'send now', 'post', 'publish', 'share', 'send money', 'transfer money',
    'delete', 'delete permanently', 'remove', 'buy', 'purchase', 'pay', 'checkout', 'confirm payment', 'submit order', 'uninstall',
    'call', 'video call', 'place call', 'make call', 'start call', 'dial', 'confirm', 'submit', 'transfer', 'install',
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

  static bool requiresApproval(
    String action, {
    String? targetLabel,
    String? packageName,
  }) {
    // Native communication actions must be explicitly approved before opening composers.
    if (action == 'place_call' || action == 'send_sms') return true;
    if (action != 'tap') return false;
    final label = (targetLabel ?? '').trim().toLowerCase();
    if (_sensitiveTapLabels.contains(label) ||
        _sensitiveTapLabels.any((sensitive) => label.contains(sensitive))) {
      return true;
    }
    if (label.isEmpty && _messagingPackages.contains(packageName)) return true;
    return false;
  }
}
