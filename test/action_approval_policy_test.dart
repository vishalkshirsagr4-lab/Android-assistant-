import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/action_approval_policy.dart';

void main() {
  group('LucyActionApprovalPolicy', () {
    test('allows ordinary phone automation without repeated prompts', () {
      for (final action in [
        'open_app', 'type', 'swipe', 'back', 'home', 'wait',
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse);
      }
    });

    test('allows ordinary YouTube navigation and playback taps', () {
      for (final label in ['Play', 'Search', 'Home', 'Next', 'Pause']) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(
            'tap', targetLabel: label, packageName: 'com.google.android.youtube',
          ),
          isFalse,
        );
      }
    });

    test('requires approval before sending or publishing content', () {
      for (final label in ['Send', 'Post', 'Publish', 'Share', 'Delete', 'Pay']) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isTrue,
        );
      }
    });

    test('requires approval for unlabeled taps in messaging apps', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'tap', packageName: 'com.whatsapp',
        ),
        isTrue,
      );
    });
  });
}
