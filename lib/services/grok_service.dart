import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// xAI/Grok provider. Credentials are stored in Android secure storage.
class GrokService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_xai_api_key';
  static const _endpoint = 'https://api.x.ai/v1/responses';
  static const _modelsEndpoint = 'https://api.x.ai/v1/models';
  static const _model = 'grok-4.7';

  /// Accept raw keys and common copied formats without storing wrapper text.
  String _normalizeApiKey(String input) {
    var value = input.trim();
    if (value.startsWith('Bearer ')) value = value.substring(7).trim();
    if (value.startsWith('XAI_API_KEY=')) {
      value = value.substring('XAI_API_KEY='.length).trim();
    }
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  Future<void> saveApiKey(String key) async {
    final value = _normalizeApiKey(key);
    if (value.isEmpty) throw ArgumentError('Paste your xAI API key.');
    await _storage.write(key: _keyName, value: value);
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.trim().isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  Future<void> validateApiKey(String apiKey) async {
    final key = _normalizeApiKey(apiKey);
    if (key.isEmpty) throw ArgumentError('Paste your xAI API key.');
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse(_modelsEndpoint),
        headers: {'Authorization': 'Bearer $key', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw GrokRequestException(
          _errorMessage(response.statusCode, response.body, checkingKey: true),
          response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) {
        throw const FormatException('xAI returned an unexpected models response.');
      }
      final models = data.whereType<Map>()
          .map((item) => item['id']?.toString()).whereType<String>().toSet();
      if (!models.contains(_model)) {
        throw const GrokRequestException(
          'The key works, but grok-4.7 is not listed for this xAI account.',
          403,
        );
      }
    } on TimeoutException {
      throw TimeoutException('xAI key check timed out. Check your connection.');
    } finally {
      client.close();
    }
  }

  Future<String> complete(
    String prompt, {
    String model = _model,
    String? systemPrompt,
    Uint8List? imageBytes,
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final storedKey = await _storage.read(key: _keyName);
    final key = storedKey == null ? null : _normalizeApiKey(storedKey);
    if (key == null || key.trim().isEmpty) {
      throw StateError('Add an xAI API key in Lucy Tools first.');
    }
    if (prompt.trim().isEmpty) throw ArgumentError('Prompt cannot be empty.');

    final userContent = <Map<String, dynamic>>[
      {'type': 'input_text', 'text': prompt.trim()},
    ];
    if (imageBytes != null) {
      userContent.add({
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
      });
    }

    // Keep the request to documented Responses API fields. JSON is requested
    // in the system prompt and parsed/validated by Lucy after the response.
    final input = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      input.add({'role': 'system', 'content': systemPrompt});
    }
    input.add({'role': 'user', 'content': userContent});

    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer ${key.trim()}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'model': model, 'input': input}),
      ).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GrokRequestException(
          _errorMessage(response.statusCode, response.body),
          response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('Grok returned an invalid response object.');
      }
      final output = decoded['output'];
      final result = StringBuffer();
      if (output is List) {
        for (final item in output.whereType<Map>()) {
          final parts = item['content'];
          if (parts is List) {
            for (final part in parts.whereType<Map>()) {
              if (part['type'] == 'output_text' && part['text'] is String) {
                result.write(part['text']);
              }
            }
          }
        }
      }
      final answer = result.toString().trim();
      if (answer.isEmpty) {
        throw FormatException(
          'Grok returned no text (status: ${decoded['status'] ?? 'unknown'}).',
        );
      }
      return answer;
    } on TimeoutException {
      throw TimeoutException('Grok request timed out. Check your connection and retry.');
    } finally {
      client.close();
    }
  }

  String _errorMessage(int status, String body, {bool checkingKey = false}) {
    String detail = '';
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      detail = error is Map
          ? (error['message']?.toString() ?? '')
          : (error?.toString() ?? '');
    } catch (_) {
      detail = body;
    }
    if (detail.length > 400) detail = detail.substring(0, 400);
    if (status == 400) {
      final lowerDetail = detail.toLowerCase();
      if (checkingKey && (lowerDetail.contains('incorrect api key') ||
          lowerDetail.contains('invalid api key') ||
          lowerDetail.contains('api key provided'))) {
        return 'This is not a valid xAI API key. Create one in the xAI Console API Keys page. A Grok app/X subscription or management key will not work. Paste only the key itself, without Bearer.';
      }
      return 'xAI rejected the request (HTTP 400). ' +
          (detail.isEmpty ? 'Check the request format.' : detail);
    }
    if (status == 401) return 'xAI rejected this API key (HTTP 401).';
    if (status == 403) return 'This xAI key does not have access (HTTP 403).';
    if (status == 404) return 'Grok model or API endpoint not found (HTTP 404).';
    if (status == 429) return 'xAI rate limit or account quota reached (HTTP 429).';
    if (status >= 500) return 'xAI service error (HTTP $status). Try again later.';
    return '${checkingKey ? 'xAI key check' : 'Grok request'} failed (HTTP $status). $detail';
  }
}

class GrokRequestException implements Exception {
  const GrokRequestException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
