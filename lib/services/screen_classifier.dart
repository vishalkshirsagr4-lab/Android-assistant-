import 'dart:convert';

/// Cheap, deterministic screen classification from the accessibility tree.
/// It is a planning hint only; it never authorizes an action.
class ScreenClassification {
  const ScreenClassification({
    required this.type,
    required this.confidence,
    required this.signals,
  });

  final String type;
  final double confidence;
  final List<String> signals;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'confidence': confidence,
        'signals': signals,
      };
}

class ScreenClassifier {
  ScreenClassification classify(String? rawTree) {
    if (rawTree == null || rawTree.trim().isEmpty) {
      return const ScreenClassification(type: 'unknown', confidence: 0, signals: <String>[]);
    }
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(rawTree) as Map<String, dynamic>;
    } catch (_) {
      return const ScreenClassification(type: 'unknown', confidence: 0, signals: <String>[]);
    }
    final packageName = (decoded['package'] ?? '').toString().toLowerCase();
    final elements = decoded['elements'];
    final labels = <String>[];
    if (elements is List) {
      for (final value in elements) {
        if (value is! Map) continue;
        for (final key in const <String>['text', 'desc', 'type']) {
          final text = (value[key] ?? '').toString().trim().toLowerCase();
          if (text.isNotEmpty) labels.add(text);
        }
      }
    }
    final corpus = '$packageName ${labels.join(' ')}';
    bool hasAny(List<String> terms) => terms.any(corpus.contains);
    List<String> matched(List<String> terms) => terms.where(corpus.contains).take(5).toList();

    ScreenClassification result(String type, List<String> signals, [double confidence = 0.82]) =>
        ScreenClassification(type: type, confidence: confidence, signals: signals);

    const payment = <String>['payment', 'pay now', 'upi', 'checkout', 'cvv', 'card number', 'bank account', 'transfer money', 'transaction'];
    if (hasAny(payment)) return result('payment', matched(payment), 0.96);
    const login = <String>['sign in', 'log in', 'login', 'password', 'passcode', 'verification code', 'one-time password', 'otp'];
    if (hasAny(login)) return result('login', matched(login), 0.93);
    const settings = <String>['settings', 'preferences', 'permissions', 'notifications', 'privacy', 'accessibility'];
    if (hasAny(settings)) return result('settings', matched(settings));
    const video = <String>['youtube', 'video player', 'playback', 'pause video', 'skip ad', 'skip ads', 'watch later', 'captions'];
    if (hasAny(video)) return result('video', matched(video));
    const ad = <String>['sponsored', 'advertisement', 'skip ad', 'close ad', 'learn more', 'install now'];
    if (hasAny(ad)) return result('ad', matched(ad), 0.88);
    const popup = <String>['not now', 'maybe later', 'no thanks', 'dismiss', 'got it', 'allow notifications', 'rate us', 'reject all'];
    if (hasAny(popup)) return result('popup', matched(popup), 0.84);
    const email = <String>['inbox', 'compose', 'subject', 'reply', 'forward', 'all mail', 'sent mail', 'gmail'];
    if (hasAny(email) || packageName.contains('gmail')) return result('email', matched(email), 0.86);
    const chat = <String>['message', 'send message', 'type a message', 'chat info', 'last seen', 'online', 'whatsapp', 'telegram'];
    if (hasAny(chat) || packageName.contains('whatsapp') || packageName.contains('telegram')) return result('chat', matched(chat), 0.85);
    const calendar = <String>['calendar', 'event', 'meeting', 'attendees', 'reminder', 'starts', 'ends', 'all day'];
    if (hasAny(calendar)) return result('event_calendar', matched(calendar), 0.84);
    const form = <String>['submit', 'required field', 'enter name', 'phone number', 'email address', 'save changes'];
    if (hasAny(form)) return result('form', matched(form), 0.8);
    const note = <String>['notes', 'keep note', 'checklist', 'untitled note', 'new note', 'note title'];
    if (hasAny(note)) return result('note', matched(note), 0.8);
    const article = <String>['article', 'published', 'read more', 'table of contents', 'by author', 'minutes read'];
    if (hasAny(article)) return result('article', matched(article), 0.78);
    const list = <String>['search', 'sort by', 'filter', 'recent', 'all items', 'inbox', 'chats', 'downloads'];
    if (hasAny(list)) return result('list', matched(list), 0.72);
    return const ScreenClassification(type: 'unknown', confidence: 0.25, signals: <String>[]);
  }
}
