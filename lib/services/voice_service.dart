import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'lucy_settings_store.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Owns the Flutter TTS engine and Lucy's user-started native Android
/// SpeechRecognizer foreground service.
class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  static const MethodChannel _native = MethodChannel(
    'com.poc.screen_aware_ai/voice',
  );

  static const String _rateKey = 'lucy_voice_rate';
  static const String _pitchKey = 'lucy_voice_pitch';
  static const String _volumeKey = 'lucy_voice_volume';

  static const Map<String, String> _langToTtsLocale = {
    'en': 'en-US',
    'ja': 'ja-JP',
    'ar': 'ar-SA',
    'hi': 'hi-IN',
    'kn': 'kn-IN',
  };

  static const Map<String, String> _langToSttLocale = {
    'en': 'en_US',
    'ja': 'ja_JP',
    'ar': 'ar_SA',
    'hi': 'hi_IN',
    'kn': 'kn_IN',
  };

  bool _nativeHandlerInstalled = false;
  bool _isInitialized = false;
  bool _isListening = false;
  bool _isPausedForProcessing = false;
  bool _isSpeaking = false;
  bool _disposed = false;
  String _currentTtsLanguage = '';

  double _speechRate = 0.48;
  double _pitch = 1.0;
  double _volume = 1.0;

  bool get isListening => _isListening;
  bool get isSpeaking => _isSpeaking;
  double get speechRate => _speechRate;
  double get pitch => _pitch;
  double get volume => _volume;

  Function(String text, bool isFinal)? onResult;
  Function()? onListeningDone;
  Function(String error)? onError;

  static String? sttLocaleFor(String? lang) =>
      _langToSttLocale[lang?.toLowerCase()];

  static String? ttsLocaleFor(String? lang) =>
      _langToTtsLocale[lang?.toLowerCase()];

  static const Map<String, String> languageNames = <String, String>{
    'en': 'English',
    'hi': 'हिन्दी',
    'kn': 'ಕನ್ನಡ',
    'ja': '日本語',
    'ar': 'العربية',
  };

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    if (_disposed) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      _speechRate = (prefs.getDouble(_rateKey) ?? 0.48)
          .clamp(0.35, 0.65)
          .toDouble();
      _pitch = (prefs.getDouble(_pitchKey) ?? 1.0)
          .clamp(0.8, 1.2)
          .toDouble();
      _volume = (prefs.getDouble(_volumeKey) ?? 1.0)
          .clamp(0.3, 1.0)
          .toDouble();

      // Initialize recognition independently. A missing TTS voice pack must
      // never prevent Hindi/Kannada speech recognition from starting.
      _isInitialized = await _speech.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (_) {
      _isInitialized = false;
      onError?.call('speech_recognition_unavailable');
      return false;
    }

    try {
      await _tts.awaitSpeakCompletion(true);
      await _setTtsLanguage('en-US');
      await _applyTtsSettings();
    } catch (_) {
      // TTS is optional. Recognition remains usable even if no voice engine or
      // selected language pack is installed; speak() reports failure safely.
    }

    _tts.setStartHandler(() {
      _isSpeaking = true;
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
    });

    return _isInitialized;
  }

  Future<void> _setTtsLanguage(String targetLocale) async {
    if (targetLocale == _currentTtsLanguage) return;
    try {
      final result = await _tts.setLanguage(targetLocale);
      if (result is num && result < 0) {
        throw StateError('Selected TTS language is unavailable');
      }
      _currentTtsLanguage = targetLocale;
    } catch (_) {
      if (targetLocale == 'en-US') rethrow;
      final fallback = await _tts.setLanguage('en-US');
      if (fallback is num && fallback < 0) {
        throw StateError('No supported TTS language is installed');
      }
      _currentTtsLanguage = 'en-US';
    }
  }

  Future<void> _applyTtsSettings() async {
    await _tts.setSpeechRate(_speechRate);
    await _tts.setPitch(_pitch);
    await _tts.setVolume(_volume);
  }

  /// Adjusts the installed Android TTS engine. Values are clamped to
  /// conservative ranges and persisted locally on this device.
  Future<void> setVoiceSettings({
    double? speechRate,
    double? pitch,
    double? volume,
  }) async {
    if (_disposed) return;

    if (speechRate != null) {
      _speechRate = speechRate.clamp(0.35, 0.65).toDouble();
    }
    if (pitch != null) {
      _pitch = pitch.clamp(0.8, 1.2).toDouble();
    }
    if (volume != null) {
      _volume = volume.clamp(0.3, 1.0).toDouble();
    }

    if (_isInitialized) {
      await _applyTtsSettings();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_rateKey, _speechRate);
    await prefs.setDouble(_pitchKey, _pitch);
    await prefs.setDouble(_volumeKey, _volume);
  }

  Future<bool> startListening({String? localeId}) async {
    if (!_isInitialized && !await initialize()) {
      onError?.call(
        'Speech recognition is unavailable or microphone permission is missing.',
      );
      return false;
    }
    if (_disposed) return false;

    if (_isSpeaking) {
      await stopSpeaking();
    }
    if (_isListening && !_isPausedForProcessing) return true;
    if (_isListening && _isPausedForProcessing) {
      try {
        final resumed = await _native.invokeMethod<bool>('resumeAfterProcessing');
        _isPausedForProcessing = false;
        return resumed == true;
      } catch (error) {
        onError?.call('Could not resume listening: $error');
        return false;
      }
    }

    if (!_nativeHandlerInstalled) {
      _nativeHandlerInstalled = true;
      _native.setMethodCallHandler((call) async {
        if (call.method == 'onResult' && call.arguments is Map) {
          final data = Map<dynamic, dynamic>.from(call.arguments as Map);
          final words = data['text']?.toString() ?? '';
          if (words.isNotEmpty) {
            onResult?.call(words, data['isFinal'] == true);
          }
        } else if (call.method == 'onError' && call.arguments is Map) {
          final data = Map<dynamic, dynamic>.from(call.arguments as Map);
          final message = data['message']?.toString() ?? '';
          if (message.startsWith('LANGUAGE_UNAVAILABLE:')) {
            onError?.call('language_unavailable');
          } else if (message == 'MICROPHONE_PERMISSION_REQUIRED') {
            onError?.call('microphone_permission_required');
          } else {
            // Do not expose platform exception text to spoken replies or UI.
            onError?.call('speech_recognition_unavailable');
          }
        } else if (call.method == 'onStopped') {
          final data = call.arguments is Map
              ? Map<dynamic, dynamic>.from(call.arguments as Map)
              : const <dynamic, dynamic>{};
          final wasListening = _isListening;
          _isListening = false;
          if (wasListening && data['userInitiated'] != true && !_disposed) {
            onListeningDone?.call();
          }
        }
      });
    }

    try {
      final started = await _native
          .invokeMethod<bool>('start', {
            'localeId': localeId ?? 'en_US',
          })
          .timeout(const Duration(seconds: 5));
      _isListening = started == true;
      if (!_isListening) {
        onError?.call(
          'Android did not start the microphone foreground service.',
        );
      }
      return _isListening;
    } catch (error) {
      _isListening = false;
      onError?.call('Could not start native speech recognition: $error');
      return false;
    }
  }

  /// Updates Lucy's existing Android microphone notification without restarting
  /// speech recognition. The status never includes the user's spoken command.
  Future<void> updateNotificationStatus(String status) async {
    if (_disposed) return;
    try {
      await _native.invokeMethod<bool>('updateStatus', {
        'status': status.trim().isEmpty ? 'Lucy is working' : status.trim(),
      });
    } catch (_) {
      // Notification updates are best-effort; they must never interrupt a task.
    }
  }

  /// Pauses recognition but keeps the foreground service and Stop notification
  /// alive while Lucy processes a command or speaks its response.
  Future<void> pauseListeningForProcessing() async {
    if (!_isListening || _isPausedForProcessing || _disposed) return;
    try {
      await _native.invokeMethod<bool>('pauseForProcessing');
      _isPausedForProcessing = true;
    } catch (_) {
      // Continue processing even if Android cannot pause recognition cleanly.
    }
  }

  Future<void> stopListening() async {
    // Clear the flags before Android's onDestroy broadcast arrives so a
    // deliberate stop is never interpreted as an unexpected disconnect.
    _isListening = false;
    _isPausedForProcessing = false;
    try {
      await _native.invokeMethod<bool>('stop');
    } catch (_) {
      // The service may already have stopped during an Android lifecycle event.
    }
  }

  /// Splits completed model text into sentence-sized speech units.
  /// The model providers currently return complete responses; this improves
  /// playback responsiveness and allows intermediate speech to overlap actions,
  /// but it is not token-level model streaming.
  static List<String> splitSpeechChunks(
    String text, {
    int maxChars = 220,
  }) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return const <String>[];
    final sentences = normalized
        .split(RegExp(r'(?<=[.!?。！？؟।])\s+'))
        .where((sentence) => sentence.trim().isNotEmpty);
    final chunks = <String>[];
    for (final sentence in sentences) {
      final value = sentence.trim();
      if (value.length <= maxChars) {
        chunks.add(value);
        continue;
      }
      var current = '';
      for (final word in value.split(' ')) {
        final candidate = current.isEmpty ? word : '$current $word';
        if (candidate.length > maxChars && current.isNotEmpty) {
          chunks.add(current);
          current = word;
        } else {
          current = candidate;
        }
      }
      if (current.isNotEmpty) chunks.add(current);
    }
    return chunks;
  }

  bool _streamingSpeechActive = false;
  Future<void> _streamingSpeechQueue = Future<void>.value();
  int _streamingSpeechGeneration = 0;

  /// Prepares TTS so complete sentences can be spoken while Gemini is
  /// still generating the rest of Lucy's structured response.
  Future<void> beginStreamingSpeech({String? lang}) async {
    if (_disposed) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(LucySettingsStore.voiceOutput) == false) return;
    if (!_isInitialized && !await initialize()) return;
    if (_isSpeaking) await stopSpeaking();
    final targetLocale = ttsLocaleFor(lang) ?? 'en-US';
    try {
      await _setTtsLanguage(targetLocale);
    } catch (_) {
      onError?.call('tts_unavailable');
      return;
    }
    _streamingSpeechGeneration = ++_speechGeneration;
    _streamingSpeechQueue = Future<void>.value();
    _streamingSpeechActive = true;
  }

  /// Queues a complete sentence emitted from the partial model response.
  void addStreamingSpeechText(String sentence) {
    if (!_streamingSpeechActive || _disposed) return;
    final value = sentence.trim();
    if (value.isEmpty) return;
    final generation = _streamingSpeechGeneration;
    _streamingSpeechQueue = _streamingSpeechQueue.then((_) async {
      if (_disposed || generation != _speechGeneration) return;
      _isSpeaking = true;
      try {
        await _tts.speak(value);
      } catch (_) {
        onError?.call('Text-to-speech failed.');
      } finally {
        if (generation == _speechGeneration) _isSpeaking = false;
      }
    });
  }

  /// Closes the stream and returns a future that completes after queued speech.
  Future<void> finishStreamingSpeech() async {
    if (!_streamingSpeechActive) return;
    _streamingSpeechActive = false;
    await _streamingSpeechQueue;
  }

  /// Cancels queued speech if the streaming provider fails before valid JSON.
  Future<void> cancelStreamingSpeech() async {
    _streamingSpeechActive = false;
    await stopSpeaking();
  }

  int _speechGeneration = 0;

  /// Plays sentence-sized units in order. Calling stopSpeaking invalidates the
  /// current generation so no later sentence starts after an interruption.
  Future<void> speakProgressively(String text, {String? lang}) async {
    if (_disposed || text.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(LucySettingsStore.voiceOutput) == false) return;
    if (!_isInitialized && !await initialize()) return;

    if (_isListening && !_isPausedForProcessing) {
      await stopListening();
    }
    if (_isSpeaking) await stopSpeaking();

    final generation = ++_speechGeneration;
    final targetLocale = ttsLocaleFor(lang) ?? 'en-US';
    try {
      await _setTtsLanguage(targetLocale);
    } catch (_) {
      onError?.call('tts_unavailable');
      return;
    }

    for (final chunk in splitSpeechChunks(text)) {
      if (_disposed || generation != _speechGeneration) break;
      _isSpeaking = true;
      try {
        await _tts.speak(chunk);
      } catch (error) {
        onError?.call('Text-to-speech failed.');
        break;
      } finally {
        _isSpeaking = false;
      }
    }
  }

  Future<void> speak(String text, {String? lang}) async {
    if (_disposed || text.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(LucySettingsStore.voiceOutput) == false) return;
    if (!_isInitialized && !await initialize()) return;

    if (_isListening && !_isPausedForProcessing) {
      await stopListening();
    }
    if (_isSpeaking) {
      await stopSpeaking();
    }

    final targetLocale = ttsLocaleFor(lang) ?? 'en-US';
    try {
      await _setTtsLanguage(targetLocale);
      _isSpeaking = true;
      await _tts.speak(text);
    } catch (_) {
      _isSpeaking = false;
      onError?.call('tts_unavailable');
    } finally {
      _isSpeaking = false;
    }
  }

  Future<void> stopSpeaking() async {
    _speechGeneration++;
    try {
      await _tts.stop();
    } catch (_) {
      // A stop can race with natural TTS completion.
    } finally {
      _isSpeaking = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.setMethodCallHandler(null);
    unawaited(_disposeNative());
    unawaited(_disposeSpeech());
    unawaited(_disposeTts());
  }

  Future<void> _disposeNative() async {
    try {
      await _native.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  Future<void> _disposeSpeech() async {
    try {
      await _speech.stop();
      await _speech.cancel();
    } catch (_) {}
  }

  Future<void> _disposeTts() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
