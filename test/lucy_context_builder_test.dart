import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/lucy_context_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.poc.screen_aware_ai/context');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic> snapshot = <String, dynamic>{};

  setUp(() {
    snapshot = <String, dynamic>{
      'batteryPercent': 64,
      'charging': true,
      'network': 'Wi-Fi connected',
      'foregroundApp': 'Messages',
      'notificationAccessEnabled': true,
      'notificationContextEnabled': true,
      'notifications': <Map<String, dynamic>>[
        <String, dynamic>{
          'app': 'Messages',
          'sender': 'Family',
          'title': 'Dinner plan',
          'text': 'Meet at 7 pm',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      'calendarAccessEnabled': true,
      'calendarEvents': <Map<String, dynamic>>[
        <String, dynamic>{
          'title': 'Study',
          'startTimeMillis': DateTime.now()
              .add(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
          'endTimeMillis': DateTime.now()
              .add(const Duration(minutes: 90))
              .millisecondsSinceEpoch,
          'location': 'Home',
        },
      ],
      'locationEnabled': true,
      'approximateLocation': <String, double>{
        'latitude': 15.35,
        'longitude': 75.14,
      },
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getContextSnapshot') return snapshot;
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('builds compact context from available opt-in sources', () async {
    final context = await LucyContextBuilder().buildPromptContext();

    expect(context, contains('Battery: 64%, charging.'));
    expect(context, contains('Foreground app: Messages.'));
    expect(context, contains('Dinner plan'));
    expect(context, contains('Meet at 7 pm'));
    expect(context, contains('Upcoming calendar events'));
    expect(context, contains('Approximate location (rounded)'));
  });

  test('does not include notifications unless Lucy notification context is enabled',
      () async {
    snapshot['notificationContextEnabled'] = false;

    final context = await LucyContextBuilder().buildPromptContext();

    expect(context, isNot(contains('Dinner plan')));
    expect(context, isNot(contains('Meet at 7 pm')));
  });

  test('continues to provide basic context when optional sources are absent',
      () async {
    snapshot = <String, dynamic>{
      'batteryPercent': 20,
      'charging': false,
      'network': 'offline',
      'notifications': <dynamic>[],
      'calendarEvents': <dynamic>[],
    };

    final context = await LucyContextBuilder().buildPromptContext();

    expect(context, contains('Battery: 20%, not charging.'));
    expect(context, contains('Network: offline.'));
    expect(context, isNot(contains('Recent notifications')));
    expect(context, isNot(contains('Approximate location')));
  });
}
