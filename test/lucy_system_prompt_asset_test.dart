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
    expect(prompt, contains('MULTI-STEP TASK COMPLETION'));
    expect(prompt, contains('STRICT ACTION-TURN CONTRACT'));
    expect(prompt, contains('[TASK_CONTEXT]'));
    expect(prompt, contains('Use "batch" only for safe, reversible UI micro-steps'));
    expect(prompt, contains('Completion requires the done_when condition'));
    expect(prompt, contains('wait for explicit approval of the exact selected messages'));
    expect(prompt, isNot(contains(r'\n')));
  });
}
