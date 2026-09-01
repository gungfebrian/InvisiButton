# Tools

Command-line instruments. No SwiftPM, no dependencies — `swiftc` and the system frameworks only.

```bash
./tools/build.sh          # → tools/bin/capture
```

| File | What it is |
| --- | --- |
| `capture/main.swift` | **T-004.** Full-rate SPU IMU session recorder. The instrument every later stage is measured against. Format and labelling protocol are a contract — D-010. |

## capture

```bash
./tools/bin/capture --list      # which SPU devices matched
./tools/bin/capture --sanity    # 3 s health check: rate, drops, gravity, die temp
./tools/bin/capture --desk oak-dining --material solid-oak --compliance hard
```

Writes two files per session to `data/sessions/`:

- `<stamp>_desk-<id>_pose-<pose>_user-<user>.ibcap` — 32-byte little-endian records
- `…​.json` — sidecar: machine, desk, pose, user, label table, every label and mark event,
  per-channel report/drop/wrap/temperature counts

### Keys

```
l r f b c   knock left / right / front / back / on-chassis
t p n u d   typing · trackpad-click · laptop-nudge · cup-down · other desk impact
a           ambient          0   clear label to none
1 2 3       force: soft / normal / hard
SPACE       mark — "an event just happened"
?           help             q   finish and write the session
```

### The labelling protocol, in one line

**Set the label before you knock.** The label is a span; every sample carries it until you change
it. Onsets are recovered offline by the detector, so your reaction time never lands in the ground
truth. `SPACE` marks are for *counting* events, never for timing them.

### Reading a session

```python
import struct
REC = '<QIBBBBiiiI'   # t_ns, seq, chan, label, force, mark, x, y, z, temp
raw = open(path, 'rb').read()
for i in range(len(raw) // 32):
    t_ns, seq, chan, label, force, mark, x, y, z, temp = struct.unpack_from(REC, raw, i * 32)
    ax, ay, az = x / 65536, y / 65536, z / 65536      # g, or deg/s on chan 1
    celsius = temp / 65536
```

Three things that will bite you if you skip them:

1. **`seq` is 16-bit and wraps every 81.92 s.** Unwrap with `(seq - prev) % 65536` before using
   it as a sample index. A one-hour session wraps 44 times and nothing throws.
2. **`t_ns` is arrival time, not sample time** — p95 1615 µs against a 1250 µs period. Use `seq`.
3. **Channels are interleaved** in one file. Split on `chan` (0 = accel, 1 = gyro) first.

### Integrity

Every session prints `LOSSLESS` or `GAPPED` per channel, from the invariant
`seq_advance == reports - 1`. Verified across a counter wrap: 95 s, 152 047 records, 0 drops,
0 writer stalls.

**A `GAPPED` session is not automatically worthless.** Analysis windows are indexed by array
position, so a dropped report silently compresses real time inside a window — the same class of
bug as mishandling the seq wrap. The tools therefore reject *individual events* whose window spans
a discontinuity and report how many they dropped, rather than discarding the session.

Judge by where the loss is: four isolated single-sample gaps in 486 184 reports (0.0016%,
`desk4` negatives, 2026-08-31 — both channels stalling at identical timestamps, i.e. the process
being descheduled) costs four events. A sustained gap, a burst during the events you care about,
or any session with `sync stalls` above zero should be recaptured.

### The keyboard is part of the experiment

A keystroke couples into the chassis and reads at roughly the amplitude of a light desk knock,
arriving **0–13 ms before the key registers in software** (measured, `Mac17,2`). Every keystroke
is timestamped in the sidecar as `key_events`; `peek.py` excludes onsets within `[-5, +60] ms` of
one and tells you how many it dropped.

**Collection protocol: no keypresses between knocks.** Set the label, knock the whole block, then
move on. See D-011.

## peek.py

```bash
python3 tools/analyze/peek.py data/sessions/<stamp>_...ibcap
```

Descriptive only — it reports what is in the file and deliberately does not classify anything or
produce an accuracy number. Onsets are found from the largest single-axis excursion, never from a
collapsed magnitude, and every readout keeps the three axes separate.
