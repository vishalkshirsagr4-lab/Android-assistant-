import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// OpenAI-compatible 100milionseek provider.
///
/// This service deliberately sends text only: the provider documentation does
/// not clearly guarantee image input. Screen-image requests use Gemini/Groq/Grok.
/// Requests use the provider's standard chat-completions message schema.
class HmsService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_hms_api_key';
  static const baseUrl = 'https://100milionseek.top/v1';
  static const model = 'deepseek-v4.1-flash-free';
  static const _modelsEndpoint = '$baseUrl/models';
  static const _chatEndpoint = '$baseUrl/chat/completions';

  final List<Map<String, dynamic>> _history = [];
  String? _quotaRemaining;
  String? _quotaResetAt;

  String? get quotaRemaining => _quotaRemaining;
  String? get quotaResetAt => _quotaResetAt;

  void resetChat() => _history.clear();

  String _normalizeKey(String input) {
    var value = input.trim();
    if (value.startsWith('Bearer ')) value = value.substring(7).trim();
    if (value.startsWith('HMS_API_KEY=')) {
      value = value.substring('HMS_API_KEY='.length).trim();
    }
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  Future<void> saveApiKey(String input) async {
    final key = _normalizeKey(input);
    if (key.isEmpty) throw ArgumentError('Paste your 100milionseek API key.');
    await _storage.write(key: _keyName, value: key);
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.trim().isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  Future<void> validateApiKey(String input) async {
    final key = _normalizeKey(input);
    if (key.isEmpty) throw ArgumentError('Paste your 100milionseek API key.');
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse(_modelsEndpoint),
        headers: {'Authorization': 'Bearer $key', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw HmsRequestException(
          _errorMessage(response.statusCode, response.body),
          response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) {
        throw const FormatException(
          '100milionseek returned an unexpected models response.',
        );
      }
      final models = data.whereType<Map>()
          .map((item) => item['id']?.toString())
          .whereType<String>().toSet();
      if (!models.contains(model)) {
        throw const HmsRequestException(
          'The key is valid, but the advertised Lucy model is not available.',
          404,
        );
      }
    } on TimeoutException {
      throw TimeoutException('100milionseek key check timed out. Check your connection.');
    } finally {
      client.close();
    }
  }

  Future<String> complete(
    String prompt, {
    required String systemPrompt,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final stored = await _storage.read(key: _keyName);
    final key = stored == null ? null : _normalizeKey(stored);
    if (key == null || key.isEmpty) {
      throw StateError('Add a 100milionseek API key in Lucy tools first.');
    }
    if (prompt.trim().isEmpty) throw ArgumentError('Prompt cannot be empty.');

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ..._history,
      {'role': 'user', 'content': prompt.trim()},
    ];
    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(_chatEndpoint),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': 0.2,
          'max_tokens': 4096,
          'stream': false,
        }),
      ).timeout(timeout);

      _quotaRemaining = response.headers['x-quota-remaining'];
      _quotaResetAt = response.headers['x-quota-reset'];

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HmsRequestException(
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
      final answer = message is Map
          ? message['content']?.toString().trim()
          : null;
      if (answer == null || answer.isEmpty) {
        throw const FormatException('100milionseek returned an empty response.');
      }

      _history
        ..add({'role': 'user', 'content': _trim(prompt.trim(), 1800)})
        ..add({'role': 'assistant', 'content': _trim(answer, 1800)});
      if (_history.length > 4) {
        _history.removeRange(0, _history.length - 4);
      }
      return answer;
    } on TimeoutException {
      throw TimeoutException('100milionseek request timed out.');
    } finally {
      client.close();
    }
  }

  String _trim(String value, int max) =>
      value.length > max ? value.substring(0, max) : value;

  String _errorMessage(int status, String body) {
    var detail = '';
    var code = '';
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        detail = error['message']?.toString() ?? '';
        code = error['code']?.toString() ?? '';
      } else {
        detail = error?.toString() ?? '';
      }
    } catch (_) {
      detail = body;
    }
    if (detail.length > 300) detail = detail.substring(0, 300);
    if (status == 401) return '100milionseek rejected the API key (HTTP 401).';
    if (status == 429 && code == 'daily_quota_exceeded') {
      return '100milionseek daily allowance is exhausted. It resets at 00:00 UTC.';
    }
    if (status == 429 && code == 'session_limit_reached') {
      return '100milionseek is handling its maximum of five parallel requests.';
    }
    if (status == 429) return '100milionseek rate limit reached. $detail';
    if (status == 503) return '100milionseek is temporarily busy or saturated.';
    if (status >= 500) return '100milionseek server error (HTTP $status).';
    return '100milionseek request failed (HTTP $status): $detail';
  }
}

class HmsRequestException implements Exception {
  const HmsRequestException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
