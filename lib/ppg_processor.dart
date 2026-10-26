import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';

import 'optical_presence_gate.dart';

enum PpgSignalQuality { noFinger, acquiring, poor, fair, good }

class PpgUpdate {
  const PpgUpdate({
    required this.presence,
    required this.signalQuality,
    required this.progress,
    required this.green,
    required this.filtered,
    required this.bpm,
  });

  final PresenceState presence;
  final PpgSignalQuality signalQuality;
  final double progress;
  final double green;
  final double filtered;
  final int? bpm;
}

class PpgProcessor {
  static const _historyDuration = Duration(seconds: 15);
  static const _sampleRateHz = 30;
  static const _samplePeriodSeconds = 1 / _sampleRateHz;
  static const _baselineCutoffHz = 0.75;
  static const _smoothingCutoffHz = 3.5;
  static const _minimumAcDcRatio = 0.001;
  static const _fairAcDcRatio = 0.002;
  static const _goodAcDcRatio = 0.01;
  static const _minimumPeakDistance = Duration(milliseconds: 285);
  static const _maximumPeakDistance = Duration(milliseconds: 1350);
  static const _requiredIntervals = 3;

  final OpticalPresenceGate _presenceGate = OpticalPresenceGate();
  final Queue<_SignalSample> _history = Queue<_SignalSample>();
  final Queue<Duration> _intervals = Queue<Duration>();

  DateTime? _activeStartedAt;
  DateTime? _lastPositivePeak;
  DateTime? _lastNegativePeak;
  _RawGreenSample? _lastRawSample;
  DateTime? _gridStartTimestamp;
  int _nextGridIndex = 1;
  double? _previousGridRaw;
  double _highPass = 0;
  double _lowPass = 0;
  int? _bpm;
  int _rejectedIntervals = 0;

  bool get isCalibrated => _presenceGate.isCalibrated;

  List<double> get waveform =>
      _history.map((sample) => sample.filtered).toList(growable: false);

  PpgUpdate addFrame(CameraImage image, DateTime timestamp) {
    final color = _measureFrame(image);
    final presence = _presenceGate.process(color.metrics, timestamp);

    if (presence != PresenceState.active) {
      _resetPulseSignal();
      _activeStartedAt = null;
      return PpgUpdate(
        presence: presence,
        signalQuality: presence == PresenceState.detecting
            ? PpgSignalQuality.acquiring
            : PpgSignalQuality.noFinger,
        progress: 0,
        green: color.green,
        filtered: 0,
        bpm: null,
      );
    }

    return addGreenSample(color.green, timestamp);
  }

  PpgUpdate addGreenSample(double green, DateTime timestamp) {
    _activeStartedAt ??= timestamp;
    final previous = _lastRawSample;
    var bpm = _bpm;
    if (previous == null) {
      _gridStartTimestamp = timestamp;
      _filterAtGrid(green, timestamp);
    } else {
      if (!timestamp.isAfter(previous.timestamp)) {
        throw ArgumentError.value(
          timestamp,
          'timestamp',
          'Sample timestamps must be strictly increasing.',
        );
      }
      while (true) {
        final gridTimestamp = _gridTimestamp(_nextGridIndex);
        if (gridTimestamp.isAfter(timestamp)) break;
        final fraction =
            gridTimestamp.difference(previous.timestamp).inMicroseconds /
                timestamp.difference(previous.timestamp).inMicroseconds;
        final interpolated =
            previous.value + (green - previous.value) * fraction;
        _filterAtGrid(interpolated, gridTimestamp);
        bpm = _detectPulsePeak() ?? bpm;
        _nextGridIndex++;
      }
    }
    _lastRawSample = _RawGreenSample(timestamp, green);
    final progress = timestamp.difference(_activeStartedAt!).inMilliseconds /
        const Duration(seconds: 10).inMilliseconds;

    return PpgUpdate(
      presence: PresenceState.active,
      signalQuality: _quality,
      progress: progress.clamp(0.0, 1.0),
      green: green,
      filtered: _history.isEmpty ? 0 : _history.last.filtered,
      bpm: bpm ?? _bpm,
    );
  }

  PpgSignalQuality get _quality {
    if (_history.length < 30) return PpgSignalQuality.acquiring;
    final recent = _history.toList().reversed.take(90).toList();
    final dc = recent.map((sample) => sample.raw).reduce((a, b) => a + b) /
        recent.length;
    if (dc <= 0) return PpgSignalQuality.poor;
    final minimum = recent.map((sample) => sample.filtered).reduce(math.min);
    final maximum = recent.map((sample) => sample.filtered).reduce(math.max);
    final acDcRatio = (maximum - minimum) / dc;
    if (acDcRatio < _fairAcDcRatio) return PpgSignalQuality.poor;
    if (_intervals.length >= _requiredIntervals && _rejectedIntervals == 0) {
      return acDcRatio >= _goodAcDcRatio
          ? PpgSignalQuality.good
          : PpgSignalQuality.fair;
    }
    return PpgSignalQuality.fair;
  }

  DateTime _gridTimestamp(int index) {
    final offsetMicroseconds =
        (index * Duration.microsecondsPerSecond / _sampleRateHz).round();
    return _gridStartTimestamp!.add(
      Duration(microseconds: offsetMicroseconds),
    );
  }

  void _filterAtGrid(double value, DateTime timestamp) {
    final previousRaw = _previousGridRaw ?? value;
    final highPassRc = 1 / (2 * math.pi * _baselineCutoffHz);
    final highPassAlpha = highPassRc / (highPassRc + _samplePeriodSeconds);
    _highPass = highPassAlpha * (_highPass + value - previousRaw);

    final lowPassRc = 1 / (2 * math.pi * _smoothingCutoffHz);
    final lowPassAlpha =
        _samplePeriodSeconds / (lowPassRc + _samplePeriodSeconds);
    _lowPass += lowPassAlpha * (_highPass - _lowPass);
    _previousGridRaw = value;

    _history.addLast(_SignalSample(timestamp, value, _lowPass));
    final cutoff = timestamp.subtract(_historyDuration);
    while (_history.isNotEmpty && _history.first.timestamp.isBefore(cutoff)) {
      _history.removeFirst();
    }
  }

  int? _detectPulsePeak() {
    if (_history.length < 3) return null;
    final samples = _history.toList();
    final prior = samples[samples.length - 3];
    final peak = samples[samples.length - 2];
    final current = samples.last;
    final isMaximum =
        peak.filtered > prior.filtered && peak.filtered > current.filtered;
    final isMinimum =
        peak.filtered < prior.filtered && peak.filtered < current.filtered;
    if (!isMaximum && !isMinimum) return null;

    final prominenceStart =
        peak.timestamp.subtract(const Duration(milliseconds: 500));
    final localSamples = samples
        .where((sample) => !sample.timestamp.isBefore(prominenceStart))
        .toList();
    if (localSamples.length < 3) return null;
    final local = localSamples.map((sample) => sample.filtered).toList();
    final localMin = local.reduce(math.min);
    final localMax = local.reduce(math.max);
    final prominence =
        isMaximum ? peak.filtered - localMin : localMax - peak.filtered;
    final signalRange = localMax - localMin;
    final localDc = localSamples
            .map((sample) => sample.raw)
            .reduce((left, right) => left + right) /
        localSamples.length;
    if (localDc <= 0) return null;
    final prominenceRatio = prominence / localDc;
    final minimumProminenceRatio =
        math.max(_minimumAcDcRatio, signalRange / localDc * 0.18);
    if (prominenceRatio < minimumProminenceRatio) return null;

    final previousPeak = isMaximum ? _lastPositivePeak : _lastNegativePeak;
    if (isMaximum) {
      _lastPositivePeak = peak.timestamp;
    } else {
      _lastNegativePeak = peak.timestamp;
    }
    if (previousPeak == null) return null;

    final interval = peak.timestamp.difference(previousPeak);
    if (interval < _minimumPeakDistance) return null;
    if (interval > _maximumPeakDistance) {
      _intervals.clear();
      _bpm = null;
      _rejectedIntervals++;
      return null;
    }

    if (_intervals.length == 1) {
      final firstInterval = _intervals.first.inMicroseconds;
      if ((interval.inMicroseconds - firstInterval).abs() / firstInterval >
          0.35) {
        _rejectedIntervals++;
        return null;
      }
    } else if (_intervals.length >= _requiredIntervals) {
      final sorted = _intervals.map((item) => item.inMicroseconds).toList()
        ..sort();
      final medianInterval = sorted[sorted.length ~/ 2];
      if ((interval.inMicroseconds - medianInterval).abs() / medianInterval >
          0.25) {
        _rejectedIntervals++;
        return null;
      }
    }

    _intervals.addLast(interval);
    while (_intervals.length > 5) {
      _intervals.removeFirst();
    }
    _rejectedIntervals = 0;
    if (_intervals.length < _requiredIntervals) return null;

    final meanInterval =
        _intervals.fold<int>(0, (sum, item) => sum + item.inMicroseconds) /
            _intervals.length;
    _bpm = (60 * Duration.microsecondsPerSecond / meanInterval).round();
    return _bpm;
  }

  _FrameColor _measureFrame(CameraImage image) {
    if (image.format.group == ImageFormatGroup.bgra8888 ||
        (Platform.isIOS && image.planes.length == 1)) {
      return _measureBgra(image);
    }
    if (image.planes.length < 3) {
      throw StateError('Camera must provide YUV420 or BGRA8888 frames.');
    }
    return _measureYuv420(image);
  }

  _FrameColor _measureBgra(CameraImage image) {
    final plane = image.planes.first;
    final stats = _ColorAccumulator();
    _forEachRoiPixel(image, (x, y) {
      final offset = y * plane.bytesPerRow + x * 4;
      if (offset + 2 >= plane.bytes.length) return;
      final blue = plane.bytes[offset].toDouble();
      final green = plane.bytes[offset + 1].toDouble();
      final red = plane.bytes[offset + 2].toDouble();
      stats.add(
        green: green,
        red: red,
        luma: 0.299 * red + 0.587 * green + 0.114 * blue,
        u: 128 - 0.169 * red - 0.331 * green + 0.5 * blue,
        v: 128 + 0.5 * red - 0.419 * green - 0.081 * blue,
      );
    });
    return stats.finish();
  }

  _FrameColor _measureYuv420(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final stats = _ColorAccumulator();
    _forEachRoiPixel(image, (x, y) {
      final yOffset = y * yPlane.bytesPerRow + x;
      final chromaX = x ~/ 2;
      final chromaY = y ~/ 2;
      final uOffset =
          chromaY * uPlane.bytesPerRow + chromaX * (uPlane.bytesPerPixel ?? 1);
      final vOffset =
          chromaY * vPlane.bytesPerRow + chromaX * (vPlane.bytesPerPixel ?? 1);
      if (yOffset >= yPlane.bytes.length ||
          uOffset >= uPlane.bytes.length ||
          vOffset >= vPlane.bytes.length) {
        return;
      }

      final luma = yPlane.bytes[yOffset].toDouble();
      final u = uPlane.bytes[uOffset].toDouble();
      final v = vPlane.bytes[vOffset].toDouble();
      final green = (luma - 0.344136 * (u - 128) - 0.714136 * (v - 128))
          .clamp(0.0, 255.0);
      final red = (luma + 1.402 * (v - 128)).clamp(0.0, 255.0);
      stats.add(green: green, red: red, luma: luma, u: u, v: v);
    });
    return stats.finish();
  }

  void _forEachRoiPixel(CameraImage image, void Function(int x, int y) visit) {
    final left = image.width ~/ 4;
    final right = image.width - left;
    final top = image.height ~/ 4;
    final bottom = image.height - top;
    final stepX = math.max(1, (right - left) ~/ 40);
    final stepY = math.max(1, (bottom - top) ~/ 40);
    for (var y = top; y < bottom; y += stepY) {
      for (var x = left; x < right; x += stepX) {
        visit(x, y);
      }
    }
  }

  void _resetPulseSignal() {
    _history.clear();
    _intervals.clear();
    _lastPositivePeak = null;
    _lastNegativePeak = null;
    _lastRawSample = null;
    _gridStartTimestamp = null;
    _nextGridIndex = 1;
    _previousGridRaw = null;
    _highPass = 0;
    _lowPass = 0;
    _bpm = null;
    _rejectedIntervals = 0;
  }
}

class _SignalSample {
  const _SignalSample(this.timestamp, this.raw, this.filtered);

  final DateTime timestamp;
  final double raw;
  final double filtered;
}

class _RawGreenSample {
  const _RawGreenSample(this.timestamp, this.value);

  final DateTime timestamp;
  final double value;
}

class _FrameColor {
  const _FrameColor(this.green, this.metrics);

  final double green;
  final OpticalFrameMetrics metrics;
}

class _ColorAccumulator {
  int _count = 0;
  int _skinCount = 0;
  double _greenTotal = 0;
  double _redTotal = 0;
  double _lumaTotal = 0;
  double _lumaSquaredTotal = 0;

  void add({
    required double green,
    required double red,
    required double luma,
    required double u,
    required double v,
  }) {
    _count++;
    _greenTotal += green;
    _redTotal += red;
    _lumaTotal += luma;
    _lumaSquaredTotal += luma * luma;
    if (luma >= 20 && u >= 70 && u <= 150 && v >= 120 && v <= 195) {
      _skinCount++;
    }
  }

  _FrameColor finish() {
    if (_count == 0) {
      throw StateError('The camera frame contained no readable ROI pixels.');
    }
    final meanLuma = _lumaTotal / _count;
    final variance = _lumaSquaredTotal / _count - meanLuma * meanLuma;
    return _FrameColor(
      _greenTotal / _count,
      OpticalFrameMetrics(
        meanLuma: meanLuma,
        meanRed: _redTotal / _count,
        lumaVariance: math.max(0, variance),
        skinToneRatio: _skinCount / _count,
      ),
    );
  }
}
