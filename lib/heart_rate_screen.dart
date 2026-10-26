import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:heart_bpm/heart_bpm.dart';
import 'package:permission_handler/permission_handler.dart';

import 'camera_service.dart';
import 'optical_presence_gate.dart';
import 'ppg_processor.dart';

enum MeasurementExitReason { inactivityTimeout }

class HeartRateScreen extends StatefulWidget {
  const HeartRateScreen({
    required this.onSample,
    required this.onBpm,
    this.cameraService,
    super.key,
  });

  final ValueChanged<SensorValue> onSample;
  final ValueChanged<int?> onBpm;
  final CameraService? cameraService;

  @override
  State<HeartRateScreen> createState() => _HeartRateScreenState();
}

class _HeartRateScreenState extends State<HeartRateScreen> {
  late final CameraService _cameraService;
  final PpgProcessor _processor = PpgProcessor();
  final List<double> _waveform = [];
  PresenceState _presence = PresenceState.idle;
  PpgSignalQuality _quality = PpgSignalQuality.noFinger;
  String? _error;
  int? _bpm;
  double _progress = 0;
  int _frameNumber = 0;
  int _sampleCount = 0;
  bool _processingFrame = false;
  bool _summaryShown = false;
  bool _isClosing = false;
  bool _hasReachedActive = false;
  DateTime? _scanStartedAt;
  DateTime? _weakSignalStartedAt;
  Duration _finalDuration = Duration.zero;
  Timer? _inactivityTimer;
  Future<void>? _cameraStopFuture;
  late final Future<void> _cameraStartFuture;

  @override
  void initState() {
    super.initState();
    _cameraService = widget.cameraService ?? CameraService();
    _scanStartedAt = DateTime.now();
    _inactivityTimer = Timer(const Duration(seconds: 20), _checkInactivity);
    _cameraStartFuture = _startCamera();
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    unawaited(
      _stopCamera().catchError((Object error, StackTrace stackTrace) {
        debugPrint('Unable to stop camera while closing scan: '
            '$error\n$stackTrace');
      }),
    );
    super.dispose();
  }

  void _checkInactivity() {
    if (!mounted || _hasReachedActive || _isClosing || _error != null) return;
    if (_presence != PresenceState.idle &&
        _presence != PresenceState.detecting) {
      return;
    }
    _isClosing = true;
    unawaited(_returnAfterInactivityTimeout());
  }

  Future<void> _returnAfterInactivityTimeout() async {
    try {
      await _stopCamera();
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to stop camera after inactivity timeout: '
          '$error\n$stackTrace');
    }
    if (!mounted) return;
    Navigator.of(context).pop(MeasurementExitReason.inactivityTimeout);
  }

  Future<void> _completeScan() async {
    if (!mounted || _summaryShown || _isClosing) return;
    _inactivityTimer?.cancel();
    _finalDuration = DateTime.now().difference(_scanStartedAt!);
    setState(() {
      _summaryShown = true;
    });
    try {
      await _stopCamera();
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to stop camera after scan completion: '
          '$error\n$stackTrace');
    }
  }

  Future<void> _stopCamera() => _cameraStopFuture ??= _stopCameraAfterStart();

  Future<void> _stopCameraAfterStart() async {
    await _cameraStartFuture;
    await _cameraService.dispose();
  }

  void _finishAndReturnHome() {
    if (_isClosing) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

  Future<void> _startCamera() async {
    try {
      await _cameraService.start(_processFrame);
      if (mounted && !_summaryShown && !_isClosing) setState(() {});
    } on Object catch (error, stackTrace) {
      debugPrint('Unable to start the PPG camera: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  void _processFrame(CameraImage image) {
    if (_processingFrame ||
        !mounted ||
        _error != null ||
        _summaryShown ||
        _isClosing) {
      return;
    }
    _processingFrame = true;
    try {
      final update = _processor.addFrame(image, DateTime.now());
      final presenceChanged = update.presence != _presence;
      _presence = update.presence;

      if (update.presence == PresenceState.active) {
        if (!_hasReachedActive) {
          _hasReachedActive = true;
          _inactivityTimer?.cancel();
        }
        _quality = update.signalQuality;
        _progress = update.progress;
        _bpm = update.bpm;
        _sampleCount++;
        if (_quality == PpgSignalQuality.poor ||
            _quality == PpgSignalQuality.acquiring) {
          _weakSignalStartedAt ??= DateTime.now();
        } else {
          _weakSignalStartedAt = null;
        }
        widget.onSample(
          SensorValue(time: DateTime.now(), value: update.green),
        );
        widget.onBpm(update.bpm);
      } else if (update.presence != PresenceState.released) {
        _quality = update.signalQuality;
        _progress = update.progress;
        _bpm = null;
        _weakSignalStartedAt = null;
      }

      if (update.presence == PresenceState.active) {
        _waveform
          ..add(update.filtered)
          ..removeRange(
            0,
            _waveform.length > 300 ? _waveform.length - 300 : 0,
          );
      } else if (update.presence == PresenceState.released) {
        unawaited(_completeScan());
      }
      _frameNumber++;
      if (!_summaryShown && (presenceChanged || _frameNumber % 3 == 0)) {
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
        return 'Finger removed. Preparing your summary.';
    }
  }

  String? get _signalGuidance {
    final weakSince = _weakSignalStartedAt;
    if (weakSince == null ||
        DateTime.now().difference(weakSince) < const Duration(seconds: 5)) {
      return null;
    }
    if (_quality == PpgSignalQuality.poor) {
      return 'If your fingers feel cold, warm your hands and try again. '
          'You can also adjust your fingertip pressure slightly.';
    }
    if (_quality == PpgSignalQuality.acquiring) {
      return 'Keep your finger still and fully cover both the camera lens '
          'and flashlight. Try adjusting pressure slightly.';
    }
    return null;
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
    if (_summaryShown) return _buildSummary(theme);

    final controller = _cameraService.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Heart-rate measurement'),
        actions: [
          TextButton(
            onPressed: _completeScan,
            child: const Text('Finish'),
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
                  if (_error == null) const Center(child: _LensTargetOverlay()),
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
                  if (_signalGuidance case final guidance?) ...[
                    const SizedBox(height: 8),
                    Text(
                      guidance,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _completeScan,
                  child: const Text('Finish scan'),
                ),
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

  Widget _buildSummary(ThemeData theme) {
    final bpm = _bpm;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Complete'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  bpm?.toString() ?? '--',
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text('BPM', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  bpm == null
                      ? 'No reliable heart-rate estimate was captured.'
                      : 'Your final heart-rate estimate',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                Card(
                  child: Column(
                    children: [
                      _SummaryStat(
                        label: 'Signal quality',
                        value: _qualityLabel,
                      ),
                      const Divider(height: 1),
                      _SummaryStat(
                        label: 'Scan duration',
                        value: '${_finalDuration.inSeconds} seconds',
                      ),
                      const Divider(height: 1),
                      _SummaryStat(
                        label: 'Samples collected',
                        value: '$_sampleCount',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'This camera-based estimate is not a medical diagnosis.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _finishAndReturnHome,
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LensTargetOverlay extends StatelessWidget {
  const _LensTargetOverlay();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: 240,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.68),
            border: Border.all(color: Colors.white, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt, color: Colors.white),
                  SizedBox(width: 12),
                  Icon(Icons.flash_on, color: Colors.amber),
                ],
              ),
              SizedBox(height: 8),
              Text(
                'Place fingertip over the rear camera lens and flashlight',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
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
