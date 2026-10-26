import 'dart:io';

import 'package:heart_bpm/heart_bpm.dart';
import 'package:path_provider/path_provider.dart';

class PpgCsvLogger {
  PpgCsvLogger._(this._file, this._sessionId)
      : _window = List<SensorValue>.filled(
          50,
          SensorValue(time: DateTime.now(), value: 0),
          growable: true,
        );

  static const _header =
      'session_id,timestamp_ms,raw_average_green,window_mean_green,'
      'window_max_green,peak_threshold_green,rising_edge_count_in_window,'
      'peak_detected,peak_interval_count,instantaneous_window_bpm,'
      'ema_bpm_diagnostic,bpm';
  static const _alpha = 0.8;

  final File _file;
  final String _sessionId;
  final List<SensorValue> _window;
  Future<void> _writeQueue = Future<void>.value();
  int _currentBpm = 0;

  String get filePath => _file.path;

  static Future<PpgCsvLogger> create({Directory? directory}) async {
    final targetDirectory = directory ?? await _getTargetDirectory();
    final dataDirectory = Directory(
      '${targetDirectory.path}${Platform.pathSeparator}data',
    );
    await dataDirectory.create(recursive: true);
    final file = File(
      '${dataDirectory.path}${Platform.pathSeparator}heart_rate_samples.csv',
    );
    if (!await file.exists() || await file.length() == 0) {
      await file.writeAsString('$_header\n', flush: true);
    }
    return PpgCsvLogger._(
      file,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
  }

  static Future<Directory> _getTargetDirectory() async {
    // Android and iOS app bundles are not writable.
    if (Platform.isAndroid || Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }

    final executablePath = Platform.resolvedExecutable;
    final separatorIndex = executablePath.lastIndexOf(Platform.pathSeparator);
    if (separatorIndex < 0) {
      throw FileSystemException(
        'Could not determine the application executable directory',
        executablePath,
      );
    }
    final directoryEnd = Platform.isWindows && separatorIndex == 2
        ? separatorIndex + 1
        : separatorIndex;
    return Directory(executablePath.substring(0, directoryEnd));
  }

  Future<void> appendSample(SensorValue sample, {required int? bpm}) {
    final trace = _trace(sample);
    final values = <Object?>[
      _sessionId,
      sample.time.millisecondsSinceEpoch,
      sample.value,
      trace.windowMean,
      trace.windowMax,
      trace.threshold,
      trace.risingEdgeCount,
      trace.hasRisingEdge,
      trace.intervalCount,
      trace.instantaneousBpm,
      trace.emaBpm,
      bpm,
    ];
    final row = values.map(_escapeCsv).join(',');
    final write = _writeQueue.then(
      (_) => _file.writeAsString('$row\n', mode: FileMode.append, flush: true),
    );
    // The returned future reports write failures; recover the queue for later samples.
    _writeQueue = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return write;
  }

  Future<void> flush() => _writeQueue;

  _PpgTrace _trace(SensorValue sample) {
    _window.removeAt(0);
    _window.add(sample);

    var windowMean = 0.0;
    var windowMax = 0.0;
    for (final value in _window) {
      windowMean += value.value / _window.length;
      if (value.value > windowMax) {
        windowMax = value.value.toDouble();
      }
    }

    final threshold = (windowMax + windowMean) / 2;
    var risingEdgeCount = 0;
    var intervalCount = 0;
    var previousTimestamp = 0;
    var instantaneousBpm = 0.0;
    for (var index = 1; index < _window.length; index++) {
      if (_window[index - 1].value < threshold &&
          _window[index].value > threshold) {
        risingEdgeCount++;
        final timestamp = _window[index].time.millisecondsSinceEpoch;
        if (previousTimestamp != 0) {
          intervalCount++;
          instantaneousBpm += 60000 / (timestamp - previousTimestamp);
        }
        previousTimestamp = timestamp;
      }
    }

    if (intervalCount > 0) {
      instantaneousBpm /= intervalCount;
      _currentBpm =
          ((1 - _alpha) * _currentBpm + _alpha * instantaneousBpm).toInt();
    }

    return _PpgTrace(
      windowMean: windowMean,
      windowMax: windowMax,
      threshold: threshold,
      risingEdgeCount: risingEdgeCount,
      hasRisingEdge: risingEdgeCount > 0,
      intervalCount: intervalCount,
      instantaneousBpm: intervalCount > 0 ? instantaneousBpm : null,
      emaBpm: _currentBpm,
    );
  }

  static String _escapeCsv(Object? value) {
    final text = value?.toString() ?? '';
    return '"${text.replaceAll('"', '""')}"';
  }
}

class _PpgTrace {
  const _PpgTrace({
    required this.windowMean,
    required this.windowMax,
    required this.threshold,
    required this.risingEdgeCount,
    required this.hasRisingEdge,
    required this.intervalCount,
    required this.instantaneousBpm,
    required this.emaBpm,
  });

  final double windowMean;
  final double windowMax;
  final double threshold;
  final int risingEdgeCount;
  final bool hasRisingEdge;
  final int intervalCount;
  final double? instantaneousBpm;
  final int emaBpm;
}
