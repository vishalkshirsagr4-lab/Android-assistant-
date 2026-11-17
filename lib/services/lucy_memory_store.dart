import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A locally stored memory that Lucy saves only after an explicit user request.
class LucyMemory {
  final String id;
  final String type;
  final String text;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final double confidence;
  final String source;
  final bool userApproved;

  /// Backwards-compatible aliases used by the existing settings UI.
  String get category => type;
  String get content => text;
  DateTime get updatedAt => lastUsedAt;

  const LucyMemory({
    required this.id,
    required this.type,
    required this.text,
    required this.createdAt,
    required this.lastUsedAt,
    required this.confidence,
    required this.source,
    required this.userApproved,
  });

  factory LucyMemory.fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(
          json['createdAt']?.toString() ?? '',
        ) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final lastUsed = DateTime.tryParse(
          (json['lastUsedAt'] ?? json['updatedAt'])?.toString() ?? '',
        ) ??
        created;
    final rawType = (json['type'] ?? json['category'])?.toString() ?? 'fact';
    final rawText = (json['text'] ?? json['content'])?.toString() ?? '';
    return LucyMemory(
      id: json['id']?.toString() ?? '',
      type: _normalizeMemoryType(rawType),
      text: rawText,
      createdAt: created,
      lastUsedAt: lastUsed,
      confidence: ((json['confidence'] as num?)?.toDouble() ?? 1)
          .clamp(0, 1)
          .toDouble(),
      source: json['source']?.toString() ?? 'user_approved',
      userApproved: json['userApproved'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'lastUsedAt': lastUsedAt.toIso8601String(),
    'confidence': confidence,
    'source': source,
    'userApproved': userApproved,
  };
}

String _normalizeMemoryType(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    'preference' => 'preference',
    'routine' => 'routine',
    'person' || 'relationship' || 'contact' => 'person',
    'place' => 'place',
    _ => 'fact',
  };
}

/// Structured on-device memory. It has no arbitrary item-count cap: only
/// explicit user-approved details are stored, and only relevant entries are
/// selected for each model request.
class LucyMemoryStore {
  static const String _storageKey = 'lucy_structured_memories_v3';
  static const String _previousStorageKey = 'lucy_structured_memories_v2';
  static const String _legacyKey = 'lucy_user_approved_memories_v1';

  final SharedPreferences _prefs;
  final List<LucyMemory> _items = [];

  LucyMemoryStore(this._prefs);

  List<LucyMemory> get items => List.unmodifiable(_items);

  Future<void> initialize() async {
    _items.clear();
    final encoded = _prefs.getString(_storageKey) ??
        _prefs.getString(_previousStorageKey);
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is Map) {
              final item = LucyMemory.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (item.text.trim().isNotEmpty) _items.add(item);
            }
          }
        }
      } catch (_) {
        // Corrupt memory data must never prevent Lucy from starting.
        _items.clear();
      }
    }

    // Migrate the previous string-list format without losing user data.
    if (_items.isEmpty) {
      final legacy = _prefs.getStringList(_legacyKey) ?? const <String>[];
      for (final value in legacy) {
        final text = value.trim();
        if (text.isEmpty) continue;
        final now = DateTime.now();
        _items.add(
          LucyMemory(
            id: 'legacy_${now.microsecondsSinceEpoch}_${_items.length}',
            type: 'fact',
            text: text,
            createdAt: now,
            lastUsedAt: now,
            confidence: 1,
            source: 'legacy_user_approved',
            userApproved: true,
          ),
        );
      }
    }

    if (_items.isNotEmpty) await _persist();
  }

  Future<void> remember(
    String content, {
    String category = 'fact',
    String? type,
    double confidence = 1,
    String source = 'user_approved',
  }) async {
    final cleaned = content.trim();
    if (cleaned.isEmpty || cleaned.length > 240) return;
    final normalizedType = _normalizeMemoryType(type ?? category);
    final duplicate = _items.indexWhere(
      (item) =>
          item.type == normalizedType &&
          item.text.toLowerCase() == cleaned.toLowerCase(),
    );
    final now = DateTime.now();
    if (duplicate >= 0) {
      final old = _items.removeAt(duplicate);
      _items.insert(
        0,
        LucyMemory(
          id: old.id,
          type: old.type,
          text: cleaned,
          createdAt: old.createdAt,
          lastUsedAt: now,
          confidence: confidence.clamp(0, 1).toDouble(),
          source: source,
          userApproved: true,
        ),
      );
    } else {
      _items.insert(
        0,
        LucyMemory(
          id: 'mem_${now.microsecondsSinceEpoch}',
          type: normalizedType,
          text: cleaned,
          createdAt: now,
          lastUsedAt: now,
          confidence: confidence.clamp(0, 1).toDouble(),
          source: source,
          userApproved: true,
        ),
      );
    }
    await _persist();
  }

  Future<int> forgetMatching(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return 0;
    final before = _items.length;
    _items.removeWhere(
      (item) =>
          item.text.toLowerCase().contains(needle) ||
          item.type.toLowerCase() == needle,
    );
    final removed = before - _items.length;
    if (removed > 0) await _persist();
    return removed;
  }

  Future<void> clear() async {
    _items.clear();
    await _prefs.remove(_storageKey);
    await _prefs.remove(_previousStorageKey);
    await _prefs.remove(_legacyKey);
  }

  String get summary => _items
      .map((item) => '[${item.type}] ${item.text}')
      .join('\n');

  /// Select only the highest-relevance memories for the current request.
  /// Unicode tokenization keeps Hindi, Kannada, Japanese and Arabic searchable.
  String relevantContext(String query, {int limit = 6}) {
    if (_items.isEmpty || limit <= 0) return '';
    final queryTokens = _tokens(query);
    final now = DateTime.now();
    final ranked = _items.map((item) {
      final contentTokens = _tokens('${item.type} ${item.text}');
      final overlap = queryTokens.intersection(contentTokens).length;
      final ageDays = now.difference(item.lastUsedAt).inDays.clamp(0, 365);
      final recency = 1 / (1 + ageDays / 30);
      final score = overlap * 2 + item.confidence + recency * 0.25;
      return (item: item, score: score, matched: overlap > 0);
    }).toList()
      ..sort((a, b) {
        final scoreOrder = b.score.compareTo(a.score);
        return scoreOrder != 0
            ? scoreOrder
            : b.item.lastUsedAt.compareTo(a.item.lastUsedAt);
      });

    final selected = ranked
        .where((entry) => entry.matched)
        .take(limit)
        .map((entry) => entry.item)
        .toList();
    if (selected.isEmpty && queryTokens.isEmpty) {
      selected.addAll(_items.take(limit));
    }
    if (selected.isEmpty) return '';

    final selectedIds = selected.map((item) => item.id).toSet();
    for (var index = 0; index < _items.length; index++) {
      final item = _items[index];
      if (selectedIds.contains(item.id)) {
        _items[index] = LucyMemory(
          id: item.id,
          type: item.type,
          text: item.text,
          createdAt: item.createdAt,
          lastUsedAt: now,
          confidence: item.confidence,
          source: item.source,
          userApproved: item.userApproved,
        );
      }
    }
    unawaited(_persist());

    return selected
        .map(
          (item) =>
              '[type: ${item.type}; confidence: ${item.confidence.toStringAsFixed(2)}] ${item.text}',
        )
        .join('\n');
  }

  Set<String> _tokens(String value) {
    const ignored = {
      'the', 'and', 'for', 'with', 'that', 'this', 'what', 'when', 'where',
      'how', 'you', 'your', 'are', 'was', 'were', 'have', 'has', 'had',
      'from', 'about', 'please', 'lucy', 'remember', 'forget', 'tell', 'me',
      'my', 'is', 'a', 'an', 'to', 'of', 'in', 'on', 'it', 'i',
    };
    return RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .where((token) => token.length > 1 && !ignored.contains(token))
        .toSet();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _storageKey,
      jsonEncode(_items.map((item) => item.toJson()).toList()),
    );
    await _prefs.remove(_previousStorageKey);
    await _prefs.remove(_legacyKey);
  }
}
