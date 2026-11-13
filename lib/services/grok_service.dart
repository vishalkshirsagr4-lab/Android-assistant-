import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// xAI/Grok multimodal provider. API keys remain in secure device storage.
class GrokService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_xai_api_key';
  static const _endpoint = 'https://api.x.ai/v1/responses';
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

    final content = <Map<String, dynamic>>[
      {'type': 'input_text', 'text': normalizedPrompt},
    ];
    if (imageBytes != null) {
      content.add({
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
      });
    }

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
              if (systemPrompt != null && systemPrompt.isNotEmpty)
                'instructions': systemPrompt,
              'input': [
                {'role': 'user', 'content': content},
              ],
              'reasoning': {'effort': 'low'},
              'store': false,
            }),
          )
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        String detail = '';
        try {
          final errorBody = jsonDecode(response.body);
          final error = errorBody is Map ? errorBody['error'] : null;
          detail = error is Map
              ? (error['message']?.toString() ?? '')
              : (error?.toString() ?? '');
        } catch (_) {
          detail = response.body;
        }
        if (detail.length > 240) detail = detail.substring(0, 240);
        final message = switch (response.statusCode) {
          400 => 'Grok rejected the request format (HTTP 400). $detail',
          401 => 'Grok rejected the saved API key. Verify the xAI key in Lucy Tools.',
          403 => 'This xAI key does not have permission for the selected model.',
          404 => 'The selected Grok model or API endpoint was not found. Check the model ID.',
          429 => 'Grok rate limit or account quota reached. Check xAI billing and try later.',
          >= 500 => 'xAI is temporarily unavailable (HTTP ${response.statusCode}). Try again.',
          _ => 'Grok request failed (HTTP ${response.statusCode}). $detail',
        };
        throw GrokRequestException(message, response.statusCode);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Grok returned an invalid response.');
      }
      final output = decoded['output'];
      final text = StringBuffer();
      if (output is List) {
        for (final item in output.whereType<Map>()) {
          final parts = item['content'];
          if (parts is List) {
            for (final part in parts.whereType<Map>()) {
              if (part['type'] == 'output_text' && part['text'] is String) {
                text.write(part['text']);
              }
            }
          }
        }
      }
      final answer = text.toString().trim();
      if (answer.isEmpty) {
        final status = decoded['status']?.toString() ?? 'unknown';
        throw FormatException('Grok returned no text (response status: $status).');
      }
      return answer;
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
