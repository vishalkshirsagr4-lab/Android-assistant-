import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'grok_service.dart';
import 'groq_service.dart';

/// Represents a single action the AI wants to perform.
class AgentAction {
  final String type; // tap, type, open_app, back, home, swipe, wait
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
  bool _useGrok = false;
  bool _useGroq = false;
  final GrokService _grokService = GrokService();
  final GroqService _groqService = GroqService();

  bool get isConfigured =>
      _useGrok || _useGroq || (_apiKey != null && _apiKey!.isNotEmpty);
  bool get isUsingGrok => _useGrok;
  bool get isUsingGroq => _useGroq;
  void useGrok(bool enabled) {
    _useGrok = enabled;
    if (enabled) _useGroq = false;
  }
  void useGroq(bool enabled) {
    _useGroq = enabled;
    if (enabled) _useGrok = false;
  }

  Future<bool> isProviderReady() async {
    if (_useGrok) return _grokService.isConfigured();
    if (_useGroq) return _groqService.isConfigured();
    return _apiKey != null && _apiKey!.isNotEmpty;
  }

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
- {"type": "wait", "ms": 1000} — Wait before next screenshot
- {"type":"native_action","action":"set_alarm","params":{"hour":7,"minute":30,"label":"Wake up"}} — Open the Android alarm editor
- {"type":"native_action","action":"set_timer","params":{"seconds":300,"label":"Tea"}} — Open the Android timer
- {"type":"native_action","action":"place_call","params":{"phone_number":"+911234567890"}} — Open the dialer with the number filled; NEVER call silently
- {"type":"native_action","action":"send_sms","params":{"phone_number":"+911234567890","message":"Hello"}} — Open the SMS composer; NEVER send silently
- {"type":"native_action","action":"open_url","params":{"url":"https://example.com"}} — Open an HTTP(S) URL
- {"type":"native_action","action":"maps_navigate","params":{"destination":"Hubballi railway station"}} — Open Maps navigation
- {"type":"native_action","action":"music_search","params":{"query":"song name"}} — Search YouTube for music
- {"type":"native_action","action":"flashlight","params":{"enabled":true}} — Toggle flashlight
- {"type":"native_action","action":"set_volume","params":{"percent":50}} — Set media volume (0–100)
- {"type":"native_action","action":"set_brightness","params":{"percent":60}} — Set screen brightness (1–100; may require system permission)
- {"type":"native_action","action":"battery_status","params":{}} — Read battery level and charging state
- {"type":"native_action","action":"storage_status","params":{}} — Read device storage status
- {"type":"native_action","action":"find_contact","params":{"name":"Mom"}} — Find a contact by name (runtime permission required)
- {"type":"native_action","action":"create_calendar_event","params":{"title":"Meeting","begin_time_millis":1790000000000,"end_time_millis":1790003600000,"description":"Notes"}} — Open calendar event editor; user saves it
- {"type":"native_action","action":"open_settings","params":{"page":"wifi"}} — Open an allowlisted settings page: wifi, bluetooth, display, sound, battery, apps, accessibility, location, general
- {"type":"native_action","action":"take_photo","params":{}} — Open the system camera
- {"type":"native_action","action":"share_text","params":{"text":"Text to share"}} — Open Android Sharesheet

NATIVE ACTION RULES:
- Prefer native_action for supported phone operations instead of navigating screens manually.
- For place_call and send_sms, first ask for explicit confirmation in conversation. After confirmation, open the dialer or SMS composer; the user must press the final call/send control themselves.
- Never invent a phone number, contact, date, time, URL, or message. Ask for missing required details.
- For create_calendar_event, convert the user's stated local date/time to epoch milliseconds; ask if the date or duration is unclear. The event is not saved until the user confirms in the calendar app.
- If a native action reports failure or permission denial, explain briefly and use UI automation only when appropriate.
- Native action response shape: {"actions":[{"type":"native_action","action":"battery_status","params":{}}],"speak":"","done":true,"lang":"en"}.
- Continue returning EXACTLY ONE action per response.

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

CONVERSATION MODE:
- If no screenshot and no UI_TREE are supplied, treat the message as ordinary conversation. Answer naturally; do not invent phone actions or claim to see the screen.
- Do not ask what to do next when the requested task has a clear next step. Make a short internal plan, perform one action, inspect the result, and continue until the original goal is complete.
- Ask one concise clarification only when a required detail is genuinely missing or multiple materially different actions are possible.
- Before sending a message, making a call, deleting content, purchasing, posting publicly, or changing security/account settings, obtain explicit confirmation.
- Reuse known app layout hints only as guidance. Always use current live UI_TREE element IDs and bounds; never assume cached coordinates remain valid.

CRITICAL RULES:
1. You MUST respond with ONLY valid JSON. No markdown, no explanation outside JSON.
2. Return EXACTLY ONE action per response. After each action you will receive a fresh screenshot and UI tree showing the result. Do NOT batch multiple actions.
3. For taps: ALWAYS use {"type": "tap", "element": <id>} where <id> is the element's "id" from the UI tree. NEVER use raw x/y coordinates for taps. NEVER guess coordinates from the screenshot.
4. After performing an action, set "done": false to receive the updated screen.
5. Set "done": true only when the user's request is fully completed or you've reported the info they asked for.
6. Keep "speak" concise — it will be read aloud. Only include "speak" text when you have something meaningful to tell the user (e.g., task done, error, or asking for clarification). For intermediate steps, use an empty string.
7. If you cannot perform an action or need more info, explain in "speak" and set "done": true.
8. When asked to read/describe screen content, read it from the screenshot and UI tree, speak it, and set "done": true.
9. Use the UI tree "package" field to confirm which app is in the foreground.

LANGUAGE RULES:
- Detect the language of the user's most recent command.
- The "speak" field MUST be written in that same language. If the user speaks Japanese, reply in natural Japanese. If the user speaks Arabic, reply in natural Modern Standard Arabic. If the user speaks English, reply in English. If the user speaks Hindi, reply in natural Hindi with lang 'hi'. If the user speaks Kannada, reply in natural Kannada with lang 'kn'.
- Also return a "lang" field with the BCP-47 short code of the language you used for "speak": "en" for English, "ja" for Japanese, "ar" for Arabic, "hi" for Hindi, or "kn" for Kannada. If "speak" is empty, still return the language of the user's most recent command.
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

  void configure(String apiKey) {
    _apiKey = apiKey;
    _model = GenerativeModel(
      model: 'gemini-3.1-flash-lite-preview',
      apiKey: apiKey,
      generationConfig: GenerationConfig(responseMimeType: 'application/json'),
      systemInstruction: Content.system(_systemPrompt),
    );
    _chat = _model!.startChat();
  }

  /// Send a message with an optional screenshot, screen size, and UI tree.
  Future<AgentResponse> agentChat(
    String message, {
    Uint8List? imageBytes,
    Map<String, int>? screenSize,
    String? uiTree,
    String memoryContext = '',
  }) async {
    if (!isConfigured) {
      return AgentResponse.fallback(
        'AI not configured. Please set your API key.',
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

      if (memoryContext.trim().isNotEmpty) {
        buffer.writeln('[USER_APPROVED_MEMORY — use only when relevant; never infer extra personal facts]');
        buffer.writeln(memoryContext);
        buffer.writeln('[/USER_APPROVED_MEMORY]');
      }
      buffer.write(message);
      final fullMessage = buffer.toString();

      if (_useGrok) {
        final grokText = await _grokService.complete(
          fullMessage,
          systemPrompt: _systemPrompt,
          imageBytes: imageBytes,
        );
        return _parseAgentResponse(grokText);
      }
      if (_useGroq) {
        final groqText = await _groqService.complete(
          fullMessage,
          systemPrompt: _systemPrompt,
          imageBytes: imageBytes,
        );
        return _parseAgentResponse(groqText);
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
    _groqService.resetChat();
  }
}
