# InvisiButton

Knock the desk around a MacBook, macOS runs an action.

InvisiButton reads the built-in SPU IMU (accelerometer and gyroscope, Bosch BMI286, 800 Hz)
straight from an ordinary user process, classifies the impulse, and dispatches an action.
No microphone. No network. No accounts. No LLM. Detection is fully local and deterministic.

macOS 15+, Apple Silicon MacBooks only.

## Why an accelerometer

Every shipping competitor uses the microphone, collapses the signal to a scalar, and can
therefore only count knocks: one, two, three. Direction is thrown away at the first step.

InvisiButton keeps the 3-axis vector from both channels, which yields knock *location* (left,
right, front) from the same sensor, with no mic permission and no orange privacy indicator.

Direction is measured to be **per-desk calibrated**: it separates strongly within a desk and
does not transfer across desks. That is a shipped constraint, not a bug. See `DECISIONS.md`
D-013, D-020, D-024.

## Status

Phase 1 (tech) in progress. Stage 0 closed, Stages 1 through 4 largely done, Stage 5
(calibration contract) and the Phase 1 exit gate open. Phase 2 (design) has not started.

No accuracy number appears anywhere in this repo until the `tools/detect/evaluate.py` harness
measures it on real hardware, held out by desk. See `TASKS.md` for the live queue.

## Build

No Xcode project, no SwiftPM, no third-party dependencies. `swiftc` and system frameworks only.

```bash
./app/build.sh
```

Produces `app/build/InvisiButton.app`, ad-hoc signed so it launches locally. Developer ID
signing and notarization are T-021, not done yet.

```bash
./tools/build.sh
```

Produces `tools/bin/capture`, the full-rate session recorder that every detection claim is
measured against.

## The one thing that is easy to get wrong

Opening the `AppleSPUHIDDevice` is not enough. It returns `rc=0x0` and then delivers **zero**
reports forever, with no error. You must first wake the `AppleSPUHIDDriver` *service*, which is
a different IOKit registry object:

```swift
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it)
// for each service:
IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState"     as CFString, 1 as CFNumber)
IORegistryEntrySetCFProperty(svc, "ReportInterval"               as CFString, 1250 as CFNumber)
```

Then open the HID devices and register input report callbacks as normal. Setting
`ReportInterval` on the `IOHIDDevice` does nothing. There are no HID feature reports. Root does
not help; privilege was never the gate.

Reference implementation: `spikes/spu-wake.swift`. Full ruled-out matrix: `RESEARCH.md`.

## Sensor reference

```
IOHIDManager match: PrimaryUsagePage 0xFF00 (65280), PrimaryUsage 3 (accel) / 9 (gyro)
Transport "SPU", VendorID 1452, maxInputReportSize 22
Report: int32 little-endian at byte offsets 6 (X), 10 (Y), 14 (Z), / 65536 -> g
Native rate ~800 Hz
```

Verified on MacBook Pro `Mac17,2` (M5, Darwin 25.6.0), 2026-08-30, at euid=501 with no root.

## Layout

| Path | What it is |
| --- | --- |
| `app/` | The menu bar app. `LSUIElement`, single process, no daemon, no XPC. |
| `tools/` | Capture, replay, and offline analysis instruments. See `tools/README.md`. |
| `spikes/` | Working IOKit probes with real captured output. Evidence, not app code. |

## Non-negotiables

- **A false trigger costs more than a missed knock.** Every ambiguity resolves toward doing
  nothing. This is the tie-breaker for any tuning question.
- **Never decimate the sensor stream.** Rise time and the first 10 to 20 ms carry the entire
  signal. 100 Hz destroys both.
- **Never collapse the 3-axis vector to a scalar magnitude.** That vector is the only thing
  that differentiates this product.
- **No microphone in v1.** No mic permission, no privacy indicator. That is a feature.
- **No fabricated accuracy numbers.** Nothing measured, nothing claimed.
- **Hold out by desk, never by random split.** Random splits leak desk identity.

## Caveats

Private, undocumented API. Apple can change or remove SPU HID access in any macOS release.
The app is built to degrade loudly and specifically, naming the machine, the OS, and what was
looked for, rather than failing silently.
