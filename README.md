# Heart Rate Scan

A cross-platform Flutter application for Android and iOS, with a heart-rate
scanner and CSV sample logger.

## Open in Android Studio

Open this `standalone` folder as the project. Configure Android Studio to use
your Flutter SDK path; the Dart SDK is bundled with Flutter.

## Run

From this folder, run:

```sh
flutter pub get
flutter run
```

The app uses the rear camera and torch to estimate heart rate with a green-channel
PPG signal. It requests camera permission, locks focus and exposure, and streams
low-resolution frames as YUV420 on Android or BGRA8888 on iOS. Keep the lens
uncovered for the one-second ambient calibration. When a finger is detected,
fully cover the lens and flashlight and hold still. Stable coverage is required
before pulse processing starts; the BPM stays blank until three consistent,
plausible pulse intervals are found. A 0.75–3.5 Hz IIR bandpass approximation,
peak prominence and interval checks reject baseline drift and placement changes.
The measurement screen displays a filtered waveform, signal quality, and a
10-second progress indicator. The indicator reaches 100% after ten seconds but
does not automatically stop the scan; removing the finger for 300 ms ends the
session.
Each session appends accepted raw green-channel samples and logger diagnostics to
`data/heart_rate_samples.csv` under the app's writable storage directory (the
application documents directory on Android/iOS, or the executable directory
on desktop). Frames that fail presence validation are excluded from both BPM
calculation and CSV logging. The Start Measurement button opens a dedicated
camera screen with the live BPM meter overlaid on the preview.

## How the measurement works

This is an optical estimate from camera frames, not a medical-grade ECG or a
clinically validated measurement. In the diagrams below, `Y` is luma,
`U`/`V` are chroma, `G` is the estimated green channel, and all durations are
measured from camera-frame timestamps.

### Camera pixels and frame metrics

The app requests camera permission, chooses the first rear camera, initializes
it at low resolution, enables the torch, waits 500 ms, locks exposure and focus,
and starts the image stream. It samples a centered rectangular region of
interest (ROI): the middle half of the frame in both dimensions. The pixel
stride is chosen to sample at most about 40 positions per ROI dimension.

- **Android YUV420:** use the Y plane for `Y`; use the subsampled U/V planes
  for each pixel. Estimate `G = clamp(Y - 0.344136(U - 128) -
  0.714136(V - 128), 0, 255)` and
  `R = clamp(Y + 1.402(V - 128), 0, 255)`.
- **BGRA8888:** read B, G, R from the pixel bytes and calculate
  `Y = 0.299R + 0.587G + 0.114B`,
  `U = 128 - 0.169R - 0.331G + 0.5B`, and
  `V = 128 + 0.5R - 0.419G - 0.081B`.
- For all sampled ROI pixels, calculate the average green (`mean G`), average
  luma (`mean Y`), average red, luma variance
  `mean(Y²) - mean(Y)²` (clamped to at least zero), and the skin-tone ratio.
  A pixel contributes to the skin-tone count when
  `Y >= 20`, `70 <= U <= 150`, and `120 <= V <= 195`; the ratio is
  `skin-tone pixel count / sampled pixel count`.

The frame's **mean green** is the raw PPG sample. Red and the skin-tone ratio
are used for presence checks, not for the BPM calculation.

### Finger-presence state machine

The optical gate follows this decision tree for each frame:

```text
Frame metrics received
|
+-- State already RELEASED?
|   +-- Yes -> Stay RELEASED (terminal for this scan)
|   +-- No
|
+-- Not calibrated yet?
|   +-- Yes -> Add frame's mean luma and luma variance to calibration samples
|   |          +-- At least 1 second elapsed AND at least 8 frames?
|   |              +-- No -> Keep collecting; remain IDLE
|   |              +-- Yes -> Baseline mean luma and variance are the
|   |                         averages of all collected frames; remain IDLE
|   +-- No -> Evaluate finger and coverage
|
+-- Finger detected? (skin-tone ratio >= 0.15 AND mean luma >= 12)
|   +-- No
|   |   +-- Currently ACTIVE? -> Start/continue removal timer
|   |   |   +-- Not removed for 300 ms yet -> Stay ACTIVE
|   |   |   +-- Removed for at least 300 ms -> RELEASED
|   |   +-- Not ACTIVE -> Clear coverage timer; IDLE
|   +-- Yes
|       +-- Currently ACTIVE?
|       |   +-- Looks covered? -> Clear removal timer; stay ACTIVE
|       |   +-- Does not look covered? -> Start/continue removal timer
|       |       +-- Less than 300 ms -> Stay ACTIVE
|       |       +-- At least 300 ms -> RELEASED
|       +-- Not ACTIVE -> Set state to DETECTING
|           +-- Looks covered?
|               +-- No -> Clear confirmation timer; stay DETECTING
|               +-- Yes -> Start/continue coverage confirmation timer
|                   +-- Covered continuously for less than 450 ms
|                   |   -> Stay DETECTING
|                   +-- Covered continuously for at least 450 ms
|                       -> ACTIVE; begin pulse processing
|
+-- Looks covered means ALL of:
    +-- Skin-tone ratio >= 0.55
    +-- Mean luma >= 12
    +-- Either:
        +-- Absolute luma change from calibration baseline
        |   >= max(5, 8% of baseline mean luma)
        +-- Current luma variance <= 75% of baseline variance
```

The calibration timer starts with the first received frame. The implementation
does not independently check that calibration frames are truly uncovered or
that the baseline is sufficiently stable. The color and brightness thresholds
are heuristics and may behave differently across cameras, skin tones, and
lighting.

### BPM signal processing and decision tree

Only frames whose presence state is `ACTIVE` enter the pulse processor and CSV
sample callback. The processor filters the mean-green sample using a two-stage,
first-order IIR approximation to a 0.75–3.5 Hz bandpass:

```text
dt = clamp(time since previous sample, 1/120 s, 1/5 s)
    (first sample uses 1/30 s)

high-pass cutoff = 0.75 Hz
RC_HP = 1 / (2 pi * 0.75)
alpha_HP = RC_HP / (RC_HP + dt)
high = alpha_HP * (previous high + current G - previous G)

low-pass cutoff = 3.5 Hz
RC_LP = 1 / (2 pi * 3.5)
alpha_LP = dt / (RC_LP + dt)
filtered = previous filtered + alpha_LP * (high - previous filtered)
```

The processor keeps up to 15 seconds of filtered history. Peak detection then
uses the latest three samples and branches as follows:

```text
New filtered sample
|
+-- Fewer than 3 samples in history? -> No peak yet
+-- Middle of latest 3 samples is not a strict local maximum or minimum?
|   +-- Yes -> No peak
|   +-- No -> Check prominence using samples from the preceding 500 ms
|       +-- Fewer than 3 local samples? -> No peak
|       +-- For a maximum: prominence = peak - local minimum
|       +-- For a minimum: prominence = local maximum - peak
|       +-- Require prominence >= max(0.08, 18% of local signal range)
|           +-- No -> Reject this peak
|           +-- Yes -> Compare with previous peak of the same kind
|               (maxima with maxima, minima with minima)
|               +-- No previous same-kind peak -> Save it; no interval yet
|               +-- Interval < 285 ms -> Ignore interval
|               +-- Interval > 1350 ms
|               |   -> Clear accepted intervals and BPM; reject interval
|               +-- Interval differs from median accepted interval by >25%
|               |   -> Reject interval
|               +-- Otherwise -> Accept interval; keep at most 5 intervals
|                   +-- Fewer than 3 accepted intervals? -> BPM stays unset
|                   +-- At least 3 -> BPM = round(60,000,000 / mean interval us)
|
+-- BPM range implied by interval limits: about 44–211 BPM
```

An interval is the time between two successive maxima **or** two successive
minima. Each prominence-qualified extremum becomes the reference for the next
interval check, including when its interval is rejected. Once at least three
intervals are accepted, BPM is calculated from the mean of the currently
retained (up to five) intervals. A rejected interval does not directly replace
the displayed BPM, except that an interval longer than 1350 ms clears it. A
later accepted interval resets the rejected-interval counter. Consequently, the
last accepted BPM can remain visible while newer intervals are rejected; the
quality label is calculated separately and does not mark the BPM as stale.

The signal-quality label is a separate heuristic over the latest up to 90
filtered samples:

```text
Fewer than 30 samples -> ACQUIRING
Otherwise calculate amplitude = max(filtered) - min(filtered)
+-- Amplitude < 0.08 -> POOR
+-- At least 3 accepted intervals and no outstanding rejected interval
|   -> GOOD
+-- Amplitude > 0.3 -> FAIR
+-- Otherwise -> POOR
```

The 90-sample window is a sample count, not a fixed time span. `GOOD` is not a
guarantee that the signal is physiologically valid; periodic movement or other
optical artifacts can also be periodic. This is why the result should not be
used for diagnosis or urgent medical decisions. The `0.08` and `0.3` amplitude
thresholds are in filtered signal units, not BPM units.

### App and session control-flow tree

```text
Launch app
|
+-- Home screen: BPM "--"; Start Measurement enabled
    |
    +-- User taps Start Measurement
        +-- Create CSV logger
        |   +-- Failure -> Show logging error; remain on home screen
        |   +-- Success -> Open measurement screen; reset home BPM/waveform
        |
        +-- Request camera permission
            +-- Denied/permanently denied -> Show error
            |   +-- Permanently denied -> Offer Open app settings
            +-- Granted
                +-- No camera or no rear camera -> Show error
                +-- Rear camera found
                    +-- Camera initialization, torch, lock, or stream fails
                    |   -> Dispose camera; show error
                    +-- Stream starts
                        +-- Frame callback already processing / screen disposed
                        |   -> Skip frame
                        +-- Frame processing throws
                        |   -> Log error; show processing error
                        +-- Presence is IDLE or DETECTING
                        |   -> Clear pulse history/BPM; do not log sample
                        +-- Presence becomes ACTIVE
                        |   -> Filter green sample; update BPM, quality,
                        |      progress and waveform; append raw sample and
                        |      logger diagnostics to CSV
                        +-- Presence becomes/remains RELEASED
                            -> Clear home BPM; wait 600 ms; close screen
        |
        +-- User taps close at any time
            -> Close measurement screen
        |
        +-- Measurement screen closes
            -> Stop image stream, turn torch off, dispose camera,
               flush CSV writes, return to home screen
```

CSV logger diagnostics are a separate threshold/EMA trace; they do not produce
or validate the BPM shown by the app. The scan is not automatically stopped at
the 10-second progress mark.

iOS builds require Xcode on macOS. The iOS runner requests camera permission
using the usage description in `ios/Runner/Info.plist`.

## Build Android APK

```sh
flutter build apk --debug
```
