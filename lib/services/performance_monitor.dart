import 'dart:io';

import 'package:flutter/services.dart';

class LucyPerformanceSnapshot {
  const LucyPerformanceSnapshot({
    required this.rssBytes,
    required this.measuredAt,
    this.cpuPercent,
    this.batteryPercent,
    this.lastResponseMs,
  });

  final int rssBytes;
  final DateTime measuredAt;
  final double? cpuPercent;
  final int? batteryPercent;
  final int? lastResponseMs;

  String get ramLabel => '${(rssBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  String get cpuLabel => cpuPercent == null ? 'Unavailable' : '${cpuPercent!.toStringAsFixed(1)}%';
  String get batteryLabel => batteryPercent == null ? 'Unavailable' : '$batteryPercent%';
}

/// Samples lightweight process/device metrics only when the tools screen opens.
class LucyPerformanceMonitor {
  LucyPerformanceMonitor._();
  static final LucyPerformanceMonitor shared = LucyPerformanceMonitor._();
  static const _channel = MethodChannel('com.poc.screen_aware_ai/screen');
  int? _lastResponseMs;

  void recordResponse(Duration duration) {
    _lastResponseMs = duration.inMilliseconds;
  }

  Future<LucyPerformanceSnapshot> snapshot() async {
    Map<dynamic, dynamic> native = const {};
    if (Platform.isAndroid) {
      try {
        native = await _channel.invokeMapMethod<dynamic, dynamic>('getDeviceMetrics') ?? const {};
      } on PlatformException {
        // Keep RAM and latency visible even if an OEM blocks a metric.
      }
    }
    return LucyPerformanceSnapshot(
      rssBytes: ProcessInfo.currentRss,
      measuredAt: DateTime.now(),
      cpuPercent: (native['cpuPercent'] as num?)?.toDouble(),
      batteryPercent: (native['batteryPercent'] as num?)?.toInt(),
      lastResponseMs: _lastResponseMs,
    );
  }
}
