import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/action_approval_policy.dart';

void main() {
  group('LucyActionApprovalPolicy', () {
    test('allows routine navigation, communication and content actions', () {
      for (final action in [
        'open_app', 'type', 'swipe', 'back', 'home', 'wait',
        'set_flashlight', 'set_volume', 'schedule_reminder',
        'read_contact', 'create_calendar_event', 'take_photo', 'open_url',
        'set_alarm', 'set_timer', 'scroll_to_end', 'scroll_to_top',
        'read_all', 'open_each', 'batch', 'place_call', 'send_sms',
        'share_text', 'open_settings',
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse,
            reason: action);
      }
    });

    test('does not ask approval for delete, send, share, install or call taps', () {
      for (final label in [
        'Send', 'Send message', 'Delete', 'Delete permanently', 'Remove',
        'Share', 'Post', 'Publish', 'Install', 'Uninstall', 'Call',
        'Video call', 'Confirm', 'Submit',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isFalse,
          reason: label,
        );
      }
    });

    test('requires approval for explicit payment and UPI actions', () {
      for (final label in [
        'Pay', 'Payment', 'UPI', 'Send money', 'Transfer money',
        'Confirm payment', 'Pay now', 'Checkout', 'Purchase', 'Buy now',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isTrue,
          reason: label,
        );
      }
    });

    test('requires approval for interactions inside Indian financial apps', () {
      for (final package in [
        'com.google.android.apps.nbu.paisa.user',
        'com.phonepe.app',
        'net.one97.paytm',
        'com.sbi.lotusintouch',
        'com.dreamplug.androidapp',
        'com.example.upi.wallet',
      ]) {
        for (final action in ['tap', 'type', 'swipe', 'back']) {
          expect(
            LucyActionApprovalPolicy.requiresApproval(
              action,
              targetLabel: 'Continue',
              packageName: package,
            ),
            isTrue,
            reason: '$package / $action',
          );
        }
      }
    });

    test('does not gate ordinary mail swipes or password typing outside finance apps', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'swipe',
          packageName: 'com.google.android.gm',
        ),
        isFalse,
      );
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'swipe',
          packageName: 'com.microsoft.office.outlook',
        ),
        isFalse,
      );
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'type',
          sensitiveInput: true,
          packageName: 'com.example.app',
        ),
        isFalse,
      );
    });

    test('model risk metadata does not add prompts to routine actions', () {
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'open_app',
          modelRisk: 'high',
          confidence: 0.1,
        ),
        isFalse,
      );
      expect(
        LucyActionApprovalPolicy.requiresApproval(
          'tap',
          targetLabel: 'Delete permanently',
          modelRisk: 'high',
          confidence: 0.1,
        ),
        isFalse,
      );
    });

    test('financial app protection cannot be downgraded by model metadata', () {
      expect(
        LucyActionApprovalPolicy.effectiveRisk(
          'tap',
          targetLabel: 'Continue',
          packageName: 'com.phonepe.app',
          modelRisk: 'low',
          confidence: 1,
        ),
        'high',
      );
    });

    test('Autopilot disabled permits only explicit memory operations', () {
      for (final action in [
        'remember', 'forget', 'recall_memories', 'forget_skill',
        'forget_app_layout',
      ]) {
        expect(LucyActionApprovalPolicy.allowedWhenAutopilotDisabled(action),
            isTrue, reason: action);
      }
      for (final action in [
        'open_app', 'tap', 'type', 'swipe', 'back', 'home',
        'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each',
        'batch', 'run_skill', 'place_call', 'send_sms', 'share_text',
      ]) {
        expect(LucyActionApprovalPolicy.allowedWhenAutopilotDisabled(action),
            isFalse, reason: action);
      }
    });

    test('recognizes Android permission prompts in supported languages', () {
      for (final prompt in [
        'Allow Lucy to access the microphone? Only this time',
        'Allow WhatsApp to send you notifications? Allow / Don’t allow',
        'अनुमति दें · ऐप इस्तेमाल करते समय',
        'ಅನುಮತಿಸಿ · ಅಪ್ಲಿಕೇಶನ್ ಬಳಸುವಾಗ',
        'アプリの使用中に許可しますか？ 今回のみ',
        'السماح أثناء استخدام التطبيق',
      ]) {
        expect(LucyActionApprovalPolicy.isPermissionPromptText(prompt), isTrue,
            reason: prompt);
      }
      expect(
        LucyActionApprovalPolicy.isPermissionPromptText(
          'Allow notifications from this website?',
        ),
        isFalse,
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
