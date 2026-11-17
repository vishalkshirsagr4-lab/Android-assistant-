import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Private, bounded JSON store for learned screen maps and safe workflows.
class LucyLearningStore {
  static const int maxUiMaps = 200;
  static const int maxSkills = 100;
  static const int maxElementsPerMap = 120;

  File? _file;
  Future<void> _writeQueue = Future<void>.value();
  final Map<String, Map<String, dynamic>> _uiMaps = <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _skills = <String, Map<String, dynamic>>{};

  List<Map<String, dynamic>> get uiMaps => List.unmodifiable(
        _uiMaps.values.map((value) => Map<String, dynamic>.from(value)),
      );

  List<Map<String, dynamic>> get skills => List.unmodifiable(
        _skills.values.map((value) => Map<String, dynamic>.from(value)),
      );

  Future<void> initialize() async {
    final directory = await getApplicationDocumentsDirectory();
    _file = File(directory.path + '/lucy_learning_v1.json');
    if (!await _file!.exists()) return;
    try {
      final decoded = jsonDecode(await _file!.readAsString());
      if (decoded is! Map) return;
      final maps = decoded['uiMaps'];
      if (maps is List) {
        for (final value in maps.whereType<Map>()) {
          final item = Map<String, dynamic>.from(value);
          final key = item['key']?.toString() ?? '';
          if (key.isNotEmpty) _uiMaps[key] = item;
        }
      }
      final savedSkills = decoded['skills'];
      if (savedSkills is List) {
        for (final value in savedSkills.whereType<Map>()) {
          final item = Map<String, dynamic>.from(value);
          final id = item['id']?.toString() ?? '';
          if (id.isNotEmpty) _skills[id] = item;
        }
      }
      _trimLru();
    } catch (_) {
      _uiMaps.clear();
      _skills.clear();
    }
  }

  Future<void> recordUiMap({
    required String packageName,
    required String signature,
    required List<Map<String, dynamic>> elements,
    String appVersionCode = 'unknown',
    Map<String, double>? screenSize,
  }) async {
    if (packageName.isEmpty || signature.isEmpty) return;
    final key = packageName + '::' + signature;
    final now = DateTime.now().toIso8601String();
    final width = screenSize?['width'] ?? 1;
    final height = screenSize?['height'] ?? 1;
    final selected = elements.take(maxElementsPerMap).map((element) {
      final bounds = element['bounds'];
      Map<String, dynamic> normalizedBounds = <String, dynamic>{};
      if (bounds is Map) {
        double? ratio(dynamic value, double dimension) {
          if (value is! num || dimension <= 0) return null;
          return (value.toDouble() / dimension).clamp(0, 1).toDouble();
        }

        normalizedBounds = <String, dynamic>{
          'cx': ratio(bounds['cx'], width),
          'cy': ratio(bounds['cy'], height),
          'width': ratio(bounds['w'], width),
          'height': ratio(bounds['h'], height),
        };
      }
      return <String, dynamic>{
        'resourceId': element['resourceId']?.toString() ?? '',
        'text': _clip(element['text']),
        'desc': _clip(element['desc']),
        'class': (element['class'] ?? element['type'])?.toString() ?? '',
        'bounds01': normalizedBounds,
        'clickable': element['clickable'] == true,
        'editable': element['editable'] == true,
        'scrollable': element['scrollable'] == true,
      };
    }).toList();

    final previous = _uiMaps[key];
    _uiMaps.remove(key);
    _uiMaps[key] = <String, dynamic>{
      'key': key,
      'package': packageName,
      'appVersionCode': appVersionCode,
      'signature': signature,
      'elements': selected,
      'scrollContainers': selected
          .where((element) => element['scrollable'] == true)
          .toList(),
      'searchBoxes': selected.where((element) {
        final labels = (element['resourceId'].toString() + ' ' +
                element['text'].toString() + ' ' +
                element['desc'].toString())
            .toLowerCase();
        return element['editable'] == true || labels.contains('search');
      }).toList(),
      'actionTargets': selected.where((element) {
        final labels = (element['resourceId'].toString() + ' ' +
                element['text'].toString() + ' ' +
                element['desc'].toString())
            .toLowerCase();
        return labels.contains('send') ||
            labels.contains('skip') ||
            labels.contains('close') ||
            labels.contains('search');
      }).toList(),
      'createdAt': previous?['createdAt'] ?? now,
      'lastUsedAt': now,
      'successCount': previous?['successCount'] ?? 0,
    };
    _trimLru();
    await _persist();
  }

  Future<void> recordSkill({
    required String id,
    required String command,
    String? commandTemplate,
    required String packageName,
    required String startSignature,
    required List<Map<String, dynamic>> actions,
    String appVersionCode = 'unknown',
  }) async {
    final normalized = normalizeCommand(command);
    if (normalized.isEmpty || packageName.isEmpty || actions.isEmpty) return;
    const allowed = <String>{
      'open_app',
      'tap',
      'back',
      'home',
      'scroll_to_end',
      'scroll_to_top',
      'read_all',
    };
    final safeActions = actions.where((action) {
      final type = action['type']?.toString() ?? '';
      if (!allowed.contains(type) &&
          !(type == 'type' && action['parameter'] == 'query')) {
        return false;
      }
      if (type == 'tap') {
        return (action['resourceId']?.toString().isNotEmpty ?? false) ||
            (action['label']?.toString().isNotEmpty ?? false);
      }
      if (type == 'open_app') {
        return action['package']?.toString().isNotEmpty ?? false;
      }
      return true;
    }).take(12).map((value) => Map<String, dynamic>.from(value)).toList();

    if (safeActions.isEmpty || safeActions.length != actions.length) return;
    if (safeActions.any((action) => action['type'] == 'type') &&
        !(commandTemplate?.contains('{query}') ?? false)) {
      return;
    }

    final now = DateTime.now().toIso8601String();
    final existing = _skills[id];
    final sameSequence = existing != null &&
        jsonEncode(existing['actions']) == jsonEncode(safeActions);
    final successCount = sameSequence
        ? ((existing['successCount'] as num?) ?? 0).toInt() + 1
        : 1;
    _skills.remove(id);
    _skills[id] = <String, dynamic>{
      'id': id,
      'command': normalized,
      'commandTemplate': commandTemplate ?? normalized,
      'package': packageName,
      'appVersionCode': appVersionCode,
      'startSignature': startSignature,
      'actions': safeActions,
      // A skill becomes eligible for approval only after the same sequence
      // has succeeded twice. A changed sequence resets approval and count.
      'successCount': successCount,
      'failureCount': sameSequence
          ? ((existing['failureCount'] as num?) ?? 0).toInt()
          : 0,
      'approved': sameSequence && existing['approved'] == true,
      'createdAt': existing?['createdAt'] ?? now,
      'lastUsedAt': now,
    };
    _trimLru();
    await _persist();
  }

  Future<Map<String, dynamic>?> findSkill({
    required String command,
    required String packageName,
    required String startSignature,
    String appVersionCode = 'unknown',
  }) async {
    final normalized = normalizeCommand(command);
    var invalidated = false;
    for (final entry in _skills.entries.toList().reversed) {
      final skill = entry.value;
      if (skill['approved'] != true ||
          ((skill['successCount'] as num?) ?? 0).toInt() < 2) {
        continue;
      }
      if (skill['package'] != packageName) continue;
      final template = skill['commandTemplate']?.toString() ??
          skill['command']?.toString() ??
          '';
      final parameters = _matchCommandTemplate(template, normalized);
      if (parameters == null) continue;
      final version = skill['appVersionCode']?.toString() ?? 'unknown';
      if (version != 'unknown' &&
          appVersionCode != 'unknown' &&
          version != appVersionCode) {
        _skills.remove(entry.key);
        invalidated = true;
        continue;
      }
      if (skill['startSignature'] != startSignature) continue;
      skill['lastUsedAt'] = DateTime.now().toIso8601String();
      _skills.remove(entry.key);
      _skills[entry.key] = skill;
      await _persist();
      return <String, dynamic>{...skill, 'parameters': parameters};
    }
    if (invalidated) await _persist();
    return null;
  }

  Map<String, String>? _matchCommandTemplate(
    String template,
    String normalizedCommand,
  ) {
    const placeholder = '{query}';
    if (!template.contains(placeholder)) {
      return normalizeCommand(template) == normalizedCommand
          ? <String, String>{}
          : null;
    }
    final parts = template.split(placeholder);
    if (parts.length != 2) return null;
    final prefix = normalizeCommand(parts.first);
    final suffix = normalizeCommand(parts.last);
    final pattern = RegExp(
      '^' + RegExp.escape(prefix) + '(.+?)' + RegExp.escape(suffix) + r'$',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(normalizedCommand);
    if (match == null) return null;
    final query = match.group(1)?.trim() ?? '';
    return query.isEmpty ? null : <String, String>{'query': query};
  }

  /// User approval is required before any learned workflow can replay.
  /// The exact same workflow must have succeeded at least twice first.
  Future<bool> setSkillApproved(
    String id, {
    required bool approved,
  }) async {
    final skill = _skills[id];
    if (skill == null) return false;
    final successfulRuns = ((skill['successCount'] as num?) ?? 0).toInt();
    if (approved && successfulRuns < 2) return false;
    skill['approved'] = approved;
    skill['lastUsedAt'] = DateTime.now().toIso8601String();
    await _persist();
    return true;
  }

  Future<void> markSkillResult(String id, {required bool success}) async {
    final skill = _skills[id];
    if (skill == null) return;
    final key = success ? 'successCount' : 'failureCount';
    skill[key] = ((skill[key] as num?) ?? 0).toInt() + 1;
    skill['lastUsedAt'] = DateTime.now().toIso8601String();
    if (!success && (skill['failureCount'] as int) >= 2) {
      _skills.remove(id);
    }
    await _persist();
  }

  Future<int> forgetAppLayout(String packageName) async {
    final keys = _uiMaps.entries
        .where((entry) => entry.value['package'] == packageName)
        .map((entry) => entry.key)
        .toList();
    for (final key in keys) {
      _uiMaps.remove(key);
    }
    if (keys.isNotEmpty) await _persist();
    return keys.length;
  }

  Future<bool> forgetSkill(String nameOrId) async {
    final query = nameOrId.trim().toLowerCase();
    final matches = _skills.entries
        .where((entry) =>
            entry.key.toLowerCase() == query ||
            entry.value['command']?.toString().toLowerCase() == query)
        .map((entry) => entry.key)
        .toList();
    for (final key in matches) {
      _skills.remove(key);
    }
    if (matches.isNotEmpty) await _persist();
    return matches.isNotEmpty;
  }

  Future<void> clear() async {
    _uiMaps.clear();
    _skills.clear();
    final file = _file;
    if (file != null && await file.exists()) await file.delete();
  }

  static String normalizeCommand(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String stableSignature({
    required String packageName,
    required List<Map<String, dynamic>> elements,
  }) {
    final stable = elements.map((element) {
      final id = element['resourceId']?.toString() ?? '';
      final label = (element['text'] ?? element['desc'])?.toString() ?? '';
      final type = (element['class'] ?? element['type'])?.toString() ?? '';
      return id + '|' + label + '|' + type;
    }).where((value) => value != '||').take(160).toList()..sort();
    final input = packageName + '|' + stable.join(';');
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _clip(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.length <= 180 ? text : text.substring(0, 180);
  }

  void _trimLru() {
    while (_uiMaps.length > maxUiMaps) {
      _uiMaps.remove(_uiMaps.keys.first);
    }
    while (_skills.length > maxSkills) {
      _skills.remove(_skills.keys.first);
    }
  }

  Future<void> _persist() {
    final file = _file;
    if (file == null) return Future<void>.value();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        'version': 1,
        'uiMaps': _uiMaps.values.toList(),
        'skills': _skills.values.toList(),
      };
      final temp = File(file.path + '.tmp');
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(file.path);
    });
    return _writeQueue;
  }
}
