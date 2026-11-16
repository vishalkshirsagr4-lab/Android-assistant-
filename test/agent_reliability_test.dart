import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/agent_reliability.dart';

void main() {
  group('LucyAgentLoopGuard', () {
    test('requests a re-plan when the same action repeats on the same screen', () {
      final guard = LucyAgentLoopGuard();

      expect(
        guard.shouldReplan(
          actionType: 'tap',
          packageName: 'com.example.app',
          uiSignature: '{"elements":[]}',
        ),
        isFalse,
      );
      expect(
        guard.shouldReplan(
          actionType: 'tap',
          packageName: 'com.example.app',
          uiSignature: '{"elements":[]}',
        ),
        isTrue,
      );
    });

    test('does not treat a changed screen as the same loop', () {
      final guard = LucyAgentLoopGuard();

      guard.shouldReplan(
        actionType: 'tap',
        packageName: 'com.example.app',
        uiSignature: 'before',
      );

      expect(
        guard.shouldReplan(
          actionType: 'tap',
          packageName: 'com.example.app',
          uiSignature: 'after',
        ),
        isFalse,
      );
    });

    test('detects several different actions that leave the same screen stuck', () {
      final guard = LucyAgentLoopGuard();

      expect(
        guard.shouldReplan(
          actionType: 'tap',
          packageName: 'com.example.app',
          uiSignature: 'unchanged',
        ),
        isFalse,
      );
      expect(
        guard.shouldReplan(
          actionType: 'swipe',
          packageName: 'com.example.app',
          uiSignature: 'unchanged',
        ),
        isFalse,
      );
      expect(
        guard.shouldReplan(
          actionType: 'back',
          packageName: 'com.example.app',
          uiSignature: 'unchanged',
        ),
        isTrue,
      );
    });

    test('limits re-plans and can reset for the next user task', () {
      final guard = LucyAgentLoopGuard(maxReplans: 2);

      expect(guard.canReplan, isTrue);
      guard.markReplanned();
      expect(guard.canReplan, isTrue);
      guard.markReplanned();
      expect(guard.canReplan, isFalse);

      guard.reset();
      expect(guard.canReplan, isTrue);
      expect(guard.replans, 0);
    });
  });
}
