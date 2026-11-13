import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/lucy_activity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('activity history redacts credentials and one-time codes', () async {
    final store = LucyActivityStore();
    await store.record(
      'user_message',
      'password=hunter2 otp: 123456 bearer abcdefghijklmnopqrstuvwxyz',
    );

    final events = await store.readEvents();
    expect(events, hasLength(1));
    final summary = events.single['summary'] as String;
    expect(summary, isNot(contains('hunter2')));
    expect(summary, isNot(contains('123456')));
    expect(summary, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    expect(summary, contains('[redacted]'));
  });

  test('default routines are disabled and require approval', () async {
    final store = LucyActivityStore();
    final routines = await store.readAutomationTemplates();

    expect(routines, isNotEmpty);
    for (final routine in routines) {
      expect(routine['enabled'], isFalse);
      expect(routine['requiresApproval'], isTrue);
    }
  });

  test('activity history is bounded to the newest 300 events', () async {
    final store = LucyActivityStore();
    for (var i = 0; i < 305; i++) {
      await store.record('test', 'event $i');
    }

    final events = await store.readEvents();
    expect(events, hasLength(300));
    expect(events.first['summary'], 'event 5');
    expect(events.last['summary'], 'event 304');
  });
}
