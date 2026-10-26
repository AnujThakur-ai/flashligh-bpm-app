class OpticalFrameMetrics {
  const OpticalFrameMetrics({
    required this.meanLuma,
    required this.meanRed,
    required this.lumaVariance,
    required this.skinToneRatio,
  });

  final double meanLuma;
  final double meanRed;
  final double lumaVariance;
  final double skinToneRatio;
}

enum PresenceState { idle, detecting, active, released }

class OpticalPresenceGate {
  static const calibrationDuration = Duration(seconds: 1);
  static const confirmationDuration = Duration(milliseconds: 450);
  static const releaseDuration = Duration(milliseconds: 300);
  static const minimumCalibrationFrames = 8;
  static const coverageFailureDebounceFrames = 3;

  final List<OpticalFrameMetrics> _calibrationFrames = [];
  DateTime? _calibrationStartedAt;
  DateTime? _candidateStartedAt;
  DateTime? _releaseStartedAt;
  double? _baselineMeanLuma;
  double? _baselineVariance;
  int _consecutiveCoverageFailures = 0;

  PresenceState state = PresenceState.idle;
  bool get isCalibrated => _baselineMeanLuma != null;

  PresenceState process(OpticalFrameMetrics frame, DateTime timestamp) {
    if (state == PresenceState.released) return state;

    if (!isCalibrated) {
      _calibrationStartedAt ??= timestamp;
      _calibrationFrames.add(frame);
      if (timestamp.difference(_calibrationStartedAt!) >= calibrationDuration &&
          _calibrationFrames.length >= minimumCalibrationFrames) {
        _baselineMeanLuma = _calibrationFrames
                .map((sample) => sample.meanLuma)
                .reduce((left, right) => left + right) /
            _calibrationFrames.length;
        _baselineVariance = _calibrationFrames
                .map((sample) => sample.lumaVariance)
                .reduce((left, right) => left + right) /
            _calibrationFrames.length;
      }
      return state;
    }

    final fingerDetected = frame.skinToneRatio >= 0.15 && frame.meanLuma >= 12;
    final covered = _looksCovered(frame);
    if (state == PresenceState.active) {
      if (fingerDetected && covered) {
        _consecutiveCoverageFailures = 0;
        _releaseStartedAt = null;
      } else {
        _consecutiveCoverageFailures++;
        if (_consecutiveCoverageFailures >= coverageFailureDebounceFrames) {
          _releaseStartedAt ??= timestamp;
        }
        if (_releaseStartedAt != null &&
            timestamp.difference(_releaseStartedAt!) >= releaseDuration) {
          state = PresenceState.released;
        }
      }
      return state;
    }

    if (state == PresenceState.detecting) {
      if (!fingerDetected || !covered) {
        _consecutiveCoverageFailures++;
        if (_consecutiveCoverageFailures >= coverageFailureDebounceFrames) {
          _candidateStartedAt = null;
          _consecutiveCoverageFailures = 0;
          if (!fingerDetected) state = PresenceState.idle;
        }
        return state;
      }
      _consecutiveCoverageFailures = 0;
    } else {
      if (!fingerDetected) {
        _candidateStartedAt = null;
        _consecutiveCoverageFailures = 0;
        state = PresenceState.idle;
        return state;
      }

      state = PresenceState.detecting;
      if (!covered) return state;
    }

    _candidateStartedAt ??= timestamp;
    if (timestamp.difference(_candidateStartedAt!) >= confirmationDuration) {
      state = PresenceState.active;
      _releaseStartedAt = null;
      _consecutiveCoverageFailures = 0;
    }
    return state;
  }

  bool _looksCovered(OpticalFrameMetrics frame) {
    final baselineMean = _baselineMeanLuma!;
    final baselineVariance = _baselineVariance!;
    final lumaChanged =
        (frame.meanLuma - baselineMean).abs() >= _max(5, baselineMean * 0.08);
    final varianceReduced = frame.lumaVariance <= baselineVariance * 0.75;
    return frame.skinToneRatio >= 0.55 &&
        frame.meanLuma >= 12 &&
        (lumaChanged || varianceReduced);
  }

  double _max(double left, double right) => left > right ? left : right;
}
