import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/ai_service.dart';

void main() {
  group('AgentResponse reliability schema', () {
    test('parses a plan and one risk-scored action', () {
      final response = AgentResponse.fromJson(
        <String, dynamic>{
          'route': 'phone',
          'needs_screen': false,
          'plan': <String>['Open the app', 'Verify the target screen'],
          'actions': <dynamic>[
            <String, dynamic>{
              'type': 'open_app',
              'package': 'com.example.app',
              'confidence': 0.95,
              'risk': 'low',
              'reason': 'Opening an app is reversible.',
            },
          ],
          'speak': '',
          'done': false,
          'lang': 'en',
        },
        '{}',
        provider: 'gemini',
      );

      expect(response.plan, hasLength(2));
      expect(response.actions, hasLength(1));
      expect(response.actions.single.type, 'open_app');
      expect(response.provider, 'gemini');
    });

    test('parses the Phase 1 route and goal/done_when schema', () {
      final response = AgentResponse.fromJson(
        <String, dynamic>{
          'route': 'read',
          'needs_screen': true,
          'plan': <String, dynamic>{
            'goal': 'Read the current article',
            'done_when': 'All available article text has been collected',
          },
          'actions': <dynamic>[],
          'speak': 'Here is the summary.',
          'done': true,
          'lang': 'en',
          'confidence': 0.91,
          'risk': 'low',
          'collected': <String, dynamic>{'items': <String>['First point']},
        },
        '{}',
        provider: 'groq',
      );

      expect(response.route, 'read');
      expect(response.needsScreen, isTrue);
      expect(response.goal, 'Read the current article');
      expect(response.doneWhen, 'All available article text has been collected');
      expect(response.confidence, 0.91);
      expect(response.risk, 'low');
      expect(response.collected['items'], <String>['First point']);
    });

    test('parses a model-directed memory action', () {
      final response = AgentResponse.fromJson(
        <String, dynamic>{
          'route': 'phone',
          'needs_screen': false,
          'plan': <String, dynamic>{
            'goal': 'Remember the requested preference',
            'done_when': 'The preference is stored locally',
          },
          'actions': <dynamic>[
            <String, dynamic>{
              'type': 'remember',
              'text': 'The user prefers short explanations',
              'memory_type': 'preference',
              'confidence': 0.99,
              'risk': 'low',
              'reason': 'The user explicitly asked to save this preference.',
            },
          ],
          'speak': '',
          'done': true,
          'lang': 'en',
        },
        '{}',
      );

      expect(response.route, 'phone');
      expect(response.actions.single.type, 'remember');
    });

    test('parses native deep scroll and read actions', () {
      for (final type in [
        'scroll_to_end',
        'scroll_to_top',
        'read_all',
        'open_each',
      ]) {
        final response = AgentResponse.fromJson(
          <String, dynamic>{
            'route': 'read',
            'needs_screen': true,
            'plan': <String, dynamic>{
              'goal': 'Inspect the full visible list',
              'done_when': 'The native tool reports the requested coverage',
            },
            'actions': <dynamic>[
              <String, dynamic>{
                'type': type,
                'maxScrolls': 80,
                'maxItems': 10,
                'confidence': 0.98,
                'risk': 'low',
                'reason': 'The user asked Lucy to inspect this screen.',
              },
            ],
            'speak': '',
            'done': false,
            'lang': 'en',
          },
          '{}',
        );
        expect(response.actions.single.type, type);
        expect(response.needsScreen, isTrue);
      }
    });

    test('rejects deep reading actions when needs_screen is false', () {
      expect(
        () => AgentResponse.fromJson(
          <String, dynamic>{
            'route': 'read',
            'needs_screen': false,
            'plan': <String, dynamic>{
              'goal': 'Read the list',
              'done_when': 'The list was inspected',
            },
            'actions': <dynamic>[
              <String, dynamic>{
                'type': 'read_all',
                'confidence': 0.98,
                'risk': 'low',
                'reason': 'The user asked for screen reading.',
              },
            ],
            'speak': '',
            'done': false,
            'lang': 'en',
          },
          '{}',
        ),
        throwsFormatException,
      );
    });

    test('keeps event responses action-free', () {
      final response = AgentResponse.fromJson(
        <String, dynamic>{
          'actions': <dynamic>[],
          'speak': 'Memory saved.',
          'done': true,
          'lang': 'en',
        },
        '{}',
      );

      expect(response.actions, isEmpty);
      expect(response.done, isTrue);
    });

    test('rejects actions without a plan', () {
      expect(
        () => AgentResponse.fromJson(
          <String, dynamic>{
            'actions': <dynamic>[
              <String, dynamic>{
                'type': 'open_app',
                'package': 'com.example.app',
                'confidence': 0.95,
                'risk': 'low',
                'reason': 'Reversible navigation.',
              },
            ],
            'speak': '',
            'done': false,
            'lang': 'en',
          },
          '{}',
        ),
        throwsFormatException,
      );
    });

    test('rejects an invalid risk value', () {
      expect(
        () => AgentResponse.fromJson(
          <String, dynamic>{
            'plan': <String>['Open the app'],
            'actions': <dynamic>[
              <String, dynamic>{
                'type': 'open_app',
                'package': 'com.example.app',
                'confidence': 0.95,
                'risk': 'safe',
                'reason': 'Invalid risk label.',
              },
            ],
            'speak': '',
            'done': false,
            'lang': 'en',
          },
          '{}',
        ),
        throwsFormatException,
      );
    });

    test('rejects multiple actions in a single step', () {
      Map<String, dynamic> action(String package) => <String, dynamic>{
        'type': 'open_app',
        'package': package,
        'confidence': 0.95,
        'risk': 'low',
        'reason': 'Reversible navigation.',
      };

      expect(
        () => AgentResponse.fromJson(
          <String, dynamic>{
            'plan': <String>['Open one app'],
            'actions': <dynamic>[
              action('com.example.one'),
              action('com.example.two'),
            ],
            'speak': '',
            'done': false,
            'lang': 'en',
          },
          '{}',
        ),
        throwsFormatException,
      );
    });
  });
}
