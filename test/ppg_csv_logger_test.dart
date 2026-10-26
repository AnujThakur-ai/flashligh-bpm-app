import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heart_bpm/heart_bpm.dart';
import 'package:heart_rate_scan_standalone/ppg_csv_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory targetDirectory;

  setUp(() async {
    targetDirectory = await Directory.systemTemp.createTemp();
  });

  tearDown(() async {
    await targetDirectory.delete(recursive: true);
  });

  test('writes raw samples and threshold diagnostics to CSV', () async {
    final logger = await PpgCsvLogger.create(directory: targetDirectory);
    final timestamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    await logger.appendSample(
      SensorValue(time: timestamp, value: 42),
      bpm: null,
    );
    await logger.flush();

    final lines = await File(logger.filePath).readAsLines();
    expect(
      File(logger.filePath).parent.path,
      '${targetDirectory.path}${Platform.pathSeparator}data',
    );
    expect(lines, hasLength(2));
    expect(
      lines.first,
      'session_id,timestamp_ms,raw_average_green,window_mean_green,'
      'window_max_green,peak_threshold_green,rising_edge_count_in_window,'
      'peak_detected,peak_interval_count,instantaneous_window_bpm,'
      'ema_bpm_diagnostic,bpm',
    );
    expect(lines.last, contains('"1700000000000","42","0.84","42.0","21.42"'));
    expect(lines.last, contains('"1","true","0","","0",""'));
  });

  test('creates missing parent directories before opening the CSV file',
      () async {
    final nestedDirectory = Directory(
      '${targetDirectory.path}${Platform.pathSeparator}nested'
      '${Platform.pathSeparator}app',
    );
    expect(await nestedDirectory.exists(), isFalse);

    final logger = await PpgCsvLogger.create(directory: nestedDirectory);

    expect(await nestedDirectory.exists(), isTrue);
    expect(await File(logger.filePath).exists(), isTrue);
  });
}
