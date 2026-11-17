import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Persistent, bounded UI knowledge and replayable low-risk workflows.
class LucyLearningStore {
  static const int maxUiMaps = 200;
  static const int maxSkills = 100;
  static const int maxElementsPerMap = 120;
  File? _file;
  final Map<String, Map<String, dynamic>> _uiMaps = {};
  final Map<String, Map<String, dynamic>> _skills = {};

  List<Map<String, dynamic>> get uiMaps =>
      List.unmodifiable(_uiMaps.values.map((e) => Map<String, dynamic>.from(e)));
  List<Map<String, dynamic>> get skills =>
      List.unmodifiable(_skills.values.map((e) => Map<String, dynamic>.from(e)));

  Future<void> initialize() async {
    final directory = await getApplicationDocumentsDirectory();
    _file = File('\${directory.path}/lucy_learning_v1.json');
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
      final skills = decoded['skills'];
      if (skills is List) {
        for (final value in skills.whereType<Map>()) {
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
    final key = '$packageName::$signature';
    final now = DateTime.now().toIso8601String();
    final width = screenSize?['width'] ?? 1;
    final height = screenSize?['height'] ?? 1;
    final selected = elements.take(maxElementsPerMap).map((element) {
      final bounds = element['bounds'];
      Map<String, dynamic> normalizedBounds = {};
      if (bounds is Map) {
        double? ratio(dynamic value, double dimension) =>
            value is num && dimension > 0
                ? (value.toDouble() / dimension).clamp(0, 1).toDouble()
                : null;
        normalizedBounds = {
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
        'class': element['class']?.toString() ?? '',
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
      'scrollContainers': selected.where((e) => e['scrollable'] == true).toList(),
      'searchBoxes': selected.where((e) => e['editable'] == true ||
          '\${e['resourceId']} \${e['text']} \${e['desc']}'.toLowerCase().contains('search')).toList(),
      'actionTargets': selected.where((e) {
        final label = '\${e['resourceId']} \${e['text']} \${e['desc']}'.toLowerCase();
        return label.contains('send') || label.contains('skip') ||
            label.contains('close') || label.contains('search');
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
    required String packageName,
    required String startSignature,
    required List<Map<String, dynamic>> actions,
    String appVersionCode = 'unknown',
  }) async {
    final normalized = normalizeCommand(command);
    if (normalized.isEmpty || packageName.isEmpty || actions.isEmpty) return;
    const allowed = <String>{
      'open_app', 'tap', 'back', 'home', 'scroll_to_end',
      'scroll_to_top', 'read_all',
    };
    final safeActions = actions.where((action) {
      final type = action['type']?.toString() ?? '';
      if (!allowed.contains(type)) return false;
      if (type == 'tap') {
        return (action['resourceId']?.toString().isNotEmpty ?? false) ||
            (action['label']?.toString().isNotEmpty ?? false);
      }
      if (type == 'open_app') return (action['package']?.toString().isNotEmpty ?? false);
      return true;
    }).take(12).map((e) => Map<String, dynamic>.from(e)).toList();
    if (safeActions.isEmpty || safeActions.length != actions.length) return;
    final now = DateTime.now().toIso8601String();
    final existing = _skills[id];
    _skills.remove(id);
    _skills[id] = <String, dynamic>{
      'id': id,
      'command': normalized,
      'package': packageName,
      'appVersionCode': appVersionCode,
      'startSignature': startSignature,
      'actions': safeActions,
      'successCount': (existing?['successCount'] as num? ?? 0).toInt() + 1,
      'failureCount': (existing?['failureCount'] as num? ?? 0).toInt(),
      'createdAt': existing?['createdAt'] ?? now,
      'lastUsedAt': now,
    };
    _trimLru();
    await _persist();
  }

  Map<String, dynamic>? findSkill({
    required String command,
    required String packageName,
    required String startSignature,
    String appVersionCode = 'unknown',
  }) {
    final normalized = normalizeCommand(command);
    for (final entry in _skills.entries.toList().reversed) {
      final skill = entry.value;
      if (skill['command'] != normalized || skill['package'] != packageName) continue;
      final version = skill['appVersionCode']?.toString() ?? 'unknown';
      if (version != 'unknown' && appVersionCode != 'unknown' && version != appVersionCode) {
        _skills.remove(entry.key);
        continue;
      }
      if (skill['startSignature'] != startSignature) continue;
      skill['lastUsedAt'] = DateTime.now().toIso8601String();
      return Map<String, dynamic>.from(skill);
    }
    return null;
  }

  Future<void> markSkillResult(String id, {required bool success}) async {
    final skill = _skills[id];
    if (skill == null) return;
    final key = success ? 'successCount' : 'failureCount';
    skill[key] = ((skill[key] as num?) ?? 0).toInt() + 1;
    skill['lastUsedAt'] = DateTime.now().toIso8601String();
    if (!success && (skill['failureCount'] as int) >= 2) _skills.remove(id);
    await _persist();
  }

  Future<int> forgetAppLayout(String packageName) async {
    final keys = _uiMaps.entries.where((entry) => entry.value['package'] == packageName)
        .map((entry) => entry.key).toList();
    for (final key in keys) { _uiMaps.remove(key); }
    if (keys.isNotEmpty) await _persist();
    return keys.length;
  }

  Future<bool> forgetSkill(String nameOrId) async {
    final query = nameOrId.trim().toLowerCase();
    final matches = _skills.entries.where((entry) =>
        entry.key.toLowerCase() == query ||
        entry.value['command']?.toString().toLowerCase() == query)
        .map((e) => e.key).toList();
    for (final key in matches) { _skills.remove(key); }
    if (matches.isNotEmpty) await _persist();
    return matches.isNotEmpty;
  }

  Future<void> clear() async {
    _uiMaps.clear();
    _skills.clear();
    final file = _file;
    if (file != null && await file.exists()) await file.delete();
  }

  static String normalizeCommand(String value) => value.toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ').trim();

  static String stableSignature({
    required String packageName,
    required List<Map<String, dynamic>> elements,
  }) {
    final stable = elements.map((element) {
      final id = element['resourceId']?.toString() ?? '';
      final label = (element['text'] ?? element['desc'])?.toString() ?? '';
      final type = element['class']?.toString() ?? '';
      return '$id|$label|$type';
    }).where((value) => value != '||').take(160).toList()..sort();
    final input = '$packageName|\${stable.join(';')}';
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
    while (_uiMaps.length > maxUiMaps) _uiMaps.remove(_uiMaps.keys.first);
    while (_skills.length > maxSkills) _skills.remove(_skills.keys.first);
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final payload = {
      'version': 1,
      'uiMaps': _uiMaps.values.toList(),
      'skills': _skills.values.toList(),
    };
    final temp = File('\${file.path}.tmp');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename(file.path);
  }
}
