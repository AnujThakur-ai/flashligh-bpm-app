import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';
import 'package:heart_rate_scan_standalone/camera_service.dart';
import 'package:heart_rate_scan_standalone/heart_rate_screen.dart';

class _TestCameraService extends CameraService {
  int disposeCalls = 0;
  bool _isDisposed = false;

  @override
  Future<void> start(void Function(CameraImage image) onImage) async {
    _isDisposed = false;
  }

  @override
  Future<void> dispose() async {
    if (!_isDisposed) {
      _isDisposed = true;
      disposeCalls++;
    }
  }
}

void main() {
  testWidgets('Finish freezes the summary until Done is tapped',
      (WidgetTester tester) async {
    final cameraService = _TestCameraService();
    var returnedToHome = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => HeartRateScreen(
                      onSample: (_) {},
                      onBpm: (_) {},
                      cameraService: cameraService,
                    ),
                  ),
                );
                returnedToHome = true;
              },
              child: const Text('Open scan'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open scan'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(
      find.text('Place fingertip over the rear camera lens and flashlight'),
      findsOneWidget,
    );

    await tester.tap(find.text('Finish scan'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Scan Complete'), findsOneWidget);
    expect(find.text('No reliable heart-rate estimate was captured.'),
        findsOneWidget);
    expect(find.text('Signal quality'), findsOneWidget);
    expect(find.text('Samples collected'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(returnedToHome, isFalse);
    expect(cameraService.disposeCalls, 1);

    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(returnedToHome, isTrue);
  });

  testWidgets('no-coverage timeout stops camera and returns timeout reason',
      (WidgetTester tester) async {
    final cameraService = _TestCameraService();
    MeasurementExitReason? exitReason;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                exitReason =
                    await Navigator.of(context).push<MeasurementExitReason>(
                  MaterialPageRoute<MeasurementExitReason>(
                    builder: (_) => HeartRateScreen(
                      onSample: (_) {},
                      onBpm: (_) {},
                      cameraService: cameraService,
                    ),
                  ),
                );
              },
              child: const Text('Open scan'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open scan'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(exitReason, MeasurementExitReason.inactivityTimeout);
    expect(cameraService.disposeCalls, 1);
  });
}
