import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A locally stored memory that Lucy saves only after an explicit user request.
class LucyMemory {
  final String id;
  final String category;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double confidence;
  final bool userApproved;

  const LucyMemory({
    required this.id,
    required this.category,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    required this.confidence,
    required this.userApproved,
  });

  factory LucyMemory.fromJson(Map<String, dynamic> json) {
    return LucyMemory(
      id: json['id']?.toString() ?? '',
      category: json['category']?.toString() ?? 'fact',
      content: json['content']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1,
      userApproved: json['userApproved'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'confidence': confidence,
    'userApproved': userApproved,
  };
}

/// Structured, bounded, on-device memory. It never learns from conversation
/// history automatically; callers must pass an explicit user-approved fact.
class LucyMemoryStore {
  static const String _storageKey = 'lucy_structured_memories_v2';
  static const String _legacyKey = 'lucy_user_approved_memories_v1';
  static const int _maxMemories = 50;
  final SharedPreferences _prefs;
  final List<LucyMemory> _items = [];

  LucyMemoryStore(this._prefs);

  List<LucyMemory> get items => List.unmodifiable(_items);

  Future<void> initialize() async {
    _items.clear();
    final encoded = _prefs.getString(_storageKey);
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is Map) {
              final item = LucyMemory.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (item.content.trim().isNotEmpty) _items.add(item);
            }
          }
        }
      } catch (_) {
        // A corrupt memory file must not prevent Lucy from starting.
        _items.clear();
      }
    }

    // Migrate the previous explicit-memory list without losing user data.
    if (_items.isEmpty) {
      final legacy = _prefs.getStringList(_legacyKey) ?? const <String>[];
      for (final value in legacy) {
        final content = value.trim();
        if (content.isEmpty) continue;
        final now = DateTime.now();
        _items.add(
          LucyMemory(
            id: 'legacy_${now.microsecondsSinceEpoch}_${_items.length}',
            category: 'fact',
            content: content,
            createdAt: now,
            updatedAt: now,
            confidence: 1,
            userApproved: true,
          ),
        );
      }
      if (_items.isNotEmpty) await _persist();
    }
  }

  Future<void> remember(
    String content, {
    String category = 'fact',
    double confidence = 1,
  }) async {
    final cleaned = content.trim();
    if (cleaned.isEmpty || cleaned.length > 240) return;
    final normalizedCategory = _normalizeCategory(category);
    final duplicate = _items.indexWhere(
      (item) =>
          item.category == normalizedCategory &&
          item.content.toLowerCase() == cleaned.toLowerCase(),
    );
    final now = DateTime.now();
    if (duplicate >= 0) {
      final old = _items.removeAt(duplicate);
      _items.insert(
        0,
        LucyMemory(
          id: old.id,
          category: old.category,
          content: cleaned,
          createdAt: old.createdAt,
          updatedAt: now,
          confidence: confidence.clamp(0, 1).toDouble(),
          userApproved: true,
        ),
      );
    } else {
      _items.insert(
        0,
        LucyMemory(
          id: 'mem_${now.microsecondsSinceEpoch}',
          category: normalizedCategory,
          content: cleaned,
          createdAt: now,
          updatedAt: now,
          confidence: confidence.clamp(0, 1).toDouble(),
          userApproved: true,
        ),
      );
    }
    if (_items.length > _maxMemories) {
      _items.removeRange(_maxMemories, _items.length);
    }
    await _persist();
  }

  Future<int> forgetMatching(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return 0;
    final before = _items.length;
    _items.removeWhere(
      (item) =>
          item.content.toLowerCase().contains(needle) ||
          item.category.toLowerCase() == needle,
    );
    final removed = before - _items.length;
    if (removed > 0) await _persist();
    return removed;
  }

  Future<void> clear() async {
    _items.clear();
    await _prefs.remove(_storageKey);
    await _prefs.remove(_legacyKey);
  }

  String get summary =>
      _items.map((item) => '[${item.category}] ${item.content}').join('\n');

  /// Return a small relevance-ranked subset instead of uploading all memories.
  String relevantContext(String query, {int limit = 6}) {
    if (_items.isEmpty) return '';
    final queryTokens = _tokens(query);
    final ranked =
        _items.map((item) {
          final contentTokens = _tokens('${item.category} ${item.content}');
          final overlap = queryTokens.intersection(contentTokens).length;
          return (item: item, score: overlap);
        }).toList()..sort((a, b) {
          final scoreOrder = b.score.compareTo(a.score);
          return scoreOrder != 0
              ? scoreOrder
              : b.item.updatedAt.compareTo(a.item.updatedAt);
        });

    final selected = ranked
        .where((entry) => entry.score > 0)
        .take(limit)
        .map((entry) => entry.item)
        .toList();
    if (selected.isEmpty && queryTokens.isEmpty) {
      selected.addAll(_items.take(limit));
    }
    return selected
        .map(
          (item) =>
              '[${item.category}; confidence ${item.confidence.toStringAsFixed(2)}] ${item.content}',
        )
        .join('\n');
  }

  Set<String> _tokens(String value) {
    const ignored = {
      'the',
      'and',
      'for',
      'with',
      'that',
      'this',
      'what',
      'when',
      'where',
      'how',
      'you',
      'your',
      'are',
      'was',
      'were',
      'have',
      'has',
      'had',
      'from',
      'about',
      'please',
      'lucy',
      'remember',
      'forget',
      'tell',
      'me',
      'my',
      'is',
      'a',
      'an',
      'to',
      'of',
      'in',
      'on',
      'it',
      'i',
    };
    return RegExp(r'[a-z0-9]+')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .where((token) => token.length > 1 && !ignored.contains(token))
        .toSet();
  }

  String _normalizeCategory(String value) {
    const allowed = {'fact', 'preference', 'routine', 'relationship', 'goal'};
    final normalized = value.trim().toLowerCase();
    return allowed.contains(normalized) ? normalized : 'fact';
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _storageKey,
      jsonEncode(_items.map((item) => item.toJson()).toList()),
    );
    await _prefs.remove(_legacyKey);
  }
}
