import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/action_approval_policy.dart';

void main() {
  group('LucyActionApprovalPolicy', () {
    test('allows routine phone and screen actions without approval', () {
      for (final action in [
        'open_app',
        'type',
        'swipe',
        'back',
        'home',
        'wait',
        'set_flashlight',
        'set_volume',
        'schedule_reminder',
        'read_contact',
        'create_calendar_event',
        'take_photo',
        'open_url',
        'set_alarm',
        'set_timer',
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse,
            reason: action);
      }
    });

    test('allows harmless taps including generic confirmation and permission labels', () {
      for (final label in [
        'Play', 'Search', 'Home', 'Next', 'Pause',
        'Confirm', 'Submit', 'Allow', 'Grant', 'Install',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(
            'tap',
            targetLabel: label,
            packageName: 'com.example.app',
          ),
          isFalse,
          reason: label,
        );
      }
    });

    test('requires approval for payment and destructive tap labels', () {
      for (final label in [
        'Send money', 'Transfer money', 'Delete', 'Delete permanently',
        'Buy', 'Purchase', 'Pay', 'Checkout', 'Uninstall',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isTrue,
          reason: label,
        );
      }
    });

    test('requires approval for external communication actions', () {
      for (final action in ['place_call', 'send_sms', 'share_text']) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isTrue,
            reason: action);
      }
    });

    test('requires approval for taps inside financial apps', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'tap',
          targetLabel: 'Balance',
          packageName: 'com.example.upi.wallet',
        ),
        isTrue,
      );
    });

    test('requires approval for sensitive account and security settings', () {
      for (final page in ['Security', 'Account', 'Password', 'Privacy']) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(
            'open_settings',
            targetLabel: page,
          ),
          isTrue,
          reason: page,
        );
      }
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'open_settings',
          targetLabel: 'Display',
        ),
        isFalse,
      );
    });

    test('typing into a password field always requires approval', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'type',
          sensitiveInput: true,
          modelRisk: 'low',
          confidence: 0.99,
        ),
        isTrue,
      );
    });

    test('typing in a financial app requires approval', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'type',
          packageName: 'com.example.upi.wallet',
        ),
        isTrue,
      );
    });

    test('model risk and low confidence do not add prompts to routine actions', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'open_app',
          modelRisk: 'high',
          confidence: 0.4,
        ),
        isFalse,
      );
    });

    test('model cannot downgrade a locally sensitive action', () {
      expect(
        LucyActionApprovalPolicy.effectiveRisk(
          'send_sms',
          modelRisk: 'low',
          confidence: 1,
        ),
        'high',
      );
    });

    test('unknown action types fail closed', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval('unknown_action'),
        isTrue,
      );
    });
  });
}
