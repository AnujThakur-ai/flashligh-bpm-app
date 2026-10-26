import 'dart:async';

import 'package:flutter/material.dart';
import 'package:heart_bpm/heart_bpm.dart';

import 'heart_rate_screen.dart';
import 'ppg_csv_logger.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseModern',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.redAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PulseHomePage(),
    );
  }
}

class PulseHomePage extends StatefulWidget {
  const PulseHomePage({super.key});

  @override
  State<PulseHomePage> createState() => _PulseHomePageState();
}

class _PulseHomePageState extends State<PulseHomePage>
    with SingleTickerProviderStateMixin {
  List<SensorValue> data = [];
  int? bpmValue;
  String? _csvPath;
  String? _loggingError;
  bool _isMeasuring = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _startMeasurement() async {
    setState(() {
      _isMeasuring = true;
      _loggingError = null;
      bpmValue = null;
      data = [];
    });

    late final PpgCsvLogger logger;
    try {
      logger = await PpgCsvLogger.create();
    } catch (error, stackTrace) {
      _reportLoggingError(error, stackTrace);
      if (mounted) {
        setState(() {
          _isMeasuring = false;
        });
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _csvPath = logger.filePath;
    });
    int? sessionBpm;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => HeartRateScreen(
          onSample: (value) {
            unawaited(
              logger
                  .appendSample(value, bpm: sessionBpm)
                  .catchError(_reportLoggingError),
            );
            if (!mounted) return;
            setState(() {
              if (data.length >= 100) data.removeAt(0);
              data = [...data, value];
            });
          },
          onBpm: (value) {
            sessionBpm = value;
            if (!mounted || bpmValue == value) return;
            setState(() {
              bpmValue = value;
            });
          },
        ),
      ),
    );

    await logger.flush();
    if (!mounted) return;
    setState(() {
      _isMeasuring = false;
    });
  }

  void _reportLoggingError(Object error, StackTrace stackTrace) {
    debugPrint('Failed to save heart-rate samples: $error\n$stackTrace');
    if (!mounted) return;
    setState(() {
      _loggingError = 'CSV logging failed: $error';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 20),
                      Text(
                        "Place Finger on Camera & Flash",
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Keep the camera uncovered during calibration, then "
                        "cover both the camera and flashlight",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const Spacer(),
                      // Animated Heart & BPM Display Card
                      Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 36,
                            horizontal: 24,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ScaleTransition(
                                scale: _scaleAnimation,
                                child: Icon(
                                  Icons.favorite,
                                  size: 72,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                bpmValue?.toString() ?? "--",
                                style: theme.textTheme.displayLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "BPM",
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Live Waveform Monitor Box
                      Container(
                        height: 100,
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.outline
                                .withValues(alpha: 0.2),
                          ),
                        ),
                        child: CustomPaint(
                          painter: WaveformPainter(
                            data: data,
                            lineColor: theme.colorScheme.error,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Heart BPM Dialog trigger container/button
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton.icon(
                          onPressed: _isMeasuring ? null : _startMeasurement,
                          icon: const Icon(Icons.monitor_heart_outlined),
                          label: Text(
                            _isMeasuring
                                ? "Measurement in progress"
                                : "Start Measurement",
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (_csvPath != null || _loggingError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _loggingError ?? 'CSV: $_csvPath',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _loggingError == null
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Custom Painter to render real-time raw sensor wave data
class WaveformPainter extends CustomPainter {
  final List<SensorValue> data;
  final Color lineColor;

  WaveformPainter({required this.data, required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final double widthStep =
        size.width / (data.length > 1 ? data.length - 1 : 1);

    // Normalize values relative to max/min in current buffer
    double minY =
        data.map((e) => e.value).reduce((a, b) => a < b ? a : b).toDouble();
    double maxY =
        data.map((e) => e.value).reduce((a, b) => a > b ? a : b).toDouble();
    double range = maxY - minY;
    if (range == 0) range = 1.0;

    for (int i = 0; i < data.length; i++) {
      double x = i * widthStep;
      double normalizedY =
          size.height - ((data[i].value - minY) / range * size.height);
      if (i == 0) {
        path.moveTo(x, normalizedY);
      } else {
        path.lineTo(x, normalizedY);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.data != data || oldDelegate.lineColor != lineColor;
  }
}
