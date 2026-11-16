import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'lucy_context_builder.dart';
import 'voice_service.dart';
import 'screen_capture_service.dart';
import 'lucy_activity_store.dart';
import 'grok_service.dart';
import 'groq_service.dart';
import 'hms_service.dart';
import 'performance_monitor.dart';
import 'action_approval_policy.dart';
import 'routine_scheduler.dart';
import 'phone_action_service.dart';
import 'lucy_memory_store.dart';

enum AgentState {
  idle,
  listening,
  capturing,
  analyzing,
  speaking,
  waitingConfirmation,
  executingAction,
}

class ConversationEntry {
  final String text;
  final bool isUser;
  final Uint8List? screenshotBytes;
  final DateTime timestamp;

  ConversationEntry({
    required this.text,
    required this.isUser,
    this.screenshotBytes,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class _UiSnapshot {
  final String? rawTree;
  final String? packageName;
  final List<Map<String, dynamic>> elements;
  final bool hasFocusedEditable;

  const _UiSnapshot({
    required this.rawTree,
    required this.packageName,
    required this.elements,
    required this.hasFocusedEditable,
  });

  String get signature => rawTree ?? '';
}

class AgentController extends ChangeNotifier {
  final AiService _aiService = AiService();
  final LucyContextBuilder _contextBuilder = LucyContextBuilder();
  final GrokService _grokService = GrokService();
  final GroqService _groqService = GroqService();
  final HmsService _hmsService = HmsService();
  final VoiceService _voiceService = VoiceService();
  final ScreenCaptureManager _screenCapture = ScreenCaptureManager();
  final LucyActivityStore _activityStore = LucyActivityStore();
  final LucyPerformanceMonitor _performanceMonitor =
      LucyPerformanceMonitor.shared;
  final PhoneActionService _phoneActions = PhoneActionService();

  AgentState _state = AgentState.idle;
  AgentState get state => _state;

  final List<ConversationEntry> _conversation = [];
  List<ConversationEntry> get conversation => List.unmodifiable(_conversation);

  String _statusMessage =
      'I can see your screen and help you interact with apps';
  String get statusMessage => _statusMessage;

  Uint8List? _lastScreenshotBytes;
  Uint8List? get lastScreenshotBytes => _lastScreenshotBytes;

  String? _currentTranscript = '';
  String? get currentTranscript => _currentTranscript;

  bool _isActive = false;
  bool get isActive => _isActive;

  int _listenRetryCount = 0;
  bool _listenRestartScheduled = false;
  Timer? _silenceTimeoutTimer;
  static const Duration _conversationSilenceTimeout = Duration(seconds: 60);
  bool _pushToTalkMode = false;
  Completer<void>? _pushToTalkFinalResult;

  static const int _maxStepsPerCommand = 50;
  static const Duration _uiPollInterval = Duration(milliseconds: 120);
  static const Duration _tapReadyTimeout = Duration(milliseconds: 900);
  static const Duration _typeReadyTimeout = Duration(milliseconds: 900);
  static const Duration _navigationReadyTimeout = Duration(milliseconds: 1200);
  static const Duration _openAppReadyTimeout = Duration(milliseconds: 2500);

  bool _cancelRequested = false;
  Completer<bool>? _pendingVoiceApproval;

  bool _isAskingForFurtherHelp = false;

  /// Language code of the most recent agent reply ("en" or "ja").
  /// Used to localize hardcoded follow-ups, cancel-word detection, TTS, and STT locale.
  String _currentLang = 'en';
  String get currentLang => _currentLang;

  static const String _langPrefKey = 'lucy_lang';
  static const String _providerPrefKey = 'lucy_ai_provider';
  static const String _legacyProviderPrefKey = 'lucy_use_grok';
  static const Set<String> _supportedLangs = {'en', 'ja', 'ar', 'hi', 'kn'};
  LucyMemoryStore? _memoryStore;
  String get memorySummary => _memoryStore?.summary ?? '';
  List<LucyMemory> get savedMemories =>
      _memoryStore?.items ?? const <LucyMemory>[];

  Future<void> rememberUserMemory(
    String content, {
    String category = 'fact',
  }) async {
    await _memoryStore?.remember(content, category: category);
    notifyListeners();
  }

  Future<int> forgetUserMemory(String query) async {
    final removed = await _memoryStore?.forgetMatching(query) ?? 0;
    notifyListeners();
    return removed;
  }

  Future<void> clearUserMemories() async {
    await _memoryStore?.clear();
    notifyListeners();
  }

  Future<void> _replyToMemoryCommand(String reply) async {
    _addConversation(reply, false);
    _setState(AgentState.speaking);
    await _voiceService.speak(reply, lang: _currentLang);
  }

  String _memoryReply(
    String key, {
    String value = '',
    int count = 0,
  }) {
    switch (_currentLang) {
      case 'ja':
        return switch (key) {
          'empty' => 'まだ保存された思い出はありません。「覚えておいて」と言えば保存できます。',
          'show' => 'あなたが保存を頼んだ内容はこちらです。$value',
          'cleared' => 'この端末に保存していたLucyのメモリーを消去しました。',
          'nameForgot' => '呼び方の設定を忘れました。',
          'noName' => '保存された呼び方はありません。',
          'askForget' => '忘れてほしい内容を教えてください。',
          'forgot' => '一致した$count件のメモリーを忘れました。',
          'noMatch' => 'その内容に一致するメモリーは見つかりませんでした。',
          'askRemember' => '覚えておく内容を教えてください。',
          'saved' => '$valueとしてこの端末に保存しました。いつでも確認したり、削除したりできます。',
          _ => 'メモリーを更新しました。',
        };
      case 'ar':
        return switch (key) {
          'empty' => 'لا توجد ذكريات محفوظة بعد. قل «تذكّر أن…» لحفظ شيء.',
          'show' => 'هذه هي المعلومات التي طلبت مني حفظها: $value',
          'cleared' => 'مسحت الذكريات التي حفظتها على هذا الجهاز.',
          'nameForgot' => 'نسيت الاسم الذي طلبت مني استخدامه.',
          'noName' => 'لا يوجد اسم مفضّل محفوظ.',
          'askForget' => 'ما المعلومة التي تريد مني نسيانها؟',
          'forgot' => 'نسيت $count من عناصر الذاكرة المطابقة.',
          'noMatch' => 'لم أجد معلومة محفوظة تطابق ذلك.',
          'askRemember' => 'ما الذي تريد مني تذكّره؟',
          'saved' => 'حفظت ذلك على هذا الجهاز ضمن $value. يمكنك طلب عرضه أو حذفه في أي وقت.',
          _ => 'تم تحديث الذاكرة.',
        };
      case 'hi':
        return switch (key) {
          'empty' => 'अभी कोई याद सेव नहीं है। कुछ सेव करवाने के लिए कहो, “याद रखना कि…”।',
          'show' => 'तुमने जो बातें सेव करने को कहा था, वे ये हैं: $value',
          'cleared' => 'मैंने इस डिवाइस पर सेव की गई यादें मिटा दी हैं।',
          'nameForgot' => 'मैंने तुम्हारा पसंदीदा नाम भूल दिया है।',
          'noName' => 'कोई पसंदीदा नाम सेव नहीं है।',
          'askForget' => 'बताओ, कौन-सी सेव की हुई बात भूलनी है?',
          'forgot' => 'मैंने मेल खाने वाली $count यादें हटा दी हैं।',
          'noMatch' => 'उस बात से मेल खाती कोई सेव की हुई याद नहीं मिली।',
          'askRemember' => 'बताओ, क्या याद रखना है?',
          'saved' => 'मैंने इसे इस डिवाइस पर $value के रूप में सेव कर लिया है।',
          _ => 'याद अपडेट कर दी है।',
        };
      case 'kn':
        return switch (key) {
          'empty' => 'ಇನ್ನೂ ಯಾವುದೇ ನೆನಪುಗಳನ್ನು ಉಳಿಸಿಲ್ಲ. “ಇದನ್ನು ನೆನಪಿಟ್ಟುಕೋ…” ಎಂದು ಹೇಳಬಹುದು.',
          'show' => 'ನೀವು ಉಳಿಸಲು ಕೇಳಿದ ವಿಷಯಗಳು ಇವು: $value',
          'cleared' => 'ಈ ಸಾಧನದಲ್ಲಿ ಉಳಿಸಿದ್ದ ನೆನಪುಗಳನ್ನು ಅಳಿಸಿದ್ದೇನೆ.',
          'nameForgot' => 'ನಿಮ್ಮ ಇಷ್ಟದ ಹೆಸರನ್ನು ಮರೆತಿದ್ದೇನೆ.',
          'noName' => 'ಯಾವುದೇ ಇಷ್ಟದ ಹೆಸರು ಉಳಿಸಿಲ್ಲ.',
          'askForget' => 'ಯಾವ ಉಳಿಸಿದ ವಿಷಯವನ್ನು ಮರೆಯಬೇಕು ಎಂದು ಹೇಳಿ.',
          'forgot' => 'ಹೊಂದಿಕೆಯಾದ $count ನೆನಪುಗಳನ್ನು ಮರೆತಿದ್ದೇನೆ.',
          'noMatch' => 'ಆ ವಿಷಯಕ್ಕೆ ಹೊಂದುವ ಉಳಿಸಿದ ನೆನಪು ಸಿಗಲಿಲ್ಲ.',
          'askRemember' => 'ಏನು ನೆನಪಿಟ್ಟುಕೊಳ್ಳಬೇಕು ಎಂದು ಹೇಳಿ.',
          'saved' => '$value ಎಂದು ಈ ಸಾಧನದಲ್ಲಿ ಉಳಿಸಿದ್ದೇನೆ. ಬೇಕಾದಾಗ ನೋಡಬಹುದು ಅಥವಾ ಅಳಿಸಬಹುದು.',
          _ => 'ನೆನಪನ್ನು ನವೀಕರಿಸಿದ್ದೇನೆ.',
        };
      default:
        return switch (key) {
          'empty' => 'I do not have any saved memories yet. Say “remember that…” when you want me to save something.',
          'show' => 'Here is what I have saved because you asked me to remember it: $value',
          'cleared' => 'I cleared the memories Lucy saved on this device.',
          'nameForgot' => 'I forgot your saved preferred name.',
          'noName' => 'I do not have a preferred name saved.',
          'askForget' => 'Tell me the saved detail you want me to forget.',
          'forgot' => 'I forgot $count matching saved memory items.',
          'noMatch' => 'I could not find a saved memory matching that detail.',
          'askRemember' => 'Tell me what you want me to remember.',
          'saved' => 'Saved on this device as a $value. You can ask what I remember or tell me to forget it.',
          _ => 'Memory updated.',
        };
    }
  }

  bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);

  Future<bool> _handleMemoryCommand(String text) async {
    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();

    const recallCommands = {
      'what do you remember',
      'what do you remember about me',
      'show my memories',
      'list memories',
      '何を覚えてる',
      '私について何を覚えてる',
      '覚えていることを見せて',
      'ماذا تتذكر',
      'ماذا تتذكر عني',
      'اعرض ذكرياتي',
      'तुम्हें क्या याद है',
      'मेरे बारे में क्या याद है',
      'मेरी यादें बताओ',
      'ನಿನಗೆ ಏನು ನೆನಪಿದೆ',
      'ನನ್ನ ಬಗ್ಗೆ ಏನು ನೆನಪಿದೆ',
      'ನನ್ನ ನೆನಪುಗಳನ್ನು ತೋರಿಸು',
    };
    if (recallCommands.contains(lower)) {
      final summary = memorySummary;
      await _replyToMemoryCommand(
        summary.isEmpty
            ? _memoryReply('empty')
            : _memoryReply('show', value: summary),
      );
      return true;
    }

    const clearCommands = {
      'forget all memories',
      'forget everything',
      'clear my memories',
      'delete all memories',
      'すべて忘れて',
      '全部忘れて',
      '記憶を全部消して',
      'انسَ كل شيء',
      'امسح كل الذكريات',
      'भूल जाओ सब कुछ',
      'सब यादें मिटा दो',
      'ಎಲ್ಲವನ್ನೂ ಮರೆತುಬಿಡು',
      'ಎಲ್ಲ ನೆನಪುಗಳನ್ನು ಅಳಿಸು',
    };
    if (clearCommands.contains(lower)) {
      await clearUserMemories();
      await _replyToMemoryCommand(_memoryReply('cleared'));
      return true;
    }

    const forgetNameCommands = {
      'forget my name',
      'forget my nickname',
      'forget my preferred name',
      '私の名前を忘れて',
      '私のニックネームを忘れて',
      'انسَ اسمي',
      'ماذا عن اسمي، انسَه',
      'मेरा नाम भूल जाओ',
      'मेरा निकनेम भूल जाओ',
      'ನನ್ನ ಹೆಸರನ್ನು ಮರೆತುಬಿಡು',
      'ನನ್ನ ಅಡ್ಡಹೆಸರನ್ನು ಮರೆತುಬಿಡು',
    };
    if (forgetNameCommands.contains(lower)) {
      final removed = await forgetUserMemory('prefers to be addressed as');
      await _replyToMemoryCommand(
        _memoryReply(removed > 0 ? 'nameForgot' : 'noName'),
      );
      return true;
    }

    String? preferredName;
    for (final prefix in ['call me ', 'my nickname is ']) {
      if (lower.startsWith(prefix)) {
        preferredName = trimmed.substring(prefix.length).trim();
        break;
      }
    }
    if (preferredName == null) {
      final patterns = <RegExp>[
        RegExp(r'^私を(.+?)と呼んで$'),
        RegExp(r'^نادني\s+(.+)$'),
        RegExp(r'^मुझे\s+(.+?)\s+बुलाओ$'),
        RegExp(r'^ನನ್ನನ್ನು\s+(.+?)\s+ಎಂದು ಕರೆಯಿರಿ$'),
      ];
      for (final pattern in patterns) {
        final match = pattern.firstMatch(trimmed);
        if (match != null) {
          preferredName = match.group(1)?.trim();
          break;
        }
      }
    }
    if (preferredName != null) {
      preferredName = preferredName.replaceAll(RegExp(r'[.!?。！？]+$'), '').trim();
      if (preferredName.isNotEmpty && preferredName.length <= 60) {
        await forgetUserMemory('prefers to be addressed as');
        await rememberUserMemory(
          'The user prefers to be addressed as $preferredName.',
          category: 'preference',
        );
        await _replyToMemoryCommand(
          _currentLang == 'hi'
              ? 'ठीक है, मैं तुम्हें $preferredName कहूँगा।'
              : _currentLang == 'kn'
              ? 'ಸರಿ, ಇನ್ನು ಮುಂದೆ ನಿಮ್ಮನ್ನು $preferredName ಎಂದು ಕರೆಯುತ್ತೇನೆ.'
              : _currentLang == 'ja'
              ? 'わかりました。これから$preferredNameと呼びます。'
              : _currentLang == 'ar'
              ? 'حسنًا، سأناديك $preferredName.'
              : 'Okay. I will call you $preferredName.',
        );
      } else {
        await _replyToMemoryCommand(_memoryReply('askRemember'));
      }
      return true;
    }

    const forgetPrefixes = [
      'forget that ',
      'forget ',
      '忘れて ',
      'انسَ ',
      'भूल जाओ ',
      'ಮರೆತುಬಿಡು ',
    ];
    for (final prefix in forgetPrefixes) {
      if (lower.startsWith(prefix)) {
        final query = trimmed.substring(prefix.length).trim();
        if (query.isEmpty || query == 'this') {
          await _replyToMemoryCommand(_memoryReply('askForget'));
        } else {
          final removed = await forgetUserMemory(query);
          await _replyToMemoryCommand(
            _memoryReply(removed > 0 ? 'forgot' : 'noMatch', count: removed),
          );
        }
        return true;
      }
    }

    const rememberPrefixes = [
      'remember that ',
      'remember: ',
      'lucy remember ',
      '覚えておいて ',
      'تذكر أن ',
      'याद रखना कि ',
      'ನೆನಪಿಟ್ಟುಕೋ ',
    ];
    for (final prefix in rememberPrefixes) {
      if (lower.startsWith(prefix)) {
        final fact = trimmed.substring(prefix.length).trim();
        if (fact.isEmpty) {
          await _replyToMemoryCommand(_memoryReply('askRemember'));
          return true;
        }
        final factLower = fact.toLowerCase();
        final category = _containsAny(factLower, [
          'contact',
          'phone number',
          'mobile number',
          'email address',
          'contact number',
          'संपर्क',
          'फोन नंबर',
          'ಸಂಪರ್ಕ',
          'ದೂರವಾಣಿ ಸಂಖ್ಯೆ',
          '連絡先',
          '電話番号',
          'جهة الاتصال',
          'رقم الهاتف',
        ])
            ? 'contact'
            : _containsAny(factLower, [
          'prefer',
          'like',
          'favorite',
          'favourite',
          'पसंद',
          'ಇಷ್ಟ',
          '好き',
          'أفضل',
        ])
            ? 'preference'
            : _containsAny(factLower, [
                'every day',
                'every morning',
                'every evening',
                'routine',
                'रोज',
                'ಪ್ರತಿ ದಿನ',
                '毎日',
                'كل يوم',
              ])
            ? 'routine'
            : _containsAny(factLower, [
                'my friend',
                'my mother',
                'my father',
                'my brother',
                'my sister',
                'मेरा दोस्त',
                'मेरी माँ',
                'ನನ್ನ ಸ್ನೇಹಿತ',
                '母',
                'صديقي',
              ])
            ? 'relationship'
            : _containsAny(factLower, [
                'goal',
                'want to become',
                'planning to',
                'लक्ष्य',
                'ಗುರಿ',
                '目標',
                'هدفي',
              ])
            ? 'goal'
            : 'fact';
        await rememberUserMemory(fact, category: category);
        await _replyToMemoryCommand(_memoryReply('saved', value: category));
        return true;
      }
    }
    return false;
  }

  /// Set the UI/voice language. Persists across restarts. Restarts the
  /// listener if currently active so STT picks up the new locale.
  Future<void> setLanguage(String lang) async {
    final normalized = lang.toLowerCase();
    if (!_supportedLangs.contains(normalized)) return;
    if (_currentLang == normalized) return;
    _currentLang = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langPrefKey, normalized);
    if (_isActive && _state == AgentState.listening) {
      await _voiceService.stopListening();
      _startListening();
    }
  }

  static const Map<String, String> _followUps = {
    'en': 'Do you need any further help?',
    'ja': '他に何かお手伝いできることはありますか？',
    'ar': 'هل تحتاج إلى أي مساعدة أخرى؟',
    'hi': 'क्या आपको और किसी मदद की ज़रूरत है?',
    'kn': 'ನಿಮಗೆ ಇನ್ನೇನಾದರೂ ಸಹಾಯ ಬೇಕೇ?',
  };
  static const Map<String, String> _stoppingMessages = {
    'en': 'Alright, stopping the agent.',
    'ja': 'わかりました。エージェントを停止します。',
    'ar': 'حسنًا، سأوقف المساعد الآن.',
    'hi': 'ठीक है, मैं Lucy को रोक रहा हूँ।',
    'kn': 'ಸರಿ, Lucy ಅನ್ನು ನಿಲ್ಲಿಸುತ್ತಿದ್ದೇನೆ.',
  };

  // Patterns that mean "no, I'm done" when replying to the follow-up prompt.
  static final RegExp _negativeEn = RegExp(
    r'^(no|nope|nah|stop|exit|nothing|not\b.*)$',
  );
  // Hiragana/katakana/kanji forms of "no", "stop", "that's enough", "done".
  static final RegExp _negativeJa = RegExp(
    r'(いいえ|いえ|けっこう|結構|もういい|もう大丈夫|大丈夫|終了|終わり|やめて|止めて|停止|いらない|不要|ない)',
  );
  // Arabic forms: "no", "stop", "enough", "done", "nothing".
  static final RegExp _negativeHiKn = RegExp(
    r'(नहीं|रुको|बंद|बस|ಸಾಕು|ಬೇಡ|ನಿಲ್ಲಿಸು)',
  );
  static final RegExp _negativeAr = RegExp(
    r'(لا|كلا|توقف|قف|اوقف|أوقف|اكتفي|يكفي|كفى|انتهى|انتهيت|خلاص|لا شيء|لا شكرا|لا شكرًا)',
  );

  AiService get aiService => _aiService;
  ScreenCaptureManager get screenCapture => _screenCapture;
  double get voiceSpeechRate => _voiceService.speechRate;
  double get voicePitch => _voiceService.pitch;
  double get voiceVolume => _voiceService.volume;

  Future<void> configureVoice({
    double? speechRate,
    double? pitch,
    double? volume,
  }) async {
    await _voiceService.setVoiceSettings(
      speechRate: speechRate,
      pitch: pitch,
      volume: volume,
    );
    notifyListeners();
  }

  Future<void> setVoiceStyle(String style) async {
    switch (style) {
      case 'calm':
        await configureVoice(speechRate: 0.42, pitch: 0.92);
        return;
      case 'bright':
        await configureVoice(speechRate: 0.54, pitch: 1.08);
        return;
      default:
        await configureVoice(speechRate: 0.48, pitch: 1.0);
    }
  }

  Future<void> interruptSpeaking() async {
    if (!_isActive || _state != AgentState.speaking) return;
    _cancelRequested = true;
    await _voiceService.stopSpeaking();
    _statusMessage = 'Interrupted. Listening for you…';
    notifyListeners();
  }

  /// Whether a cancel has been requested by the user.
  bool get cancelRequested => _cancelRequested;

  /// Force-stop the current agent loop immediately.
  void requestCancel() {
    _cancelRequested = true;
    _voiceService.stopSpeaking();
    notifyListeners();
  }

  Future<void> initialize() async {
    await _activityStore.seedDefaults();
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString(_langPrefKey);
    await _aiService.restoreConfiguration(
      legacyKey: prefs.getString('gemini_api_key'),
    );
    if (prefs.containsKey('gemini_api_key')) {
      await prefs.remove('gemini_api_key');
    }
    _memoryStore = LucyMemoryStore(prefs);
    await _memoryStore!.initialize();
    final savedProvider = prefs.getString(_providerPrefKey);
    final provider =
        savedProvider ??
        ((prefs.getBool(_legacyProviderPrefKey) ?? false) ? 'grok' : 'gemini');
    _aiService.useGrok(provider == 'grok');
    _aiService.useGroq(provider == 'groq');
    _aiService.useHms(provider == 'hms');
    if (savedLang != null && _supportedLangs.contains(savedLang)) {
      _currentLang = savedLang;
    }

    await _voiceService.initialize();

    // Wire native stop notification action → requestCancel
    _screenCapture.onForceStop = () {
      if (_isActive) {
        // A notification Stop is a full stop, not merely a task cancellation.
        unawaited(stopAgent());
      }
    };

    _voiceService.onResult = (text, isFinal) {
      _currentTranscript = text;
      if (isFinal) {
        final completed = _pushToTalkFinalResult;
        if (completed != null && !completed.isCompleted) completed.complete();
      }
      if (text.trim().isNotEmpty) _resetSilenceTimeout();
      final pendingApproval = _pendingVoiceApproval;
      if (pendingApproval != null && isFinal && text.trim().isNotEmpty) {
        final answer = text.trim().toLowerCase().replaceAll(
          RegExp(r'\s+'),
          ' ',
        );
        const affirmativeAnswers = {
          'approve',
          'approved',
          'yes',
          'allow',
          'continue',
          'go ahead',
          'haan',
          'han',
          'ho',
          'haanji',
          'manzoor',
          'हाँ',
          'हां',
          'मंजूर',
          'ಹೌದು',
          'ಮಂಜೂರು',
        };
        const negativeAnswers = {
          'deny',
          'denied',
          'no',
          'cancel',
          'stop',
          'reject',
          'beda',
          'illa',
          'nahi',
          'mat karo',
          'नहीं',
          'नही',
          'ಬೇಡ',
          'ಇಲ್ಲ',
        };
        final denied = negativeAnswers.contains(answer);
        final approved = affirmativeAnswers.contains(answer);
        if (denied || approved) {
          if (!pendingApproval.isCompleted)
            pendingApproval.complete(!denied && approved);
          unawaited(_voiceService.stopListening());
        } else {
          _currentTranscript = 'Please say approve or cancel.';
          unawaited(
            _voiceService.speak(
              'Please say approve or cancel.',
              lang: _currentLang,
            ),
          );
          unawaited(
            _voiceService.startListening(
              localeId: VoiceService.sttLocaleFor(_currentLang),
            ),
          );
        }
      } else if (isFinal && text.isNotEmpty) {
        _handleUserInput(text);
      }
      notifyListeners();
    };

    _voiceService.onListeningDone = () {
      if (!_isActive || _state != AgentState.listening) return;
      _listenRetryCount++;
      _scheduleListeningRestart();
    };

    _voiceService.onError = (error) {
      debugPrint('Lucy speech recognition error: $error');
      if (!_isActive || _state != AgentState.listening) return;
      final normalized = error.toLowerCase();
      if (normalized.contains('permission') ||
          normalized.contains('not_available') ||
          normalized.contains('recognizer_not_found')) {
        _statusMessage =
            'Microphone or speech service unavailable. Check permissions and retry.';
        unawaited(stopAgent());
        return;
      }
      _listenRetryCount++;
      _scheduleListeningRestart();
    };
  }

  bool get isGrokProvider => _aiService.isUsingGrok;
  bool get isGroqProvider => _aiService.isUsingGroq;
  bool get isHmsProvider => _aiService.isUsingHms;

  Future<void> setGrokProvider(bool enabled) async {
    if (enabled && !await _grokService.isConfigured()) {
      _statusMessage = 'Save a valid xAI API key before selecting Grok.';
      notifyListeners();
      return;
    }
    _aiService.useGrok(enabled);
    final selectedProvider = enabled
        ? 'grok'
        : (_aiService.isUsingGroq
              ? 'groq'
              : _aiService.isUsingHms
              ? 'hms'
              : 'gemini');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPrefKey, selectedProvider);
    _statusMessage = enabled
        ? 'Grok selected for Lucy.'
        : '${selectedProvider == 'groq' ? 'Groq' : 'Gemini'} selected for Lucy.';
    notifyListeners();
  }

  Future<void> setGroqProvider(bool enabled) async {
    if (enabled && !await _groqService.isConfigured()) {
      _statusMessage = 'Save a Groq API key before selecting Groq.';
      notifyListeners();
      return;
    }
    _aiService.useGroq(enabled);
    final selectedProvider = enabled
        ? 'groq'
        : (_aiService.isUsingGrok
              ? 'grok'
              : _aiService.isUsingHms
              ? 'hms'
              : 'gemini');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPrefKey, selectedProvider);
    _statusMessage = enabled
        ? 'Groq selected for Lucy.'
        : '${selectedProvider == 'grok' ? 'Grok' : 'Gemini'} selected for Lucy.';
    notifyListeners();
  }

  Future<void> setHmsProvider(bool enabled) async {
    if (enabled && !await _hmsService.isConfigured()) {
      _statusMessage =
          'Save a verified 100milionseek API key before selecting it.';
      notifyListeners();
      return;
    }
    _aiService.useHms(enabled);
    final selectedProvider = enabled
        ? 'hms'
        : (_aiService.isUsingGrok
              ? 'grok'
              : _aiService.isUsingGroq
              ? 'groq'
              : 'gemini');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPrefKey, selectedProvider);
    _statusMessage = enabled
        ? '100milionseek selected. Automatic provider fallback remains enabled.'
        : '$selectedProvider selected for Lucy.';
    notifyListeners();
  }

  Future<void> configureAi(String apiKey) async {
    await _aiService.configure(apiKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gemini_api_key');
    notifyListeners();
  }

  Future<void> removeGeminiKey() async {
    await _aiService.clearGeminiKey();
    notifyListeners();
  }

  Future<void> toggleAgent() async {
    if (_isActive) {
      await stopAgent();
    } else {
      await startAgent();
    }
  }

  Future<void> startAgent({bool voiceOnly = false}) async {
    final providerReady = await _aiService.isProviderReady();
    _pushToTalkMode = voiceOnly;
    _pushToTalkFinalResult = voiceOnly ? Completer<void>() : null;
    _isActive = true;
    _addConversation(
      voiceOnly
          ? 'Push-to-talk started. Release the microphone button to stop listening.'
          : 'Agent started. Listening for your commands. To stop Lucy while it is in another app, open notifications and tap "Stop Lucy".',
      false,
    );
    _statusMessage = voiceOnly
        ? 'Push-to-talk · release the button to stop'
        : providerReady
        ? 'Listening… Tap to stop, or hold the microphone for push-to-talk.'
        : 'Offline voice commands ready. Add an AI key for screen tasks.';
    _isAskingForFurtherHelp = false;
    notifyListeners();

    if (providerReady && !voiceOnly) {
      final hasScreenPermission = await _screenCapture.requestPermission();
      if (!hasScreenPermission) {
        _addConversation(
          'Screen capture permission denied. I can still handle local voice commands.',
          false,
        );
      }
      final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
      if (!hasAccessibility) {
        _addConversation(
          'Accessibility service is not enabled. Lucy can listen, but cannot tap or type in other apps.',
          false,
        );
      }
    }

    _listenRetryCount = 0;
    await _startListening();
    // Start the microphone foreground service only after the speech plugin has
    // had a chance to request RECORD_AUDIO from the visible activity.
    // NativeVoiceService owns the microphone foreground service and Stop notification.
    // Avoid starting a second microphone foreground service.
  }

  Future<void> stopAgent() async {
    _isActive = false;
    _pushToTalkMode = false;
    _pushToTalkFinalResult = null;
    _listenRestartScheduled = false;
    _silenceTimeoutTimer?.cancel();
    _silenceTimeoutTimer = null;
    _cancelRequested = false;
    await _voiceService.stopListening();
    await _voiceService.stopSpeaking();
    // VoiceService.stopListening() stops NativeVoiceService and removes its notification.
    _setState(AgentState.idle);
    _statusMessage = 'I can see your screen and help you interact with apps';
    _addConversation('Agent stopped.', false);
    notifyListeners();
  }

  void _scheduleListeningRestart() {
    if (!_isActive || _listenRestartScheduled) return;
    _listenRestartScheduled = true;
    final seconds = (1 << (_listenRetryCount.clamp(0, 5))).clamp(2, 30);
    _statusMessage =
        'Speech session ended. Reconnecting in $seconds seconds...';
    notifyListeners();
    Future.delayed(Duration(seconds: seconds), () {
      _listenRestartScheduled = false;
      if (_isActive && _state == AgentState.listening) {
        unawaited(_startListening());
      }
    });
  }

  Future<void> _startListening() async {
    if (!_isActive) return;
    _setState(AgentState.listening);
    _statusMessage = '🎤 Listening... Open notifications to stop Lucy.';
    _currentTranscript = '';
    notifyListeners();

    final started = await _voiceService.startListening(
      localeId: VoiceService.sttLocaleFor(_currentLang),
    );
    if (!started && _isActive) {
      _listenRetryCount++;
      _scheduleListeningRestart();
    } else if (started) {
      _listenRetryCount = 0;
      _resetSilenceTimeout();
    }
  }

  Future<void> finishPushToTalk() async {
    if (!_isActive || !_pushToTalkMode) return;
    final finalResult = _pushToTalkFinalResult;
    if (_state == AgentState.listening && finalResult != null) {
      await Future.any<void>([
        finalResult.future,
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
    }
    // If no final utterance arrived, stop the voice-only session. If a command
    // is already being processed, its completion path stops the session.
    if (_isActive && _state == AgentState.listening) {
      await stopAgent();
    }
  }

  Future<void> _resumeOrFinishListening() async {
    if (!_isActive) return;
    if (_pushToTalkMode) {
      await stopAgent();
    } else {
      await _startListening();
    }
  }

  void _resetSilenceTimeout() {
    _silenceTimeoutTimer?.cancel();
    if (!_isActive || _state != AgentState.listening) return;
    _silenceTimeoutTimer = Timer(_conversationSilenceTimeout, () {
      if (_isActive && _state == AgentState.listening) {
        _statusMessage = 'Conversation paused after 60 seconds without speech.';
        unawaited(stopAgent());
      }
    });
  }

  /// Main handler: user says something → agent loop begins.
  Future<void> _handleUserInput(String text) async {
    if (!_isActive || _state != AgentState.listening) return;

    _silenceTimeoutTimer?.cancel();
    _silenceTimeoutTimer = null;
    _setState(AgentState.analyzing);
    await _voiceService.stopListening();

    _addConversation(text, true);
    _currentTranscript = '';

    if (await _handleMemoryCommand(text)) {
      await _resumeOrFinishListening();
      return;
    }

    if (await _handleOfflineCommand(text)) {
      await _resumeOrFinishListening();
      return;
    }

    if (!await _aiService.isProviderReady()) {
      await _speakLocalReply(
        'I can help offline with the time, battery and flashlight. Add an AI provider key in Lucy tools for screen and app tasks.',
      );
      await _resumeOrFinishListening();
      return;
    }

    if (_isAskingForFurtherHelp) {
      _isAskingForFurtherHelp = false;
      final trimmed = text.trim();
      final textLowerAscii = trimmed.toLowerCase().replaceAll(
        RegExp(r'[^\w\s]'),
        '',
      );
      final isNegative =
          _negativeEn.hasMatch(textLowerAscii) ||
          _negativeJa.hasMatch(trimmed) ||
          _negativeHiKn.hasMatch(trimmed) ||
          _negativeAr.hasMatch(trimmed);
      if (isNegative) {
        _setState(AgentState.speaking);
        final stopMsg =
            _stoppingMessages[_currentLang] ?? _stoppingMessages['en']!;
        _addConversation(stopMsg, false);
        await _voiceService.speak(stopMsg, lang: _currentLang);

        await Future.delayed(const Duration(milliseconds: 500));
        while (_voiceService.isSpeaking) {
          await Future.delayed(const Duration(milliseconds: 200));
        }

        await stopAgent();
        return;
      }
    }

    await _runAgentLoop(text);

    // Continuous mode resumes; push-to-talk closes after one completed turn.
    await _resumeOrFinishListening();
  }

  Future<void> _speakLocalReply(String reply) async {
    _addConversation(reply, false);
    _setState(AgentState.speaking);
    await _voiceService.speak(reply, lang: _currentLang);
  }

  Future<bool> _handleOfflineCommand(String text) async {
    final command = text.toLowerCase().trim();
    final asksTime = RegExp(
      r"(what.?s the time|what time is it|tell me the time|current time|\btime\b|\bclock\b|समय|कितने बजे|ಸಮಯ|ಗಂಟೆ|時刻|時間|الوقت)",
    ).hasMatch(command);
    final asksBattery = RegExp(
      r"(battery|charge level|battery status|बैटरी|ಚಾರ್ಜ್|ಬ್ಯಾಟರಿ|電池|بطارية|شحن)",
    ).hasMatch(command);
    final asksFlashlight = RegExp(
      r"(flashlight|torch|टॉर्च|ಟಾರ್ಚ್|懐中電灯|مصباح)",
    ).hasMatch(command);

    if (asksTime) {
      final now = DateTime.now();
      final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
      final time = hour.toString() + ':' +
          now.minute.toString().padLeft(2, '0') +
          (now.hour >= 12 ? ' PM' : ' AM');
      final reply = switch (_currentLang) {
        'hi' => 'अभी ' + time + ' बजे हैं।',
        'kn' => 'ಈಗ ಸಮಯ ' + time + '.',
        'ja' => '現在の時刻は ' + time + ' です。',
        'ar' => 'الوقت الآن ' + time + '.',
        _ => "It's " + time + '.',
      };
      await _speakLocalReply(reply);
      return true;
    }

    if (asksBattery) {
      try {
        final result = await _phoneActions.execute(
          'get_device_status',
          const <String, dynamic>{},
        );
        final data = result is Map
            ? Map<dynamic, dynamic>.from(result)
            : const <dynamic, dynamic>{};
        final percent = data['batteryPercent'];
        final charging = data['charging'] == true;
        final value = percent is num ? percent.round().toString() : null;
        final reply = value == null
            ? 'I could not read the battery status on this device.'
            : switch (_currentLang) {
                'hi' => 'बैटरी ' + value + ' प्रतिशत है' +
                    (charging ? ' और फोन चार्ज हो रहा है।' : '।'),
                'kn' => 'ಬ್ಯಾಟರಿ ' + value + ' ಪ್ರತಿಶತ ಇದೆ' +
                    (charging ? ' ಮತ್ತು ಫೋನ್ ಚಾರ್ಜ್ ಆಗುತ್ತಿದೆ.' : '.'),
                'ja' => 'バッテリー残量は ' + value + ' パーセントです' +
                    (charging ? '。充電中です。' : '。'),
                'ar' => 'مستوى البطارية ' + value + ' بالمئة' +
                    (charging ? '، والهاتف قيد الشحن.' : '.'),
                _ => 'Battery is at ' + value + ' percent' +
                    (charging ? ' and charging.' : '.'),
              };
        await _speakLocalReply(reply);
      } catch (_) {
        await _speakLocalReply('I could not read the battery status right now.');
      }
      return true;
    }

    if (asksFlashlight) {
      final turnOff = RegExp(
        r"(turn off|switch off|disable|off|बंद|ಆಫ್|消して|关闭|إيقاف)",
      ).hasMatch(command);
      try {
        final changed = await _phoneActions.execute(
          'set_flashlight',
          <String, dynamic>{'enabled': !turnOff},
        );
        final reply = changed == true
            ? switch (_currentLang) {
                'hi' => turnOff ? 'टॉर्च बंद कर दी।' : 'टॉर्च चालू कर दी।',
                'kn' => turnOff ? 'ಟಾರ್ಚ್ ಆಫ್ ಮಾಡಿದೆ.' : 'ಟಾರ್ಚ್ ಆನ್ ಮಾಡಿದೆ.',
                'ja' => turnOff ? 'ライトを消しました。' : 'ライトをつけました。',
                'ar' => turnOff ? 'أطفأت المصباح.' : 'شغّلت المصباح.',
                _ => turnOff ? 'Flashlight off.' : 'Flashlight on.',
              }
            : 'I could not change the flashlight. Check camera permission and device support.';
        await _speakLocalReply(reply);
      } catch (_) {
        await _speakLocalReply(
          'I could not change the flashlight. Check camera permission and device support.',
        );
      }
      return true;
    }

    return false;
  }

  /// The core agent loop: capture → analyze → act → repeat.
  Future<void> _runAgentLoop(String userMessage) async {
    _cancelRequested = false;
    int step = 0;
    String currentMessage = userMessage;
    // Screen dimensions are stable for this command, but device context is
    // refreshed before every model request so new notifications, battery,
    // network, foreground-app and calendar changes are visible to Lucy.
    // Android omits optional sources unless the user granted access.
    final screenSize = await _screenCapture.getScreenSize();

    while (step < _maxStepsPerCommand && _isActive && !_cancelRequested) {
      step++;

      // 1. Capture screenshot (with retries for reliability after app switches)
      _setState(AgentState.capturing);
      _statusMessage = '📸 Capturing screen... (step $step)';
      notifyListeners();

      final screenshotFuture = _captureScreenWithRetry();
      final uiSnapshotFuture = _fetchUiSnapshot();

      final screenshotBytes = await screenshotFuture;
      if (screenshotBytes != null) {
        _lastScreenshotBytes = screenshotBytes;
      }

      if (_cancelRequested) break;

      // 1b. Fetch UI tree from accessibility service (runs in parallel-ready)
      final uiSnapshot = await uiSnapshotFuture;
      final uiTree = uiSnapshot?.rawTree;

      if (_cancelRequested) break;

      // 2. Send to AI (with screenshot + UI tree)
      _setState(AgentState.analyzing);
      _statusMessage = '🤖 Thinking... (step $step)';
      notifyListeners();

      final aiStopwatch = Stopwatch()..start();
      final deviceContext = await _contextBuilder.buildPromptContext();
      if (_cancelRequested) break;
      final localNow = DateTime.now();
      final requestWithClock =
          '[Device local date/time: ${localNow.toIso8601String()}]\n'
          '${deviceContext.isEmpty ? '' : '$deviceContext\n'}'
          '${currentMessage}';
      final agentResponse = await _aiService.agentChat(
        requestWithClock,
        imageBytes: screenshotBytes,
        screenSize: screenSize,
        uiTree: uiTree,
        memoryContext: _memoryStore?.relevantContext(userMessage) ?? '',
      );
      aiStopwatch.stop();
      _performanceMonitor.recordResponse(aiStopwatch.elapsed);

      if (_cancelRequested) break;

      // Update the current language from the AI's tag (falls back to previous).
      if (_supportedLangs.contains(agentResponse.lang) &&
          agentResponse.lang != _currentLang) {
        _currentLang = agentResponse.lang;
        // Persist so next launch + STT locale match what the user actually spoke.
        unawaited(
          SharedPreferences.getInstance().then(
            (prefs) => prefs.setString(_langPrefKey, _currentLang),
          ),
        );
      }

      // Show AI response and action summary in conversation
      String speakText = agentResponse.speak;
      if (agentResponse.done) {
        if (speakText.isNotEmpty &&
            !speakText.endsWith(' ') &&
            !speakText.endsWith('\n')) {
          speakText += ' ';
        }
        speakText += _followUps[_currentLang] ?? _followUps['en']!;
        _isAskingForFurtherHelp = true;
      } else {
        _isAskingForFurtherHelp = false;
      }

      String displayText = speakText;
      if (agentResponse.actions.isNotEmpty) {
        final actionSummary = agentResponse.actions
            .map(
              (a) => '⚡ ${a.type}${a.params.isNotEmpty ? ': ${a.params}' : ''}',
            )
            .join('\n');
        displayText = displayText.isEmpty
            ? actionSummary
            : '$displayText\n\n$actionSummary';
      }
      if (displayText.trim().isNotEmpty) {
        _addConversation(displayText, false, screenshotBytes: screenshotBytes);
      }

      if (_cancelRequested) break;

      // 3. Execute actions
      if (agentResponse.actions.isNotEmpty) {
        _setState(AgentState.executingAction);
        _statusMessage = '⚡ Executing actions... (step $step)';
        notifyListeners();

        var latestSnapshot = uiSnapshot;
        for (final action in agentResponse.actions) {
          if (_cancelRequested) break;
          latestSnapshot = await _executeAction(action, latestSnapshot);
        }
      }

      if (_cancelRequested) break;

      // 4. Speak the response (only speak if done or has something to say)
      if (speakText.isNotEmpty) {
        _setState(AgentState.speaking);
        _statusMessage = '🔊 Speaking...';
        notifyListeners();

        final ttsText = _trimForTts(speakText);
        await _voiceService.speak(ttsText, lang: _currentLang);

        // Wait for TTS to finish
        await Future.delayed(const Duration(milliseconds: 500));
        while (_voiceService.isSpeaking && !_cancelRequested) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (_cancelRequested) break;

      // 5. Check if done
      if (agentResponse.done) {
        break;
      }

      // Not done → continue the loop with a follow-up message
      currentMessage =
          'I have executed the actions. Here is the updated screen. Continue with the task.';
      // If screenshot capture might fail next iteration, the AI will still
      // receive the message but without an image. The retry logic in
      // _captureScreenWithRetry handles this by making multiple attempts.
    }

    // Handle cancellation
    if (_cancelRequested) {
      _cancelRequested = false;
      _addConversation('🛑 Stopped by user.', false);
      return;
    }

    if (step >= _maxStepsPerCommand) {
      _addConversation(
        '⚠️ Reached maximum steps ($_maxStepsPerCommand). Stopping.',
        false,
      );
    }
  }

  /// Capture the screen with retry logic.
  /// After navigating to another app, the first capture attempt may return null
  /// because the VirtualDisplay hasn't rendered a fresh frame yet. Retrying
  /// with increasing delays ensures we eventually get a valid screenshot.
  Future<Uint8List?> _captureScreenWithRetry({int maxRetries = 3}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        final bytes = await _screenCapture.captureScreen();
        if (bytes != null) return bytes;
      } catch (e) {
        print('Screenshot capture attempt ${i + 1} failed: $e');
      }
      if (i < maxRetries - 1) {
        // Increasing delay between retries: 200ms, 400ms
        await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
    print('All $maxRetries screenshot capture attempts failed');
    return null;
  }

  /// Resolve element ID from the UI tree to (cx, cy) coordinates.
  /// Returns null if the element is not found.
  Map<String, double>? _resolveElementCoordinates(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    final element = _findElementById(elementId, uiElements);
    if (element != null) {
      final bounds = element['bounds'] as Map<String, dynamic>?;
      if (bounds != null) {
        return {
          'x': (bounds['cx'] as num).toDouble(),
          'y': (bounds['cy'] as num).toDouble(),
        };
      }
    }
    return null;
  }

  Map<String, dynamic>? _findElementById(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    for (final element in uiElements) {
      if (element['id'] == elementId) {
        return element;
      }
    }
    return null;
  }

  Future<_UiSnapshot?> _fetchUiSnapshot() async {
    try {
      final uiTree = await _screenCapture.getUITree();
      if (uiTree == null || uiTree.isEmpty) {
        return null;
      }

      final parsed = jsonDecode(uiTree) as Map<String, dynamic>;
      final elementsJson = parsed['elements'] as List<dynamic>? ?? const [];
      final elements = elementsJson
          .whereType<Map>()
          .map((element) => Map<String, dynamic>.from(element))
          .toList(growable: false);

      final hasFocusedEditable = elements.any(
        (element) => element['editable'] == true && element['focused'] == true,
      );

      return _UiSnapshot(
        rawTree: uiTree,
        packageName: parsed['package'] as String?,
        elements: elements,
        hasFocusedEditable: hasFocusedEditable,
      );
    } catch (e) {
      return null;
    }
  }

  bool _didPackageChange(_UiSnapshot? before, _UiSnapshot? after) {
    if (before?.packageName == null || after?.packageName == null) {
      return false;
    }
    return before!.packageName != after!.packageName;
  }

  bool _didTreeSignatureChange(_UiSnapshot? before, _UiSnapshot? after) {
    final beforeSignature = before?.signature;
    final afterSignature = after?.signature;
    if (beforeSignature == null || afterSignature == null) {
      return false;
    }
    return beforeSignature != afterSignature;
  }

  bool _tapTargetsEditableField(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) {
    final elementId = action.params['element'] as num?;
    if (elementId == null || beforeSnapshot == null) {
      return false;
    }

    final element = _findElementById(
      elementId.toInt(),
      beforeSnapshot.elements,
    );
    if (element == null) {
      return false;
    }

    return element['editable'] == true ||
        element['focusable'] == true ||
        (element['type']?.toString().contains('EditText') ?? false);
  }

  Duration _readinessTimeoutForAction(AgentAction action) {
    switch (action.type) {
      case 'open_app':
        return _openAppReadyTimeout;
      case 'tap':
        return _tapReadyTimeout;
      case 'type':
        return _typeReadyTimeout;
      case 'swipe':
      case 'back':
      case 'home':
        return _navigationReadyTimeout;
      case 'wait':
        final ms = (action.params['ms'] as num?)?.toInt() ?? 1000;
        return Duration(milliseconds: ms.clamp(0, 10000));
      default:
        return Duration.zero;
    }
  }

  bool _isActionReady(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
    _UiSnapshot? currentSnapshot,
  ) {
    if (currentSnapshot == null) {
      return false;
    }

    if (beforeSnapshot == null) {
      return true;
    }

    final packageChanged = _didPackageChange(beforeSnapshot, currentSnapshot);
    final treeChanged = _didTreeSignatureChange(
      beforeSnapshot,
      currentSnapshot,
    );

    switch (action.type) {
      case 'open_app':
        final targetPackage = action.params['package'] as String?;
        if (targetPackage != null &&
            targetPackage.isNotEmpty &&
            currentSnapshot.packageName == targetPackage) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'tap':
        final expectsFocusedInput = _tapTargetsEditableField(
          action,
          beforeSnapshot,
        );
        if (expectsFocusedInput && currentSnapshot.hasFocusedEditable) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'type':
      case 'swipe':
      case 'back':
      case 'home':
      case 'wait':
        return packageChanged || treeChanged;
      default:
        return true;
    }
  }

  Future<_UiSnapshot?> _waitForActionReadiness(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) async {
    final timeout = _readinessTimeoutForAction(action);
    if (timeout == Duration.zero) {
      return beforeSnapshot;
    }

    final canObserveUi = await _screenCapture.isAccessibilityEnabled();
    if (!canObserveUi) {
      return beforeSnapshot;
    }

    _UiSnapshot? latestSnapshot = beforeSnapshot;
    final deadline = DateTime.now().add(timeout);

    while (!_cancelRequested) {
      final currentSnapshot = await _fetchUiSnapshot();
      if (currentSnapshot != null) {
        latestSnapshot = currentSnapshot;
      }

      if (_isActionReady(action, beforeSnapshot, currentSnapshot)) {
        return currentSnapshot;
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        break;
      }

      await Future.delayed(
        remaining < _uiPollInterval ? remaining : _uiPollInterval,
      );
    }

    return latestSnapshot;
  }

  /// Execute a single agent action.
  Future<bool> _requestVoiceApproval(
    AgentAction action,
    String? targetLabel, {
    required String requiredRisk,
    bool sensitiveInput = false,
  }) async {
    if (!_isActive || _pendingVoiceApproval != null) return false;
    final details = <String>[
      action.type.replaceAll('_', ' '),
      if (targetLabel != null && targetLabel.isNotEmpty) 'target $targetLabel',
      if (action.params['text'] is String && sensitiveInput)
        'text: [hidden sensitive input]',
      if (action.params['text'] is String && !sensitiveInput)
        'text: ${action.params['text']}',
      if (action.params['message'] is String)
        'message: ${action.params['message']}',
      if (action.params['recipient'] is String)
        'recipient: ${action.params['recipient']}',
      'risk: $requiredRisk',
      if (action.params['reason'] is String)
        'reason: ${action.params['reason']}',
    ].join('. ');
    final prompt = requiredRisk == 'medium'
        ? 'Lucy wants to $details. Is that okay? Say yes or no.'
        : 'Lucy wants to $details. This is a high-risk action. Say approve to continue, or cancel to stop.';
    _setState(AgentState.waitingConfirmation);
    _statusMessage = 'Waiting for your spoken approval...';
    _addConversation(prompt, false);
    await _voiceService.speak(prompt, lang: _currentLang);
    await Future.delayed(const Duration(milliseconds: 250));
    while (_voiceService.isSpeaking && _isActive) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!_isActive) return false;
    final completer = Completer<bool>();
    _pendingVoiceApproval = completer;
    _currentTranscript = '';
    final started = await _voiceService.startListening(
      localeId: VoiceService.sttLocaleFor(_currentLang),
    );
    if (!started) {
      _pendingVoiceApproval = null;
      _addConversation(
        'I could not hear an approval. The action was not performed.',
        false,
      );
      return false;
    }
    var approved = false;
    try {
      approved = await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _addConversation(
        'Approval timed out. The action was not performed.',
        false,
      );
    } finally {
      _pendingVoiceApproval = null;
      await _voiceService.stopListening();
      _currentTranscript = '';
      if (_isActive) _setState(AgentState.executingAction);
    }
    if (approved) {
      _addConversation('Approval received. Continuing the task.', false);
    }
    return approved;
  }

  Future<_UiSnapshot?> _executeAction(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) async {
    // Ordinary navigation is hands-free. Consequential actions pause the
    // task, ask for spoken approval, and resume the same agent loop on approval.
    String? targetLabel;
    if (action.type == 'place_call' || action.type == 'send_sms') {
      targetLabel = action.params['phoneNumber']?.toString();
    }
    if (action.type == 'open_settings') {
      targetLabel = action.params['page']?.toString();
    }
    var sensitiveInput = false;
    if (beforeSnapshot != null && action.type == 'type') {
      // Password fields are marked by Android's accessibility tree. Never
      // type into them without a separate spoken approval.
      final focusedElement = beforeSnapshot.elements.cast<Map<String, dynamic>?>().firstWhere(
            (element) =>
                element != null &&
                element['focused'] == true &&
                element['editable'] == true,
            orElse: () => null,
          );
      sensitiveInput = focusedElement?['password'] == true;
    }
    if (action.type == 'tap' && beforeSnapshot != null) {
      final elementId = (action.params['element'] as num?)?.toInt();
      if (elementId != null &&
          elementId >= 0 &&
          elementId < beforeSnapshot.elements.length) {
        final element = beforeSnapshot.elements[elementId];
        targetLabel = [
          element['text']?.toString() ?? '',
          element['desc']?.toString() ?? '',
        ].where((value) => value.isNotEmpty).join(' ').trim();
      }
    }
    final rawConfidence = action.params['confidence'];
    final modelConfidence = rawConfidence is num
        ? rawConfidence.toDouble().clamp(0.0, 1.0).toDouble()
        : 0.5;
    if (modelConfidence < 0.30) {
      _addConversation(
        'I am not confident I understood that action correctly. Please repeat or clarify the request.',
        false,
      );
      _cancelRequested = true;
      return beforeSnapshot;
    }
    final requiredRisk = LucyActionApprovalPolicy.effectiveRisk(
      action.type,
      targetLabel: targetLabel,
      packageName: beforeSnapshot?.packageName,
      modelRisk: action.params['risk']?.toString(),
      confidence: modelConfidence,
      sensitiveInput: sensitiveInput,
    );
    if (requiredRisk != 'low') {
      final approved = await _requestVoiceApproval(
        action,
        targetLabel,
        requiredRisk: requiredRisk,
        sensitiveInput: sensitiveInput,
      );
      if (!approved) {
        _cancelRequested = true;
        _addConversation('Action cancelled. I will stop this task.', false);
        return beforeSnapshot;
      }
    }

    // Actions that require the accessibility service
    const accessibilityActions = {'tap', 'type', 'swipe', 'back', 'home'};

    if (accessibilityActions.contains(action.type)) {
      final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
      if (!hasAccessibility) {
        _addConversation(
          '⚠️ Cannot execute "${action.type}" — accessibility service not enabled. '
          'Please enable it in Settings → Accessibility → Lucy.',
          false,
        );
        return beforeSnapshot;
      }
    }

    try {
      switch (action.type) {
        case 'open_app':
          final package = action.params['package'] as String? ?? '';
          if (package.isNotEmpty) {
            final success = await _screenCapture.openApp(package);
            if (!success) {
              print('Failed to open app: $package');
            }
          }
          break;

        case 'tap':
          // Never guess tap coordinates. A missing/stale UI element must fail
          // closed rather than tapping an arbitrary location on the user's phone.
          final elementId = (action.params['element'] as num?)?.toInt();
          if (elementId == null || beforeSnapshot == null) {
            _addConversation(
              'I could not verify the screen element to tap, so I did not tap anything.',
              false,
            );
            return beforeSnapshot;
          }
          final coords = _resolveElementCoordinates(
            elementId,
            beforeSnapshot.elements,
          );
          if (coords == null) {
            _addConversation(
              'That screen element is no longer available. I did not tap anything.',
              false,
            );
            return beforeSnapshot;
          }
          await _screenCapture.performTap(coords['x']!, coords['y']!);
          break;

        case 'type':
          final text = action.params['text'] as String? ?? '';
          if (text.isNotEmpty) {
            await _screenCapture.performType(text);
          }
          break;

        case 'swipe':
          final startX = (action.params['startX'] as num?)?.toDouble() ?? 0;
          final startY = (action.params['startY'] as num?)?.toDouble() ?? 0;
          final endX = (action.params['endX'] as num?)?.toDouble() ?? 0;
          final endY = (action.params['endY'] as num?)?.toDouble() ?? 0;
          await _screenCapture.performSwipe(startX, startY, endX, endY);
          break;

        case 'back':
          await _screenCapture.pressBack();
          break;

        case 'home':
          await _screenCapture.pressHome();
          break;

        case 'schedule_reminder':
          final title = action.params['title']?.toString().trim() ?? '';
          final body = action.params['body']?.toString().trim() ?? title;
          final delayMinutes =
              (action.params['delayMinutes'] as num?)?.toInt() ?? 0;
          final repeatMinutes =
              (action.params['repeatIntervalMinutes'] as num?)?.toInt() ?? 0;
          if (title.isEmpty || delayMinutes < 1) {
            _addConversation(
              'I need a reminder title and a future time. Please say when you want it.',
              false,
            );
            break;
          }
          final reminderId = 'voice_${DateTime.now().millisecondsSinceEpoch}';
          await LucyRoutineScheduler.scheduleReminder(
            id: reminderId,
            title: title,
            body: body,
            delayMinutes: delayMinutes,
            repeatIntervalMinutes: repeatMinutes,
          );
          _addConversation(
            repeatMinutes >= 15
                ? 'Reminder scheduled: $title. It will repeat every $repeatMinutes minutes.'
                : 'Reminder scheduled: $title.',
            false,
          );
          break;

        case 'set_alarm':
        case 'set_timer':
        case 'place_call':
        case 'send_sms':
        case 'open_url':
        case 'start_navigation':
        case 'music_search':
        case 'set_flashlight':
        case 'set_volume':
        case 'set_brightness':
        case 'get_device_status':
        case 'read_contact':
        case 'create_calendar_event':
        case 'open_settings':
        case 'take_photo':
        case 'share_text':
          await _executeNativePhoneAction(action);
          break;

        case 'wait':
          break;

        default:
          debugPrint('Unknown action type: ${action.type}');
      }
    } catch (e) {
      print('Error executing action ${action.type}: $e');
    }

    return _waitForActionReadiness(action, beforeSnapshot);
  }

  Future<void> _executeNativePhoneAction(AgentAction action) async {
    dynamic nativeResult;
    try {
      nativeResult = await _phoneActions.execute(action.type, action.params);
    } catch (error) {
      debugPrint(
        'Native phone action ${action.type} failed; trying UI fallback: $error',
      );
      nativeResult = false;
    }

    final resultMap = nativeResult is Map
        ? Map<String, dynamic>.from(nativeResult)
        : <String, dynamic>{};
    final needsBrightnessAccess = resultMap['requiresSettingsAccess'] == true;
    final succeeded =
        nativeResult == true ||
        resultMap['success'] == true ||
        resultMap.containsKey('batteryPercent') ||
        resultMap.containsKey('phoneNumber') ||
        (action.type == 'set_volume' && resultMap.containsKey('level')) ||
        (action.type == 'set_brightness' && needsBrightnessAccess);

    if (needsBrightnessAccess) {
      const message =
          'Android opened special access settings. Allow Lucy to change system brightness, then repeat your brightness command.';
      _addConversation(message, false);
      return;
    }

    if (!succeeded) {
      const fallbackPackages = <String, String>{
        'set_alarm': 'com.google.android.deskclock',
        'set_timer': 'com.google.android.deskclock',
        'open_url': 'com.android.chrome',
        'place_call': 'com.google.android.dialer',
        'send_sms': 'com.google.android.apps.messaging',
        'start_navigation': 'com.google.android.apps.maps',
        'music_search': 'com.google.android.youtube',
        'read_contact': 'com.google.android.contacts',
        'create_calendar_event': 'com.google.android.calendar',
        'open_settings': 'com.android.settings',
        'take_photo': 'com.android.camera2',
      };
      final packageName = fallbackPackages[action.type];
      if (packageName != null) {
        final opened = await _screenCapture.openApp(packageName);
        if (opened) {
          _addConversation(
            'The direct Android action was unavailable, so I opened the related app for screen-based control.',
            false,
          );
          return;
        }
      }
      _addConversation(
        'Android could not complete that action, and the related app could not be opened. Nothing was sent or called.',
        false,
      );
      return;
    }

    if (action.type == 'get_device_status') {
      final battery = resultMap['batteryPercent'];
      final charging = resultMap['charging'] == true;
      final total = (resultMap['storageTotalBytes'] as num?)?.toDouble() ?? 0;
      final free = (resultMap['storageFreeBytes'] as num?)?.toDouble() ?? 0;
      final usedGb = total > 0 ? (total - free) / (1024 * 1024 * 1024) : 0;
      final totalGb = total / (1024 * 1024 * 1024);
      final message =
          'Battery: ${battery ?? 'unknown'} percent, '
          '${charging ? 'charging' : 'not charging'}. '
          'Storage used: ${usedGb.toStringAsFixed(1)} of ${totalGb.toStringAsFixed(1)} GB.';
      _addConversation(message, false);
      await _voiceService.speak(message, lang: _currentLang);
    } else if (action.type == 'read_contact') {
      final name = resultMap['name']?.toString();
      final number = resultMap['phoneNumber']?.toString();
      final message = name == null || number == null
          ? 'I could not find a matching contact.'
          : 'I found $name. The saved number is $number.';
      _addConversation(message, false);
      await _voiceService.speak(message, lang: _currentLang);
    } else if (action.type == 'set_brightness' &&
        resultMap['success'] == true) {
      final level = resultMap['level'] ?? action.params['level'] ?? '';
      _addConversation('Brightness set to $level percent.', false);
    } else if (action.type == 'set_flashlight') {
      final enabled = action.params['enabled'] != false;
      _addConversation(
        enabled ? 'Flashlight turned on.' : 'Flashlight turned off.',
        false,
      );
    } else if (action.type == 'place_call') {
      _addConversation(
        'I opened the dialer with the requested number. Review it and tap Call when you are ready.',
        false,
      );
    } else if (action.type == 'send_sms') {
      _addConversation(
        'I opened your SMS app with the message filled in. Review it and tap Send when you are ready.',
        false,
      );
    } else if (action.type == 'create_calendar_event') {
      _addConversation(
        'I opened your calendar with the event details. Review them and save the event.',
        false,
      );
    } else if (action.type == 'take_photo') {
      _addConversation(
        'Camera opened. Take the photo when you are ready.',
        false,
      );
    } else if (action.type == 'share_text') {
      _addConversation(
        'The Android share sheet is ready. Choose where to share the text.',
        false,
      );
    } else if (action.type == 'set_alarm') {
      _addConversation('Your alarm details are ready in the Clock app.', false);
    } else if (action.type == 'set_timer') {
      _addConversation('Your timer is ready in the Clock app.', false);
    }
  }

  String _trimForTts(String text) {
    // Remove action/emoji markers for cleaner TTS
    String cleaned = text;
    cleaned = cleaned.replaceAll(RegExp(r'⚡.*?\n'), '');
    cleaned = cleaned.trim();
    if (cleaned.length > 300) {
      return '${cleaned.substring(0, 297)}...';
    }
    return cleaned;
  }

  void _setState(AgentState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<bool> capturePreview() async {
    final screenshotBytes = await _captureScreenWithRetry();
    if (screenshotBytes == null) {
      return false;
    }

    _lastScreenshotBytes = screenshotBytes;
    notifyListeners();
    return true;
  }

  void _addConversation(
    String text,
    bool isUser, {
    Uint8List? screenshotBytes,
  }) {
    _conversation.add(
      ConversationEntry(
        text: text,
        isUser: isUser,
        screenshotBytes: screenshotBytes,
      ),
    );
    // Store event metadata only; conversation text can contain private information.
    unawaited(
      _activityStore.record(isUser ? 'user_message' : 'assistant_message'),
    );
    notifyListeners();
  }

  void clearConversation() {
    _conversation.clear();
    _lastScreenshotBytes = null;
    _isAskingForFurtherHelp = false;
    _aiService.resetChat();
    notifyListeners();
  }

  @override
  void dispose() {
    _silenceTimeoutTimer?.cancel();
    _voiceService.dispose();
    super.dispose();
  }
}
