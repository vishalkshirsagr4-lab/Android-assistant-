import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/voice_service.dart';

void main() {
  group('VoiceService language configuration', () {
    test('maps all five UI languages to Android speech and TTS locales', () {
      expect(VoiceService.sttLocaleFor('hi'), 'hi_IN');
      expect(VoiceService.sttLocaleFor('kn'), 'kn_IN');
      expect(VoiceService.ttsLocaleFor('hi'), 'hi-IN');
      expect(VoiceService.ttsLocaleFor('kn'), 'kn-IN');
      expect(VoiceService.sttLocaleFor('en'), 'en_US');
      expect(VoiceService.sttLocaleFor('ja'), 'ja_JP');
      expect(VoiceService.sttLocaleFor('ar'), 'ar_SA');
      expect(VoiceService.languageNames.keys, containsAll(['en', 'hi', 'kn', 'ja', 'ar']));
    });
  });

  group('VoiceService progressive speech chunks', () {
    test('keeps sentence boundaries as separate speech units', () {
      expect(
        VoiceService.splitSpeechChunks('First sentence. Second sentence!'),
        <String>['First sentence.', 'Second sentence!'],
      );
    });

    test('keeps Japanese and Hindi punctuation intact', () {
      expect(
        VoiceService.splitSpeechChunks('पहला वाक्य। 次の文。'),
        <String>['पहला वाक्य।', '次の文。'],
      );
    });

    test('splits long sentences without losing words', () {
      final input = List<String>.generate(90, (index) => 'word$index').join(' ');
      final chunks = VoiceService.splitSpeechChunks(input, maxChars: 80);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 80), isTrue);
      expect(chunks.join(' '), input);
    });

    test('returns no chunks for whitespace-only input', () {
      expect(VoiceService.splitSpeechChunks('   \n  '), isEmpty);
    });
  });
}
