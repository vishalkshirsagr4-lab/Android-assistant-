import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'grok_service.dart';

/// Represents a single action the AI wants to perform.
class AgentAction {
  final String type; // open_app, tap, type, swipe, back, home, wait, schedule_reminder
  final Map<String, dynamic> params;

  AgentAction({required this.type, this.params = const {}});

  @override
  String toString() => 'AgentAction($type, $params)';
}

/// Parsed structured response from the AI agent.
class AgentResponse {
  final List<AgentAction> actions;
  final String speak;
  final bool done;
  final String lang; // BCP-47-ish short code: "en", "ja". Empty if unknown.
  final String rawResponse;

  AgentResponse({
    required this.actions,
    required this.speak,
    required this.done,
    required this.lang,
    required this.rawResponse,
  });

  factory AgentResponse.fromJson(Map<String, dynamic> json, String raw) {
    final actionsList = (json['actions'] as List<dynamic>? ?? [])
        .map(
          (a) => AgentAction(
            type: a['type'] as String? ?? 'wait',
            params: Map<String, dynamic>.from(a as Map)..remove('type'),
          ),
        )
        .toList();

    return AgentResponse(
      actions: actionsList,
      speak: json['speak'] as String? ?? '',
      done: json['done'] as bool? ?? true,
      lang: (json['lang'] as String? ?? '').toLowerCase(),
      rawResponse: raw,
    );
  }

  factory AgentResponse.fallback(String raw) {
    return AgentResponse(
      actions: [],
      speak: raw.length > 300 ? '${raw.substring(0, 297)}...' : raw,
      done: true,
      lang: '',
      rawResponse: raw,
    );
  }
}

class AiService {
  GenerativeModel? _model;
  ChatSession? _chat;
  String? _apiKey;
  static const _secureStorage = FlutterSecureStorage();
  static const _geminiKeyName = 'lucy_gemini_api_key';
  bool _useGrok = false;
  final GrokService _grokService = GrokService();

  bool get isConfigured => _useGrok || (_apiKey != null && _apiKey!.isNotEmpty);
  bool get isUsingGrok => _useGrok;
  void useGrok(bool enabled) => _useGrok = enabled;
  Future<bool> isProviderReady() async =>
      _useGrok ? _grokService.isConfigured() : isConfigured;

  static const _systemPrompt = '''
You are an autonomous AI agent controlling an Android phone. You receive TWO sources of information each step:

1. SCREENSHOT — a visual image of the current screen
2. UI TREE — a JSON list of interactive/text elements with EXACT pixel bounds

THE UI TREE gives you each element's:
- "id": integer index (use this to reference elements for tap actions)
- "type": Android view class (e.g. Button, EditText, TextView, ImageView)
- "text": visible text on the element (if any)
- "desc": content description / accessibility label (if any)
- "clickable": true if the element can be tapped
- "editable": true if the element is a text input field
- "bounds": {"cx": centerX, "cy": centerY, "w": width, "h": height} — pixel coordinates

AVAILABLE ACTIONS:
- {"type": "open_app", "package": "com.whatsapp"} — Launch an app by package name
- {"type": "tap", "element": 5} — Tap the UI tree element with the given id. ALWAYS use this for tapping.
- {"type": "type", "text": "Hello!"} — Type text into the focused input field
- {"type": "swipe", "startX": 540, "startY": 1500, "endX": 540, "endY": 500} — Swipe/scroll
- {"type": "back"} — Press the back button
- {"type": "home"} — Press the home button
- {"type": "schedule_reminder", "title": "Study", "body": "Time to study", "delayMinutes": 30, "repeatIntervalMinutes": 0} — Schedule a notification reminder; repeatIntervalMinutes must be 0 or at least 15\n- {"type": "wait", "ms": 1000} — Wait before next screenshot

COMMON APP PACKAGES:
- WhatsApp: com.whatsapp
- Chrome: com.android.chrome
- Settings: com.android.settings
- YouTube: com.google.android.youtube
- Gmail: com.google.android.gm
- Messages: com.google.android.apps.messaging
- Phone: com.google.android.dialer
- Camera: com.android.camera2
- Maps: com.google.android.apps.maps
- Calendar: com.google.android.calendar
- Clock: com.google.android.deskclock
- Calculator: com.google.android.calculator
- Files: com.google.android.apps.nbu.files
- Play Store: com.android.vending
- Photos: com.google.android.apps.photos
- Contacts: com.google.android.contacts
- Instagram: com.instagram.android
- X/Twitter: com.twitter.android
- Telegram: org.telegram.messenger
- Facebook: com.facebook.katana
- Spotify: com.spotify.music
- ChatGPT: com.openai.chatgpt

CRITICAL RULES:
1. You MUST respond with ONLY valid JSON. No markdown, no explanation outside JSON.
2. Return EXACTLY ONE action per response. After each action you will receive a fresh screenshot and UI tree showing the result. Do NOT batch multiple actions.
3. For taps: ALWAYS use {"type": "tap", "element": <id>} where <id> is the element's "id" from the UI tree. NEVER use raw x/y coordinates for taps. NEVER guess coordinates from the screenshot.
4. After performing an action, set "done": false to receive the updated screen.
5. Set "done": true only when the user's request is fully completed or you've reported the info they asked for.
6. Keep "speak" concise — it will be read aloud. Only include "speak" text when you have something meaningful to tell the user (e.g., task done, error, or asking for clarification). For intermediate steps, use an empty string.
7. If you cannot perform an action or need more info, explain in "speak" and set "done": true.\n8. For voice reminders, convert the requested time to delayMinutes using the current local time context supplied by the app. If the time is ambiguous, ask a brief question instead of guessing.\n9. When asked to text a message, open the requested messaging app, select the recipient only when clearly identified, and type the exact requested message. When Lucy reaches Send/Publish or another consequential action, the app will pause and ask the user to say "approve" or "cancel". If approved, continue the same task from that exact step; if cancelled or approval times out, stop without performing it. Never treat unrelated speech or background audio as approval.\n10. For YouTube requests, open YouTube, use its visible search UI, type the requested song/video title, and select a matching result. Do not claim playback until the screen confirms it.
8. When asked to read/describe screen content, read it from the screenshot and UI tree, speak it, and set "done": true.
9. Use the UI tree "package" field to confirm which app is in the foreground.

LANGUAGE RULES:
- Detect the language of the user's most recent command.
- The "speak" field MUST be written in that same language. If the user speaks Japanese, reply in natural Japanese. If the user speaks Arabic, reply in natural Modern Standard Arabic. If the user speaks English, reply in English.
- Also return a "lang" field with the BCP-47 short code of the language you used for "speak": "en" for English, "ja" for Japanese, "ar" for Arabic. If "speak" is empty, still return the language of the user's most recent command.
- Keep this language consistent across the whole task until the user switches language.
- Action JSON keys/values (type, package, text) stay as-is — only "speak" is localized. When typing into an input field, the "text" value should match what the user asked to type (in whichever language they used).

RESPONSE FORMAT (strict JSON, one action only):
{
  "actions": [
    {"type": "open_app", "package": "com.whatsapp"}
  ],
  "speak": "",
  "done": false,
  "lang": "en"
}
''';

  Future<void> configure(String apiKey) async {
    final normalizedKey = apiKey.trim();
    if (normalizedKey.isEmpty) throw ArgumentError('Gemini API key cannot be empty.');
    await _secureStorage.write(key: _geminiKeyName, value: normalizedKey);
    _apiKey = normalizedKey;
    _model = GenerativeModel(
      model: 'gemini-3.1-flash-lite-preview',
      apiKey: normalizedKey,
      generationConfig: GenerationConfig(responseMimeType: 'application/json'),
      systemInstruction: Content.system(_systemPrompt),
    );
    _chat = _model!.startChat();
  }

  Future<void> restoreConfiguration({String? legacyKey}) async {
    String? key;
    try {
      key = await _secureStorage.read(key: _geminiKeyName);
      if ((key == null || key.isEmpty) && legacyKey != null && legacyKey.trim().isNotEmpty) {
        key = legacyKey.trim();
        await _secureStorage.write(key: _geminiKeyName, value: key);
      }
    } catch (_) {
      // Keep the app launchable in restricted test/desktop environments.
      // Android production builds use the encrypted platform keystore.
      key = legacyKey?.trim();
    }
    if (key != null && key.isNotEmpty) {
      final normalizedKey = key;
      _apiKey = normalizedKey;
      _model = GenerativeModel(
        model: 'gemini-3.1-flash-lite-preview',
        apiKey: normalizedKey,
        generationConfig: GenerationConfig(responseMimeType: 'application/json'),
        systemInstruction: Content.system(_systemPrompt),
      );
      _chat = _model!.startChat();
    }
  }

  Future<void> clearGeminiKey() async {
    await _secureStorage.delete(key: _geminiKeyName);
    _apiKey = null;
    _model = null;
    _chat = null;
  }

  /// Send a message with an optional screenshot, screen size, and UI tree.
  Future<AgentResponse> agentChat(
    String message, {
    Uint8List? imageBytes,
    Map<String, int>? screenSize,
    String? uiTree,
  }) async {
    if (!isConfigured) {
      return AgentResponse.fallback(
        'AI not configured. Please set an AI provider key in Lucy settings.',
      );
    }

    try {
      // Build the text message with metadata
      final buffer = StringBuffer();

      if (screenSize != null) {
        buffer.writeln(
          '[Screen: ${screenSize['width']}x${screenSize['height']} pixels]',
        );
      }

      if (uiTree != null) {
        buffer.writeln('[UI_TREE]');
        buffer.writeln(uiTree);
        buffer.writeln('[/UI_TREE]');
      }

      buffer.write(message);
      final fullMessage = buffer.toString();

      if (_useGrok) {
        final text = await _grokService.complete(
          fullMessage,
          systemPrompt: _systemPrompt,
          imageBytes: imageBytes,
        );
        return _parseAgentResponse(text);
      }

      Content content;
      if (imageBytes != null) {
        content = Content.multi([
          TextPart(fullMessage),
          DataPart('image/jpeg', imageBytes),
        ]);
      } else {
        content = Content('user', [TextPart(fullMessage)]);
      }

      final response = await _chat!.sendMessage(content);
      final text = response.text ?? '{}';
      return _parseAgentResponse(text);
    } catch (e) {
      return AgentResponse.fallback('Error: ${e.toString()}');
    }
  }

  /// Parse the AI's JSON response into an AgentResponse.
  AgentResponse _parseAgentResponse(String text) {
    try {
      // Try to extract JSON from the response
      String jsonStr = text.trim();

      // If wrapped in markdown code block, extract it
      if (jsonStr.startsWith('```')) {
        final startIdx = jsonStr.indexOf('{');
        final endIdx = jsonStr.lastIndexOf('}');
        if (startIdx != -1 && endIdx != -1) {
          jsonStr = jsonStr.substring(startIdx, endIdx + 1);
        }
      }

      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AgentResponse.fromJson(json, text);
    } catch (e) {
      // If JSON parsing fails, treat the whole response as a spoken message
      return AgentResponse.fallback(text);
    }
  }

  /// Reset chat history for a fresh conversation.
  void resetChat() {
    if (_model != null) {
      _chat = _model!.startChat();
    }
  }
}
