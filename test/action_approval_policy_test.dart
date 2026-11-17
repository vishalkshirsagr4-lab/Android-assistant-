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
        'scroll_to_end',
        'scroll_to_top',
        'read_all',
        'open_each',
        'batch',
      ]) {
        expect(LucyActionApprovalPolicy.requiresApproval(action), isFalse,
            reason: action);
      }
    });

    test('allows harmless taps including generic confirmation and permission labels', () {
      for (final label in [
        'Play', 'Search', 'Home', 'Next', 'Pause',
        'Confirm', 'Submit', 'Allow', 'Grant',
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

    test('requires approval for app installation and account security changes', () {
      for (final label in [
        'Install',
        'Install now',
        'Change password',
        'Recovery email',
        'Enable 2FA',
        'Factory reset',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval('tap', targetLabel: label),
          isTrue,
          reason: label,
        );
      }
    });

    test('recognizes common Indian payment app package names as sensitive', () {
      for (final package in [
        'com.google.android.apps.nbu.paisa.user',
        'com.phonepe.app',
        'net.one97.paytm',
        'com.sbi.lotusintouch',
        'com.dreamplug.androidapp',
      ]) {
        expect(
          LucyActionApprovalPolicy.requiresApproval(
            'tap',
            targetLabel: 'Continue',
            packageName: package,
          ),
          isTrue,
          reason: package,
        );
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

    test('Autopilot disabled permits only explicit memory operations', () {
      for (final action in ['remember', 'forget', 'recall_memories']) {
        expect(
          LucyActionApprovalPolicy.allowedWhenAutopilotDisabled(action),
          isTrue,
          reason: action,
        );
      }
      for (final action in [
        'open_app',
        'tap',
        'type',
        'swipe',
        'back',
        'home',
        'scroll_to_end',
        'scroll_to_top',
        'read_all',
        'open_each',
        'batch',
        'run_skill',
        'place_call',
        'send_sms',
        'share_text',
        'set_flashlight',
        'set_volume',
      ]) {
        expect(
          LucyActionApprovalPolicy.allowedWhenAutopilotDisabled(action),
          isFalse,
          reason: action,
        );
      }
    });

    test('detects Android permission prompts in supported languages', () {
      for (final prompt in [
        'Allow Lucy to access the microphone? Only this time',
        'अनुमति दें · ऐप इस्तेमाल करते समय',
        'ಅನುಮತಿಸಿ · ಅಪ್ಲಿಕೇಶನ್ ಬಳಸುವಾಗ',
        'アプリの使用中に許可しますか？ 今回のみ',
        'السماح أثناء استخدام التطبيق',
      ]) {
        expect(
          LucyActionApprovalPolicy.isPermissionPromptText(prompt),
          isTrue,
          reason: prompt,
        );
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
