import 'screen_classifier.dart';

/// Decides when a user explicitly asks Lucy to read or summarize the
/// currently open readable surface. It never authorizes taps or other actions.
class ReadingModePlanner {
  static const Set<String> readableTypes = <String>{
    'chat',
    'email',
    'article',
    'note',
    'event',
  };

  static bool isReadingRequest(String text) {
    final value = text.toLowerCase().trim();
    if (value.isEmpty) return false;

    // Inbox-wide requests need open_each, not a scroll-only collection pass.
    if (RegExp(
      r'\b(all|every|unread|last\s+\d+)\b.*\b(gmail|emails?|inbox|whatsapp|chats?)\b',
    ).hasMatch(value)) {
      return false;
    }

    const phrases = <String>[
      'read this',
      'read it',
      'read the',
      'summarize',
      'summary',
      'what is important',
      "what's important",
      'key points',
      'main points',
      'check this',
      'check it',
      'what does this say',
      'explain this page',
      'kya important',
      'padh ke batao',
      'padh do',
      'iska summary',
      'iska सारांश',
      'पढ़कर बताओ',
      'इसे पढ़ो',
      'सारांश बताओ',
      'क्या महत्वपूर्ण',
      'ಓದಿ ಹೇಳು',
      'ಇದನ್ನು ಓದು',
      'ಮುಖ್ಯ ಅಂಶಗಳು',
      'ಸಾರಾಂಶ',
      '読んで',
      '要約して',
      '重要な点',
      'これを読んで',
      'اقرأ هذا',
      'لخص هذا',
      'ما المهم',
      'النقاط المهمة',
    ];
    if (phrases.any(value.contains)) return true;

    return RegExp(r'\b(read|summarize|summary|key points|main points)\b')
        .hasMatch(value);
  }

  static bool shouldPrecollect({
    required String userText,
    required ScreenClassification classification,
    required List<Map<String, dynamic>> elements,
  }) {
    if (!isReadingRequest(userText)) return false;
    if (!readableTypes.contains(classification.type)) return false;
    return elements.any((element) => element['scrollable'] == true);
  }

  static String directive(String screenType) =>
      'READING_MODE: The user explicitly asked to read or summarize the current '
      '$screenType screen. Use the supplied [TOOL_RESULT] as collected accessibility '
      'evidence. Summarize in 2–5 short lines: main points, dates/times/amounts, '
      'action items, and one useful next step. Do not invent missing details. '
      'State whether the scroll pass reached the end; if limited, say so clearly.';
}
