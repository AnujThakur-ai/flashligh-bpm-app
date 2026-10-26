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
  static const _baselineCutoffHz = 0.75;
  static const _smoothingCutoffHz = 3.5;
  static const _minimumPeakDistance = Duration(milliseconds: 285);
  static const _maximumPeakDistance = Duration(milliseconds: 1350);
  static const _requiredIntervals = 3;

  final OpticalPresenceGate _presenceGate = OpticalPresenceGate();
  final Queue<_SignalSample> _history = Queue<_SignalSample>();
  final Queue<Duration> _intervals = Queue<Duration>();

  DateTime? _activeStartedAt;
  DateTime? _lastTimestamp;
  DateTime? _lastPositivePeak;
  DateTime? _lastNegativePeak;
  double? _previousRaw;
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
    final filtered = _filter(green, timestamp);
    final bpm = _detectPulsePeak(filtered);
    final progress = timestamp.difference(_activeStartedAt!).inMilliseconds /
        const Duration(seconds: 10).inMilliseconds;

    return PpgUpdate(
      presence: PresenceState.active,
      signalQuality: _quality,
      progress: progress.clamp(0.0, 1.0),
      green: green,
      filtered: filtered,
      bpm: bpm ?? _bpm,
    );
  }

  PpgSignalQuality get _quality {
    if (_history.length < 30) return PpgSignalQuality.acquiring;
    final recent = _history.toList().reversed.take(90).toList();
    final values = recent.map((sample) => sample.filtered);
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final amplitude = maximum - minimum;
    if (amplitude < 0.08) return PpgSignalQuality.poor;
    if (_intervals.length >= _requiredIntervals && _rejectedIntervals == 0) {
      return PpgSignalQuality.good;
    }
    return amplitude > 0.3 ? PpgSignalQuality.fair : PpgSignalQuality.poor;
  }

  double _filter(double value, DateTime timestamp) {
    final previousTimestamp = _lastTimestamp;
    final dt = previousTimestamp == null
        ? 1 / 30
        : (timestamp.difference(previousTimestamp).inMicroseconds /
                Duration.microsecondsPerSecond)
            .clamp(1 / 120, 1 / 5);
    final previousRaw = _previousRaw ?? value;
    final highPassRc = 1 / (2 * math.pi * _baselineCutoffHz);
    final highPassAlpha = highPassRc / (highPassRc + dt);
    _highPass = highPassAlpha * (_highPass + value - previousRaw);

    final lowPassRc = 1 / (2 * math.pi * _smoothingCutoffHz);
    final lowPassAlpha = dt / (lowPassRc + dt);
    _lowPass += lowPassAlpha * (_highPass - _lowPass);
    _lastTimestamp = timestamp;
    _previousRaw = value;

    _history.addLast(_SignalSample(timestamp, value, _lowPass));
    final cutoff = timestamp.subtract(_historyDuration);
    while (_history.isNotEmpty && _history.first.timestamp.isBefore(cutoff)) {
      _history.removeFirst();
    }
    return _lowPass;
  }

  int? _detectPulsePeak(double filtered) {
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
    final local = samples
        .where((sample) => !sample.timestamp.isBefore(prominenceStart))
        .map((sample) => sample.filtered)
        .toList();
    if (local.length < 3) return null;
    final localMin = local.reduce(math.min);
    final localMax = local.reduce(math.max);
    final prominence =
        isMaximum ? peak.filtered - localMin : localMax - peak.filtered;
    final signalRange = localMax - localMin;
    final minimumProminence = math.max(0.08, signalRange * 0.18);
    if (prominence < minimumProminence) return null;

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

    if (_intervals.isNotEmpty) {
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
    _lastTimestamp = null;
    _previousRaw = null;
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
