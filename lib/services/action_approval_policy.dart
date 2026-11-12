/// Central fail-closed policy for actions that can change another app or
/// device state. Keep this list conservative and covered by unit tests.
class LucyActionApprovalPolicy {
  static const Set<String> approvalRequiredActions = {
    'open_app',
    'tap',
    'type',
    'swipe',
    'back',
    'home',
  };

  static bool requiresApproval(String action) =>
      approvalRequiredActions.contains(action);
}
