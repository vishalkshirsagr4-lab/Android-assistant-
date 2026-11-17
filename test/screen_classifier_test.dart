import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/screen_classifier.dart';

void main() {
  Map<String, dynamic> tree(String package, List<String> labels) => <String, dynamic>{
        'package': package,
        'elements': labels
            .map((label) => <String, dynamic>{'text': label, 'type': 'TextView'})
            .toList(),
      };

  group('ScreenClassifier', () {
    final classifier = ScreenClassifier();

    test('identifies payment screens before generic forms', () {
      final result = classifier.classify(jsonEncode(
        tree('com.example.checkout', <String>['Card number', 'Pay now', 'Submit']),
      ));
      expect(result.type, 'payment');
      expect(result.confidence, greaterThan(0.9));
    });

    test('identifies login screens as sensitive', () {
      final result = classifier.classify(jsonEncode(
        tree('com.example.app', <String>['Enter password', 'Sign in']),
      ));
      expect(result.type, 'login');
    });

    test('identifies common chat apps', () {
      final result = classifier.classify(jsonEncode(
        tree('com.whatsapp', <String>['Type a message', 'Online']),
      ));
      expect(result.type, 'chat');
    });

    test('returns unknown for malformed or missing trees', () {
      expect(classifier.classify('not-json').type, 'unknown');
      expect(classifier.classify(null).type, 'unknown');
    });
  });
}
