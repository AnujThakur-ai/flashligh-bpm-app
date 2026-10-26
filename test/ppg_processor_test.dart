import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:heart_rate_scan_standalone/ppg_processor.dart';

void main() {
  test('does not report BPM for a steady green signal', () {
    final processor = PpgProcessor();
    final start = DateTime(2026, 1, 1);
    PpgUpdate? update;

    for (var frame = 0; frame < 450; frame++) {
      update = processor.addGreenSample(
        120,
        start.add(Duration(milliseconds: frame * 33)),
      );
    }

    expect(update?.bpm, isNull);
    expect(update?.progress, 1);
  });

  test('calculates BPM from sustained green-channel pulses', () {
    final processor = PpgProcessor();
    final start = DateTime(2026, 1, 1);
    PpgUpdate? update;

    for (var frame = 0; frame < 450; frame++) {
      final elapsed = frame / 30;
      final pulse = 120 + 2 * math.sin(2 * math.pi * 1.2 * elapsed);
      final drift = elapsed * 0.15;
      update = processor.addGreenSample(
        pulse + drift,
        start.add(Duration(milliseconds: frame * 33)),
      );
    }

    expect(update?.bpm, isNotNull);
    expect(update!.bpm, inInclusiveRange(68, 76));
    expect(update.signalQuality, PpgSignalQuality.good);
    expect(processor.waveform, isNotEmpty);
  });

  test('resampling and AC/DC normalization tolerate jitter and sensor gain',
      () {
    final start = DateTime(2026, 1, 1);
    final jitterMilliseconds = [0, 7, -5, 3];

    for (final baseline in [40.0, 200.0]) {
      final processor = PpgProcessor();
      PpgUpdate? update;
      for (var frame = 0; frame < 450; frame++) {
        final elapsed = frame / 30 +
            jitterMilliseconds[frame % jitterMilliseconds.length] / 1000;
        final timestamp = start.add(
          Duration(microseconds: (elapsed * 1000000).round()),
        );
        final pulse =
            baseline + baseline * 0.003 * math.sin(2 * math.pi * 1.2 * elapsed);
        update = processor.addGreenSample(pulse, timestamp);
      }

      expect(update?.bpm, inInclusiveRange(68, 76));
      expect(update?.signalQuality, PpgSignalQuality.fair);
    }
  });

  test('resets filter and rolling history after a long raw-frame gap', () {
    final processor = PpgProcessor();
    final start = DateTime(2026, 1, 1);

    for (var frame = 0; frame < 20; frame++) {
      processor.addGreenSample(
        100,
        start.add(Duration(milliseconds: frame * 33)),
      );
    }

    final afterGap = processor.addGreenSample(
      220,
      start.add(const Duration(seconds: 1)),
    );

    expect(processor.waveform, [0]);
    expect(afterGap.filtered, 0);
    expect(afterGap.bpm, isNull);
    expect(afterGap.progress, closeTo(0.1, 0.01));
  });

  test('does not treat a finger-placement step as a pulse', () {
    final processor = PpgProcessor();
    final start = DateTime(2026, 1, 1);
    PpgUpdate? update;

    for (var frame = 0; frame < 450; frame++) {
      final placementStep = frame < 5 ? frame * 12.0 : 60.0;
      update = processor.addGreenSample(
        100 + placementStep,
        start.add(Duration(milliseconds: frame * 33)),
      );
    }

    expect(update?.bpm, isNull);
  });
}
