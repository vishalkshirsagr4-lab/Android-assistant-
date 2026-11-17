import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/performance_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LucyPerformanceMonitor.shared.resetForTesting();
  });

  test('keeps bounded latency samples and computes percentiles', () async {
    final monitor = LucyPerformanceMonitor.shared;
    monitor.recordTiming('tree', const Duration(milliseconds: 100));
    monitor.recordTiming('tree', const Duration(milliseconds: 200));
    monitor.recordTiming(
      'tree',
      const Duration(milliseconds: 300),
      success: false,
    );

    final snapshot = await monitor.snapshot();
    final tree = snapshot.timings['tree']!;

    expect(tree.samples, 3);
    expect(tree.lastMs, 300);
    expect(tree.medianMs, 200);
    expect(tree.p95Ms, 300);
    expect(tree.failures, 1);
  });

  test('tracks task counts, steps and duration without Android metrics', () async {
    final monitor = LucyPerformanceMonitor.shared;
    monitor.beginTask();
    monitor.recordStep();
    monitor.recordStep();
    await monitor.endTask(success: false);

    final snapshot = await monitor.snapshot();
    expect(snapshot.failedTasks, 1);
    expect(snapshot.completedTasks, 0);
    expect(snapshot.lastTaskSteps, 2);
    expect(snapshot.lastTaskDurationMs, isNotNull);
  });

  test('bounds retained samples to prevent long-session memory growth', () async {
    final monitor = LucyPerformanceMonitor.shared;
    for (var index = 0; index < 160; index++) {
      monitor.recordTiming('execution', Duration(milliseconds: index));
    }

    final snapshot = await monitor.snapshot();
    expect(snapshot.timings['execution']!.samples, 120);
    expect(snapshot.timings['execution']!.lastMs, 159);
  });
}
