import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/action_approval_policy.dart';

void main() {
  group('LucyActionApprovalPolicy', () {
    test('allows known low-risk navigation and device actions', () {
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
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse);
      }
    });

    test('allows ordinary YouTube navigation and playback taps', () {
      for (final label in ['Play', 'Search', 'Home', 'Next', 'Pause']) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(
            'tap',
            targetLabel: label,
            packageName: 'com.google.android.youtube',
          ),
          isFalse,
        );
      }
    });

    test('requires approval for consequential tap labels', () {
      for (final label in ['Send', 'Post', 'Publish', 'Share', 'Delete', 'Pay']) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isTrue,
        );
      }
    });

    test('requires approval for communication, sharing and medium-risk actions', () {
      for (final action in [
        'place_call',
        'send_sms',
        'share_text',
        'read_contact',
        'create_calendar_event',
        'take_photo',
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isTrue);
      }
    });

    test('requires approval for unlabeled taps in messaging apps', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'tap',
          packageName: 'com.whatsapp',
        ),
        isTrue,
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
      expect(
        LucyActionApprovalPolicy.effectiveRisk(
          'type',
          sensitiveInput: true,
          modelRisk: 'low',
          confidence: 0.99,
        ),
        'high',
      );
    });

    test('typing in a financial app requires approval', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'type',
          packageName: 'com.example.upi.wallet',
          modelRisk: 'low',
          confidence: 0.99,
        ),
        isTrue,
      );
    });

    test('model cannot downgrade a locally high-risk action', () {
      expect(
        LucyActionApprovalPolicy.effectiveRisk(
          'send_sms',
          modelRisk: 'low',
          confidence: 1,
        ),
        'high',
      );
    });

    test('model high risk escalates an otherwise low-risk action', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'open_app',
          modelRisk: 'high',
          confidence: 0.99,
        ),
        isTrue,
      );
    });

    test('low confidence escalates to confirmation', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'open_app',
          modelRisk: 'low',
          confidence: 0.4,
        ),
        isTrue,
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
