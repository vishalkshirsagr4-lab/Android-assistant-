import 'dart:io';

class LucyPerformanceSnapshot {
  const LucyPerformanceSnapshot({
    required this.rssBytes,
    required this.measuredAt,
    this.lastResponseMs,
  });

  final int rssBytes;
  final DateTime measuredAt;
  final int? lastResponseMs;

  String get ramLabel {
    final mb = rssBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// Lightweight process metrics. RSS and request latency are available from
/// Flutter without polling expensive device-wide diagnostics.
class LucyPerformanceMonitor {
  int? _lastResponseMs;

  void recordResponse(Duration duration) {
    _lastResponseMs = duration.inMilliseconds;
  }

  LucyPerformanceSnapshot snapshot() => LucyPerformanceSnapshot(
        rssBytes: ProcessInfo.currentRss,
        measuredAt: DateTime.now(),
        lastResponseMs: _lastResponseMs,
      );
}
