import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:heart_bpm/heart_bpm.dart';
import 'package:permission_handler/permission_handler.dart';

import 'camera_service.dart';
import 'optical_presence_gate.dart';
import 'ppg_processor.dart';

class HeartRateScreen extends StatefulWidget {
  const HeartRateScreen({
    required this.onSample,
    required this.onBpm,
    super.key,
  });

  final ValueChanged<SensorValue> onSample;
  final ValueChanged<int?> onBpm;

  @override
  State<HeartRateScreen> createState() => _HeartRateScreenState();
}

class _HeartRateScreenState extends State<HeartRateScreen> {
  final CameraService _cameraService = CameraService();
  final PpgProcessor _processor = PpgProcessor();
  final List<double> _waveform = [];
  PresenceState _presence = PresenceState.idle;
  PpgSignalQuality _quality = PpgSignalQuality.noFinger;
  String? _error;
  int? _bpm;
  double _progress = 0;
  int _frameNumber = 0;
  bool _processingFrame = false;
  Timer? _releaseTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_startCamera());
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    unawaited(_cameraService.dispose());
    super.dispose();
  }

  Future<void> _startCamera() async {
    try {
      await _cameraService.start(_processFrame);
      if (mounted) setState(() {});
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to start the PPG camera: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  void _processFrame(CameraImage image) {
    if (_processingFrame || !mounted || _error != null) return;
    _processingFrame = true;
    try {
      final update = _processor.addFrame(image, DateTime.now());
      final presenceChanged = update.presence != _presence;
      _presence = update.presence;
      _quality = update.signalQuality;
      _progress = update.progress;
      _bpm = update.bpm;

      if (update.presence == PresenceState.active) {
        widget.onSample(
          SensorValue(time: DateTime.now(), value: update.green),
        );
        widget.onBpm(update.bpm);
      } else if (update.presence == PresenceState.released) {
        widget.onBpm(null);
      }

      _waveform
        ..add(update.filtered)
        ..removeRange(0, _waveform.length > 300 ? _waveform.length - 300 : 0);

      if (update.presence == PresenceState.released) {
        _releaseTimer ??= Timer(const Duration(milliseconds: 600), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
      _frameNumber++;
      if (presenceChanged || _frameNumber % 3 == 0) {
        setState(() {});
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to process the camera image: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _error = 'Unable to process camera frames: $error';
        });
      }
    } finally {
      _processingFrame = false;
    }
  }

  String get _statusText {
    if (_error != null) return _error!;
    if (!_processor.isCalibrated) {
      return 'Calibrating ambient light. Keep the lens uncovered.';
    }
    switch (_presence) {
      case PresenceState.idle:
        return 'Place a finger over the rear camera and flashlight.';
      case PresenceState.detecting:
        return 'Finger detected. Fully cover both the lens and flashlight '
            'and hold still.';
      case PresenceState.active:
        if (_bpm == null) {
          return 'Coverage confirmed. Acquiring pulse signal; keep your '
              'finger still.';
        }
        return 'Pulse detected. Keep your finger steady.';
      case PresenceState.released:
        return 'Finger removed. Ending measurement.';
    }
  }

  String get _qualityLabel {
    switch (_quality) {
      case PpgSignalQuality.noFinger:
        return 'No finger';
      case PpgSignalQuality.acquiring:
        return 'Acquiring signal';
      case PpgSignalQuality.poor:
        return 'Poor signal';
      case PpgSignalQuality.fair:
        return 'Fair signal';
      case PpgSignalQuality.good:
        return 'Good signal';
    }
  }

  Color _qualityColor(ThemeData theme) {
    switch (_quality) {
      case PpgSignalQuality.noFinger:
      case PpgSignalQuality.poor:
        return theme.colorScheme.error;
      case PpgSignalQuality.acquiring:
      case PpgSignalQuality.fair:
        return Colors.amber;
      case PpgSignalQuality.good:
        return Colors.greenAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _cameraService.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Heart-rate measurement'),
        actions: [
          IconButton(
            tooltip: 'Stop measurement',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller?.value.isInitialized ?? false)
                    Center(child: CameraPreview(controller!))
                  else
                    Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                    ),
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: Card(
                      color: theme.colorScheme.surface.withValues(alpha: 0.94),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.favorite,
                              color: theme.colorScheme.error,
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _bpm?.toString() ?? '--',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'BPM',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Column(
                children: [
                  Text(_statusText, textAlign: TextAlign.center),
                  if (_error?.contains('Settings') ?? false) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => unawaited(openAppSettings()),
                      child: const Text('Open app settings'),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('Progress'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(value: _progress),
                      ),
                      const SizedBox(width: 8),
                      Text('${(_progress * 100).round()}%'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: _qualityColor(theme),
                      ),
                      const SizedBox(width: 8),
                      Text(_qualityLabel),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SizedBox.expand(
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        values: _waveform,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minimum = values.reduce((left, right) => left < right ? left : right);
    final maximum = values.reduce((left, right) => left > right ? left : right);
    final range = maximum - minimum;
    if (range < 0.001) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final widthStep = size.width / (values.length - 1);
    for (var index = 0; index < values.length; index++) {
      final x = index * widthStep;
      final y = size.height - ((values[index] - minimum) / range * size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
