import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef UpdateProgressCallback = void Function(int received, int? total);

class LucyUpdateInfo {
  const LucyUpdateInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.expectedSha256,
    required this.expectedSize,
  });

  final String version;
  final String notes;
  final String downloadUrl;
  final String? expectedSha256;
  final int? expectedSize;
}

class AppUpdateService {
  AppUpdateService();

  static const _channel = MethodChannel('com.poc.screen_aware_ai/updater');
  static const _releaseApi =
      'https://api.github.com/repos/vishalkshirsagr4-lab/Android-assistant-/releases/latest';
  static const _apkName = 'lucy-update.apk';
  static String? _pendingApkPath;
  static bool _downloadCancelled = false;

  Future<LucyUpdateInfo?> checkForUpdate() async {
    final response = await http.get(
      Uri.parse(_releaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw HttpException('GitHub returned HTTP ${response.statusCode}.');
    }

    final release = jsonDecode(response.body);
    if (release is! Map<String, dynamic>) {
      throw const FormatException('GitHub returned an invalid release response.');
    }
    if (release['draft'] == true || release['prerelease'] == true) return null;

    final tagName = release['tag_name'] as String? ?? '';
    final tag = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    if (!_isValidStableVersion(tag)) {
      throw const FormatException('The latest release has an invalid version tag.');
    }

    final installed = await _channel.invokeMapMethod<String, dynamic>(
      'getInstalledVersion',
    );
    final installedVersion = installed?['versionName']?.toString() ?? '0.0.0';
    if (!_isNewer(tag, installedVersion)) return null;

    final assets = release['assets'];
    if (assets is! List) {
      throw const FormatException('The release has no downloadable assets.');
    }

    Map<String, dynamic>? apk;
    for (final item in assets) {
      if (item is Map<String, dynamic> && item['name'] == 'lucy-latest.apk') {
        apk = item;
        break;
      }
    }
    if (apk == null) {
      throw const FormatException('The latest stable release has no lucy-latest.apk.');
    }

    final url = apk['browser_download_url'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' && uri.host != 'release-assets.githubusercontent.com') {
      throw const FormatException('The release APK URL is not a trusted HTTPS URL.');
    }

    final digestValue = apk['digest'] as String?;
    final digest = digestValue != null && digestValue.startsWith('sha256:')
        ? digestValue.substring(7).toLowerCase()
        : null;
    if (digest != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('GitHub supplied an invalid APK checksum.');
    }

    return LucyUpdateInfo(
      version: tag,
      notes: (release['body'] as String? ?? '').trim(),
      downloadUrl: uri.toString(),
      expectedSha256: digest,
      expectedSize: apk['size'] is int ? apk['size'] as int : null,
    );
  }

  Future<bool> downloadAndInstall(
    LucyUpdateInfo update, {
    UpdateProgressCallback? onProgress,
  }) async {
    _downloadCancelled = false;
    final directory = await getTemporaryDirectory();
    final apkFile = File('${directory.path}/$_apkName');

    if (await apkFile.exists()) await apkFile.delete();

    final request = http.Request('GET', Uri.parse(update.downloadUrl));
    final client = http.Client();
    IOSink? sink;
    var received = 0;
    try {
      final response = await client.send(request).timeout(
        const Duration(seconds: 45),
      );
      if (response.statusCode != 200) {
        throw HttpException('APK download failed: HTTP ${response.statusCode}.');
      }
      final total = response.contentLength ?? update.expectedSize;
      sink = apkFile.openWrite();
      await for (final chunk in response.stream) {
        if (_downloadCancelled) {
          throw const HttpException('Update download cancelled.');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0 || !await apkFile.exists()) {
        throw const HttpException('The downloaded APK is empty.');
      }
      if (update.expectedSize != null && received != update.expectedSize) {
        throw const HttpException('Downloaded APK size does not match GitHub release metadata.');
      }
      if (update.expectedSha256 != null) {
        final actual = await sha256.bind(apkFile.openRead()).first;
        if (actual.toString().toLowerCase() != update.expectedSha256) {
          throw const HttpException('APK checksum verification failed. Installation was blocked.');
        }
      }

      _pendingApkPath = apkFile.path;
      return await _installPendingIfAllowed();
    } catch (_) {
      if (sink != null) await sink.close();
      if (await apkFile.exists() && _pendingApkPath != apkFile.path) {
        await apkFile.delete();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  void cancelDownload() {
    _downloadCancelled = true;
  }

  Future<bool> _installPendingIfAllowed() async {
    final path = _pendingApkPath;
    if (path == null) return false;
    final apk = File(path);
    if (!await apk.exists() || await apk.length() == 0) {
      _pendingApkPath = null;
      return false;
    }

    final canInstall =
        await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (!canInstall) {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
      return false;
    }

    await _channel.invokeMethod<void>('installApk', {'path': path});
    // Keep the pending path until Android returns from the installer. The file
    // lives in app-private storage and is not removed by an in-place update.
    return true;
  }

  Future<void> resumePendingInstall() async {
    final directory = await getTemporaryDirectory();
    final apk = File('${directory.path}/$_apkName');
    if (await apk.exists() && await apk.length() > 0) {
      _pendingApkPath = apk.path;
      await _installPendingIfAllowed();
    }
  }

  static bool _isValidStableVersion(String value) =>
      RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(value);

  static bool _isNewer(String remote, String local) {
    final remoteParts = remote.split('.').map(int.parse).toList();
    final localMatch = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+').firstMatch(local);
    if (localMatch == null) return true;
    final localParts = localMatch.group(0)!.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (remoteParts[i] != localParts[i]) {
        return remoteParts[i] > localParts[i];
      }
    }
    return false;
  }
}
