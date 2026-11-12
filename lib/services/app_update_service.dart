import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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
  AppUpdateService._();

  static const _channel = MethodChannel('com.poc.screen_aware_ai/updater');
  static const _releaseApi =
      'https://api.github.com/repos/vishalkshirsagr4-lab/Android-assistant-/releases/latest';

  static String? _pendingApkPath;

  Future<LucyUpdateInfo?> checkForUpdate() async {
    final response = await http.get(
      Uri.parse(_releaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw HttpException('GitHub returned ${response.statusCode}.');
    }

    final release = jsonDecode(response.body) as Map<String, dynamic>;
    if (release['draft'] == true || release['prerelease'] == true) return null;

    final tag = (release['tag_name'] as String? ?? '').replaceFirst('v', '');
    final package = await PackageInfo.fromPlatform();
    if (!_isNewer(tag, package.version)) return null;

    final assets = (release['assets'] as List<dynamic>? ?? const []);
    Map<String, dynamic>? apk;
    for (final item in assets) {
      final asset = item as Map<String, dynamic>;
      if (asset['name'] == 'lucy-latest.apk' &&
          (asset['content_type'] == 'application/vnd.android.package-archive' ||
              (asset['name'] as String).endsWith('.apk'))) {
        apk = asset;
        break;
      }
    }

    if (apk == null) {
      throw const FormatException(
        'The latest GitHub release does not contain lucy-latest.apk.',
      );
    }

    return LucyUpdateInfo(
      version: tag,
      notes: (release['body'] as String? ?? '').trim(),
      downloadUrl: apk['browser_download_url'] as String,
    );
  }

  Future<bool> downloadAndInstall(LucyUpdateInfo update) async {
    final directory = await getTemporaryDirectory();
    final apkFile = File('${directory.path}/lucy-update.apk');

    if (!await apkFile.exists() || await apkFile.length() == 0) {
      final request = http.Request('GET', Uri.parse(update.downloadUrl));
      final client = http.Client();
      try {
        final response = await client.send(request).timeout(
          const Duration(minutes: 3),
        );
        if (response.statusCode != 200) {
          throw HttpException('APK download failed: ${response.statusCode}.');
        }
        final sink = apkFile.openWrite();
        await response.stream.pipe(sink);
      } finally {
        client.close();
      }
    }

    _pendingApkPath = apkFile.path;
    return _installPendingIfAllowed();
  }

  Future<bool> _installPendingIfAllowed() async {
    final path = _pendingApkPath;
    if (path == null) return false;

    final canInstall =
        await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (!canInstall) {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
      return false;
    }

    await _channel.invokeMethod<void>('installApk', {'path': path});
    _pendingApkPath = null;
    return true;
  }

  Future<void> resumePendingInstall() async {
    if (_pendingApkPath != null) {
      await _installPendingIfAllowed();
    }
  }

  static bool _isNewer(String remote, String local) {
    final remoteParts = remote.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final localParts = local.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    if (remoteParts.length != 3 || localParts.length != 3) return false;

    for (var i = 0; i < 3; i++) {
      final a = remoteParts[i];
      final b = localParts[i];
      if (a != b) return a > b;
    }
    return false;
  }
}
