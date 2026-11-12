import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _errorOccurred = false;
  bool _disposed = false;
  String _currentTtsLanguage = 'en-US';

  static const Map<String, String> _langToTtsLocale = {
    'en': 'en-US',
    'ja': 'ja-JP',
    'ar': 'ar-SA',
  };

  // speech_to_text uses the same locale IDs as TTS on Android.
  static const Map<String, String> _langToSttLocale = {
    'en': 'en_US',
    'ja': 'ja_JP',
    'ar': 'ar_SA',
  };

  /// Resolve a short language code ("en"/"ja") to an STT locale ID.
  /// Returns null for unknown codes so STT falls back to its default.
  static String? sttLocaleFor(String? lang) =>
      _langToSttLocale[lang?.toLowerCase()];

  bool get isListening => _isListening;
  bool get isSpeaking => _isSpeaking;

  // Callbacks
  Function(String text, bool isFinal)? onResult;
  Function()? onListeningDone;
  Function(String error)? onError;

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    if (_disposed) return false;

    try {
      _isInitialized = await _speech.initialize(
        onError: (error) {
          _isListening = false;
          _errorOccurred = true;
          onError?.call(error.errorMsg);
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
            if (_errorOccurred) {
              _errorOccurred = false;
            } else {
              onListeningDone?.call();
            }
          }
        },
      );

      await _tts.setLanguage('en-US');
      _currentTtsLanguage = 'en-US';
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
      });

      return _isInitialized;
    } catch (e) {
      onError?.call('Failed to initialize voice: $e');
      return false;
    }
  }

  Future<bool> startListening({String? localeId}) async {
    if (!_isInitialized && !await initialize()) {
      onError?.call('Speech recognition is unavailable or microphone permission is missing.');
      return false;
    }
    if (_disposed) return false;

    // Stop TTS if speaking
    if (_isSpeaking) {
      await stopSpeaking();
    }

    if (_isListening) return true;

    // Cancel any lingering STT session to ensure a clean engine state
    await _speech.cancel();

    _errorOccurred = false;
    try {
      await _speech.listen(
      onResult: (result) {
        onResult?.call(result.recognizedWords, result.finalResult);
      },
      // Android speech services impose their own hard session limits. Lucy
      // renews bounded sessions while the user-started foreground session lives.
      listenFor: const Duration(seconds: 55),
      pauseFor: const Duration(seconds: 5),
      localeId: localeId,
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
      );
      _isListening = true;
      return true;
    } catch (error) {
      _isListening = false;
      onError?.call('Could not start speech recognition: $error');
      return false;
    }
  }

  Future<void> stopListening() async {
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }
  }

  Future<void> speak(String text, {String? lang}) async {
    if (!_isInitialized) await initialize();

    // Stop listening while speaking
    if (_isListening) {
      await stopListening();
    }

    final targetLocale = _langToTtsLocale[lang?.toLowerCase()] ?? 'en-US';
    if (targetLocale != _currentTtsLanguage) {
      await _tts.setLanguage(targetLocale);
      _currentTtsLanguage = targetLocale;
    }

    _isSpeaking = true;
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _isSpeaking = false;
  }

  void dispose() {
    _disposed = true;
    _speech.stop();
    _speech.cancel();
    _tts.stop();
  }
}
