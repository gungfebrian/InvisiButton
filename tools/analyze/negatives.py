#!/usr/bin/env python3
"""Amplitude distributions per class, and how much they overlap a knock.

    python3 tools/analyze/negatives.py <negatives.ibcap> [knocks.ibcap]

Groundwork for T-007 and T-009. Reports what the onset amplitudes look like for
each labelled class and how often a negative class reaches knock amplitude.

This is NOT a false-positive rate. It is an amplitude-overlap measurement on
whatever sessions you point it at, with the comparison threshold taken from the
knock session's own 5th percentile. A false-positive rate is what the T-012
harness produces over a real hour with a real detector, and none exists yet.

Two things the arithmetic depends on:

  * Events whose window spans a dropped report are rejected. Windows are indexed
    by array position, so a gap silently compresses real time inside them.
  * Label keystrokes are excluded (D-011) — a finger on the keyboard is a chassis
    impulse at roughly the amplitude of a light desk knock.
"""

import json
import struct
import sys
from pathlib import Path

REC = "<QIBBBBiiiI"
RECSZ = 32
SCALE = 65536.0
ONSET_SIGMA = 12.0
REFRACTORY = 200          # samples, 250 ms
WINDOW = 120              # samples, 150 ms
KEY_LO_MS, KEY_HI_MS = -5.0, 60.0


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def robust_sigma(v):
    m = median(v)
    return 1.4826 * median([abs(x - m) for x in v]) or 1e-12


def pct(v, q):
    if not v:
        return 0.0
    s = sorted(v)
    return s[min(len(s) - 1, int(q * len(s)))]


def analyse(path):
    meta = json.loads(Path(path).with_suffix(".json").read_text())
    raw = Path(path).read_bytes()
    acc, gyr = [], []
    for i in range(len(raw) // RECSZ):
        t, seq, chan, lab, frc, mk, x, y, z, tmp = struct.unpack_from(REC, raw, i * RECSZ)
        (acc if chan == 0 else gyr).append((t, x / SCALE, y / SCALE, z / SCALE, seq))

    A = [[r[k] for r in acc] for k in (1, 2, 3)]
    G = [[r[k] for r in gyr] for k in (1, 2, 3)]
    ba, sa = [median(a) for a in A], [robust_sigma(a) for a in A]
    bg = [median(g) for g in G]

    agaps = {i for i in range(1, len(acc)) if (acc[i][4] - acc[i - 1][4]) % 65536 != 1}

    spans = [(e["t_ns"], e["name"]) for e in meta.get("label_events", []) if "label" in e]

    def label_at(t):
        cur = "none"
        for ts, nm in spans:
            if ts <= t:
                cur = nm
        return cur

    keys = [e["t_ns"] for e in meta.get("key_events", [])]

    onsets, last = [], -10 ** 9
    for i in range(len(A[0])):
        if max(abs(A[k][i] - ba[k]) / sa[k] for k in range(3)) >= ONSET_SIGMA \
                and i - last > REFRACTORY:
            onsets.append(i)
            last = i

    out, rejected = {}, 0
    for i in onsets:
        if i + WINDOW >= len(A[0]):
            continue
        if any(g in agaps for g in range(i, i + WINDOW + 1)):
            rejected += 1
            continue
        t = acc[i][0]
        if keys:
            d = (min(keys, key=lambda k: abs(k - t)) - t) / 1e6
            if KEY_LO_MS <= d <= KEY_HI_MS:
                continue
        gi = min(range(max(0, i - 40), min(len(gyr), i + 120)),
                 key=lambda j: abs(gyr[j][0] - t))

        def peak(S, b, lo):
            return max((abs(S[k] - b) for k in range(max(0, lo), min(len(S), lo + WINDOW))),
                       default=0.0)

        out.setdefault(label_at(t), []).append((
            max(peak(A[k], ba[k], i) for k in range(3)),
            max(peak(G[k], bg[k], gi) for k in (0, 1))))

    dur = {}
    for j, (ts, nm) in enumerate(spans):
        end = spans[j + 1][0] if j + 1 < len(spans) else int(meta["duration_s"] * 1e9)
        dur[nm] = dur.get(nm, 0) + (end - ts) / 1e9

    return out, dur, sa, meta, rejected


def main(neg_path, knock_path=None):
    neg, dur, sa, meta, rej = analyse(neg_path)
    d = meta["desk"]
    print(f"desk {d['id']}  ({d['material']}, {d['compliance']})  "
          f"{meta['channels'][0]['temp_c_min']:.1f} °C")
    print(f"accel noise floor  x={sa[0]*1000:.2f} y={sa[1]*1000:.2f} z={sa[2]*1000:.2f} mg")
    if rej:
        print(f"{rej} event(s) rejected for spanning a dropped report")

    rows = []
    if knock_path:
        kn, kdur, _, _, krej = analyse(knock_path)
        for c in ("knock-left", "knock-right"):
            if kn.get(c):
                rows.append((c, kn[c], kdur.get(c, 1)))
        if krej:
            print(f"{krej} knock event(s) rejected for spanning a dropped report")
    for c in ("typing", "trackpad-click", "laptop-nudge", "cup-down",
              "desk-impact-other", "ambient"):
        if c in neg or c in dur:
            rows.append((c, neg.get(c, []), dur.get(c, 1)))

    print(f"\n{'class':<19}{'events':>7}{'per min':>9}   "
          f"{'accel |peak| mg  p10/p50/p90':<30}{'gyro °/s p50':>13}")
    for cls, v, d_ in rows:
        if not v:
            print(f"{cls:<19}{0:>7}{0:>9.1f}   nothing crossed the {ONSET_SIGMA:.0f}-sigma threshold")
            continue
        a = [x[0] * 1000 for x in v]
        g = [x[1] for x in v]
        print(f"{cls:<19}{len(v):>7}{60*len(v)/d_:>9.1f}   "
              f"{pct(a,.1):>7.1f} /{median(a):>7.1f} /{pct(a,.9):>7.1f}          {median(g):>7.2f}")

    if knock_path:
        allk = [x[0] * 1000 for c in ("knock-left", "knock-right") for x in kn.get(c, [])]
        if allk:
            thr = pct(allk, .05)
            print(f"\nknock 5th-percentile accel peak: {thr:.1f} mg — "
                  f"how often each class reaches it")
            for cls in ("typing", "trackpad-click", "laptop-nudge", "cup-down", "ambient"):
                v = [x[0] * 1000 for x in neg.get(cls, [])]
                above = sum(1 for x in v if x >= thr)
                d_ = dur.get(cls, 1)
                print(f"   {cls:<18}{above:>4} of {len(v):>4}   {60*above/d_:>6.1f} per minute")
    print("\nAmplitude overlap, not a false-positive rate. See T-012.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(64)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
