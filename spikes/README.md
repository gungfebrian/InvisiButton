# Spikes

Throwaway probes kept as evidence. Not part of the app target. Sources only — binaries are
gitignored; build them as needed.

| File | What it is |
| --- | --- |
| **`spu-wake.swift`** | ⭐ **The reference implementation.** Wakes `AppleSPUHIDDriver`, then streams accel + gyro at 800 Hz, unprivileged. Start here — this is the code the app's `SensorReader` grows out of. |
| `spu-probe.swift` | First attempt. Opens SPU HID devices *without* waking the driver → zero reports forever. Kept as the negative case. |
| `spu-diag.swift` | Dumps report descriptors, HID elements, and feature reports. Proves no HID-level enable command exists (`maxFeatureReportSize = 0` everywhere) and decodes the usage-4 ambient light sensor. |
| `spu-seize-test.swift` | `kIOHIDOptionsTypeSeizeDevice` does not help. Negative result. |
| `spu-eventsystem*.swift` | `IOHIDEventSystemClient` probes across all client types. All return `services=0`. Dead end, kept so nobody retries it. |

```bash
swiftc -O spikes/spu-wake.swift -o spikes/spu-wake && ./spikes/spu-wake
```

Expected: `ACCEL … 800 Hz … rest |v| ≈ 1.00 g`. No sudo.

## The one thing to know

Opening the `AppleSPUHIDDevice` is not enough — it succeeds and then delivers nothing, silently,
forever. The driver service must be woken first. See D-008.
