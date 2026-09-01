#!/usr/bin/env python3
"""Read an .ibcap session and describe the events in it.

Groundwork for T-006. Deliberately descriptive: it reports what is in the file
and does not classify anything, score anything, or produce an accuracy number.

    python3 tools/analyze/peek.py data/sessions/<stamp>_...ibcap

Onsets are located per-axis, never from a collapsed magnitude (Product
Principle 5) — the detector triggers on the largest single-axis excursion, and
every readout below keeps the three axes separate.
"""

import json
import struct
import sys
from pathlib import Path

REC = "<QIBBBBiiiI"          # t_ns seq chan label force mark x y z temp
RECSZ = 32
SCALE = 65536.0
NOMINAL_DT = 1.0 / 800.0

ONSET_SIGMA = 12.0           # robust sigmas above the noise floor
BACKTRACK_SIGMA = 3.0        # walk back from the trigger to the true onset
KEY_ARTIFACT_LO_MS = -5.0    # a keystroke shows up 0-13 ms before the key
KEY_ARTIFACT_HI_MS = 60.0    # registers in software; exclude that window
REFRACTORY_S = 0.25
PRE_S = 0.008
POST_S = 0.150
EARLY_S = 0.010              # the "first 10 ms" window from RESEARCH.md


def load(path):
    raw = Path(path).read_bytes()
    n = len(raw) // RECSZ
    chans = {0: [], 1: []}
    marks = []
    for i in range(n):
        t, seq, chan, label, force, mark, x, y, z, temp = struct.unpack_from(REC, raw, i * RECSZ)
        chans[chan].append((t, seq, label, force, mark, x, y, z, temp))
    return chans, marks


def unwrap(seqs):
    """seq is 16-bit and wraps every 81.92 s at 800 Hz. Rebuild a monotonic index."""
    idx = [0]
    for i in range(1, len(seqs)):
        idx.append(idx[-1] + ((seqs[i] - seqs[i - 1]) % 65536))
    return idx


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def robust_sigma(v):
    m = median(v)
    return 1.4826 * median([abs(x - m) for x in v]) or 1e-12


def axes(recs, div=SCALE):
    return ([r[5] / div for r in recs],
            [r[6] / div for r in recs],
            [r[7] / div for r in recs])


def find_onsets(ax, sigma_mult=ONSET_SIGMA):
    """Largest single-axis excursion crosses N robust sigmas. Never a magnitude.

    The trigger fires partway up the impulse, so walk back to where the signal
    first left the noise floor — otherwise 'rise time' measures the detector's
    threshold, not the physics.
    """
    base = [median(a) for a in ax]
    sig = [robust_sigma(a) for a in ax]
    n = len(ax[0])
    refr = int(REFRACTORY_S * 800)
    onsets, last = [], -10 ** 9
    for i in range(n):
        score = max(abs(ax[k][i] - base[k]) / sig[k] for k in range(3))
        if score >= sigma_mult and i - last > refr:
            j = i
            while j > 0 and max(abs(ax[k][j - 1] - base[k]) / sig[k]
                                for k in range(3)) > BACKTRACK_SIGMA:
                j -= 1
            onsets.append(j)
            last = i
    return onsets, base, sig


def split_key_artifacts(onsets, acc, meta):
    """Separate real events from the operator's own keystrokes.

    A finger striking the keyboard couples into the chassis and reads at roughly
    the amplitude of a light desk knock. Measured on Mac17,2: the impulse lands
    0-13 ms *before* the keystroke registers in software. See D-011.
    """
    keys = [e["t_ns"] for e in meta.get("key_events", [])]
    if not keys:   # sessions captured before key logging existed
        keys = sorted([e["t_ns"] for e in meta.get("mark_events", [])] +
                      [e["t_ns"] for e in meta.get("label_events", [])])
    if not keys:
        return onsets, []
    real, artifact = [], []
    for i in onsets:
        t = acc[i][0]
        d = (min(keys, key=lambda k: abs(k - t)) - t) / 1e6
        (artifact if KEY_ARTIFACT_LO_MS <= d <= KEY_ARTIFACT_HI_MS else real).append(i)
    return real, artifact


def signed_peak(seq, lo, hi, base):
    """Extreme signed deviation in [lo,hi) and where it happened."""
    lo, hi = max(0, lo), min(len(seq), hi)
    best, at = 0.0, lo
    for i in range(lo, hi):
        d = seq[i] - base
        if abs(d) > abs(best):
            best, at = d, i
    return best, at


def main(path):
    side = Path(path).with_suffix(".json")
    meta = json.loads(side.read_text()) if side.exists() else {}
    chans, _ = load(path)
    acc, gyr = chans[0], chans[1]

    labels = {l["id"]: l["name"] for l in meta.get("labels", [])}
    print(f"file    {Path(path).name}")
    if meta:
        d = meta["desk"]
        print(f"desk    {d['id']}  ({d['material']}, {d['compliance']})  "
              f"pose {meta['pose']}  user {meta['user']}")
        for c in meta["channels"]:
            print(f"{c['name']:7} {c['reports']:6} reports  drops {c['drops']}  "
                  f"wraps {c['seq_wraps']}  {'LOSSLESS' if c['lossless'] else 'GAPPED'}  "
                  f"{c['temp_c_min']:.2f}–{c['temp_c_max']:.2f} °C")

    ax = axes(acc)
    gx = axes(gyr)
    onsets, base, sig = find_onsets(ax)
    onsets, artifacts = split_key_artifacts(onsets, acc, meta)
    print(f"\nnoise floor (robust sigma, accel)  x={sig[0]*1000:.2f}  "
          f"y={sig[1]*1000:.2f}  z={sig[2]*1000:.2f}  mg")
    print(f"onset threshold  {ONSET_SIGMA:.0f} sigma  "
          f"= {ONSET_SIGMA*sig[0]*1000:.1f}/{ONSET_SIGMA*sig[1]*1000:.1f}/"
          f"{ONSET_SIGMA*sig[2]*1000:.1f} mg per axis")

    marks = meta.get("mark_events", [])
    lab_spans = [(e["t_ns"], e["name"]) for e in meta.get("label_events", []) if "label" in e]

    def label_at(t):
        cur = "none"
        for ts, nm in lab_spans:
            if ts <= t:
                cur = nm
        return cur

    pre, post, early = int(PRE_S * 800), int(POST_S * 800), int(EARLY_S * 800)
    print(f"\n{len(onsets)} events · {len(artifacts)} keystroke artifacts excluded "
          f"· {len(marks)} operator marks\n")
    hdr = (f"{'#':>3} {'t_s':>7} {'label':<12} "
           f"{'peak ax':>8} {'ay':>8} {'az':>8}  "
           f"{'rise_ms':>7}  {'early sign':>10}  "
           f"{'gyro gx':>8} {'gy':>8} {'gz':>8}")
    print(hdr)
    print("-" * len(hdr))

    rows = []
    for k, i in enumerate(onsets):
        t = acc[i][0] / 1e9
        px, atx = signed_peak(ax[0], i - pre, i + post, base[0])
        py, aty = signed_peak(ax[1], i - pre, i + post, base[1])
        pz, atz = signed_peak(ax[2], i - pre, i + post, base[2])
        rise = (max(atx, aty, atz) - i) * NOMINAL_DT * 1000
        ex, _ = signed_peak(ax[0], i, i + early, base[0])
        ey, _ = signed_peak(ax[1], i, i + early, base[1])
        ez, _ = signed_peak(ax[2], i, i + early, base[2])
        sgn = f"{'+' if ex>0 else '-'}{'+' if ey>0 else '-'}{'+' if ez>0 else '-'}"

        # gyro is a separate device with its own index; align on t_ns
        gi = min(range(len(gyr)), key=lambda j: abs(gyr[j][0] - acc[i][0]))
        gbase = [median(g) for g in gx]
        ggx, _ = signed_peak(gx[0], gi - pre, gi + post, gbase[0])
        ggy, _ = signed_peak(gx[1], gi - pre, gi + post, gbase[1])
        ggz, _ = signed_peak(gx[2], gi - pre, gi + post, gbase[2])

        lbl = label_at(acc[i][0])
        rows.append((lbl, px, py, pz, ex, ey, ez, sgn, ggx, ggy, ggz, rise))
        print(f"{k+1:>3} {t:>7.2f} {lbl:<12} "
              f"{px:>8.3f} {py:>8.3f} {pz:>8.3f}  "
              f"{rise:>7.1f}  {sgn:>10}  "
              f"{ggx:>8.1f} {ggy:>8.1f} {ggz:>8.1f}")

    # ── consistency, per label ────────────────────────────────────────────────
    from collections import defaultdict
    by = defaultdict(list)
    for r in rows:
        by[r[0]].append(r)

    for lbl, rs in by.items():
        if len(rs) < 3:
            continue
        print(f"\n── {lbl}  (n={len(rs)}) ──")
        sgns = defaultdict(int)
        for r in rs:
            sgns[r[7]] += 1
        top = sorted(sgns.items(), key=lambda kv: -kv[1])
        print("  early-10ms sign pattern (x,y,z):  " +
              "   ".join(f"{s} ×{c}" for s, c in top))
        print(f"  dominant pattern {top[0][0]} in {top[0][1]}/{len(rs)} events")
        for name, j in (("accel peak x", 1), ("accel peak y", 2), ("accel peak z", 3)):
            v = [r[j] for r in rs]
            print(f"  {name:14} median {median(v):+7.3f} g   "
                  f"range {min(v):+7.3f} .. {max(v):+7.3f}")
        for name, j in (("gyro peak x", 8), ("gyro peak y", 9), ("gyro peak z", 10)):
            v = [r[j] for r in rs]
            print(f"  {name:14} median {median(v):+7.1f} °/s range {min(v):+7.1f} .. {max(v):+7.1f}")
        rise = [r[11] for r in rs]
        print(f"  rise to peak   median {median(rise):.1f} ms  "
              f"range {min(rise):.1f} .. {max(rise):.1f}")

    # ── operator reaction delay: validates D-010's span labelling ─────────────
    if marks and onsets:
        ot = [acc[i][0] for i in onsets]
        delays = []
        for m in marks:
            prior = [t for t in ot if t <= m["t_ns"]]
            if prior:
                delays.append((m["t_ns"] - prior[-1]) / 1e6)
        if delays:
            print(f"\noperator reaction delay, mark minus preceding onset  "
                  f"median {median(delays):.0f} ms   "
                  f"range {min(delays):.0f} .. {max(delays):.0f} ms   (n={len(delays)})")
            print("this is why labels are spans and marks are not onset timestamps — D-010")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(64)
    main(sys.argv[1])
