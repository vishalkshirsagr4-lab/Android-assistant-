import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/action_approval_policy.dart';

void main() {
  group('LucyActionApprovalPolicy', () {
    test('requires approval for every screen-changing action', () {
      for (final action in [
        'open_app',
        'tap',
        'type',
        'swipe',
        'back',
        'home',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(action),
          isTrue,
          reason: '$action must require approval',
        );
      }
    });

    test('does not classify passive or unknown actions as executable approvals', () {
      for (final action in ['wait', 'read_screen', 'unknown']) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse);
      }
    });
  });
}
