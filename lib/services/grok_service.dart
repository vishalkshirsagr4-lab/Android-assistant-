import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Optional xAI/Grok text provider. API keys remain in secure device storage.
class GrokService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_xai_api_key';
  static const _endpoint = 'https://api.x.ai/v1/chat/completions';
  static const Duration defaultTimeout = Duration(seconds: 25);

  Future<void> saveApiKey(String key) async {
    final value = key.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(key, 'key', 'API key cannot be empty.');
    }
    await _storage.write(key: _keyName, value: value);
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  Future<String> complete(
    String prompt, {
    String model = 'grok-3-mini',
    Duration timeout = defaultTimeout,
  }) async {
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'Prompt cannot be empty.');
    }

    final key = await _storage.read(key: _keyName);
    if (key == null || key.isEmpty) {
      throw StateError('Add an xAI API key in Lucy settings first.');
    }

    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'user', 'content': normalizedPrompt},
              ],
              'temperature': 0.4,
            }),
          )
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = switch (response.statusCode) {
          401 => 'Grok rejected the API key. Check the key in Lucy settings.',
          403 => 'Grok access is not enabled for this API key.',
          429 => 'Grok rate limit reached. Wait a moment and try again.',
          >= 500 => 'Grok service is temporarily unavailable. Try again shortly.',
          _ => 'Grok request failed (HTTP ${response.statusCode}).',
        };
        throw GrokRequestException(message, response.statusCode);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Grok returned an invalid response.');
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const FormatException('Grok returned no answer.');
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException('Grok returned an empty answer.');
      }
      return content.trim();
    } on TimeoutException {
      throw TimeoutException(
        'Grok took too long to respond. Check your connection and retry.',
        timeout,
      );
    } finally {
      client.close();
    }
  }
}

class GrokRequestException implements Exception {
  const GrokRequestException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}
