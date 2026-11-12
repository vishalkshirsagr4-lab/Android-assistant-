import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LucyUpdateInfo {
  const LucyUpdateInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
  });

  final String version;
  final String notes;
  final String downloadUrl;
}

class AppUpdateService {
  AppUpdateService();

  static const _channel = MethodChannel('com.poc.screen_aware_ai/updater');
  static const _releaseApi =
      'https://api.github.com/repos/vishalkshirsagr4-lab/Android-assistant-/releases/latest';
  static const _pendingApkKey = 'lucy_pending_update_apk';
  static const _pendingVersionKey = 'lucy_pending_update_version';
  static const _permissionPendingKey = 'lucy_update_permission_pending';

  Future<LucyUpdateInfo?> checkForUpdate() async {
    final response = await http.get(
      Uri.parse(_releaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      },
    ).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw HttpException(
        'GitHub release check failed (HTTP ${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GitHub returned an invalid release response.');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) return null;

    final rawTag = decoded['tag_name'];
    if (rawTag is! String || rawTag.trim().isEmpty) {
      throw const FormatException('The latest release has no version tag.');
    }
    final tag = rawTag.trim().startsWith('v')
        ? rawTag.trim().substring(1)
        : rawTag.trim();

    final installed = await _channel.invokeMapMethod<String, String>(
      'getInstalledVersion',
    );
    final installedVersion = installed?['versionName'];
    if (installedVersion == null || installedVersion.isEmpty) {
      throw const PlatformException(
        code: 'VERSION_UNAVAILABLE',
        message: 'Lucy could not read its installed version.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final pendingVersion = prefs.getString(_pendingVersionKey);
    if (pendingVersion != null && !_isNewer(pendingVersion, installedVersion)) {
      await clearPendingInstall();
    }
    if (!_isNewer(tag, installedVersion)) return null;

    final assets = decoded['assets'];
    if (assets is! List) {
      throw const FormatException('The latest release has no APK assets.');
    }

    Map<String, dynamic>? apk;
    for (final item in assets) {
      if (item is Map<String, dynamic> &&
          item['name'] == 'lucy-latest.apk' &&
          item['state'] == 'uploaded') {
        apk = item;
        break;
      }
    }
    if (apk == null || apk['browser_download_url'] is! String) {
      throw const FormatException(
        'The latest release is missing the uploaded lucy-latest.apk.',
      );
    }

    return LucyUpdateInfo(
      version: tag,
      notes: (decoded['body'] as String? ?? '').trim(),
      downloadUrl: apk['browser_download_url'] as String,
    );
  }

  Future<bool> downloadAndInstall(LucyUpdateInfo update) async {
    final directory = await getTemporaryDirectory();
    final apkFile = File('${directory.path}/lucy-update-${update.version}.apk');

    if (await apkFile.exists()) {
      await apkFile.delete();
    }

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(update.downloadUrl))
        ..headers['Accept'] = 'application/octet-stream';
      final response = await client.send(request).timeout(
        const Duration(minutes: 4),
      );
      if (response.statusCode != 200) {
        throw HttpException('APK download failed (HTTP ${response.statusCode}).');
      }

      sink = apkFile.openWrite();
      await response.stream.pipe(sink);
      sink = null; // Stream.pipe closes the sink after the stream completes.

      final size = await apkFile.length();
      if (size < 1024) {
        throw const FormatException('The downloaded APK is empty or incomplete.');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingApkKey, apkFile.path);
      await prefs.setString(_pendingVersionKey, update.version);
      return _installPendingIfAllowed();
    } catch (_) {
      if (sink != null) {
        await sink.close();
      }
      if (await apkFile.exists()) {
        await apkFile.delete();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _installPendingIfAllowed() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_pendingApkKey);
    if (path == null || path.isEmpty) return false;

    final apk = File(path);
    if (!await apk.exists() || await apk.length() < 1024) {
      await _clearPendingInstall(prefs, apk);
      throw const FileSystemException('The saved update APK is no longer available.');
    }

    final canInstall =
        await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (!canInstall) {
      await prefs.setBool(_permissionPendingKey, true);
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
      return false;
    }

    await prefs.setBool(_permissionPendingKey, false);
    await _channel.invokeMethod<void>('installApk', {'path': path});
    // Keep the pending path until Android returns to Lucy. If the installer is
    // cancelled, the user can retry without downloading the APK again.
    return true;
  }

  Future<void> resumePendingInstall() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_permissionPendingKey) != true) return;

    final path = prefs.getString(_pendingApkKey);
    if (path == null || path.isEmpty) return;

    final apk = File(path);
    if (!await apk.exists() || await apk.length() < 1024) {
      await _clearPendingInstall(prefs, apk);
      return;
    }

    final canInstall =
        await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (canInstall) {
      await prefs.setBool(_permissionPendingKey, false);
      await _channel.invokeMethod<void>('installApk', {'path': path});
    }
  }

  Future<void> clearPendingInstall() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_pendingApkKey);
    await _clearPendingInstall(
      prefs,
      path == null ? null : File(path),
    );
  }

  Future<void> _clearPendingInstall(
    SharedPreferences prefs,
    File? apk,
  ) async {
    await prefs.remove(_pendingApkKey);
    await prefs.remove(_pendingVersionKey);
    await prefs.remove(_permissionPendingKey);
    if (apk != null && await apk.exists()) {
      await apk.delete();
    }
  }

  static bool _isNewer(String remote, String local) {
    final pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$');
    final remoteMatch = pattern.firstMatch(remote);
    final localMatch = pattern.firstMatch(local);
    if (remoteMatch == null || localMatch == null) return false;

    for (var i = 1; i <= 3; i++) {
      final a = int.parse(remoteMatch.group(i)!);
      final b = int.parse(localMatch.group(i)!);
      if (a != b) return a > b;
    }

    final remotePre = remoteMatch.group(4);
    final localPre = localMatch.group(4);
    if (remotePre == localPre) return false;
    if (remotePre == null) return true;
    if (localPre == null) return false;

    final remoteParts = remotePre.split('.');
    final localParts = localPre.split('.');
    for (var i = 0; i < remoteParts.length && i < localParts.length; i++) {
      final a = remoteParts[i];
      final b = localParts[i];
      if (a == b) continue;
      final ai = int.tryParse(a);
      final bi = int.tryParse(b);
      if (ai != null && bi != null) return ai > bi;
      if (ai != null) return true;
      if (bi != null) return false;
      return a.compareTo(b) > 0;
    }
    return remoteParts.length > localParts.length;
  }
}
