import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/ai_service.dart';

void main() {
  group('AgentResponse reliability schema', () {
    test('parses a plan and one risk-scored action', () {
      final response = AgentResponse.fromJson(
        <String, dynamic>{
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
