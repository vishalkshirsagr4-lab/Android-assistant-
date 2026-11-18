import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/proactive_decision_service.dart';

void main() {
  test('parses proactive settings and last decision metadata', () {
    final status = LucyProactiveStatus.fromMap({
      'enabled': true,
      'quietStartHour': 21,
      'quietEndHour': 7,
      'dailyLimit': 2,
      'cooldownMinutes': 90,
      'lastSuggestion': 'Battery is low',
      'lastReason': 'Battery is below 20%.',
      'lastRisk': 'low',
      'lastConfidence': 0.95,
      'lastSuggestionAt': 1790000000000,
    });

    expect(status.enabled, isTrue);
    expect(status.quietStartHour, 21);
    expect(status.quietEndHour, 7);
    expect(status.dailyLimit, 2);
    expect(status.cooldownMinutes, 90);
    expect(status.lastSuggestion, 'Battery is low');
    expect(status.lastReason, 'Battery is below 20%.');
    expect(status.lastRisk, 'low');
    expect(status.lastConfidence, 0.95);
    expect(status.lastSuggestedAt, isNotNull);
  });

  test('uses safe defaults for missing values', () {
    final status = LucyProactiveStatus.fromMap(const {});
    expect(status.enabled, isFalse);
    expect(status.quietStartHour, 22);
    expect(status.quietEndHour, 8);
    expect(status.dailyLimit, 3);
    expect(status.cooldownMinutes, 120);
  });
}
