import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/reading_mode_planner.dart';
import 'package:screen_aware_ai/services/screen_classifier.dart';

void main() {
  group('ReadingModePlanner', () {
    test('recognizes English and Hinglish reading requests', () {
      expect(ReadingModePlanner.isReadingRequest('Summarize this article'), isTrue);
      expect(ReadingModePlanner.isReadingRequest('kya important hai'), isTrue);
      expect(ReadingModePlanner.isReadingRequest('padh ke batao'), isTrue);
    });

    test('recognizes Hindi, Kannada, Japanese and Arabic requests', () {
      expect(ReadingModePlanner.isReadingRequest('इसे पढ़ो और सारांश बताओ'), isTrue);
      expect(ReadingModePlanner.isReadingRequest('ಇದನ್ನು ಓದಿ ಹೇಳು'), isTrue);
      expect(ReadingModePlanner.isReadingRequest('この記事を要約して'), isTrue);
      expect(ReadingModePlanner.isReadingRequest('اقرأ هذا ولخص هذا'), isTrue);
    });

    test('does not replace inbox-wide thread inspection with list scrolling', () {
      expect(ReadingModePlanner.isReadingRequest('check all my Gmail'), isFalse);
      expect(ReadingModePlanner.isReadingRequest('read last 10 WhatsApp chats'), isFalse);
    });

    test('precollects only readable scrollable screens', () {
      const article = ScreenClassification(
        type: 'article',
        confidence: 0.95,
        signals: <String>['article'],
      );
      expect(
        ReadingModePlanner.shouldPrecollect(
          userText: 'Summarize this',
          classification: article,
          elements: <Map<String, dynamic>>[
            <String, dynamic>{'scrollable': true},
          ],
        ),
        isTrue,
      );
      expect(
        ReadingModePlanner.shouldPrecollect(
          userText: 'Summarize this',
          classification: article,
          elements: <Map<String, dynamic>>[
            <String, dynamic>{'scrollable': false},
          ],
        ),
        isFalse,
      );
    });
  });
}
