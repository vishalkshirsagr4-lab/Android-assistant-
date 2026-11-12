import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Optional xAI/Grok text provider. Keys remain in Android secure storage and
/// are never written to preferences, logs, analytics or source control.
class GrokService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'lucy_xai_api_key';
  static const _endpoint = 'https://api.x.ai/v1/chat/completions';

  Future<void> saveApiKey(String key) async {
    final value = key.trim();
    if (value.isEmpty) {
      await _storage.delete(key: _keyName);
    } else {
      await _storage.write(key: _keyName, value: value);
    }
  }

  Future<bool> isConfigured() async =>
      (await _storage.read(key: _keyName))?.isNotEmpty ?? false;

  Future<void> clearApiKey() => _storage.delete(key: _keyName);

  Future<String> complete(String prompt, {String model = 'grok-3-mini'}) async {
    final key = await _storage.read(key: _keyName);
    if (key == null || key.isEmpty) {
      throw StateError('Add an xAI API key in Lucy settings first.');
    }
    final client = http.Client();
    try {
      final response = await client.post(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.4,
        }),
      ).timeout(const Duration(seconds: 35));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Grok request failed (HTTP ${response.statusCode}).');
      }
      final data = jsonDecode(response.body);
      final content = data['choices']?[0]?['message']?['content'];
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException('Grok returned an empty response.');
      }
      return content.trim();
    } finally {
      client.close();
    }
  }
}
