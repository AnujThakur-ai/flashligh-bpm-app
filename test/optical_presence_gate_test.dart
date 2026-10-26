import 'package:flutter_test/flutter_test.dart';
import 'package:heart_rate_scan_standalone/optical_presence_gate.dart';

void main() {
  group('OpticalPresenceGate', () {
    test('calibrates then requires sustained optical coverage', () {
      final gate = OpticalPresenceGate();
      final start = DateTime(2026, 1, 1);
      const ambient = OpticalFrameMetrics(
        meanLuma: 100,
        meanRed: 100,
        lumaVariance: 400,
        skinToneRatio: 0.05,
      );
      const covered = OpticalFrameMetrics(
        meanLuma: 65,
        meanRed: 65,
        lumaVariance: 100,
        skinToneRatio: 0.8,
      );

      for (var frame = 0; frame < 16; frame++) {
        gate.process(ambient, start.add(Duration(milliseconds: frame * 70)));
      }
      expect(gate.isCalibrated, isTrue);
      expect(gate.state, PresenceState.idle);

      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1120))),
        PresenceState.detecting,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1570))),
        PresenceState.active,
      );
    });

    test('rejects a luminance change without a skin-tone signature', () {
      final gate = OpticalPresenceGate();
      final start = DateTime(2026, 1, 1);
      const ambient = OpticalFrameMetrics(
        meanLuma: 100,
        meanRed: 100,
        lumaVariance: 400,
        skinToneRatio: 0.05,
      );
      for (var frame = 0; frame < 16; frame++) {
        gate.process(ambient, start.add(Duration(milliseconds: frame * 70)));
      }

      const changedBackground = OpticalFrameMetrics(
        meanLuma: 45,
        meanRed: 45,
        lumaVariance: 80,
        skinToneRatio: 0.1,
      );
      expect(
        gate.process(
          changedBackground,
          start.add(const Duration(milliseconds: 1120)),
        ),
        PresenceState.idle,
      );
    });

    test('resets detection when coverage is not continuous', () {
      final gate = OpticalPresenceGate();
      final start = DateTime(2026, 1, 1);
      const ambient = OpticalFrameMetrics(
        meanLuma: 100,
        meanRed: 100,
        lumaVariance: 400,
        skinToneRatio: 0.05,
      );
      const covered = OpticalFrameMetrics(
        meanLuma: 65,
        meanRed: 65,
        lumaVariance: 100,
        skinToneRatio: 0.8,
      );
      for (var frame = 0; frame < 16; frame++) {
        gate.process(ambient, start.add(Duration(milliseconds: frame * 70)));
      }

      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1120))),
        PresenceState.detecting,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 1300))),
        PresenceState.idle,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1400))),
        PresenceState.detecting,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1850))),
        PresenceState.active,
      );
    });

    test('detects a finger before requiring complete stable coverage', () {
      final gate = OpticalPresenceGate();
      final start = DateTime(2026, 1, 1);
      const ambient = OpticalFrameMetrics(
        meanLuma: 100,
        meanRed: 100,
        lumaVariance: 400,
        skinToneRatio: 0.05,
      );
      const partialFinger = OpticalFrameMetrics(
        meanLuma: 90,
        meanRed: 90,
        lumaVariance: 350,
        skinToneRatio: 0.3,
      );
      const covered = OpticalFrameMetrics(
        meanLuma: 65,
        meanRed: 65,
        lumaVariance: 100,
        skinToneRatio: 0.8,
      );
      for (var frame = 0; frame < 16; frame++) {
        gate.process(ambient, start.add(Duration(milliseconds: frame * 70)));
      }

      expect(
        gate.process(
          partialFinger,
          start.add(const Duration(milliseconds: 1120)),
        ),
        PresenceState.detecting,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1200))),
        PresenceState.detecting,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1650))),
        PresenceState.active,
      );
    });

    test('debounces coverage failures before terminating the session', () {
      final gate = OpticalPresenceGate();
      final start = DateTime(2026, 1, 1);
      const ambient = OpticalFrameMetrics(
        meanLuma: 100,
        meanRed: 100,
        lumaVariance: 400,
        skinToneRatio: 0.05,
      );
      const covered = OpticalFrameMetrics(
        meanLuma: 65,
        meanRed: 65,
        lumaVariance: 100,
        skinToneRatio: 0.8,
      );
      for (var frame = 0; frame < 16; frame++) {
        gate.process(ambient, start.add(Duration(milliseconds: frame * 70)));
      }
      gate.process(covered, start.add(const Duration(milliseconds: 1120)));
      gate.process(covered, start.add(const Duration(milliseconds: 1570)));

      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 1600))),
        PresenceState.active,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 1650))),
        PresenceState.active,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 1700))),
        PresenceState.active,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 1800))),
        PresenceState.active,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 1900))),
        PresenceState.active,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 2199))),
        PresenceState.active,
      );
      expect(
        gate.process(ambient, start.add(const Duration(milliseconds: 2200))),
        PresenceState.released,
      );
      expect(
        gate.process(covered, start.add(const Duration(milliseconds: 2000))),
        PresenceState.released,
      );
    });
  });
}
