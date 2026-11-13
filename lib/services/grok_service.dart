import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// xAI/Grok multimodal provider. API keys remain in secure device storage.
class GrokService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_xai_api_key';
  static const _endpoint = 'https://api.x.ai/v1/chat/completions';
  static const _modelsEndpoint = 'https://api.x.ai/v1/models';
  // Reasoning models can take several minutes. Keep this configurable per call.
  static const Duration defaultTimeout = Duration(seconds: 900);
  static const Duration validationTimeout = Duration(seconds: 25);

  Future<void> saveApiKey(String key) async {
    final value = key.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(key, 'key', 'API key cannot be empty.');
    }
    await _storage.write(key: _keyName, value: value);
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.trim().isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  /// Verifies the credential with xAI and confirms that the selected model is
  /// available to that key before Lucy switches providers.
  Future<void> validateApiKey(
    String apiKey, {
    String model = 'grok-4.7',
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'Paste your xAI API key.');
    }
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(_modelsEndpoint),
            headers: {
              'Authorization': 'Bearer $key',
              'Accept': 'application/json',
            },
          )
          .timeout(validationTimeout);
      if (response.statusCode == 401) {
        throw const GrokRequestException(
          'xAI rejected this API key. Check that you copied the complete key.',
          401,
        );
      }
      if (response.statusCode == 403) {
        throw const GrokRequestException(
          'This xAI key does not have permission to access the API.',
          403,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GrokRequestException(
          'Could not verify the xAI key (HTTP ${response.statusCode}).',
          response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) {
        throw const FormatException('xAI returned an unexpected models response.');
      }
      final available = data
          .whereType<Map>()
          .map((item) => item['id']?.toString())
          .whereType<String>()
          .toSet();
      if (!available.contains(model)) {
        throw GrokRequestException(
          'The key is valid, but model "$model" is not available to this xAI account. '
          'Check model access in the xAI console.',
          403,
        );
      }
    } on TimeoutException {
      throw TimeoutException('xAI key verification timed out. Check your connection.');
    } finally {
      client.close();
    }
  }

  Future<String> complete(
    String prompt, {
    String model = 'grok-4.7',
    String? systemPrompt,
    Uint8List? imageBytes,
    Duration timeout = defaultTimeout,
  }) async {
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'Prompt cannot be empty.');
    }

    final key = await _storage.read(key: _keyName);
    if (key == null || key.trim().isEmpty) {
      throw StateError('Add and verify an xAI API key in Lucy Tools first.');
    }

    final messages = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }

    final userContent = imageBytes == null
        ? normalizedPrompt
        : <Map<String, dynamic>>[
            {'type': 'text', 'text': normalizedPrompt},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
                'detail': 'auto',
              },
            },
          ];
    messages.add({'role': 'user', 'content': userContent});

    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer ${key.trim()}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': messages,
              'temperature': 0.7,
              'top_p': 0.95,
              'stream': false,
              'response_format': {'type': 'json_object'},
            }),
          )
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = switch (response.statusCode) {
          401 => 'Grok rejected the saved API key. Open Lucy Tools and verify it again.',
          403 => 'Grok access is not enabled for this key or model.',
          429 => 'Grok rate limit reached. Wait briefly and try again.',
          >= 500 => 'xAI is temporarily unavailable (HTTP ${response.statusCode}). Try again.',
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
        'Grok is still taking longer than expected. Lucy will not treat this as an invalid API key; check your connection and retry.',
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
