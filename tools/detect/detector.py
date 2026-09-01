#!/usr/bin/env python3
"""T-007 + T-008 + T-009 — causal onset detection, features, knock decision.

Reference implementation for the Swift pipeline in Stage 4. Pure stdlib, no
third-party dependencies, so it ports directly to Accelerate/vDSP later.

CAUSAL. Every analysis written before this used whole-session statistics — a
median and MAD over the entire file — which the app cannot do. Nothing here
looks forward: the noise floor is a running estimate, and a decision about a
sample uses only samples at or before it, plus a fixed lookahead window that the
app will pay for as latency.

Design follows D-021: the accelerometer alone cannot reject laptop handling. On
laminate a nudge's median accel peak (142 mg) is larger than a knock's (110-128).
The gyroscope rejects it — nudges are acceleration without rotation — and the
gyroscope in turn cannot reject a cup being set down, which is rotation without
acceleration. The detector therefore requires BOTH channels to fire within a
coincidence window.

Never collapses the 3-axis vector to a scalar (Product Principle 5): the trigger
is the largest single-axis excursion, and every feature keeps the axes separate.
"""

import json
import math
import struct
from pathlib import Path

REC = "<QIBBBBiiiI"
RECSZ = 32
SCALE = 65536.0
FS = 800.0

# ── T-007 detector parameters ────────────────────────────────────────────────
BASELINE_ALPHA = 1.0 / 400      # ~0.5 s baseline: tracks gravity and slow tilt
DEV_ALPHA = 1.0 / 800           # ~1 s noise-scale estimate
HOLD_SAMPLES = 240              # 300 ms: freeze the BASELINE after a trigger so an
                                # impulse does not drag the gravity estimate
DEV_CLIP = 4.0                  # the noise scale is never frozen — it updates on a
                                # deviation clipped to this many sigma. A single
                                # impulse therefore cannot inflate it, while
                                # sustained activity (typing) legitimately raises
                                # it. Freezing the noise estimate during activity
                                # was a real bug: it pinned sigma at the
                                # quiet-room floor, so every keystroke read as
                                # ~50 sigma and the detector fired on all of them.
REFRACTORY = 200                # legacy fixed dead time, kept for the offline
                                # reference detector only
MIN_REFRACTORY = 48             # 60 ms — covers the confirm window, no more
REARM_SIGMA = 3.0               # re-arm when the signal returns to baseline...
REARM_SAMPLES = 8               # ...for 10 ms
# A fixed 250 ms dead time made a double knock physically undetectable: measured
# ring duration above the trigger is p50 41 ms, p90 154 ms, p99 225 ms, so 250 ms
# was chosen to clear the p99 ring — and a natural double knock arrives in
# 100-250 ms. Hysteresis re-arms on the signal actually decaying instead, so a
# fast-decaying knock re-arms in 60 ms while a long ring still cannot retrigger.
GYRO_AXES = (0, 1)              # roll and pitch only — see _peak_dev
CONFIRM = 64                    # 80 ms of lookahead. The sigma trigger fires on
                                # the leading edge, before the peak exists; the
                                # amplitude test must run on the windowed peak or
                                # it rejects real knocks for not having arrived
                                # yet. The app pays this as latency — 80 ms
                                # against the 150 ms budget in the Phase 1 gate.
WARMUP = 1600                   # 2 s before the estimator is trusted
FREEZE_SIGMA = 6.0              # the estimator freezes on ANY notable activity,
                                # not on the decision threshold — so the noise
                                # floor a sample sees does not depend on where
                                # the operating point happens to be set, and a
                                # threshold sweep compares like with like

# ── T-008 feature window ─────────────────────────────────────────────────────
PRE = 8                         # 10 ms before onset
POST = 120                      # 150 ms after onset
EARLY = 20                      # 25 ms — impulse portion
LATE = 80                       # 100 ms — decay portion


class ChannelDetector:
    """Running baseline and noise scale per axis, with a threshold crossing.

    The noise scale is an EWMA of absolute deviation, which is cheap, causal and
    robust enough. It adapts upward during sustained activity — typing raises its
    own floor, which is the behaviour wanted from "adaptive threshold over a
    rolling noise floor".
    """

    def __init__(self, k):
        self.k = k
        self.base = [0.0, 0.0, 0.0]
        self.dev = [0.0, 0.0, 0.0]
        self.n = 0
        self.hold = 0

    def push(self, x, y, z):
        """Feed one sample. Returns (sigma, absolute deviation), or None warming."""
        v = (x, y, z)
        if self.n == 0:
            self.base = list(v)
            self.dev = [1e-4] * 3
        self.n += 1

        score = 0.0
        dev3 = [0.0, 0.0, 0.0]
        for i in range(3):
            d = abs(v[i] - self.base[i])
            dev3[i] = d
            sg = d / (self.dev[i] or 1e-12)
            if sg > score:
                score = sg

        # Noise scale always updates, on a clipped deviation.
        for i in range(3):
            d = abs(v[i] - self.base[i])
            self.dev[i] += DEV_ALPHA * (min(d, DEV_CLIP * self.dev[i]) - self.dev[i])
        # Baseline freezes during an event so the impulse does not drag gravity.
        if self.hold > 0:
            self.hold -= 1
        else:
            for i in range(3):
                self.base[i] += BASELINE_ALPHA * (v[i] - self.base[i])

        if self.n < WARMUP:
            return None
        return (score, dev3)

    def trigger(self, score):
        if score is not None and score >= self.k:
            return True
        return False


def score_stream(stream):
    """One causal pass: per-sample excursion in sigma. Independent of any
    decision threshold, so a sweep thresholds this once-computed series."""
    det = ChannelDetector(FREEZE_SIGMA)
    out = []
    for s in stream:
        sc = det.push(s[1], s[2], s[3])
        out.append(sc)
        if sc is not None and sc[0] >= FREEZE_SIGMA:
            det.hold = HOLD_SAMPLES
    return out


def load(path):
    """Split a session into the two channels, preserving arrival order and gaps."""
    meta = json.loads(Path(path).with_suffix(".json").read_text())
    raw = Path(path).read_bytes()
    acc, gyr = [], []
    for i in range(len(raw) // RECSZ):
        t, seq, chan, lab, frc, mk, x, y, z, tmp = struct.unpack_from(REC, raw, i * RECSZ)
        (acc if chan == 0 else gyr).append((t, x / SCALE, y / SCALE, z / SCALE, seq))
    return acc, gyr, meta


def gap_indices(stream):
    return {i for i in range(1, len(stream))
            if (stream[i][4] - stream[i - 1][4]) % 65536 != 1}


def _peak_dev(stream, score, lo, hi, axes=(0, 1, 2)):
    """Largest absolute deviation from baseline over [lo,hi), across `axes`.

    Per-axis maximum, never an L2 magnitude (Product Principle 5).

    The gyroscope gate uses x and y only. A vertical desk impulse rotates the
    chassis in roll and pitch and produces almost no yaw — knock gyro z measured
    0.18 deg/s against 2.6-7.3 on x and y. Sliding the laptop is the opposite:
    it is largely yaw. Including z in the gyro peak hands a laptop nudge a
    knock-like rotation-per-acceleration ratio and defeats the gate.
    """
    best = 0.0
    for j in range(max(0, lo), min(len(stream), hi)):
        sc = score[j]
        if sc is None:
            continue
        for a in axes:
            if sc[1][a] > best:
                best = sc[1][a]
    return best


def detect(acc, gyr, k_accel, k_gyro, require_both=True,
           ascore=None, gscore=None, a_min=0.0, ratio_min=0.0,
           in_pattern_ms=0.0, in_pattern_scale=0.6, expect_lo_ms=0.0):
    """T-007 + T-009. Returns [(t_ns, accel_index, gyro_index)] for accepted knocks.

    Three stages.

    1. An adaptive sigma gate finds the onset.
    2. An absolute amplitude floor rejects typing, trackpad clicks and a cup
       being set down. That floor only has to clear typing, which measured 22 and
       24 mg on two different desks — it is a property of the chassis, not of the
       desk, so a fixed value transfers.
    3. A SCALE-FREE ratio gate, gyro peak per unit accel peak, rejects laptop
       handling. This has to be scale-free: knock amplitude spans 52 mg on desk1
       to 276 mg on desk3, and desk4's laptop nudges sit at 142 mg in the middle
       of that range. Any absolute amplitude threshold that rejects those nudges
       also rejects most desk1 knocks. Rotation per unit acceleration does not
       depend on how hard the knock was — a knock rotates the chassis, sliding
       the laptop does not (D-021).

    Pass precomputed score streams to sweep thresholds without re-running the
    estimator.
    """
    if ascore is None:
        ascore = score_stream(acc)
    if gscore is None:
        gscore = score_stream(gyr)

    # In-pattern sensitivity. For `in_pattern_ms` after a confirmed knock the
    # thresholds drop by `in_pattern_scale`, because a second or third knock of
    # a deliberate pattern lands on a chassis that is still ringing and reads
    # much smaller than the first. Measured: the third knock of a triple is
    # missed 23% of the time at the idle operating point.
    #
    # This costs nothing in idle false positives. The window only opens after a
    # knock has already been accepted, so the looser threshold is never applied
    # to the quiet stream where false positives are counted.
    in_pattern_samples = int(in_pattern_ms * 800 / 1000)

    # index gyro by time once, for the coincidence lookup
    onsets, last = [], -10 ** 9
    gj = 0
    quiet = REARM_SAMPLES          # samples spent below REARM_SIGMA
    armed = True
    for i, a in enumerate(acc):
        _since_ms = (i - last) * 1000.0 / 800.0
        inpat = (in_pattern_samples > 0
                 and expect_lo_ms <= _since_ms <= in_pattern_ms)
        ka = k_accel * in_pattern_scale if inpat else k_accel
        amin = a_min * in_pattern_scale if inpat else a_min
        sc = ascore[i]
        if sc is not None and sc[0] < REARM_SIGMA:
            quiet += 1
            if quiet >= REARM_SAMPLES and i - last > MIN_REFRACTORY:
                armed = True
        else:
            quiet = 0
        if sc is None or sc[0] < ka:
            continue
        if not armed or i - last <= MIN_REFRACTORY:
            continue
        apk = _peak_dev(acc, ascore, i - 4, i + CONFIRM)
        if apk < amin:
            continue
        # The gyro index is always resolved, even when the ratio gate is off.
        # Returning None here left every gyroscope feature at zero for the
        # classifier — silently blinding it to the channel that does the work.
        while gj + 1 < len(gyr) and gyr[gj][0] < a[0]:
            gj += 1
        if require_both:
            gpk = _peak_dev(gyr, gscore, gj - 4, gj + CONFIRM, axes=GYRO_AXES)
            if gpk / (apk + 1e-12) < ratio_min:
                continue
        onsets.append((a[0], i, gj))
        last = i
        armed = False
        quiet = 0
    return onsets


def peak_sigma(stream, score, lo, hi, axes=(0, 1, 2)):
    """Peak excursion in units of the RUNNING noise scale.

    Amplitude relative to the desk's own noise floor rather than in absolute g.
    Absolute amplitude carries desk identity — knocks measured 52 mg on desk1 and
    276 mg on desk3 — so a model that uses it fails on a held-out desk.
    """
    best = 0.0
    for j in range(max(0, lo), min(len(stream), hi)):
        sc = score[j]
        if sc is not None and sc[0] > best:
            best = sc[0]
    return best


# ── T-008 features ───────────────────────────────────────────────────────────

def _window(stream, idx, lo, hi):
    return [[stream[j][c] for j in range(max(0, idx + lo), min(len(stream), idx + hi))]
            for c in (1, 2, 3)]


def features(acc, gyr, ai, gi):
    """Per-event features. Axes stay separate; nothing is collapsed to a scalar."""
    A = _window(acc, ai, -PRE, POST)
    f = {}
    if not A[0]:
        return None
    base = [sum(c[:PRE]) / max(1, len(c[:PRE])) for c in A]

    for name, c, b in zip("xyz", A, base):
        d = [v - b for v in c]
        pk = max(d, key=abs) if d else 0.0
        at = d.index(pk) if d else 0
        f[f"a_{name}_peak"] = pk
        f[f"a_{name}_rise_ms"] = (at - PRE) * 1000.0 / FS
        e_early = sum(v * v for v in d[PRE:PRE + EARLY])
        e_late = sum(v * v for v in d[PRE + EARLY:PRE + LATE])
        f[f"a_{name}_decay"] = e_early / (e_late + 1e-12)
        zc = sum(1 for j in range(1, len(d)) if (d[j] > 0) != (d[j - 1] > 0))
        f[f"a_{name}_zcr"] = zc / max(1, len(d))

    f["a_peak"] = max(abs(f[f"a_{n}_peak"]) for n in "xyz")
    f["a_energy_early"] = sum(f[f"a_{n}_decay"] for n in "xyz") / 3

    if gi is not None:
        G = _window(gyr, gi, -PRE, POST)
        gbase = [sum(c[:PRE]) / max(1, len(c[:PRE])) for c in G]
        for name, c, b in zip("xyz", G, gbase):
            d = [v - b for v in c]
            pk = max(d, key=abs) if d else 0.0
            f[f"g_{name}_peak"] = pk
        f["g_peak"] = max(abs(f[f"g_{n}_peak"]) for n in "xyz")
        f["g_xy_peak"] = max(abs(f[f"g_{n}_peak"]) for n in "xy")
        f["g_yaw_frac"] = abs(f["g_z_peak"]) / (f["g_peak"] + 1e-12)
        # duration of the rotational event, the nudge/impulse discriminator
        gd = [max(abs(G[0][j] - gbase[0]), abs(G[1][j] - gbase[1]))
              for j in range(len(G[0]))]
        gthr = (max(gd) if gd else 0.0) * 0.5
        f["g_dur_ms"] = sum(1 for v in gd if v >= gthr) * 1000.0 / FS
    else:
        for name in "xyz":
            f[f"g_{name}_peak"] = 0.0
        f["g_peak"] = 0.0
        f["g_xy_peak"] = 0.0
        f["g_yaw_frac"] = 0.0
        f["g_dur_ms"] = 0.0

    # The D-021 discriminator: rotation per unit acceleration. A knock rotates
    # the chassis; sliding the laptop does not.
    f["g_over_a"] = f["g_xy_peak"] / (f["a_peak"] + 1e-12)

    # Duration above half-peak on the strongest accel axis — a nudge is
    # sustained, a knock is an impulse.
    best = max("xyz", key=lambda n: abs(f[f"a_{n}_peak"]))
    ci = "xyz".index(best)
    d = [v - base[ci] for v in A[ci]]
    thr = abs(f[f"a_{best}_peak"]) * 0.5
    f["a_dur_ms"] = sum(1 for v in d if abs(v) >= thr) * 1000.0 / FS
    return f


def label_spans(meta):
    return [(e["t_ns"], e["name"]) for e in meta.get("label_events", []) if "label" in e]


def label_at(spans, t):
    cur = "none"
    for ts, nm in spans:
        if ts <= t:
            cur = nm
    return cur
