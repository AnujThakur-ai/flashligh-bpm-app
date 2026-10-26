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
before pulse processing starts; the BPM stays blank until three plausible
pulse intervals are found. Raw green samples are linearly interpolated onto a
fixed 30 Hz grid before a time-invariant 0.75–3.5 Hz IIR bandpass. Relative
AC/DC peak prominence and interval checks reject low-quality signals, baseline
drift, and placement changes.
The measurement screen displays a filtered waveform, signal quality, and a
10-second progress indicator. The indicator reaches 100% after ten seconds but
does not automatically stop the scan; three consecutive uncovered frames start
a 300 ms removal confirmation before ending the session.
Each session appends accepted raw green-channel samples and logger diagnostics to
`data/heart_rate_samples.csv` under the app's writable storage directory (the
application documents directory on Android/iOS, or the executable directory
on desktop). Frames that fail presence validation are excluded from both BPM
calculation and CSV logging. The logger creates the `data/` parent directory
recursively before opening the CSV file. The Start Measurement button opens a
dedicated camera screen with the live BPM meter overlaid on the preview.

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
  `Y >= 20`, `70 <= U <= 150`, and `120 <= V <= 240`; the ratio is
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
+-- State is ACTIVE?
|   +-- Finger detected AND looks covered?
|       +-- Yes -> Clear failure count and removal timer; stay ACTIVE
|       +-- No -> Increment consecutive coverage-failure count
|           +-- Fewer than 3 failed frames -> Stay ACTIVE; retain history
|           +-- At least 3 -> Start/continue removal timer
|               +-- Less than 300 ms -> Stay ACTIVE; retain history
|               +-- At least 300 ms -> RELEASED
|
+-- State is DETECTING?
|   +-- Finger detected AND looks covered?
|       +-- Yes -> Clear failure count; continue/start confirmation timer
|           +-- Less than 450 ms elapsed -> Stay DETECTING
|           +-- At least 450 ms elapsed -> ACTIVE; begin pulse processing
|       +-- No -> Increment consecutive coverage-failure count
|           +-- Fewer than 3 failed frames -> Keep confirmation timer
|           +-- At least 3 -> Clear confirmation timer and failure count
|               +-- Finger still detected -> Stay DETECTING
|               +-- Finger not detected -> IDLE
|
+-- State is IDLE?
    +-- Finger not detected -> Stay IDLE
    +-- Finger detected -> Set state to DETECTING
        +-- Looks covered? -> Start confirmation timer
        +-- Not covered? -> Wait for full coverage
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
lighting. Coverage failures in both DETECTING and ACTIVE are debounced for three
consecutive frames. During DETECTING, one or two failed frames preserve the
450 ms confirmation timer; the third clears it (and returns to IDLE if the
finger is no longer detected). During ACTIVE, the third failed frame starts
the existing 300 ms release confirmation, so transient gaps do not clear the
processor's rolling history or restart progress.

### BPM signal processing and decision tree

Only frames whose presence state is `ACTIVE` enter the pulse processor and CSV
sample callback. Before filtering, the processor linearly interpolates the
timestamped raw green stream onto a uniform 30 Hz grid. Grid timestamps are
anchored at the first sample and spaced by 1/30 second (rounded to microseconds);
interpolation uses each adjacent pair of camera samples. The IIR therefore
always receives samples at the same rate even when camera frame delivery jitters
or skips a frame. If two consecutive raw camera frames are more than 100 ms
apart, the processor treats this as a stream interruption: it discards the
interpolation anchor, filter state, rolling waveform, accepted intervals, and
BPM, then starts a new grid at the current sample. It does not interpolate
across the gap. The active session's elapsed progress timer is retained. The
filter coefficients are fixed:

```text
sample rate = 30 Hz
dt = 1/30 s

high-pass cutoff = 0.75 Hz
RC_HP = 1 / (2 pi * 0.75)
alpha_HP = RC_HP / (RC_HP + 1/30)
high = alpha_HP * (previous high + current G - previous G)

low-pass cutoff = 3.5 Hz
RC_LP = 1 / (2 pi * 3.5)
alpha_LP = (1/30) / (RC_LP + 1/30)
filtered = previous filtered + alpha_LP * (high - previous filtered)
```

This is a time-invariant two-stage first-order IIR approximation; frame-to-frame
`dt` never changes its poles. The processor keeps up to 15 seconds of resampled
history. Peak detection uses the latest three samples and a local window:

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
|       +-- Calculate local DC as mean raw green in the same 500 ms window
|       +-- Require prominence / local DC >=
|           max(0.1%, 18% of local signal range / local DC)
|           +-- No -> Reject this peak
|           +-- Yes -> Compare with previous peak of the same kind
|               (maxima with maxima, minima with minima)
|               +-- No previous same-kind peak -> Save it; no interval yet
|               +-- Interval < 285 ms -> Ignore interval
|               +-- Interval > 1350 ms
|               |   -> Clear accepted intervals and BPM; reject interval
|               +-- First interval -> Accept unconditionally
|               +-- Second interval differs from first by >35% -> Reject
|               +-- Fewer than 3 accepted intervals available -> Bootstrap
|               +-- Otherwise, deviation from median >25% -> Reject interval
|               +-- Otherwise -> Accept interval; keep at most 5 intervals
|                   +-- Fewer than 3 accepted intervals? -> BPM stays unset
|                   +-- At least 3 -> BPM = round(60,000,000 / mean interval us)
|
+-- BPM range implied by interval limits: about 44–211 BPM
```

An interval is the time between two successive maxima **or** two successive
minima. Each prominence-qualified extremum becomes the reference for the next
interval check, including when its interval is rejected. The first interval is
stored without a median check, so an empty rolling buffer cannot reject its own
bootstrap sample. The second interval is compared only to the first, with 35%
tolerance. The third interval fills the initial set; once three intervals have
been accepted, subsequent intervals must be within 25% of the median of the
retained intervals. BPM remains unset until three intervals are accepted and is
then calculated from the mean of up to five accepted intervals. A rejected
interval does not directly replace the displayed BPM, except that an interval
longer than 1350 ms clears it. A later accepted interval resets the
rejected-interval counter. Consequently, the last accepted BPM can remain
visible while newer intervals are rejected; the quality label is calculated
separately and does not mark the BPM as stale.

The signal-quality label is a separate heuristic over the latest up to 90
resampled points (up to three seconds). It measures filtered AC peak-to-peak
amplitude against mean raw-green DC in that same window:

```text
Fewer than 30 points -> ACQUIRING
Otherwise AC/DC = (max(filtered) - min(filtered)) / mean(raw green)
+-- AC/DC < 0.2% -> POOR
+-- At least 3 accepted intervals, no outstanding rejection,
|   and AC/DC >= 1% -> GOOD
+-- Otherwise, if AC/DC >= 0.2% -> FAIR
```

`GOOD` is not a guarantee that the signal is physiologically valid; periodic
movement or other optical artifacts can also be periodic. This is why the result
should not be used for diagnosis or urgent medical decisions. Ratio thresholds
reduce sensitivity to sensor gain and torch intensity; they do not eliminate
all device-, placement-, or skin-dependent variation.

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
                        +-- Consecutive raw-frame gap exceeds 100 ms
                        |   -> Reset interpolation, filter, waveform, and BPM
                        |      state; re-anchor at the current sample while
                        |      preserving active-session progress
                        +-- Presence is IDLE or DETECTING
                        |   -> Clear pulse history/BPM; do not log sample
                        +-- Presence becomes ACTIVE
                        |   -> Filter green sample; update BPM, quality,
                        |      progress and waveform; append raw sample and
                        |      logger diagnostics to CSV
                        +-- Active coverage has fewer than 3 consecutive
                        |   failed frames or has failed for less than 300 ms
                        |   -> Remain ACTIVE; preserve history and progress
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
