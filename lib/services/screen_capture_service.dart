import 'package:flutter/services.dart';

import 'agent_reliability.dart';

class ScreenCaptureManager {
  static const _channel = MethodChannel('com.poc.screen_aware_ai/screen');

  bool _hasPermission = false;
  bool get hasPermission => _hasPermission;

  /// Callback fired when the native stop notification action is tapped.
  VoidCallback? onForceStop;

  bool _handlerRegistered = false;

  /// Ensure the reverse method call handler is registered (native → Dart).
  void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onForceStop') {
        onForceStop?.call();
      }
    });
  }

  /// Request screen capture permission (shows system dialog)
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestScreenCapture');
      _hasPermission = result ?? false;
      return _hasPermission;
    } catch (e) {
      LucyReliabilityLog.event('screen_permission_request_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Capture the current screen and return compressed image bytes.
  /// Automatically handles reinitialization if the capture service
  /// lost its projection (e.g., after app switch or service restart).
  Future<Uint8List?> captureScreen() async {
    if (!_hasPermission) {
      final granted = await requestPermission();
      if (!granted) return null;
    }

    try {
      final bytes = await _channel.invokeMethod<Uint8List>('captureScreen');
      return bytes;
    } on PlatformException catch (e) {
      if (e.code == 'NOT_INITIALIZED') {
        // Service exists but lost its MediaProjection — wait for
        // reinitialization (MainActivity attempts it automatically)
        // then retry once.
        LucyReliabilityLog.event('screen_capture_not_initialized', attempt: 1, success: false);
        await Future.delayed(const Duration(milliseconds: 800));
        try {
          final bytes = await _channel.invokeMethod<Uint8List>('captureScreen');
          return bytes;
        } on PlatformException catch (retryError) {
          if (retryError.code == 'NOT_INITIALIZED' ||
              retryError.code == 'NO_SERVICE') {
            // Reinitialization failed — need fresh permission grant
            LucyReliabilityLog.event('screen_capture_reinitialize_failed', attempt: 2, success: false);
            _hasPermission = false;
            final granted = await requestPermission();
            if (!granted) return null;
            // Final attempt after fresh permission
            try {
              final bytes = await _channel.invokeMethod<Uint8List>(
                'captureScreen',
              );
              return bytes;
            } catch (finalError) {
              LucyReliabilityLog.event('screen_capture_final_attempt_failed', errorType: finalError.runtimeType.toString(), success: false);
              return null;
            }
          }
          LucyReliabilityLog.event('screen_capture_retry_failed', errorType: retryError.runtimeType.toString(), success: false);
          return null;
        }
      } else if (e.code == 'NO_SERVICE') {
        // Service not running at all — request permission to start it
        LucyReliabilityLog.event('screen_capture_service_missing', success: false);
        _hasPermission = false;
        final granted = await requestPermission();
        if (!granted) return null;
        try {
          final bytes = await _channel.invokeMethod<Uint8List>('captureScreen');
          return bytes;
        } catch (retryError) {
          LucyReliabilityLog.event('screen_capture_after_permission_failed', errorType: retryError.runtimeType.toString(), success: false);
          return null;
        }
      }
      LucyReliabilityLog.event('screen_capture_failed', errorType: e.runtimeType.toString(), success: false);
      return null;
    } catch (e) {
      LucyReliabilityLog.event('screen_capture_failed', errorType: e.runtimeType.toString(), success: false);
      return null;
    }
  }

  /// Get the UI tree of the current foreground app via accessibility service.
  /// Returns a JSON string with package name and element list, or null on error.
  Future<String?> getUITree() async {
    try {
      final result = await _channel.invokeMethod<String>('getUITree');
      return result;
    } catch (e) {
      LucyReliabilityLog.event('ui_tree_capture_failed', errorType: e.runtimeType.toString(), success: false);
      return null;
    }
  }

  /// Check if accessibility service is enabled
  Future<bool> isAccessibilityEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isAccessibilityEnabled',
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Open accessibility settings
  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } catch (e) {
      LucyReliabilityLog.event('accessibility_settings_open_failed', errorType: e.runtimeType.toString(), success: false);
    }
  }

  /// Launch an app by package name
  Future<bool> openApp(String packageName) async {
    try {
      final result = await _channel.invokeMethod<bool>('openApp', {
        'packageName': packageName,
      });
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('open_app_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Perform a tap at the given coordinates
  Future<bool> performTap(double x, double y) async {
    try {
      final result = await _channel.invokeMethod<bool>('performTap', {
        'x': x,
        'y': y,
      });
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('tap_dispatch_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Type text into the currently focused input
  Future<bool> performType(String text) async {
    try {
      final result = await _channel.invokeMethod<bool>('performType', {
        'text': text,
      });
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('type_dispatch_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Perform a swipe gesture
  Future<bool> performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    try {
      final result = await _channel.invokeMethod<bool>('performSwipe', {
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
      });
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('swipe_dispatch_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Press back button
  Future<bool> pressBack() async {
    try {
      final result = await _channel.invokeMethod<bool>('pressBack');
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('back_dispatch_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Get the screen size in pixels
  Future<Map<String, int>?> getScreenSize() async {
    try {
      final result = await _channel.invokeMethod<Map>('getScreenSize');
      if (result != null) {
        return {
          'width': result['width'] as int,
          'height': result['height'] as int,
        };
      }
      return null;
    } catch (e) {
      LucyReliabilityLog.event('screen_size_read_failed', errorType: e.runtimeType.toString(), success: false);
      return null;
    }
  }

  /// Press home button
  Future<bool> pressHome() async {
    try {
      final result = await _channel.invokeMethod<bool>('pressHome');
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('home_dispatch_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  // ─── Stop controls ──────────────────────────────────────────────────

  /// Show the persistent stop notification while Lucy is active.
  Future<bool> showStopOverlay() async {
    _ensureHandler();
    try {
      final result = await _channel.invokeMethod<bool>('showStopOverlay');
      return result ?? false;
    } catch (e) {
      LucyReliabilityLog.event('stop_controls_show_failed', errorType: e.runtimeType.toString(), success: false);
      return false;
    }
  }

  /// Hide the persistent stop notification.
  Future<void> hideStopOverlay() async {
    try {
      await _channel.invokeMethod('hideStopOverlay');
    } catch (e) {
      LucyReliabilityLog.event('stop_controls_hide_failed', errorType: e.runtimeType.toString(), success: false);
    }
  }
}
