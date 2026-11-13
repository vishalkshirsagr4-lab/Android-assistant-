import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Groq Cloud provider using its OpenAI-compatible Chat Completions API.
class GroqService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_groq_api_key';
  static const _modelsEndpoint = 'https://api.groq.com/openai/v1/models';
  static const _chatEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';

  // Multimodal model supports screenshot understanding and JSON mode.
  static const model = 'qwen/qwen3.8-27b';

  // Keep the same multi-step conversation context that Gemini's ChatSession
  // retains, so Groq remembers the original task after each phone action.
  final List<Map<String, dynamic>> _history = [];

  void resetChat() => _history.clear();

  String _normalizeKey(String input) {
    var value = input.trim();
    if (value.startsWith('Bearer ')) value = value.substring(7).trim();
    if (value.startsWith('GROQ_API_KEY=')) {
      value = value.substring('GROQ_API_KEY='.length).trim();
    }
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  Future<void> saveApiKey(String key) async {
    final value = _normalizeKey(key);
    if (value.isEmpty) throw ArgumentError('Paste your Groq API key.');
    await _storage.write(key: _keyName, value: value);
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.trim().isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  Future<void> validateApiKey(String apiKey) async {
    final key = _normalizeKey(apiKey);
    if (key.isEmpty) throw ArgumentError('Paste your Groq API key.');
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse(_modelsEndpoint),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw GroqRequestException(
          _errorMessage(response.statusCode, response.body),
          response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) {
        throw const FormatException('Groq returned an unexpected models response.');
      }
      final models = data.whereType<Map>()
          .map((item) => item['id']?.toString()).whereType<String>().toSet();
      if (!models.contains(model)) {
        throw GroqRequestException(
          'The key is valid, but $model is not available to this Groq account.',
          403,
        );
      }
    } on TimeoutException {
      throw TimeoutException('Groq key check timed out. Check your connection.');
    } finally {
      client.close();
    }
  }

  Future<String> complete(
    String prompt, {
    required String systemPrompt,
    Uint8List? imageBytes,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final stored = await _storage.read(key: _keyName);
    final key = stored == null ? null : _normalizeKey(stored);
    if (key == null || key.isEmpty) {
      throw StateError('Add a Groq API key in Lucy Tools first.');
    }
    if (prompt.trim().isEmpty) throw ArgumentError('Prompt cannot be empty.');
    if (imageBytes != null && imageBytes.length > 20 * 1024 * 1024) {
      throw ArgumentError(
        'The captured screen image is larger than Groq’s 20 MB image limit. '
        'Please try again after reducing the screen resolution.',
      );
    }

    final userContent = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt.trim()},
    ];
    if (imageBytes != null) {
      userContent.add({
        'type': 'image_url',
        'image_url': {
          'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
        },
      });
    }

    final userMessage = <String, dynamic>{
      'role': 'user',
      'content': imageBytes == null ? prompt.trim() : userContent,
    };
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ..._history,
      userMessage,
    ];

    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(_chatEndpoint),
        headers: {
          'Authorization': 'Bearer ${key.trim()}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'response_format': {'type': 'json_object'},
          'temperature': 0.2,
          'max_completion_tokens': 4096,
          'reasoning_effort': 'none',
          'stream': false,
        }),
      ).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GroqRequestException(
          _errorMessage(response.statusCode, response.body),
          response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body);
      final choices = decoded is Map ? decoded['choices'] : null;
      final message = choices is List && choices.isNotEmpty &&
              choices.first is Map
          ? (choices.first as Map)['message']
          : null;
      final text = message is Map ? message['content']?.toString().trim() : null;
      if (text == null || text.isEmpty) {
        throw const FormatException('Groq returned an empty response.');
      }

      // Store both sides of the turn. Bound history to avoid unbounded token use.
      _history
        ..add(userMessage)
        ..add({'role': 'assistant', 'content': text});
      if (_history.length > 24) {
        _history.removeRange(0, _history.length - 24);
      }
      return text;
    } on TimeoutException {
      throw TimeoutException('Groq request timed out. Check your connection and retry.');
    } finally {
      client.close();
    }
  }

  String _errorMessage(int status, String body) {
    var detail = '';
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      detail = error is Map
          ? (error['message']?.toString() ?? '')
          : (error?.toString() ?? '');
    } catch (_) {
      detail = body;
    }
    if (detail.length > 350) detail = detail.substring(0, 350);
    if (status == 400) return 'Groq rejected the request (HTTP 400): $detail';
    if (status == 401) return 'Groq rejected this API key (HTTP 401). Check that it came from console.groq.com.';
    if (status == 403) return 'This Groq key or model is not permitted (HTTP 403): $detail';
    if (status == 404) return 'Groq model or endpoint not found (HTTP 404): $detail';
    if (status == 429) return 'Groq rate limit or account quota reached (HTTP 429): $detail';
    if (status >= 500) return 'Groq service error (HTTP $status). Try again later.';
    return 'Groq request failed (HTTP $status): $detail';
  }
}

class GroqRequestException implements Exception {
  const GroqRequestException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
