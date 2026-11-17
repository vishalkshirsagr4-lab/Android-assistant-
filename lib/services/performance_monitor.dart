import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class LucyTimingSummary {
  const LucyTimingSummary({
    required this.samples,
    required this.lastMs,
    required this.medianMs,
    required this.p95Ms,
    required this.failures,
  });

  final int samples;
  final int? lastMs;
  final int? medianMs;
  final int? p95Ms;
  final int failures;
}

class LucyPerformanceSnapshot {
  const LucyPerformanceSnapshot({
    required this.rssBytes,
    required this.measuredAt,
    required this.timings,
    required this.completedTasks,
    required this.failedTasks,
    required this.lastTaskSteps,
    this.cpuPercent,
    this.batteryPercent,
    this.netBatteryChangeMah,
    this.lastResponseMs,
    this.responseP50Ms,
    this.responseP95Ms,
    this.lastTaskDurationMs,
  });

  final int rssBytes;
  final DateTime measuredAt;
  final double? cpuPercent;
  final int? batteryPercent;
  /// Positive means charge used; negative means net charge gained.
  final int? netBatteryChangeMah;
  final int? lastResponseMs;
  final int? responseP50Ms;
  final int? responseP95Ms;
  final int? lastTaskDurationMs;
  final int completedTasks;
  final int failedTasks;
  final int lastTaskSteps;
  final Map<String, LucyTimingSummary> timings;

  String get ramLabel => '${(rssBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  String get cpuLabel =>
      cpuPercent == null ? 'Unavailable' : '${cpuPercent!.toStringAsFixed(1)}%';
  String get batteryLabel =>
      batteryPercent == null ? 'Unavailable' : '$batteryPercent%';
  String get batteryChangeLabel => netBatteryChangeMah == null
      ? 'Not measured'
      : '${netBatteryChangeMah! >= 0 ? '−' : '+'}${netBatteryChangeMah!.abs()} mAh';
}

/// Bounded, privacy-safe performance and task-stability measurements.
class LucyPerformanceMonitor {
  LucyPerformanceMonitor._();
  static final LucyPerformanceMonitor shared = LucyPerformanceMonitor._();
  static const _channel = MethodChannel('com.poc.screen_aware_ai/screen');
  static const int _maxSamples = 120;

  final Map<String, List<int>> _samples = <String, List<int>>{};
  final Map<String, int> _failures = <String, int>{};
  int _completedTasks = 0;
  int _failedTasks = 0;
  int _currentTaskSteps = 0;
  int _lastTaskSteps = 0;
  int? _lastTaskDurationMs;
  int? _lastNetBatteryChangeMah;
  int? _taskStartChargeUah;
  DateTime? _taskStartedAt;

  void recordResponse(Duration duration) =>
      recordTiming('model', duration);

  void recordTiming(
    String metric,
    Duration duration, {
    bool success = true,
  }) {
    final key = metric.trim().toLowerCase();
    if (key.isEmpty) return;
    final values = _samples.putIfAbsent(key, () => <int>[]);
    values.add(duration.inMilliseconds.clamp(0, 600000).toInt());
    if (values.length > _maxSamples) values.removeAt(0);
    if (!success) _failures[key] = (_failures[key] ?? 0) + 1;
  }

  void recordStep() {
    if (_taskStartedAt != null) _currentTaskSteps++;
  }

  Future<void> beginTask() async {
    _taskStartedAt = DateTime.now();
    _taskStartChargeUah = null;
    _currentTaskSteps = 0;
    final metrics = await _readNativeMetrics();
    final value = metrics['chargeCounterUah'];
    if (value is num && value >= 0) _taskStartChargeUah = value.toInt();
  }

  Future<void> endTask({required bool success}) async {
    final started = _taskStartedAt;
    if (started == null) return;
    _lastTaskDurationMs = DateTime.now().difference(started).inMilliseconds;
    _lastTaskSteps = _currentTaskSteps;
    if (success) {
      _completedTasks++;
    } else {
      _failedTasks++;
    }

    final endingMetrics = await _readNativeMetrics();
    final endValue = endingMetrics['chargeCounterUah'];
    final startValue = _taskStartChargeUah;
    if (startValue != null && endValue is num && endValue >= 0) {
      _lastNetBatteryChangeMah = ((startValue - endValue.toInt()) / 1000).round();
    }
    _taskStartedAt = null;
    _taskStartChargeUah = null;
    _currentTaskSteps = 0;
  }

  Future<Map<dynamic, dynamic>> _readNativeMetrics() async {
    if (!Platform.isAndroid) return const <dynamic, dynamic>{};
    try {
      return await _channel
              .invokeMapMethod<dynamic, dynamic>('getDeviceMetrics')
              .timeout(const Duration(seconds: 2)) ??
          const <dynamic, dynamic>{};
    } catch (_) {
      // Unsupported metrics and missing plugins must never crash the UI.
      return const <dynamic, dynamic>{};
    }
  }

  Future<LucyPerformanceSnapshot> snapshot() async {
    Map<dynamic, dynamic> native = await _readNativeMetrics();
    if (Platform.isAndroid) {
      // A second sample 250 ms later gives process CPU time a meaningful
      // interval; all native calls are bounded and optional.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      native = await _readNativeMetrics();
    }
    final response = _summaryFor('model');
    return LucyPerformanceSnapshot(
      rssBytes: ProcessInfo.currentRss,
      measuredAt: DateTime.now(),
      cpuPercent: (native['cpuPercent'] as num?)?.toDouble(),
      batteryPercent: (native['batteryPercent'] as num?)?.toInt(),
      netBatteryChangeMah: _lastNetBatteryChangeMah,
      lastResponseMs: response.lastMs,
      responseP50Ms: response.medianMs,
      responseP95Ms: response.p95Ms,
      lastTaskDurationMs: _lastTaskDurationMs,
      completedTasks: _completedTasks,
      failedTasks: _failedTasks,
      lastTaskSteps: _lastTaskSteps,
      timings: <String, LucyTimingSummary>{
        for (final key in _samples.keys) key: _summaryFor(key),
      },
    );
  }

  LucyTimingSummary _summaryFor(String key) {
    final values = List<int>.from(_samples[key] ?? const <int>[])..sort();
    final original = _samples[key] ?? const <int>[];
    if (values.isEmpty) {
      return LucyTimingSummary(
        samples: 0,
        lastMs: null,
        medianMs: null,
        p95Ms: null,
        failures: _failures[key] ?? 0,
      );
    }
    int percentile(double value) {
      final index = ((values.length - 1) * value).round();
      return values[index.clamp(0, values.length - 1).toInt()];
    }
    return LucyTimingSummary(
      samples: values.length,
      lastMs: original.isEmpty ? null : original.last,
      medianMs: percentile(0.5),
      p95Ms: percentile(0.95),
      failures: _failures[key] ?? 0,
    );
  }

  /// Test-only reset to keep singleton state isolated between unit tests.
  void resetForTesting() {
    _samples.clear();
    _failures.clear();
    _completedTasks = 0;
    _failedTasks = 0;
    _currentTaskSteps = 0;
    _lastTaskSteps = 0;
    _lastTaskDurationMs = null;
    _lastNetBatteryChangeMah = null;
    _taskStartChargeUah = null;
    _taskStartedAt = null;
  }
}
