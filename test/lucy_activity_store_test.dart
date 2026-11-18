import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/lucy_activity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('activity history never persists conversation content', () async {
    final store = LucyActivityStore();
    await store.record('user_message');
    final events = await store.readEvents();
    expect(events, hasLength(1));
    expect(events.single['summary'], 'User message received');
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
      await store.record('test');
    }

    final events = await store.readEvents();
    expect(events, hasLength(300));
    expect(events.first['summary'], 'Activity event');
    expect(events.last['summary'], 'Activity event');
  });
}
