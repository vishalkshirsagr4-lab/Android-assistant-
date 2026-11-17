import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Lucy system prompt is bundled as a readable asset', () async {
    final prompt = await rootBundle.loadString('assets/lucy_system_prompt.txt');

    expect(prompt, contains('PERSONALITY AND CONVERSATION'));
    expect(prompt, contains('MEMORY AND PRIVACY'));
    expect(prompt, contains('RESPONSE FORMAT'));
    expect(prompt, contains('LANGUAGE RULES'));
    expect(prompt, isNot(contains(r'\n')));
  });
}
