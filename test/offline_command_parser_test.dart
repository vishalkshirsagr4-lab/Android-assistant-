import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/offline_command_parser.dart';

void main() {
  group('OfflineCommunicationCommand', () {
    test('parses English calls by contact or number', () {
      expect(
        OfflineCommunicationCommand.parse('call Sarah')?.target,
        'Sarah',
      );
      expect(
        OfflineCommunicationCommand.parse('dial +91 98765 43210')?.target,
        '+91 98765 43210',
      );
    });

    test('parses Hinglish and Hindi calls', () {
      expect(
        OfflineCommunicationCommand.parse('Sarah ko call karo')?.target,
        'Sarah',
      );
      expect(
        OfflineCommunicationCommand.parse('Rahul ko phone lagao')?.target,
        'Rahul',
      );
      expect(
        OfflineCommunicationCommand.parse('कॉल करो सीमा')?.target,
        'सीमा',
      );
    });

    test('parses English SMS with explicit message body', () {
      final command =
          OfflineCommunicationCommand.parse('send SMS to Sarah: Hi there');
      expect(command?.action, 'send_sms');
      expect(command?.target, 'Sarah');
      expect(command?.message, 'Hi there');
    });

    test('parses Hinglish and Hindi SMS commands', () {
      final command =
          OfflineCommunicationCommand.parse('Sarah ko SMS bhejo Hi');
      expect(command?.action, 'send_sms');
      expect(command?.target, 'Sarah');
      expect(command?.message, 'Hi');

      final hindi =
          OfflineCommunicationCommand.parse('सीमा को मैसेज भेजो नमस्ते');
      expect(hindi?.target, 'सीमा');
      expect(hindi?.message, 'नमस्ते');
    });

    test('does not guess missing recipient or message', () {
      expect(OfflineCommunicationCommand.parse('call'), isNull);
      expect(OfflineCommunicationCommand.parse('send SMS to Sarah'), isNull);
      expect(OfflineCommunicationCommand.parse('Sarah ko hi bhejo WhatsApp par'),
          isNull);
    });
  });



  group('OfflineAppCommand', () {
    test('parses English app launch requests', () {
      expect(OfflineAppCommand.parse('open WhatsApp')?.appName, 'WhatsApp');
      expect(OfflineAppCommand.parse('launch Spotify')?.appName, 'Spotify');
      expect(OfflineAppCommand.parse('start Google Maps')?.appName, 'Google Maps');
    });

    test('parses Hindi and Kannada app launch requests', () {
      expect(OfflineAppCommand.parse('व्हाट्सऐप खोलो')?.appName, 'व्हाट्सऐप');
      expect(OfflineAppCommand.parse('ಟೆಲಿಗ್ರಾಂ ತೆರೆ')?.appName, 'ಟೆಲಿಗ್ರಾಂ');
    });

    test('leaves settings commands to the settings fast path', () {
      expect(OfflineAppCommand.parse('open settings'), isNull);
      expect(OfflineAppCommand.parse('open wifi settings'), isNull);
    });

    test('does not parse incomplete app launch requests', () {
      expect(OfflineAppCommand.parse('open'), isNull);
      expect(OfflineAppCommand.parse('launch   '), isNull);
    });
  });
}
