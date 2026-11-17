import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/lucy_learning_store.dart';
import 'package:screen_aware_ai/services/lucy_app_hint_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('lucy-learning-test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDirectory.path;
      }
      return null;
    });
  });

  tearDown(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await tempDirectory.exists()) await tempDirectory.delete(recursive: true);
  });

  test('normalizes multilingual commands and builds stable signatures', () {
    expect(
      LucyLearningStore.normalizeCommand('  Open WhatsApp!!!  '),
      'open whatsapp',
    );
    expect(
      LucyLearningStore.normalizeCommand('ಇದನ್ನು ಓದಿ ಹೇಳು'),
      'ಇದನ್ನು ಓದಿ ಹೇಳು',
    );
    final first = LucyLearningStore.stableSignature(
      packageName: 'com.example',
      elements: <Map<String, dynamic>>[
        <String, dynamic>{'resourceId': 'id/title', 'text': 'Inbox', 'class': 'TextView'},
        <String, dynamic>{'desc': 'Search', 'class': 'Button'},
      ],
    );
    final second = LucyLearningStore.stableSignature(
      packageName: 'com.example',
      elements: <Map<String, dynamic>>[
        <String, dynamic>{'desc': 'Search', 'class': 'Button'},
        <String, dynamic>{'resourceId': 'id/title', 'text': 'Inbox', 'class': 'TextView'},
      ],
    );
    expect(first, second);
  });

  test('persists UI maps with normalized bounds and resource IDs', () async {
    final store = LucyLearningStore();
    await store.initialize();
    final signature = LucyLearningStore.stableSignature(
      packageName: 'com.example.app',
      elements: <Map<String, dynamic>>[
        <String, dynamic>{
          'resourceId': 'com.example:id/search',
          'text': 'Search',
          'type': 'EditText',
          'editable': true,
          'bounds': <String, dynamic>{'cx': 500, 'cy': 100, 'w': 400, 'h': 80},
        },
      ],
    );
    await store.recordUiMap(
      packageName: 'com.example.app',
      signature: signature,
      appVersionCode: '42',
      screenSize: <String, double>{'width': 1000, 'height': 2000},
      elements: <Map<String, dynamic>>[
        <String, dynamic>{
          'resourceId': 'com.example:id/search',
          'text': 'Search',
          'type': 'EditText',
          'editable': true,
          'bounds': <String, dynamic>{'cx': 500, 'cy': 100, 'w': 400, 'h': 80},
        },
      ],
    );
    final reloaded = LucyLearningStore();
    await reloaded.initialize();
    expect(reloaded.uiMaps, hasLength(1));
    expect(reloaded.uiMaps.single['appVersionCode'], '42');
    final element = (reloaded.uiMaps.single['elements'] as List).single;
    expect(element['resourceId'], 'com.example:id/search');
    expect((element['bounds01'] as Map)['cx'], 0.5);
    expect((element['bounds01'] as Map)['cy'], 0.05);
  });

  test('records and matches only safe exact-screen skills', () async {
    final store = LucyLearningStore();
    await store.initialize();
    await store.recordSkill(
      id: 'skill_open_settings',
      command: 'Open settings',
      packageName: 'com.android.launcher',
      startSignature: 'home_signature',
      appVersionCode: '7',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'open_app', 'package': 'com.android.settings'},
        <String, dynamic>{
          'type': 'tap',
          'resourceId': 'com.android.settings:id/network',
          'label': 'Network',
        },
      ],
    );
    Future<Map<String, dynamic>?> find() => store.findSkill(
          command: ' OPEN SETTINGS ',
          packageName: 'com.android.launcher',
          startSignature: 'home_signature',
          appVersionCode: '7',
        );

    expect(await find(), isNull, reason: 'One successful run is only a suggestion.');
    expect(
      await store.setSkillApproved('skill_open_settings', approved: true),
      isFalse,
      reason: 'A skill cannot be approved before two matching successful runs.',
    );
    await store.recordSkill(
      id: 'skill_open_settings',
      command: 'Open settings',
      packageName: 'com.android.launcher',
      startSignature: 'home_signature',
      appVersionCode: '7',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'open_app', 'package': 'com.android.settings'},
        <String, dynamic>{
          'type': 'tap',
          'resourceId': 'com.android.settings:id/network',
          'label': 'Network',
        },
      ],
    );
    expect(await find(), isNull, reason: 'Repeated runs still require user approval.');
    expect(
      await store.setSkillApproved('skill_open_settings', approved: true),
      isTrue,
    );
    final found = await find();
    expect(found, isNotNull);
    expect(found!['actions'], hasLength(2));
    expect(
      await store.findSkill(
        command: 'Open settings',
        packageName: 'com.android.launcher',
        startSignature: 'different_screen',
        appVersionCode: '7',
      ),
      isNull,
    );
    await store.markSkillResult('skill_open_settings', success: true);
    expect(store.skills.single['successCount'], 3);
  });

  test('matches parameterized search skills without storing the query text', () async {
    final store = LucyLearningStore();
    await store.initialize();
    await store.recordSkill(
      id: 'skill_search',
      command: 'Search cats on Chrome',
      commandTemplate: 'search {query} on chrome',
      packageName: 'com.android.chrome',
      startSignature: 'chrome_home',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'tap', 'resourceId': 'chrome:id/search', 'label': 'Search'},
        <String, dynamic>{'type': 'type', 'parameter': 'query'},
      ],
    );
    await store.recordSkill(
      id: 'skill_search',
      command: 'Search cats on Chrome',
      commandTemplate: 'search {query} on chrome',
      packageName: 'com.android.chrome',
      startSignature: 'chrome_home',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'tap', 'resourceId': 'chrome:id/search', 'label': 'Search'},
        <String, dynamic>{'type': 'type', 'parameter': 'query'},
      ],
    );
    expect(
      await store.findSkill(
        command: 'Search red pandas on Chrome',
        packageName: 'com.android.chrome',
        startSignature: 'chrome_home',
      ),
      isNull,
    );
    expect(
      await store.setSkillApproved('skill_search', approved: true),
      isTrue,
    );
    final match = await store.findSkill(
      command: 'Search red pandas on Chrome',
      packageName: 'com.android.chrome',
      startSignature: 'chrome_home',
    );
    expect(match, isNotNull);
    expect((match!['parameters'] as Map)['query'], 'red pandas');
    final savedType = (store.skills.single['actions'] as List).last as Map;
    expect(savedType.containsKey('text'), isFalse);
  });

  test('rejects skills containing typing or other unapproved operations', () async {
    final store = LucyLearningStore();
    await store.initialize();
    await store.recordSkill(
      id: 'unsafe',
      command: 'Send a message',
      packageName: 'com.whatsapp',
      startSignature: 'chat_list',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'tap', 'label': 'Search'},
        <String, dynamic>{'type': 'type', 'text': 'private text'},
      ],
    );
    expect(store.skills, isEmpty);
  });

  test('loads app-specific hints only for a recognized package', () async {
    final catalog = LucyAppHintCatalog();
    final gmail = await catalog.loadForPackage('com.google.android.gm');
    expect(gmail['app'], 'Gmail');
    expect(gmail['strategy'], isA<List>());
    expect(await catalog.loadForPackage('com.example.unknown'), isEmpty);
  });

  test('forgets a layout and a named skill', () async {
    final store = LucyLearningStore();
    await store.initialize();
    await store.recordUiMap(
      packageName: 'com.example',
      signature: 'screen1',
      elements: <Map<String, dynamic>>[],
    );
    await store.recordSkill(
      id: 'skill1',
      command: 'read inbox',
      packageName: 'com.example',
      startSignature: 'screen1',
      actions: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'read_all'},
      ],
    );
    expect(await store.forgetAppLayout('com.example'), 1);
    expect(await store.forgetSkill('read inbox'), isTrue);
    expect(store.uiMaps, isEmpty);
    expect(store.skills, isEmpty);
  });
}
