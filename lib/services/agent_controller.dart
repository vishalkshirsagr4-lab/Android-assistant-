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
import 'agent_reliability.dart';
import 'screen_classifier.dart';
import 'reading_mode_planner.dart';
import 'lucy_settings_store.dart';
import 'lucy_learning_store.dart';
import 'lucy_app_hint_catalog.dart';

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
  final String appVersionCode;
  final List<Map<String, dynamic>> elements;
  final bool hasFocusedEditable;

  const _UiSnapshot({
    required this.rawTree,
    required this.packageName,
    this.appVersionCode = 'unknown',
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
  final LucySettingsStore _settingsStore = LucySettingsStore();
  final ScreenClassifier _screenClassifier = ScreenClassifier();
  final LucyAppHintCatalog _appHintCatalog = LucyAppHintCatalog();
  final LucyLearningStore _learningStore = LucyLearningStore();
  String? _lastRecordedUiSignature;
  Map<String, int>? _cachedScreenSize;
  final List<Map<String, dynamic>> _pendingSkillActions = <Map<String, dynamic>>[];
  String? _taskStartPackage;
  String? _taskStartSignature;
  String? _taskStartVersion;
  bool _taskSkillEligible = true;
  String? _taskSkillCommandTemplate;

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
  bool _lastActionDispatchSucceeded = true;
  String? _lastToolResult;
  int _lastActionEventSequence = 0;
  String? _previousModelTreePackage;
  Map<int, String> _previousModelTreeElements = <int, String>{};
  Completer<bool>? _pendingVoiceApproval;

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

  Future<bool> forgetUserMemoryById(String id) async {
    final removed = await _memoryStore?.forgetById(id) ?? false;
    notifyListeners();
    return removed;
  }

  Future<void> clearUserMemories() async {
    await _memoryStore?.clear();
    notifyListeners();
  }

  List<Map<String, dynamic>> get learnedUiMaps => _learningStore.uiMaps;
  List<Map<String, dynamic>> get learnedSkills => _learningStore.skills;

  Future<void> clearLearningData() async {
    await _learningStore.clear();
    _lastRecordedUiSignature = null;
    _pendingSkillActions.clear();
    notifyListeners();
  }

  /// Approve or revoke one learned skill from the user's settings screen.
  /// Approval is refused until the same sequence has succeeded twice.
  Future<bool> setLearnedSkillApproved(
    String id, {
    required bool approved,
  }) async {
    final changed = await _learningStore.setSkillApproved(
      id,
      approved: approved,
    );
    notifyListeners();
    return changed;
  }

  Future<bool> forgetLearnedSkill(String id) async {
    final removed = await _learningStore.forgetSkill(id);
    notifyListeners();
    return removed;
  }

  Future<bool> forgetLearnedUiMap(String key) async {
    final removed = await _learningStore.forgetUiMap(key);
    if (removed && _lastRecordedUiSignature == key) {
      _lastRecordedUiSignature = null;
    }
    notifyListeners();
    return removed;
  }

  Future<void> _replyToMemoryCommand(
    String context, {
    String event = 'memory_update',
  }) async {
    await _speakEvent(event, context: context);
  }

  /// Ask the configured model to phrase a short, localized status event.
  /// If every provider is unavailable, keep the event visible in status only.
  Future<void> _speakEvent(
    String event, {
    String context = '',
  }) async {
    final response = await _aiService.agentChat(
      '[EVENT: $event]\n'
      'User language: $_currentLang\n'
      'App status: $context\n'
      'Return one short natural sentence. Do not perform an action.',
    );
    if (response.isError || response.speak.trim().isEmpty) {
      _statusMessage = 'Lucy · $event';
      notifyListeners();
      return;
    }
    _addConversation(response.speak, false);
    _setState(AgentState.speaking);
    await _voiceService.speak(response.speak, lang: _currentLang);
  }


  bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);

  Future<bool> _handleMemoryCommand(String text) async {
    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();

    const recallCommands = {
      'what do you remember',
      'what do you remember about me',
      'kya yaad hai',
      'mere baare mein kya yaad hai',
      'meri memories dikhao',
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
            ? 'No saved memories were found.'
            : 'The user asked what is remembered. Summarize these saved details: $summary',
        event: 'memory_recalled',
      );
      return true;
    }

    const clearCommands = {
      'forget all memories',
      'forget everything',
      'sab kuch bhool jao',
      'sab yaadein bhool jao',
      'meri saari memories clear karo',
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
      await _replyToMemoryCommand(
        'The requested saved memories were successfully cleared.',
        event: 'memory_cleared',
      );
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
        removed > 0
            ? 'The saved preferred-name detail was removed.'
            : 'There was no saved preferred-name detail to remove.',
        event: 'memory_forgotten',
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
        RegExp(r'^mujhe\s+(.+?)\s+bulao$'),
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
          'Saved the user-approved preferred name.',
          event: 'memory_saved',
        );
      } else {
        await _replyToMemoryCommand(
            'The user asked to remember something but did not provide the detail. Ask one short question.',
            event: 'clarification_needed',
          );
      }
      return true;
    }

    const forgetPrefixes = [
      'forget that ',
      'forget ',
      'bhool jao ',
      'bhul jao ',
      'भूल जाओ ',
      '忘れて ',
      'انسَ ',
      'भूल जाओ ',
      'ಮರೆತುಬಿಡು ',
    ];
    for (final prefix in forgetPrefixes) {
      if (lower.startsWith(prefix)) {
        final query = trimmed.substring(prefix.length).trim();
        if (query.isEmpty || query == 'this') {
          await _replyToMemoryCommand(
            'The user asked to forget something but did not identify it. Ask one short question.',
            event: 'clarification_needed',
          );
        } else {
          final removed = await forgetUserMemory(query);
          await _replyToMemoryCommand(
            removed > 0
                ? 'Successfully removed $removed matching memory item(s).'
                : 'No saved memory matched the requested detail.',
            event: 'memory_forgotten',
          );
        }
        return true;
      }
    }

    const rememberPrefixes = [
      'remember that ',
      'remember: ',
      'lucy remember ',
      'yaad rakhna ki ',
      'yaad rakhna ',
      'याद रखना कि ',
      'ಯಾದಿಟ್ಟುಕೋ ',
      'ನೆನಪಿಟ್ಟುಕೋ ',
      '覚えておいて ',
      'تذكر أن ',
      'याद रखना कि ',
      'ನೆನಪಿಟ್ಟುಕೋ ',
    ];
    for (final prefix in rememberPrefixes) {
      if (lower.startsWith(prefix)) {
        final fact = trimmed.substring(prefix.length).trim();
        if (fact.isEmpty) {
          await _replyToMemoryCommand(
            'The user asked to remember something but did not provide the detail. Ask one short question.',
            event: 'clarification_needed',
          );
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
            ? 'person'
            : _containsAny(factLower, [
                'live in',
                'my address',
                'my city',
                'my hometown',
                'मेरा शहर',
                'मेरा पता',
                'ನನ್ನ ಊರು',
                'ನನ್ನ ವಿಳಾಸ',
                '住んでいる',
                'عنواني',
                'مدينتي',
              ])
            ? 'place'
            : _containsAny(factLower, [
                'goal',
                'want to become',
                'planning to',
                'लक्ष्य',
                'ಗುರಿ',
                '目標',
                'هدفي',
              ])
            ? 'fact'
            : 'fact';
        await rememberUserMemory(fact, category: category);
        await _replyToMemoryCommand(
          'Successfully saved one user-approved memory of type $category.',
          event: 'memory_saved',
        );
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
    await _learningStore.initialize();
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
    if (!await _settingsStore.isEnabled(LucySettingsStore.voiceInput)) {
      _statusMessage = 'Voice input is disabled in Privacy & settings.';
      notifyListeners();
      return;
    }
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
    notifyListeners();

    final cloudAiEnabled = await _settingsStore.isEnabled(LucySettingsStore.aiRequests);
    final screenSharingEnabled = await _settingsStore.isEnabled(LucySettingsStore.aiScreenSharing);
    final screenAutomationEnabled = await _settingsStore.isEnabled(LucySettingsStore.screenAutomation);
    if (providerReady && !voiceOnly && cloudAiEnabled && screenSharingEnabled) {
      final hasScreenPermission = await _screenCapture.requestPermission();
      if (!hasScreenPermission) {
        _addConversation(
          'Screen capture permission denied. I can still handle local voice commands.',
          false,
        );
      }
    }
    if (providerReady && !voiceOnly && cloudAiEnabled && screenAutomationEnabled) {
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
    // Stop a native deep-scroll pass before releasing task resources.
    await _screenCapture.cancelScreenOperation();
    await _screenCapture.keepScreenAwake(false);
    await _voiceService.stopListening();
    await _voiceService.stopSpeaking();
    // VoiceService.stopListening() stops NativeVoiceService and removes its notification.
    _setState(AgentState.idle);
    _statusMessage = 'Stopped';
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
    unawaited(_voiceService.updateNotificationStatus('Listening for your command'));
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
    await _voiceService.pauseListeningForProcessing();

    _addConversation(text, true);
    _currentTranscript = '';

    if (await _handleLearningCommand(text)) {
      await _resumeOrFinishListening();
      return;
    }

    if (await _settingsStore.isEnabled(LucySettingsStore.memory) &&
        await _handleMemoryCommand(text)) {
      await _resumeOrFinishListening();
      return;
    }

    if (await _handleOfflineCommand(text)) {
      await _resumeOrFinishListening();
      return;
    }

    if (!await _settingsStore.isEnabled(LucySettingsStore.aiRequests)) {
      _statusMessage = 'Cloud AI disabled · Offline commands remain available';
      notifyListeners();
      await _resumeOrFinishListening();
      return;
    }

    if (!await _aiService.isProviderReady()) {
      _statusMessage = 'AI provider not configured · Offline commands remain available';
      notifyListeners();
      await _resumeOrFinishListening();
      return;
    }

    _updateTaskProgress('Planning your request');
    await _screenCapture.keepScreenAwake(true);
    try {
      await _runAgentLoop(text);
    } finally {
      await _screenCapture.keepScreenAwake(false);
    }
    if (!_statusMessage.startsWith('AI unavailable') &&
        !_statusMessage.startsWith('Phone locked')) {
      _updateTaskProgress('Task finished · Listening again');
    }

    // Continuous mode resumes; push-to-talk closes after one completed turn.
    await _resumeOrFinishListening();
  }

  Future<void> _speakLocalReply(String reply) async {
    _addConversation(reply, false);
    _setState(AgentState.speaking);
    await _voiceService.speak(reply, lang: _currentLang);
  }

  void _showAutopilotDisabledStatus() {
    _statusMessage = 'Autopilot is off · no phone action was performed';
    _addConversation(_statusMessage, false);
    _setState(AgentState.idle);
    notifyListeners();
  }

  Future<bool> _runLocalPhoneAction(
    String action,
    Map<String, dynamic> params,
    String successReply,
  ) async {
    if (!await _settingsStore.isEnabled(LucySettingsStore.autopilot)) {
      _showAutopilotDisabledStatus();
      return true;
    }
    if (!await _settingsStore.isEnabled(LucySettingsStore.directPhoneActions)) {
      return false;
    }
    try {
      final result = await _phoneActions.execute(action, params);
      final succeeded = result == true ||
          (result is Map &&
              (result['success'] == true ||
                  result['level'] != null ||
                  result['batteryPercent'] != null));
      if (!succeeded) return false;
      await _speakLocalReply(successReply);
      return true;
    } catch (_) {
      return false;
    }
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
      if (!await _settingsStore.isEnabled(LucySettingsStore.directPhoneActions)) {
        await _speakLocalReply('Direct phone actions are disabled in Privacy & settings.');
        return true;
      }
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
        String reply;
        if (value == null) {
          reply = 'I could not read the battery status on this device.';
        } else {
          reply = switch (_currentLang) {
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
        }
        await _speakLocalReply(reply);
      } catch (_) {
        await _speakLocalReply('I could not read the battery status right now.');
      }
      return true;
    }

    if (asksFlashlight) {
      if (!await _settingsStore.isEnabled(LucySettingsStore.autopilot)) {
        _showAutopilotDisabledStatus();
        return true;
      }
      if (!await _settingsStore.isEnabled(LucySettingsStore.directPhoneActions)) {
        await _speakLocalReply('Direct phone actions are disabled in Privacy & settings.');
        return true;
      }
      final turnOff = RegExp(
        r"(turn off|switch off|disable|off|बंद|ಆಫ್|消して|关闭|إيقاف)",
      ).hasMatch(command);
      try {
        final changed = await _phoneActions.execute(
          'set_flashlight',
          <String, dynamic>{'enabled': !turnOff},
        );
        String reply;
        if (changed == true) {
          reply = switch (_currentLang) {
            'hi' => turnOff ? 'टॉर्च बंद कर दी।' : 'टॉर्च चालू कर दी।',
            'kn' => turnOff ? 'ಟಾರ್ಚ್ ಆಫ್ ಮಾಡಿದೆ.' : 'ಟಾರ್ಚ್ ಆನ್ ಮಾಡಿದೆ.',
            'ja' => turnOff ? 'ライトを消しました。' : 'ライトをつけました。',
            'ar' => turnOff ? 'أطفأت المصباح.' : 'شغّلت المصباح.',
            _ => turnOff ? 'Flashlight off.' : 'Flashlight on.',
          };
        } else {
          reply =
              'I could not change the flashlight. Check camera permission and device support.';
        }
        await _speakLocalReply(reply);
      } catch (_) {
        await _speakLocalReply(
          'I could not change the flashlight. Check camera permission and device support.',
        );
      }
      return true;
    }

    final asksVolumeUp = RegExp(
      r'(volume up|increase volume|turn volume up|louder|आवाज़ बढ़ाओ|वॉल्यूम बढ़ाओ|ಧ್ವನಿ ಹೆಚ್ಚಿಸು|音量を上げて|ارفع الصوت)',
    ).hasMatch(command);
    final asksVolumeDown = RegExp(
      r'(volume down|decrease volume|turn volume down|quieter|आवाज़ कम करो|वॉल्यूम कम करो|ಧ್ವನಿ ಕಡಿಮೆಮಾಡು|音量を下げて|اخفض الصوت)',
    ).hasMatch(command);
    final asksMute = RegExp(
      r'(mute|volume mute|silence volume|आवाज़ बंद करो|म्यूट|ಧ್ವನಿ ಮ್ಯೂಟ್|音を消して|اكتم الصوت)',
    ).hasMatch(command);
    if (asksVolumeUp || asksVolumeDown || asksMute) {
      if (!await _settingsStore.isEnabled(LucySettingsStore.autopilot)) {
        _showAutopilotDisabledStatus();
        return true;
      }
      if (!await _settingsStore.isEnabled(LucySettingsStore.directPhoneActions)) {
        return false;
      }
      final direction = asksMute ? 'mute' : asksVolumeUp ? 'up' : 'down';
      try {
        final result = await _phoneActions.execute(
          'set_volume',
          <String, dynamic>{'direction': direction, 'stream': 'music'},
        );
        final success = result is Map && result['level'] != null;
        if (success) {
          final level = (result['level'] as num).toInt();
          final max = (result['max'] as num?)?.toInt() ?? 100;
          final percent = max > 0 ? (level * 100 / max).round() : level;
          final reply = switch (_currentLang) {
            'hi' => 'वॉल्यूम ' + percent.toString() + ' प्रतिशत है।',
            'kn' => 'ವಾಲ್ಯೂಮ್ ' + percent.toString() + ' ಪ್ರತಿಶತ ಇದೆ.',
            'ja' => '音量は ' + percent.toString() + ' パーセントです。',
            'ar' => 'مستوى الصوت ' + percent.toString() + ' بالمئة.',
            _ => 'Volume is at ' + percent.toString() + ' percent.',
          };
          await _speakLocalReply(reply);
        }
      } catch (_) {
        // Keep the fast path silent if Android rejects the volume request.
      }
      return true;
    }

    const appPackages = <String, String>{
      'whatsapp': 'com.whatsapp',
      'व्हाट्सऐप': 'com.whatsapp',
      'वाट्सऐप': 'com.whatsapp',
      'ವಾಟ್ಸಾಪ್': 'com.whatsapp',
      'telegram': 'org.telegram.messenger',
      'टेलीग्राम': 'org.telegram.messenger',
      'ಟೆಲಿಗ್ರಾಂ': 'org.telegram.messenger',
      'youtube': 'com.google.android.youtube',
      'यूट्यूब': 'com.google.android.youtube',
      'ಯೂಟ್ಯೂಬ್': 'com.google.android.youtube',
      'gmail': 'com.google.android.gm',
      'जीमेल': 'com.google.android.gm',
      'ಜಿಮೇಲ್': 'com.google.android.gm',
      'chrome': 'com.android.chrome',
      'क्रोम': 'com.android.chrome',
      'क्रोम ब्राउज़र': 'com.android.chrome',
      'instagram': 'com.instagram.android',
      'इंस्टाग्राम': 'com.instagram.android',
      'ಇನ್‌ಸ್ಟಾಗ್ರಾಮ್': 'com.instagram.android',
      'maps': 'com.google.android.apps.maps',
      'google maps': 'com.google.android.apps.maps',
      'मैप्स': 'com.google.android.apps.maps',
      'ಸೆಟ್ಟಿಂಗ್ಸ್': 'com.android.settings',
      'settings': 'com.android.settings',
      'सेटिंग्स': 'com.android.settings',
    };
    final openPrefix = RegExp(
      r'^(?:open|launch|start|खोलो|खोल|ಶುರುಮಾಡು|ತೆರೆ|開いて|افتح)\s+(.+)$',
    ).firstMatch(command);
    final requestedApp = openPrefix?.group(1)?.trim();
    final packageName = requestedApp == null ? null : appPackages[requestedApp];
    if (packageName != null) {
      if (!await _settingsStore.isEnabled(LucySettingsStore.autopilot)) {
        _showAutopilotDisabledStatus();
        return true;
      }
      if (!await _settingsStore.isEnabled(LucySettingsStore.screenAutomation)) {
        return false;
      }
      final opened = await _screenCapture.openApp(packageName);
      if (opened) {
        final reply = switch (_currentLang) {
          'hi' => 'ऐप खोल दिया।',
          'kn' => 'ಆ್ಯಪ್ ತೆರೆಯಿತು.',
          'ja' => 'アプリを開きました。',
          'ar' => 'تم فتح التطبيق.',
          _ => 'App opened.',
        };
        await _speakLocalReply(reply);
      }
      return true;
    }

    final settingsMatch = RegExp(
      r'^(?:open|show|go to|खोलो|ತೆರೆ|開いて|افتح)\s+(?:(wifi|wi-fi|bluetooth|display|sound|apps|accessibility|location|battery|wireless)\s+)?settings?$',
    ).firstMatch(command);
    if (settingsMatch != null) {
      final requestedPage = settingsMatch.group(1);
      final page = switch (requestedPage) {
        'wifi' || 'wi-fi' => 'wifi',
        'bluetooth' => 'bluetooth',
        'display' => 'display',
        'sound' => 'sound',
        'apps' => 'apps',
        'accessibility' => 'accessibility',
        'location' => 'location',
        'battery' => 'battery',
        'wireless' => 'wireless',
        _ => 'general',
      };
      final reply = switch (_currentLang) {
        'hi' => 'सेटिंग्स खोल दी।',
        'kn' => 'ಸೆಟ್ಟಿಂಗ್ಸ್ ತೆರೆಯಿತು.',
        'ja' => '設定を開きました。',
        'ar' => 'تم فتح الإعدادات.',
        _ => 'Settings opened.',
      };
      if (await _runLocalPhoneAction(
        'open_settings',
        <String, dynamic>{'page': page},
        reply,
      )) return true;
    }

    final timerMatch = RegExp(
      r'^(?:set\s+)?(?:a\s+)?timer(?:\s+for)?\s+(\d{1,4})\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)$',
    ).firstMatch(command);
    if (timerMatch != null) {
      final amount = int.tryParse(timerMatch.group(1) ?? '') ?? 0;
      final unit = timerMatch.group(2) ?? '';
      final multiplier = unit.startsWith('h')
          ? 3600
          : unit.startsWith('m')
              ? 60
              : 1;
      final seconds = amount * multiplier;
      if (seconds >= 1 && seconds <= 86400) {
        final reply = switch (_currentLang) {
          'hi' => 'टाइमर शुरू कर दिया।',
          'kn' => 'ಟೈಮರ್ ಪ್ರಾರಂಭಿಸಿದೆ.',
          'ja' => 'タイマーを開始しました。',
          'ar' => 'بدأت المؤقت.',
          _ => 'Timer started.',
        };
        if (await _runLocalPhoneAction(
          'set_timer',
          <String, dynamic>{'durationSeconds': seconds},
          reply,
        )) return true;
      }
    }

    final alarmMatch = RegExp(
      r'^(?:set\s+)?(?:an?\s+)?alarm(?:\s+(?:for|at))?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$',
    ).firstMatch(command);
    if (alarmMatch != null) {
      var hour = int.tryParse(alarmMatch.group(1) ?? '') ?? -1;
      final minute = int.tryParse(alarmMatch.group(2) ?? '0') ?? -1;
      final meridiem = alarmMatch.group(3);
      if (meridiem == 'pm' && hour < 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
      if (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
        final reply = switch (_currentLang) {
          'hi' => 'अलार्म सेट करने के लिए क्लॉक ऐप खोल दिया।',
          'kn' => 'ಅಲಾರಂ ಹೊಂದಿಸಲು ಗಡಿಯಾರ ಆ್ಯಪ್ ತೆರೆಯಿತು.',
          'ja' => 'アラーム設定画面を開きました。',
          'ar' => 'فتحت شاشة ضبط المنبه.',
          _ => 'Opened the clock app to set that alarm.',
        };
        if (await _runLocalPhoneAction(
          'set_alarm',
          <String, dynamic>{'hour': hour, 'minute': minute},
          reply,
        )) return true;
      }
    }

    final navigationMatch = RegExp(
      r'^(?:navigate to|directions to|take me to|मार्ग दिखाओ|मुझे ले चलो|ದಾರಿ ತೋರಿಸು|道案内して|وجّهني إلى)\s+(.+)$',
    ).firstMatch(command);
    final destination = navigationMatch?.group(1)?.trim();
    if (destination != null && destination.isNotEmpty) {
      final reply = switch (_currentLang) {
        'hi' => 'मैप्स में रास्ता खोल दिया।',
        'kn' => 'ಮ್ಯಾಪ್ಸ್‌ನಲ್ಲಿ ಮಾರ್ಗ ತೆರೆಯಿತು.',
        'ja' => 'マップでルートを開きました。',
        'ar' => 'فتحت المسار في الخرائط.',
        _ => 'Opened the route in Maps.',
      };
      if (await _runLocalPhoneAction(
        'start_navigation',
        <String, dynamic>{'destination': destination},
        reply,
      )) return true;
    }

    final urlMatch = RegExp(
      r'^(?:open|visit)\s+((?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?)$',
    ).firstMatch(command);
    final requestedUrl = urlMatch?.group(1);
    if (requestedUrl != null) {
      final url = requestedUrl.startsWith('http')
          ? requestedUrl
          : 'https://$requestedUrl';
      final reply = switch (_currentLang) {
        'hi' => 'वेबसाइट खोल दी।',
        'kn' => 'ವೆಬ್‌ಸೈಟ್ ತೆರೆಯಿತು.',
        'ja' => 'ウェブサイトを開きました。',
        'ar' => 'تم فتح الموقع.',
        _ => 'Opened the website.',
      };
      if (await _runLocalPhoneAction(
        'open_url',
        <String, dynamic>{'url': url},
        reply,
      )) return true;
    }

    final musicMatch = RegExp(
      r'^(?:play music|search song|find song|गाना चलाओ|ಹಾಡು ಹುಡುಕು|曲を探して|ابحث عن أغنية)\s+(.+)$',
    ).firstMatch(command);
    final musicQuery = musicMatch?.group(1)?.trim();
    if (musicQuery != null && musicQuery.isNotEmpty) {
      final reply = switch (_currentLang) {
        'hi' => 'म्यूज़िक सर्च खोल दिया।',
        'kn' => 'ಮ್ಯೂಸಿಕ್ ಹುಡುಕಾಟ ತೆರೆಯಿತು.',
        'ja' => '音楽検索を開きました。',
        'ar' => 'فتحت البحث عن الموسيقى.',
        _ => 'Opened music search.',
      };
      if (await _runLocalPhoneAction(
        'music_search',
        <String, dynamic>{'query': musicQuery},
        reply,
      )) return true;
    }

    final brightnessMatch = RegExp(
      r'^(?:set )?brightness(?: to)?\s+(\d{1,3})\s*(?:%|percent)?$',
    ).firstMatch(command);
    if (brightnessMatch != null) {
      final level = int.tryParse(brightnessMatch.group(1) ?? '') ?? 0;
      if (level >= 1 && level <= 100) {
        final reply = switch (_currentLang) {
          'hi' => 'ब्राइटनेस सेट कर दी।',
          'kn' => 'ಬ್ರೈಟ್‌ನೆಸ್ ಹೊಂದಿಸಿದೆ.',
          'ja' => '明るさを設定しました。',
          'ar' => 'تم ضبط السطوع.',
          _ => 'Brightness updated.',
        };
        if (await _runLocalPhoneAction(
          'set_brightness',
          <String, dynamic>{'level': level},
          reply,
        )) return true;
      }
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
    _cachedScreenSize = screenSize;
    _pendingSkillActions.clear();
    _taskStartPackage = null;
    _taskStartSignature = null;
    _taskStartVersion = null;
    _taskSkillEligible = true;
    _taskSkillCommandTemplate = null;
    final loopGuard = LucyAgentLoopGuard();
    var currentPlan = <String>[];
    var completedPlanSteps = 0;
    _previousModelTreePackage = null;
    _previousModelTreeElements = <int, String>{};

    LucyReliabilityLog.event('agent_task_started');
    while (step < _maxStepsPerCommand && _isActive && !_cancelRequested) {
      if (await _screenCapture.isDeviceLocked()) {
        _statusMessage = 'Phone locked · Unlock to continue';
        notifyListeners();
        await _speakEvent(
          'device_locked',
          context: 'The phone is locked. Tell the user to unlock it before Lucy continues. Do not attempt to interact with the lock screen.',
        );
        _statusMessage = 'Phone locked · Unlock to continue';
        notifyListeners();
        break;
      }
      step++;

      // Fetch the cheap accessibility tree first. Rich text-first screens do
      // not need a MediaProjection frame; visual and sparse screens still do.
      _setState(AgentState.capturing);
      _updateTaskProgress('Preparing your screen · Step $step');

      final treeStopwatch = Stopwatch()..start();
      var uiSnapshot = await _fetchUiSnapshot();
      treeStopwatch.stop();
      LucyReliabilityLog.event(
        'agent_tree_fetch_timing',
        step: step,
        elapsedMs: treeStopwatch.elapsedMilliseconds,
        success: uiSnapshot != null,
      );
      var uiTree = uiSnapshot == null
          ? null
          : _buildUiTreePayload(uiSnapshot, step);

      if (step == 1 &&
          uiSnapshot != null &&
          await _settingsStore.isEnabled(LucySettingsStore.autopilot) &&
          await _tryReplayLearnedSkill(userMessage, uiSnapshot)) {
        LucyReliabilityLog.event('learned_skill_replayed', success: true);
        await _speakEvent(
          'skill_replayed',
          context: 'A previously successful low-risk navigation or reading skill was replayed and verified.',
        );
        return;
      }

      // Explicit reading requests collect the complete accessible scrollable
      // surface before planning. Inbox-wide requests use open_each instead.
      if (step == 1 &&
          uiSnapshot != null &&
          ReadingModePlanner.shouldPrecollect(
            userText: userMessage,
            classification: _screenClassifier.classify(uiSnapshot.rawTree),
            elements: uiSnapshot.elements,
          )) {
        final readingStopwatch = Stopwatch()..start();
        final collected = await _screenCapture.scrollScreen(
          forward: true,
          maxScrolls: 80,
          collect: true,
        );
        readingStopwatch.stop();
        if (collected != null) {
          currentMessage = userMessage + '\n' +
              '[TOOL_RESULT]\n' + jsonEncode(collected) + '\n[/TOOL_RESULT]\n' +
              ReadingModePlanner.directive(
                _screenClassifier.classify(uiSnapshot.rawTree).type,
              );
          final refreshed = await _fetchUiSnapshot();
          if (refreshed != null) {
            uiSnapshot = refreshed;
            // The original tree was not sent to the model, so force a full
            // refreshed tree rather than emitting a diff against unseen data.
            _previousModelTreePackage = null;
            _previousModelTreeElements = <int, String>{};
            uiTree = _buildUiTreePayload(refreshed, step);
          }
          LucyReliabilityLog.event(
            'reading_mode_collection',
            step: step,
            elapsedMs: readingStopwatch.elapsedMilliseconds,
            success: collected['reachedEnd'] == true,
          );
        }
      }

      if (_cancelRequested) break;

      Uint8List? screenshotBytes;
      if (_shouldCaptureScreenshot(uiSnapshot)) {
        final screenshotStopwatch = Stopwatch()..start();
        screenshotBytes = await _captureScreenWithRetry();
        screenshotStopwatch.stop();
        if (screenshotBytes != null) _lastScreenshotBytes = screenshotBytes;
        LucyReliabilityLog.event(
          'agent_screenshot_timing',
          step: step,
          elapsedMs: screenshotStopwatch.elapsedMilliseconds,
          success: screenshotBytes != null,
        );
      } else {
        LucyReliabilityLog.event(
          'agent_screenshot_skipped',
          step: step,
          elapsedMs: 0,
          success: true,
        );
      }

      if (_cancelRequested) break;

      if (_isPermissionPrompt(uiSnapshot)) {
        await _speakEvent(
          'permission_needed',
          context: 'Android is showing a permission dialog. Ask the user to review and choose it themselves; never grant it automatically.',
        );
        break;
      }

      // 2. Ask for a plan and one action. The model's plan is retained locally
      // and included in subsequent turns so a provider switch does not lose it.
      _setState(AgentState.analyzing);
      _updateTaskProgress('Lucy is thinking and planning · Step $step');

      final aiStopwatch = Stopwatch()..start();
      final deviceContext = await _contextBuilder.buildPromptContext();
      if (_cancelRequested) break;
      final localNow = DateTime.now();
      final planContext = currentPlan.isEmpty
          ? ''
          : '[CURRENT_PLAN]\n'
                '${currentPlan.asMap().entries.map((entry) => '${entry.key + 1}. ${entry.value}').join('\n')}\n'
                'Completed steps: $completedPlanSteps\n'
                '[/CURRENT_PLAN]\n';
      final appHints = await _appHintCatalog.loadForPackage(uiSnapshot?.packageName);
      final appHintContext = appHints.isEmpty ? '' :
          '[APP_WORKFLOW_HINT — guidance only, never permission]\n' +
          jsonEncode(appHints) + '\n[/APP_WORKFLOW_HINT]\n';
      final autopilotEnabled = await _settingsStore.isEnabled(
        LucySettingsStore.autopilot,
      );
      final autopilotContext = autopilotEnabled
          ? '[AUTOPILOT_POLICY: enabled] Execute clear, reversible, low-risk phone actions without asking whether to begin. Keep all local safety gates for external sends/calls, payments, purchases, permanent deletion, account/security changes, app installation and Android permissions.\n'
          : '[AUTOPILOT_POLICY: disabled] Do not execute phone-control actions. Explain the next action briefly and wait for the user to enable Autopilot. Memory management explicitly requested by the user may still run.\n';
      final requestWithClock =
          '[Device local date/time: ' + localNow.toIso8601String() + ']\n' +
          (deviceContext.isEmpty ? '' : deviceContext + '\n') +
          autopilotContext + appHintContext + planContext + currentMessage;
      final allowScreenSharing = await _settingsStore.isEnabled(
        LucySettingsStore.aiScreenSharing,
      );
      final allowMemory = await _settingsStore.isEnabled(
        LucySettingsStore.memory,
      );
      await _voiceService.beginStreamingSpeech(lang: _currentLang);
      var streamedSpeech = false;
      final agentResponse = await _aiService.agentChat(
        requestWithClock,
        imageBytes: allowScreenSharing ? screenshotBytes : null,
        screenSize: allowScreenSharing ? screenSize : null,
        uiTree: allowScreenSharing ? uiTree : null,
        memoryContext: allowMemory
            ? (_memoryStore?.relevantContext(userMessage) ?? '')
            : '',
        onSpeakChunk: (sentence) {
          streamedSpeech = true;
          _voiceService.addStreamingSpeechText(sentence);
        },
        onSpeakReset: () {
          streamedSpeech = false;
          unawaited(_voiceService.cancelStreamingSpeech());
        },
      );
      final streamedSpeechCompletion = _voiceService.finishStreamingSpeech();
      aiStopwatch.stop();
      _performanceMonitor.recordResponse(aiStopwatch.elapsed);
      LucyReliabilityLog.event(
        'agent_model_response',
        provider: agentResponse.provider,
        step: step,
        elapsedMs: aiStopwatch.elapsedMilliseconds,
        success: agentResponse.provider != 'none',
      );

      if (_cancelRequested) break;
      if (agentResponse.isError) {
        _updateTaskProgress('AI unavailable · Check your provider or connection');
        LucyReliabilityLog.event(
          'agent_provider_unavailable',
          provider: agentResponse.provider,
          step: step,
          success: false,
        );
        break;
      }

      // Route is semantic model output, not an English keyword gate.
      // It is surfaced in task progress and validated by the response parser.
      _updateTaskProgress(switch (agentResponse.route) {
        'read' => 'Reading and checking the requested content · Step $step',
        'phone' => 'Handling your phone task · Step $step',
        _ => 'Working on your request · Step $step',
      });

      if (agentResponse.plan.isNotEmpty) {
        currentPlan = agentResponse.plan;
        if (step == 1) {
          _addConversation(
            'Plan: ${currentPlan.join(' → ')}',
            false,
          );
        }
      }

      // Update the current language from the AI's tag (falls back to previous).
      if (_supportedLangs.contains(agentResponse.lang) &&
          agentResponse.lang != _currentLang) {
        _currentLang = agentResponse.lang;
        unawaited(
          SharedPreferences.getInstance().then(
            (prefs) => prefs.setString(_langPrefKey, _currentLang),
          ),
        );
      }

      String speakText = agentResponse.speak;
      bool actionVerified = true;
      String? toolResultForNextTurn;
      var autopilotBlocked = false;

      // 3. Execute and verify the returned action.
      if (agentResponse.actions.isNotEmpty) {
        final executionStopwatch = Stopwatch()..start();
        _setState(AgentState.executingAction);
        _updateTaskProgress('Carrying out your task · Step $step');

        var latestSnapshot = uiSnapshot;
        for (final action in agentResponse.actions) {
          if (_cancelRequested) break;
          final isMemoryManagementAction = const {
            'remember',
            'forget',
            'recall_memories',
            'forget_ui_layout',
            'forget_skill',
          }.contains(action.type);
          if (!autopilotEnabled && !isMemoryManagementAction) {
            autopilotBlocked = true;
            actionVerified = false;
            _lastActionDispatchSucceeded = false;
            _taskSkillEligible = false;
            speakText = '';
            _statusMessage = 'Autopilot is off · No phone action was executed';
            notifyListeners();
            LucyReliabilityLog.event(
              'autopilot_action_blocked',
              action: action.type,
              step: step,
              success: false,
            );
            break;
          }
          final beforeAction = latestSnapshot;
          _lastActionDispatchSucceeded = true;
          latestSnapshot = await _executeAction(action, beforeAction);
          if (const {
            'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each', 'batch',
          }.contains(action.type)) {
            toolResultForNextTurn = _lastToolResult;
          }
          final requiresVisualChange = const {
            'open_app', 'tap', 'type', 'swipe', 'back', 'home', 'batch',
          }.contains(action.type);
          final changed = _didPackageChange(beforeAction, latestSnapshot) ||
              _didTreeSignatureChange(beforeAction, latestSnapshot);
          actionVerified = _lastActionDispatchSucceeded &&
              (!requiresVisualChange ||
                  _isActionReady(action, beforeAction, latestSnapshot));
          if (actionVerified) {
            _recordSkillAction(action, beforeAction, userMessage);
          } else {
            _taskSkillEligible = false;
          }

          LucyReliabilityLog.event(
            'action_verified',
            action: action.type,
            step: step,
            success: actionVerified,
          );

          if (!actionVerified) {
                  speakText = 'I could not verify that step. I am checking another safe approach.';
            final shouldReplan = loopGuard.shouldReplan(
              actionType: action.type,
              packageName: beforeAction?.packageName,
              uiSignature: beforeAction?.signature ?? 'no-ui-snapshot',
            );
            if (shouldReplan) {
              if (loopGuard.canReplan) {
                loopGuard.markReplanned();
                LucyReliabilityLog.event(
                  'agent_replan',
                  action: action.type,
                  step: step,
                  attempt: loopGuard.replans,
                );
                currentMessage =
                    'The previous action did not succeed or did not change the screen. Do not repeat it. Choose a different safe method, or ask me to resolve the blocker. Previous plan: ${currentPlan.join('; ')}';
              } else {
                _addConversation(
                  'I tried a different approach, but the screen still did not respond. I stopped to avoid repeating actions. Please check the app or permission prompt.',
                  false,
                );
                _cancelRequested = true;
              }
            } else {
              currentMessage =
                  'The previous action was not verified. Do not repeat the same action. Inspect the new screen and choose a different safe approach.';
            }
          } else if (changed || !requiresVisualChange) {
            completedPlanSteps++;
          }
        }
        executionStopwatch.stop();
        LucyReliabilityLog.event(
          'agent_execution_timing',
          step: step,
          elapsedMs: executionStopwatch.elapsedMilliseconds,
          success: actionVerified,
        );
      }

      if (_cancelRequested || autopilotBlocked) break;

      if (!actionVerified && agentResponse.done && !autopilotBlocked) {
        speakText = 'I could not confirm that the requested step worked. I will not claim it is complete.';
      }

      String displayText = speakText;
      if (agentResponse.actions.isNotEmpty && !autopilotBlocked) {
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

      // 4. Speak the response (only speak if done or has something to say)
      if (speakText.isNotEmpty) {
        final ttsStopwatch = Stopwatch()..start();
        _setState(AgentState.speaking);
        _updateTaskProgress('Lucy is preparing your answer');

        final ttsText = _trimForTts(speakText);
        final speech = streamedSpeech
            ? streamedSpeechCompletion
            : _voiceService.speakProgressively(
                ttsText,
                lang: _currentLang,
              );
        if (agentResponse.done) {
          await speech;
          await Future.delayed(const Duration(milliseconds: 250));
          while (_voiceService.isSpeaking && !_cancelRequested) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          ttsStopwatch.stop();
          LucyReliabilityLog.event(
            'agent_tts_timing',
            step: step,
            elapsedMs: ttsStopwatch.elapsedMilliseconds,
            success: true,
          );
        } else {
          // Intermediate speech runs alongside the next planning/action turn;
          // only a final answer waits for TTS completion.
          unawaited(speech.then((_) {
            ttsStopwatch.stop();
            LucyReliabilityLog.event(
              'agent_tts_timing',
              step: step,
              elapsedMs: ttsStopwatch.elapsedMilliseconds,
              success: true,
            );
          }, onError: (_) {
            ttsStopwatch.stop();
            LucyReliabilityLog.event(
              'agent_tts_timing',
              step: step,
              elapsedMs: ttsStopwatch.elapsedMilliseconds,
              success: false,
            );
          }));
        }
      }

      if (_cancelRequested) break;

      // 5. Check if done
      final hasDeepReadToolAction = agentResponse.actions.any(
        (action) => const {
          'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each',
        }.contains(action.type),
      );
      if (agentResponse.done && actionVerified && !hasDeepReadToolAction) {
        await _saveCompletedSkill(userMessage);
        LucyReliabilityLog.event('agent_task_completed', step: step, success: true);
        break;
      }

      // Not done, or an action was not verified: inspect the fresh screen and
      // continue from the retained plan rather than assuming success.
      if (toolResultForNextTurn != null) {
        currentMessage =
            'The native operation has finished. Inspect its measured results and continue the task.\n[TOOL_RESULT]\n$toolResultForNextTurn\n[/TOOL_RESULT]';
      } else if (actionVerified) {
        currentMessage =
            'I have executed the action. Here is the updated screen. Verify it and continue with the current plan.';
      }
      // If screenshot capture might fail next iteration, the AI will still
      // receive the message but without an image. The retry logic in
      // _captureScreenWithRetry handles this by making multiple attempts.
    }

    // Handle cancellation
    if (_cancelRequested) {
      _cancelRequested = false;
      LucyReliabilityLog.event('agent_task_stopped', step: step, success: false);
      _statusMessage = 'Task stopped';
      notifyListeners();
      return;
    }

    if (step >= _maxStepsPerCommand) {
      LucyReliabilityLog.event('agent_step_limit_reached', step: step, success: false);
      _statusMessage = 'Task stopped at the $_maxStepsPerCommand-step safety limit';
      notifyListeners();
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

      final packageName = parsed['package'] as String? ?? '';
      final versionCode = parsed['appVersionCode']?.toString() ?? 'unknown';
      if (packageName.isNotEmpty) {
        final signature = LucyLearningStore.stableSignature(
          packageName: packageName,
          elements: elements,
        );
        if (_isActive && _taskStartPackage == null) {
          _taskStartPackage = packageName;
          _taskStartSignature = signature;
          _taskStartVersion = versionCode;
        }
        final recordKey = packageName + ':' + versionCode + ':' + signature;
        if (recordKey != _lastRecordedUiSignature &&
            await _settingsStore.isEnabled(LucySettingsStore.uiMemory)) {
          _lastRecordedUiSignature = recordKey;
          final size = _cachedScreenSize;
          unawaited(_learningStore.recordUiMap(
            packageName: packageName,
            signature: signature,
            elements: elements,
            appVersionCode: versionCode,
            screenSize: size == null
                ? null
                : <String, double>{
                    'width': (size['width'] ?? 1).toDouble(),
                    'height': (size['height'] ?? 1).toDouble(),
                  },
          ));
        }
      }
      return _UiSnapshot(
        rawTree: uiTree,
        packageName: packageName,
        appVersionCode: versionCode,
        elements: elements,
        hasFocusedEditable: hasFocusedEditable,
      );
    } catch (e) {
      return null;
    }
  }

  void _recordSkillAction(AgentAction action, _UiSnapshot? before, String command) {
    if (!_taskSkillEligible) return;
    const allowed = <String>{'open_app', 'tap', 'back', 'home', 'scroll_to_end', 'scroll_to_top', 'read_all'};
    final packageContext = (before?.packageName ?? '').toLowerCase();
    if (const {'bank', 'wallet', 'payment', 'upi', 'finance', 'authenticator', 'password'}
        .any(packageContext.contains)) {
      _taskSkillEligible = false;
      return;
    }
    final entry = <String, dynamic>{'type': action.type};
    if (!allowed.contains(action.type) && action.type != 'type') {
      _taskSkillEligible = false;
      return;
    }
    if (action.type == 'type') {
      if (before == null || _taskSkillCommandTemplate != null) {
        _taskSkillEligible = false;
        return;
      }
      final focused = before.elements.where((element) =>
          element['focused'] == true && element['editable'] == true).toList();
      if (focused.length != 1 || focused.single['password'] == true) {
        _taskSkillEligible = false;
        return;
      }
      final fieldLabel = ((focused.single['resourceId'] ?? '').toString() + ' ' +
          (focused.single['text'] ?? '').toString() + ' ' +
          (focused.single['desc'] ?? '').toString()).toLowerCase();
      if (!fieldLabel.contains('search')) {
        _taskSkillEligible = false;
        return;
      }
      final typed = action.params['text']?.toString() ?? '';
      final normalizedCommand = LucyLearningStore.normalizeCommand(command);
      final normalizedTyped = LucyLearningStore.normalizeCommand(typed);
      final queryIndex = normalizedTyped.isEmpty
          ? -1
          : normalizedCommand.indexOf(normalizedTyped);
      if (queryIndex < 0) {
        _taskSkillEligible = false;
        return;
      }
      _taskSkillCommandTemplate = normalizedCommand.replaceRange(
        queryIndex,
        queryIndex + normalizedTyped.length,
        '{query}',
      );
      entry['parameter'] = 'query';
      _pendingSkillActions.add(entry);
      return;
    }
    if (!allowed.contains(action.type)) { _taskSkillEligible = false; return; }
    if (action.type == 'open_app') {
      final package = action.params['package']?.toString() ?? '';
      if (package.isEmpty) { _taskSkillEligible = false; return; }
      entry['package'] = package;
    } else if (action.type == 'tap') {
      if (before == null) { _taskSkillEligible = false; return; }
      final id = (action.params['element'] as num?)?.toInt();
      final element = id == null ? null : _findElementById(id, before.elements);
      if (element == null) { _taskSkillEligible = false; return; }
      final resourceId = element['resourceId']?.toString() ?? '';
      final label = [element['text']?.toString() ?? '', element['desc']?.toString() ?? ''].where((v) => v.trim().isNotEmpty).join(' ').trim();
      final package = before.packageName ?? '';
      if (const {'bank', 'wallet', 'payment', 'upi', 'finance', 'authenticator', 'password'}.any(package.toLowerCase().contains) ||
          LucyActionApprovalPolicy.effectiveRisk('tap', targetLabel: label, packageName: package) != 'low') {
        _taskSkillEligible = false;
        return;
      }
      final resourceCount = resourceId.isEmpty ? 0 : before.elements.where((item) => item['resourceId'] == resourceId).length;
      final labelCount = label.isEmpty ? 0 : before.elements.where((item) => ((item['text'] ?? '').toString() + ' ' + (item['desc'] ?? '').toString()).trim() == label).length;
      if ((resourceId.isEmpty || resourceCount != 1) && (label.isEmpty || labelCount != 1)) { _taskSkillEligible = false; return; }
      entry['resourceId'] = resourceId;
      entry['label'] = label;
    }
    _pendingSkillActions.add(entry);
    if (_pendingSkillActions.length > 12) _taskSkillEligible = false;
  }

  Future<void> _saveCompletedSkill(String command) async {
    if (!_taskSkillEligible || !await _settingsStore.isEnabled(LucySettingsStore.learnSkills) || _taskStartPackage == null || _taskStartSignature == null || _pendingSkillActions.isEmpty) return;
    final normalized = LucyLearningStore.normalizeCommand(command);
    final identity = normalized + '|' + _taskStartPackage! + '|' + _taskStartSignature!;
    var hash = 0x811c9dc5;
    for (final unit in identity.codeUnits) { hash = ((hash ^ unit) * 0x01000193) & 0xffffffff; }
    await _learningStore.recordSkill(id: 'skill_' + hash.toRadixString(16), command: command, packageName: _taskStartPackage!, startSignature: _taskStartSignature!, appVersionCode: _taskStartVersion ?? 'unknown', actions: _pendingSkillActions);
  }

  Future<bool> _tryReplayLearnedSkill(String command, _UiSnapshot startingSnapshot) async {
    if (!await _settingsStore.isEnabled(LucySettingsStore.learnSkills)) return false;
    final packageName = startingSnapshot.packageName ?? '';
    if (const {'bank', 'wallet', 'payment', 'upi', 'finance', 'authenticator', 'password'}.any(packageName.toLowerCase().contains)) {
      return false;
    }
    final signature = LucyLearningStore.stableSignature(packageName: packageName, elements: startingSnapshot.elements);
    final skill = await _learningStore.findSkill(command: command, packageName: packageName, startSignature: signature, appVersionCode: startingSnapshot.appVersionCode);
    if (skill == null) return false;
    final skillId = skill['id']?.toString() ?? '';
    final rawActions = skill['actions'];
    if (skillId.isEmpty || rawActions is! List || rawActions.isEmpty) return false;
    var current = startingSnapshot;
    for (final raw in rawActions) {
      if (_cancelRequested || raw is! Map) { await _learningStore.markSkillResult(skillId, success: false); return false; }
      final saved = Map<String, dynamic>.from(raw);
      final type = saved['type']?.toString() ?? '';
      final params = <String, dynamic>{'confidence': 0.99, 'risk': 'low', 'reason': 'Replay a previously verified low-risk navigation or reading skill.'};
      if (type == 'open_app') {
        params['package'] = saved['package'];
      } else if (type == 'type') {
        final focused = current.elements.where((element) =>
            element['focused'] == true && element['editable'] == true &&
            element['password'] != true).toList();
        final fieldLabel = focused.length == 1
            ? ((focused.single['resourceId'] ?? '').toString() + ' ' +
                (focused.single['text'] ?? '').toString() + ' ' +
                (focused.single['desc'] ?? '').toString()).toLowerCase()
            : '';
        final query = (skill['parameters'] as Map?)?['query']?.toString() ?? '';
        if (focused.length != 1 || !fieldLabel.contains('search') || query.isEmpty) {
          await _learningStore.markSkillResult(skillId, success: false);
          return false;
        }
        params['text'] = query;
      } else if (type == 'tap') {
        final resourceId = saved['resourceId']?.toString() ?? '';
        final label = saved['label']?.toString() ?? '';
        var matches = current.elements.where((element) => resourceId.isNotEmpty && element['resourceId'] == resourceId).toList();
        if (matches.length != 1 && label.isNotEmpty) {
          matches = current.elements.where((element) => ((element['text'] ?? '').toString() + ' ' + (element['desc'] ?? '').toString()).trim() == label).toList();
        }
        if (matches.length != 1) { await _learningStore.markSkillResult(skillId, success: false); return false; }
        params['element'] = matches.single['id'];
      }
      final action = AgentAction(type: type, params: params);
      current = await _executeAction(action, current) ?? current;
      if (!_lastActionDispatchSucceeded) { await _learningStore.markSkillResult(skillId, success: false); return false; }
      if (const {'scroll_to_end', 'scroll_to_top', 'read_all'}.contains(type)) {
        final rawResult = _lastToolResult;
        if (rawResult == null) { await _learningStore.markSkillResult(skillId, success: false); return false; }
        final result = jsonDecode(rawResult);
        if (result is! Map || result['reachedEnd'] != true) { await _learningStore.markSkillResult(skillId, success: false); return false; }
      }
    }
    await _learningStore.markSkillResult(skillId, success: true);
    return true;
  }

  Future<bool> _handleLearningCommand(String text) async {
    final lower = text.trim().toLowerCase();
    if (lower == 'forget this app layout' || lower == 'forget app layout') {
      final packageName = (await _fetchUiSnapshot())?.packageName ?? '';
      if (packageName.isEmpty) return true;
      final removed = await _learningStore.forgetAppLayout(packageName);
      await _speakEvent('ui_layout_forgotten', context: 'Removed ' + removed.toString() + ' learned screen layouts for the current app.');
      return true;
    }
    final match = RegExp(r'^forget skill\s+(.+)$', caseSensitive: false).firstMatch(text.trim());
    if (match != null) {
      final removed = await _learningStore.forgetSkill(match.group(1)!);
      await _speakEvent('skill_forgotten', context: removed ? 'The named learned skill was deleted.' : 'No matching learned skill was found.');
      return true;
    }
    return false;
  }

  String _buildUiTreePayload(_UiSnapshot snapshot, int step) {
    final current = <int, String>{};
    for (final element in snapshot.elements) {
      final id = (element['id'] as num?)?.toInt();
      if (id != null) current[id] = jsonEncode(element);
    }

    final package = snapshot.packageName ?? '';
    final classification = _screenClassifier.classify(snapshot.rawTree).toJson();
    final forceFull = _previousModelTreePackage != package ||
        _previousModelTreeElements.isEmpty ||
        step == 1 ||
        step % 5 == 0;

    if (forceFull) {
      _previousModelTreePackage = package;
      _previousModelTreeElements = current;
      return jsonEncode(<String, dynamic>{
        'package': package,
        'mode': 'full',
        'screen': classification,
        'elements': snapshot.elements,
      });
    }

    final changed = <Map<String, dynamic>>[];
    final removed = <int>[];
    for (final element in snapshot.elements) {
      final id = (element['id'] as num?)?.toInt();
      if (id == null) continue;
      if (_previousModelTreeElements[id] != current[id]) {
        changed.add(element);
      }
    }
    for (final oldId in _previousModelTreeElements.keys) {
      if (!current.containsKey(oldId)) removed.add(oldId);
    }

    final unchangedCount = current.length - changed.length;
    _previousModelTreePackage = package;
    _previousModelTreeElements = current;
    return jsonEncode(<String, dynamic>{
      'package': package,
      'mode': 'diff',
      'screen': classification,
      'baseStep': step - 1,
      'elements': changed,
      'removed': removed,
      'unchangedCount': unchangedCount < 0 ? 0 : unchangedCount,
    });
  }

  bool _shouldCaptureScreenshot(_UiSnapshot? snapshot) {
    if (snapshot == null || snapshot.elements.length < 8) return true;

    final types = snapshot.elements
        .map((element) => (element['type'] ?? '').toString().toLowerCase())
        .toList(growable: false);
    final packageName = (snapshot.packageName ?? '').toLowerCase();
    final visualSurface = types.any((type) =>
        type.contains('webview') ||
        type.contains('surfaceview') ||
        type.contains('textureview') ||
        type.contains('videoview') ||
        type.contains('canvas') ||
        type.contains('glsurface'));
    if (visualSurface) return true;

    if (packageName.contains('youtube') ||
        packageName.contains('instagram') ||
        packageName.contains('tiktok')) {
      return true;
    }

    final readable = snapshot.elements
        .map((element) => ((element['text'] ?? '').toString() +
            ' ' +
            (element['desc'] ?? '').toString()).trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final totalChars = readable.fold<int>(0, (sum, value) => sum + value.length);
    final imageCount = types.where((type) => type.contains('imageview')).length;
    if (imageCount >= 3 && (readable.length < 12 || totalChars < 260)) {
      return true;
    }
    return readable.length < 8 || totalChars < 160;
  }

  bool _isPermissionPrompt(_UiSnapshot? snapshot) {
    if (snapshot == null) return false;
    final visibleText = snapshot.elements
        .map((element) => '${element['text'] ?? ''} ${element['desc'] ?? ''}')
        .join(' ');
    return LucyActionApprovalPolicy.isPermissionPromptText(visibleText);
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

    // Wake on Android accessibility events first, then verify with a fresh
    // tree. Keep the short polling fallback for apps that emit no useful event.
    final eventWait = timeout.inMilliseconds.clamp(0, 500).toInt();
    if (eventWait > 0) {
      await _screenCapture.waitForUiEvent(
        afterSequence: _lastActionEventSequence,
        timeoutMs: eventWait,
      );
      final eventSnapshot = await _fetchUiSnapshot();
      if (eventSnapshot != null) latestSnapshot = eventSnapshot;
      if (_isActionReady(action, beforeSnapshot, eventSnapshot)) {
        return eventSnapshot;
      }
    }

    while (!_cancelRequested) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final currentSnapshot = await _fetchUiSnapshot();
      if (currentSnapshot != null) latestSnapshot = currentSnapshot;
      if (_isActionReady(action, beforeSnapshot, currentSnapshot)) {
        return currentSnapshot;
      }
      final nextRemaining = deadline.difference(DateTime.now());
      if (nextRemaining <= Duration.zero) break;
      await Future.delayed(
        nextRemaining < _uiPollInterval ? nextRemaining : _uiPollInterval,
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
    _lastActionDispatchSucceeded = true;
    _lastToolResult = null;
    const accessibilityActions = {
      'open_app', 'tap', 'type', 'swipe', 'back', 'home',
      'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each', 'batch',
    };
    const directPhoneActions = {
      'set_alarm', 'set_timer', 'place_call', 'send_sms', 'open_url',
      'start_navigation', 'music_search', 'set_flashlight', 'set_volume',
      'set_brightness', 'get_device_status', 'read_contact',
      'create_calendar_event', 'open_settings', 'take_photo', 'share_text',
    };
    if (!await _settingsStore.isEnabled(LucySettingsStore.autopilot) &&
        !LucyActionApprovalPolicy.allowedWhenAutopilotDisabled(action.type)) {
      _lastActionDispatchSucceeded = false;
      _lastToolResult = jsonEncode(<String, dynamic>{
        'success': false,
        'error': 'autopilot_disabled',
        'action': action.type,
      });
      _cancelRequested = true;
      _statusMessage = 'Autopilot is off · no phone action was performed';
      _addConversation(_statusMessage, false);
      notifyListeners();
      return beforeSnapshot;
    }
    if (accessibilityActions.contains(action.type) &&
        !await _settingsStore.isEnabled(LucySettingsStore.screenAutomation)) {
      _lastActionDispatchSucceeded = false;
      _addConversation('Screen automation is disabled in Privacy & settings. No screen action was performed.', false);
      return beforeSnapshot;
    }
    if (directPhoneActions.contains(action.type) &&
        !await _settingsStore.isEnabled(LucySettingsStore.directPhoneActions)) {
      _lastActionDispatchSucceeded = false;
      _addConversation('Direct phone actions are disabled in Privacy & settings.', false);
      return beforeSnapshot;
    }
    if (const {
      'tap', 'type', 'swipe', 'back', 'home',
      'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each', 'batch',
    }.contains(action.type) &&
        !await _settingsStore.isEnabled(LucySettingsStore.aiScreenSharing)) {
      _lastActionDispatchSucceeded = false;
      _addConversation('Screen actions need AI screen sharing enabled so Lucy can inspect and verify the target. No action was performed.', false);
      return beforeSnapshot;
    }
    if (action.type == 'schedule_reminder' &&
        !await _settingsStore.isEnabled(LucySettingsStore.scheduledReminders)) {
      _lastActionDispatchSucceeded = false;
      _addConversation('Scheduled reminders are disabled in Privacy & settings.', false);
      return beforeSnapshot;
    }
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
    // Pause only for locally identified consequential actions. Model risk
    // metadata cannot add approval prompts to routine tasks.
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
    if (const {'tap', 'type', 'swipe', 'back', 'home', 'batch'}.contains(action.type)) {
      final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
      if (!hasAccessibility) {
        _addConversation(
          '⚠️ Cannot execute "${action.type}" — accessibility service not enabled. '
          'Please enable it in Settings → Accessibility → Lucy.',
          false,
        );
        _lastActionDispatchSucceeded = false;
        return beforeSnapshot;
      }
    }

    _lastActionEventSequence = await _screenCapture.getUiEventSequence();

    try {
      switch (action.type) {
        case 'open_app':
          final package = action.params['package'] as String? ?? '';
          if (package.isNotEmpty) {
            final success = await _screenCapture.openApp(package);
            _lastActionDispatchSucceeded = success;
            LucyReliabilityLog.event(
              'action_dispatch',
              action: action.type,
              success: success,
            );
          } else {
            _lastActionDispatchSucceeded = false;
          }
          break;

        case 'tap':
          // Never guess tap coordinates. A missing/stale UI element must fail
          // closed rather than tapping an arbitrary location on the user's phone.
          final elementId = (action.params['element'] as num?)?.toInt();
          if (elementId == null || beforeSnapshot == null) {
            _lastActionDispatchSucceeded = false;
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
            _lastActionDispatchSucceeded = false;
            _addConversation(
              'That screen element is no longer available. I did not tap anything.',
              false,
            );
            return beforeSnapshot;
          }
          _lastActionDispatchSucceeded = await _screenCapture.performTap(
            coords['x']!,
            coords['y']!,
          );
          break;

        case 'type':
          final text = action.params['text'] as String? ?? '';
          if (text.isNotEmpty) {
            _lastActionDispatchSucceeded = await _screenCapture.performType(text);
          } else {
            _lastActionDispatchSucceeded = false;
          }
          break;

        case 'swipe':
          final startX = (action.params['startX'] as num?)?.toDouble() ?? 0;
          final startY = (action.params['startY'] as num?)?.toDouble() ?? 0;
          final endX = (action.params['endX'] as num?)?.toDouble() ?? 0;
          final endY = (action.params['endY'] as num?)?.toDouble() ?? 0;
          _lastActionDispatchSucceeded = await _screenCapture.performSwipe(
            startX,
            startY,
            endX,
            endY,
          );
          break;

        case 'back':
          _lastActionDispatchSucceeded = await _screenCapture.pressBack();
          break;

        case 'home':
          _lastActionDispatchSucceeded = await _screenCapture.pressHome();
          break;

        case 'scroll_to_end':
        case 'scroll_to_top':
        case 'read_all':
          final isReadAll = action.type == 'read_all';
          final isForward = action.type != 'scroll_to_top';
          final rawMaxScrolls = action.params['maxScrolls'];
          final maxScrolls = rawMaxScrolls is num
              ? rawMaxScrolls.toInt().clamp(1, 120).toInt()
              : 80;
          final result = await _screenCapture.scrollScreen(
            forward: isForward,
            maxScrolls: maxScrolls,
            collect: isReadAll,
          );
          if (result == null) {
            _lastActionDispatchSucceeded = false;
            _lastToolResult = jsonEncode(<String, dynamic>{
              'error': 'native_scroll_unavailable',
              'reachedEnd': false,
              'items': <String>[],
            });
          } else {
            _lastToolResult = jsonEncode(result);
            _lastActionDispatchSucceeded =
                result['locked'] != true &&
                result['dispatchFailed'] != true &&
                result['cancelled'] != true;
          }
          break;

        case 'open_each':
          final result = await _executeOpenEach(action, beforeSnapshot);
          _lastToolResult = jsonEncode(result);
          _lastActionDispatchSucceeded =
              result['error'] == null && result['cancelled'] != true;
          break;

        case 'batch':
          final result = await _executeBatchAction(action, beforeSnapshot);
          _lastToolResult = jsonEncode(result);
          _lastActionDispatchSucceeded = result['success'] == true;
          break;

        case 'schedule_reminder':
          final title = action.params['title']?.toString().trim() ?? '';
          final body = action.params['body']?.toString().trim() ?? title;
          final delayMinutes =
              (action.params['delayMinutes'] as num?)?.toInt() ?? 0;
          final repeatMinutes =
              (action.params['repeatIntervalMinutes'] as num?)?.toInt() ?? 0;
          if (title.isEmpty || delayMinutes < 1) {
            _lastActionDispatchSucceeded = false;
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
          _lastActionDispatchSucceeded = true;
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

        case 'run_skill':
          final name = action.params['name']?.toString() ??
              action.params['skill']?.toString() ?? '';
          _lastActionDispatchSucceeded = name.isNotEmpty &&
              beforeSnapshot != null &&
              await _tryReplayLearnedSkill(name, beforeSnapshot);
          break;

        case 'remember':
          final memoryText = (action.params['text'] ??
                  action.params['content'] ??
                  action.params['memory'])
              ?.toString()
              .trim() ?? '';
          final memoryType =
              action.params['memory_type']?.toString() ??
              action.params['category']?.toString() ??
              'fact';
          if (memoryText.isEmpty) {
            _lastActionDispatchSucceeded = false;
          } else {
            await rememberUserMemory(memoryText, category: memoryType);
            _lastActionDispatchSucceeded = true;
            await _speakEvent(
              'memory_saved',
              context: 'A user-requested memory was saved locally.',
            );
          }
          break;

        case 'forget':
          final query = action.params['query']?.toString().trim() ?? '';
          if (query.isEmpty) {
            _lastActionDispatchSucceeded = false;
          } else if (const {'all', 'everything', 'all memories'}
              .contains(query.toLowerCase())) {
            await clearUserMemories();
            _lastActionDispatchSucceeded = true;
            await _speakEvent(
              'memory_cleared',
              context: 'The user explicitly requested that all saved memories be cleared.',
            );
          } else {
            final removed = await forgetUserMemory(query);
            _lastActionDispatchSucceeded = removed > 0;
            await _speakEvent(
              'memory_forgotten',
              context: removed > 0
                  ? 'The requested matching memory was removed.'
                  : 'No saved memory matched the requested detail.',
            );
          }
          break;

        case 'recall_memories':
          _lastActionDispatchSucceeded = true;
          await _replyToMemoryCommand(
            memorySummary.isEmpty
                ? 'No saved memories were found.'
                : 'Summarize these user-approved saved memories in the user’s language: $memorySummary',
            event: 'memory_recalled',
          );
          break;

        case 'wait':
          final delay = ((action.params['ms'] as num?)?.toInt() ?? 1000)
              .clamp(0, 10000);
          await Future<void>.delayed(Duration(milliseconds: delay));
          _lastActionDispatchSucceeded = true;
          break;

        default:
          _lastActionDispatchSucceeded = false;
          LucyReliabilityLog.event(
            'unsupported_action',
            action: action.type,
            success: false,
          );
      }
    } catch (error) {
      _lastActionDispatchSucceeded = false;
      LucyReliabilityLog.event(
        'action_exception',
        action: action.type,
        success: false,
        errorType: error.runtimeType.toString(),
      );
    }

    if (const {
      'scroll_to_end', 'scroll_to_top', 'read_all', 'open_each', 'batch',
    }.contains(action.type)) {
      return _fetchUiSnapshot();
    }
    return _waitForActionReadiness(action, beforeSnapshot);
  }

  Future<Map<String, dynamic>> _executeBatchAction(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) async {
    final rawActions = action.params['actions'];
    if (rawActions is! List || rawActions.isEmpty || rawActions.length > 5) {
      return <String, dynamic>{
        'success': false,
        'error': 'invalid_batch_size',
        'completed': 0,
      };
    }

    const allowed = {'tap', 'type', 'swipe', 'back', 'wait'};
    final initialFocused = beforeSnapshot?.elements
        .cast<Map<String, dynamic>?>()
        .firstWhere(
          (element) => element != null &&
              element['focused'] == true &&
              element['editable'] == true,
          orElse: () => null,
        );
    var inputFocused = initialFocused != null;
    var focusedInputPassword = initialFocused?['password'] == true;
    final nativeActions = <Map<String, dynamic>>[];
    for (final raw in rawActions) {
      if (raw is! Map) {
        return <String, dynamic>{
          'success': false,
          'error': 'invalid_batch_action',
          'completed': nativeActions.length,
        };
      }
      final item = Map<String, dynamic>.from(raw);
      final type = item['type']?.toString() ?? '';
      if (!allowed.contains(type)) {
        return <String, dynamic>{
          'success': false,
          'error': 'unsupported_batch_action',
          'completed': nativeActions.length,
        };
      }

      String? targetLabel;
      var sensitiveInput = false;
      if (type == 'tap') {
        final elementId = (item['element'] as num?)?.toInt();
        final element = elementId == null || beforeSnapshot == null
            ? null
            : _findElementById(elementId, beforeSnapshot.elements);
        if (element == null) {
          return <String, dynamic>{
            'success': false,
            'error': 'batch_target_not_found',
            'completed': nativeActions.length,
          };
        }
        targetLabel = [
          element['text']?.toString() ?? '',
          element['desc']?.toString() ?? '',
        ].where((value) => value.isNotEmpty).join(' ').trim();
        final isEditableTarget = element['editable'] == true ||
            (element['type']?.toString().contains('EditText') ?? false);
        inputFocused = isEditableTarget;
        focusedInputPassword =
            isEditableTarget && element['password'] == true;
      } else if (type == 'type') {
        if (!inputFocused) {
          return <String, dynamic>{
            'success': false,
            'error': 'batch_input_not_focused',
            'completed': nativeActions.length,
          };
        }
        sensitiveInput = focusedInputPassword;
      }

      final risk = LucyActionApprovalPolicy.effectiveRisk(
        type,
        targetLabel: targetLabel,
        packageName: beforeSnapshot?.packageName,
        sensitiveInput: sensitiveInput,
      );
      if (risk != 'low') {
        final approved = await _requestVoiceApproval(
          AgentAction(type: type, params: item),
          targetLabel,
          requiredRisk: risk,
          sensitiveInput: sensitiveInput,
        );
        if (!approved) {
          return <String, dynamic>{
            'success': false,
            'error': 'approval_denied',
            'completed': nativeActions.length,
          };
        }
      }
      nativeActions.add(item);
    }

    final result = await _screenCapture.performBatch(nativeActions);
    if (result == null) {
      return <String, dynamic>{
        'success': false,
        'error': 'native_batch_unavailable',
        'completed': 0,
      };
    }
    return result;
  }

  Future<Map<String, dynamic>> _executeOpenEach(
    AgentAction action,
    _UiSnapshot? startingSnapshot,
  ) async {
    final requestedLimit = action.params['maxItems'];
    // Support long inboxes/chat lists while keeping a strict per-command cap.
    final maxItems = (requestedLimit is num ? requestedLimit.toInt() : 10)
        .clamp(1, 250)
        .toInt();
    final requestedScrolls = action.params['detailMaxScrolls'];
    final detailMaxScrolls =
        (requestedScrolls is num ? requestedScrolls.toInt() : 20)
            .clamp(1, 80)
            .toInt();
    final requestedPageScrolls = action.params['maxListScrolls'];
    final maxListScrolls =
        (requestedPageScrolls is num ? requestedPageScrolls.toInt() : 120)
            .clamp(1, 120)
            .toInt();
    final screenSize = await _screenCapture.getScreenSize();
    final width = (screenSize?['width'] ?? 1080).toDouble();
    final height = (screenSize?['height'] ?? 1920).toDouble();
    final visited = <String>{};
    final results = <Map<String, dynamic>>[];
    var totalCollectedChars = 0;
    var current = startingSnapshot ?? await _fetchUiSnapshot();
    final currentPackage = current?.packageName?.toLowerCase() ?? '';
    if (const {'bank', 'wallet', 'payment', 'upi', 'finance'}
        .any(currentPackage.contains)) {
      return <String, dynamic>{
        'error': 'financial_app_not_supported',
        'reachedEnd': false,
        'limited': false,
        'processed': 0,
        'items': <Map<String, dynamic>>[],
      };
    }
    var unchangedPages = 0;
    var pageScrolls = 0;
    var reachedEnd = false;
    var nativeOperationCancelled = false;

    List<Map<String, dynamic>> listRows(_UiSnapshot? snapshot) {
      if (snapshot == null) return <Map<String, dynamic>>[];
      final candidates = <Map<String, dynamic>>[];
      for (final element in snapshot.elements) {
        if (element['clickable'] != true) continue;
        final text = element['text']?.toString().trim() ?? '';
        final desc = element['desc']?.toString().trim() ?? '';
        final label = [text, if (desc.isNotEmpty && desc != text) desc]
            .where((value) => value.isNotEmpty)
            .join(' · ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (label.length < 2) continue;
        final bounds = element['bounds'];
        if (bounds is! Map) continue;
        final y = (bounds['cy'] as num?)?.toDouble();
        final x = (bounds['cx'] as num?)?.toDouble();
        if (y == null || x == null || y < height * 0.12 || y > height * 0.94) {
          continue;
        }
        final normalized = label.toLowerCase();
        if (const {
          'search', 'settings', 'more options', 'back', 'chats',
          'updates', 'calls', 'communities', 'inbox', 'compose',
          'new chat', 'new message', 'new email', 'start new chat',
          'primary', 'social', 'promotions', 'starred', 'all mail',
          'navigation', 'menu', 'refresh', 'archive', 'delete',
          'remove', 'mark as read', 'mark as unread', 'report spam',
          'block', 'unsubscribe', 'select all',
          'send', 'send message', 'send now', 'post', 'publish',
          'share', 'pay', 'payment', 'transfer', 'buy', 'purchase',
          'checkout', 'confirm', 'allow', 'grant', 'install',
          'uninstall', 'call', 'dial',
        }.contains(normalized) ||
            RegExp(r'^(delete|archive|remove|block|report|unsubscribe|send|post|publish|share|pay|transfer|buy|purchase|checkout|confirm|allow|grant|install|uninstall|call|dial)\b')
                .hasMatch(normalized)) {
          continue;
        }
        candidates.add(<String, dynamic>{
          'id': element['id'],
          'x': x,
          'y': y,
          'label': label,
          'normalized': normalized,
        });
      }
      candidates.sort(
        (a, b) => (a['y'] as double).compareTo(b['y'] as double),
      );

      // Group sender/subject/preview text that belongs to the same visible row.
      final rows = <Map<String, dynamic>>[];
      for (final candidate in candidates) {
        Map<String, dynamic>? existing;
        for (final row in rows) {
          if (((row['y'] as double) - (candidate['y'] as double)).abs() < 60) {
            existing = row;
            break;
          }
        }
        if (existing == null) {
          rows.add(<String, dynamic>{
            'id': candidate['id'],
            'x': candidate['x'],
            'y': candidate['y'],
            'labels': <String>[candidate['label']],
          });
        } else {
          final labels = existing['labels'] as List<String>;
          if (!labels.contains(candidate['label']) && labels.length < 5) {
            labels.add(candidate['label'] as String);
          }
          if ((candidate['label'] as String).length >
              (labels.first.length)) {
            existing['id'] = candidate['id'];
            existing['x'] = candidate['x'];
          }
        }
      }
      for (final row in rows) {
        final joined = (row['labels'] as List<String>).join(' | ');
        row['label'] = joined.length > 260 ? joined.substring(0, 260) : joined;
      }
      return rows;
    }

    while (results.length < maxItems && pageScrolls < maxListScrolls) {
      if (_cancelRequested || !_isActive) break;
      final rows = listRows(current);
      Map<String, dynamic>? nextRow;
      for (final row in rows) {
        final key = (row['label'] as String)
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (visited.add(key)) {
          nextRow = row;
          break;
        }
      }

      if (nextRow != null) {
        final id = (nextRow['id'] as num?)?.toInt();
        final coords = id == null || current == null
            ? null
            : _resolveElementCoordinates(id, current.elements);
        if (coords == null ||
            !await _screenCapture.performTap(coords['x']!, coords['y']!)) {
          continue;
        }

        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (_cancelRequested || !_isActive) {
          nativeOperationCancelled = true;
          break;
        }
        final openedSnapshot = await _fetchUiSnapshot();
        if (openedSnapshot == null ||
            (openedSnapshot.packageName == current?.packageName &&
                openedSnapshot.signature == current?.signature)) {
          results.add(<String, dynamic>{
            'label': nextRow['label'],
            'rowLabels': nextRow['labels'],
            'sender': null,
            'title': null,
            'keyPoints': <String>[],
            'unread': null,
            'time': null,
            'urgency': 'unknown',
            'opened': false,
            'content': <String>[],
          });
          current = openedSnapshot ?? current;
          continue;
        }
        final detailScroll = await _screenCapture.scrollScreen(
          forward: true,
          maxScrolls: detailMaxScrolls,
          collect: true,
        );
        if (_cancelRequested || !_isActive || detailScroll?['cancelled'] == true) {
          nativeOperationCancelled = true;
          break;
        }
        final detailSnapshot = await _fetchUiSnapshot();
        final content = <String>{};
        final rawItems = detailScroll?['items'];
        if (rawItems is List) {
          for (final value in rawItems) {
            final text = value.toString().trim();
            if (text.isNotEmpty && content.length < 20 &&
                totalCollectedChars < 50000) {
              final clipped = text.length > 200 ? text.substring(0, 200) : text;
              if (content.add(clipped)) totalCollectedChars += clipped.length;
            }
            if (content.length >= 20 || totalCollectedChars >= 50000) break;
          }
        }
        for (final element in detailSnapshot?.elements ??
            const <Map<String, dynamic>>[]) {
          for (final key in const ['text', 'desc']) {
            final text = element[key]?.toString().trim() ?? '';
            if (text.isNotEmpty && content.length < 20 &&
                totalCollectedChars < 50000) {
              final clipped = text.length > 200 ? text.substring(0, 200) : text;
              if (content.add(clipped)) totalCollectedChars += clipped.length;
            }
          }
        }

        final rowLabels = (nextRow['labels'] as List?)
                ?.map((value) => value.toString())
                .where((value) => value.trim().isNotEmpty)
                .toList(growable: false) ??
            <String>[];
        final detailText = content.join(' ');
        final evidenceText = '${nextRow['label']} $detailText';
        final unreadEvidence = RegExp(
          r'\b(unread|new message|new messages|未読|غير مقروء|अपठित|ಓದದ)\b',
          caseSensitive: false,
        ).hasMatch(evidenceText);
        final timeMatch = RegExp(
          r'\b(today|yesterday|tomorrow|[01]?\d|2[0-3]):[0-5]\d\b|\b(today|yesterday|tomorrow)\b',
          caseSensitive: false,
        ).firstMatch(evidenceText);
        final urgency = RegExp(
          r'\b(urgent|action required|deadline|asap|immediately|overdue)\b',
          caseSensitive: false,
        ).hasMatch(evidenceText)
            ? 'high'
            : RegExp(r'\b(important|reminder|due soon)\b', caseSensitive: false)
                    .hasMatch(evidenceText)
                ? 'medium'
                : 'unknown';
        results.add(<String, dynamic>{
          'label': nextRow['label'],
          'rowLabels': rowLabels,
          'sender': rowLabels.isNotEmpty ? rowLabels.first : null,
          'title': rowLabels.length > 1 ? rowLabels.skip(1).join(' · ') : null,
          'keyPoints': content.take(5).toList(growable: false),
          'unread': unreadEvidence ? true : null,
          'time': timeMatch?.group(0),
          'urgency': urgency,
          'opened': true,
          'content': content.toList(growable: false),
          'detailReachedEnd': detailScroll?['reachedEnd'] == true,
          'detailScrolls': detailScroll?['scrolls'] ?? 0,
        });

        if (!await _screenCapture.pressBack()) {
          return <String, dynamic>{
            'error': 'could_not_return_to_list',
            'reachedEnd': false,
            'limited': false,
            'processed': results.length,
            'items': results,
          };
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        current = await _fetchUiSnapshot();
        unchangedPages = 0;
        continue;
      }

      if (current == null || pageScrolls >= maxListScrolls) break;
      final beforeSignature = current.signature;
      final moved = await _screenCapture.performSwipe(
        width * 0.5,
        height * 0.76,
        width * 0.5,
        height * 0.30,
      );
      if (!moved) break;
      pageScrolls++;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      current = await _fetchUiSnapshot();
      if (current == null || current.signature == beforeSignature) {
        unchangedPages++;
      } else {
        unchangedPages = 0;
      }
      if (unchangedPages >= 2) {
        reachedEnd = true;
        break;
      }
    }

    return <String, dynamic>{
      'processed': results.length,
      'requestedMaxItems': maxItems,
      'maxListScrolls': maxListScrolls,
      'cancelled': nativeOperationCancelled || _cancelRequested || !_isActive,
      'reachedEnd': reachedEnd,
      'limited': !reachedEnd &&
          (results.length >= maxItems || pageScrolls >= maxListScrolls),
      'pageScrolls': pageScrolls,
      'items': results,
    };
  }

  Future<void> _executeNativePhoneAction(AgentAction action) async {
    _lastActionDispatchSucceeded = false;
    dynamic nativeResult;
    try {
      nativeResult = await _phoneActions.execute(action.type, action.params);
    } catch (error) {
      LucyReliabilityLog.event(
        'native_action_failure',
        action: action.type,
        success: false,
        errorType: error.runtimeType.toString(),
      );
      nativeResult = false;
    }

    final resultMap = nativeResult is Map
        ? Map<String, dynamic>.from(nativeResult)
        : <String, dynamic>{};
    final needsBrightnessAccess = resultMap['requiresSettingsAccess'] == true;
    if (resultMap['requiresUnlock'] == true) {
      _lastActionDispatchSucceeded = false;
      const message =
          'Your phone is locked. Unlock it first, then say the call command again. I will not bypass your phone lock.';
      _addConversation(message, false);
      await _voiceService.speak(message, lang: _currentLang);
      _cancelRequested = true;
      return;
    }
    final succeeded =
        nativeResult == true ||
        resultMap['success'] == true ||
        resultMap.containsKey('batteryPercent') ||
        resultMap.containsKey('phoneNumber') ||
        (action.type == 'set_volume' && resultMap.containsKey('level')) ||
        (action.type == 'set_brightness' && needsBrightnessAccess);

    if (needsBrightnessAccess) {
      _lastActionDispatchSucceeded = false;
      const message =
          'Android opened special access settings. Review the permission yourself, then repeat your brightness command. Lucy will not change this access automatically.';
      _addConversation(message, false);
      _cancelRequested = true;
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
          // Opening the fallback app is not proof the requested operation
          // succeeded. Let the next model turn continue with visible UI control.
          _lastActionDispatchSucceeded = false;
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
      _lastActionDispatchSucceeded = false;
      return;
    }

    _lastActionDispatchSucceeded = true;
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

  void _updateTaskProgress(String message) {
    _statusMessage = message;
    unawaited(_voiceService.updateNotificationStatus(message));
    notifyListeners();
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
