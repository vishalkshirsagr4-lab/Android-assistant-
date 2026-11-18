import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Gmail cleanup requires review, exact approval and post-action verification', () async {
    final source = await rootBundle.loadString('assets/app_hints/gmail.json');
    final hint = jsonDecode(source) as Map<String, dynamic>;
    final strategy = (hint['strategy'] as List).cast<String>();
    final combined = strategy.join(' ').toLowerCase();

    expect(combined, contains('inspect messages first'));
    expect(combined, contains('explicitly approves the exact batch'));
    expect(combined, contains('never permanently delete'));
    expect(combined, contains('verify the resulting inbox state'));
    expect(combined, contains('untrusted data'));
  });
}
