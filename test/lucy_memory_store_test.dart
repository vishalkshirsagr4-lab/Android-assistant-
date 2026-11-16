import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/lucy_memory_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('migrates legacy explicitly saved memories into structured records', () async {
    SharedPreferences.setMockInitialValues({
      'lucy_user_approved_memories_v1': [
        'I prefer simple English explanations',
        'My goal is to learn Flutter',
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LucyMemoryStore(prefs);

    await store.initialize();

    expect(store.items, hasLength(2));
    expect(store.items.first.category, 'fact');
    expect(store.items.first.userApproved, isTrue);
    expect(store.summary, contains('I prefer simple English explanations'));
    expect(prefs.getStringList('lucy_user_approved_memories_v1'), isNull);
  });

  test('stores structured categories and avoids duplicate records', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LucyMemoryStore(prefs);
    await store.initialize();

    await store.remember('I prefer Kannada explanations', category: 'preference');
    await store.remember('I prefer Kannada explanations', category: 'preference');

    expect(store.items, hasLength(1));
    expect(store.items.single.category, 'preference');
    expect(store.items.single.confidence, 1);
    expect(store.items.single.userApproved, isTrue);
  });

  test('retrieves only memories relevant to the current request', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LucyMemoryStore(prefs);
    await store.initialize();

    await store.remember('The user is learning Flutter and Dart', category: 'goal');
    await store.remember('The user prefers short Kannada explanations', category: 'preference');
    await store.remember('The user studies database management', category: 'routine');

    final context = store.relevantContext('Help me with Flutter widgets');

    expect(context, contains('Flutter and Dart'));
    expect(context, isNot(contains('database management')));
  });

  test('forgets matching memories and clears all stored data', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LucyMemoryStore(prefs);
    await store.initialize();

    await store.remember('I prefer short answers', category: 'preference');
    await store.remember('I am learning Python', category: 'goal');

    expect(await store.forgetMatching('short answers'), 1);
    expect(store.items, hasLength(1));

    await store.clear();
    expect(store.items, isEmpty);
    expect(prefs.getString('lucy_structured_memories_v2'), isNull);
  });

  test('does not store blank or oversized memory values', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LucyMemoryStore(prefs);
    await store.initialize();

    await store.remember('   ');
    await store.remember(List<String>.filled(241, 'x').join());

    expect(store.items, isEmpty);
  });
}
