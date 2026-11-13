/// Approval is reserved for consequential actions, not ordinary navigation.
class LucyActionApprovalPolicy {
  static const Set<String> _sensitiveTapLabels = {
    'send', 'send message', 'send now', 'post', 'publish', 'share',
    'delete', 'remove', 'buy', 'purchase', 'pay', 'checkout',
    'call', 'video call', 'confirm', 'submit', 'transfer',
  };

  static const Set<String> _messagingPackages = {
    'com.whatsapp',
    'org.telegram.messenger',
    'com.google.android.apps.messaging',
    'com.facebook.orca',
    'com.instagram.android',
  };

  static bool requiresApproval(
    String action, {
    String? targetLabel,
    String? packageName,
  }) {
    if (action != 'tap') return false;
    final label = (targetLabel ?? '').trim().toLowerCase();
    if (_sensitiveTapLabels.contains(label)) return true;
    if (label.isEmpty && _messagingPackages.contains(packageName)) return true;
    return false;
  }
}
