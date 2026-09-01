#!/usr/bin/env python3
"""T-012 — evaluation harness for the knock detector.

    python3 tools/detect/evaluate.py [data/sessions]

Reports recall and false positives per hour for the causal detector in
detector.py, sweeping the operating point and **holding out by desk**.

Holding out by desk is not a preference, it is the difference between a real
number and a fiction. Direction separability measured on this corpus scored ~90%
under a random split and chance across desks; a random split leaks desk identity
because knocks from one desk share a structural resonance. The same reasoning
applies to detection thresholds, which are calibrated against a desk's noise
floor and coupling.

GROUND TRUTH, and its limits
----------------------------
False positives are exact: a negative session contains no knocks by construction,
so every detection inside one is a false positive, and the session duration is
known. FP/hour is a real measurement.

Recall is approximate. The corpus records label *spans*, not knock timestamps —
by design (D-010), since operator reaction time would contaminate onset times.
The reference knock set is therefore the offline detector's events inside knock
spans: whole-session median and MAD, 12 sigma on the accelerometer, 250 ms
refractory. That detector had the whole file to work with and its counts match
the intended per-block knock counts closely, but it is a reference, not truth.
Recall figures carry its error.

Per Product Principle 1 the operating point is chosen for zero false positives
first, and recall second.
"""

import glob
import importlib.util
import sys
from collections import defaultdict
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "detector", str(Path(__file__).with_name("detector.py")))
D = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(D)

KNOCK_CLASSES = ("knock-left", "knock-right")
MATCH_MS = 60.0
OFFLINE_SIGMA = 12.0

# Sigma gates stay modest and fixed — they provide adaptivity to a changing
# noise floor. The operating point that is swept is the ABSOLUTE amplitude,
# because that is what the sixteenth pass showed transfers: typing measured
# 22 and 24 mg on two different desks while knocks ranged 110-276 mg.
K_ACCEL = 8.0
K_GYRO = 5.0
A_MIN_GRID = [0.020, 0.028, 0.035, 0.045, 0.060, 0.075]                 # g
RATIO_GRID = [0, 4, 8, 12, 16, 20, 25, 30, 40]                          # (deg/s) per g


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def robust_sigma(v):
    m = median(v)
    return 1.4826 * median([abs(x - m) for x in v]) or 1e-12


def offline_knocks(acc, spans, keys):
    """Reference knock set — non-causal, whole-session statistics.

    Keystroke artifacts are excluded (D-011). Without this the reference counts
    the operator's own label presses as knocks, and a detector that correctly
    rejects them is scored as having missed them.
    """
    A = [[r[k] for r in acc] for k in (1, 2, 3)]
    base = [median(a) for a in A]
    sig = [robust_sigma(a) for a in A]
    out, last = [], -10 ** 9
    for i in range(len(acc)):
        if max(abs(A[k][i] - base[k]) / sig[k] for k in range(3)) >= OFFLINE_SIGMA \
                and i - last > D.REFRACTORY:
            last = i
            t = acc[i][0]
            if D.label_at(spans, t) not in KNOCK_CLASSES:
                continue
            if keys:
                d = (min(keys, key=lambda k: abs(k - t)) - t) / 1e6
                if -5.0 <= d <= 60.0:
                    continue
            out.append(t)
    return out


class Session:
    def __init__(self, path):
        self.path = path
        self.acc, self.gyr, self.meta = D.load(path)
        self.desk = self.meta["desk"]["id"]
        self.spans = D.label_spans(self.meta)
        names = {n for _, n in self.spans}
        self.is_knock = bool(names & set(KNOCK_CLASSES))
        self.is_neg = bool(names - set(KNOCK_CLASSES) - {"none"})
        self.ascore = D.score_stream(self.acc)
        self.gscore = D.score_stream(self.gyr)
        self.keys = [e["t_ns"] for e in self.meta.get("key_events", [])]
        self.ref = offline_knocks(self.acc, self.spans, self.keys) if self.is_knock else []
        # seconds spent in each non-knock class
        self.neg_dur = defaultdict(float)
        for j, (ts, nm) in enumerate(self.spans):
            end = self.spans[j + 1][0] if j + 1 < len(self.spans) \
                else int(self.meta["duration_s"] * 1e9)
            if nm not in KNOCK_CLASSES:
                self.neg_dur[nm] += (end - ts) / 1e9

    def run(self, a_min, ratio_min, both=True):
        return D.detect(self.acc, self.gyr, K_ACCEL, K_GYRO, require_both=both,
                        ascore=self.ascore, gscore=self.gscore,
                        a_min=a_min, ratio_min=ratio_min)


def score(sessions, a_min, ratio_min, both=True):
    """Returns (recall, hits, refs, fp_total, fp_hours, fp_by_class)."""
    hits = refs = 0
    fp = 0
    hours = 0.0
    by_class = defaultdict(int)
    for s in sessions:
        det = [t for t, _, _ in s.run(a_min, ratio_min, both)]
        if s.is_knock:
            refs += len(s.ref)
            used = set()
            for r in s.ref:
                for j, t in enumerate(det):
                    if j not in used and abs(t - r) <= MATCH_MS * 1e6:
                        used.add(j)
                        hits += 1
                        break
        for t in det:
            cls = D.label_at(s.spans, t)
            if cls not in KNOCK_CLASSES and cls != "none":
                fp += 1
                by_class[cls] += 1
        for nm, sec in s.neg_dur.items():
            if nm != "none":
                hours += sec / 3600.0
    recall = hits / refs if refs else 0.0
    return recall, hits, refs, fp, hours, by_class


def main(root="data/sessions"):
    paths = sorted(glob.glob(f"{root}/*.ibcap"))
    print(f"loading {len(paths)} sessions…")
    sessions = []
    for p in paths:
        s = Session(p)
        if s.is_knock or s.is_neg:
            sessions.append(s)
    desks = sorted({s.desk for s in sessions})
    print(f"{len(sessions)} usable · desks {', '.join(desks)}")
    for d in desks:
        ss = [s for s in sessions if s.desk == d]
        nk = sum(len(s.ref) for s in ss)
        nh = sum(sum(s.neg_dur.values()) for s in ss) / 3600
        print(f"   {d}: {len(ss)} sessions · {nk} reference knocks · "
              f"{nh*60:.1f} min of negatives")

    print("\n── recall by desk at a mid operating point (35 mg / ratio 16) ──")
    for d in desks:
        ss = [s for s in sessions if s.desk == d and s.is_knock]
        if not ss:
            continue
        r, h, rf, _, _, _ = score(ss, 0.035, 16)
        print(f"   {d}: recall {r:5.1%} ({h}/{rf})")

    print("\n── single channel vs conjunction, all data, at a fixed gyro threshold ──")
    for both, lbl in ((False, "amplitude only"), (True, "amplitude + ratio")):
        r, h, rf, fp, hrs, bc = score(sessions, 0.035, 16, both)
        print(f"   {lbl:<16} recall {r:5.1%} ({h}/{rf})   "
              f"false positives {fp} in {hrs*60:.0f} min"
              + (f"   {dict(bc)}" if bc else ""))

    print("\n── operating-point sweep, all data (Pareto front) ──")
    pts = []
    for am in A_MIN_GRID:
        for rm in RATIO_GRID:
            r, h, rf, fp, hrs, bc = score(sessions, am, rm)
            pts.append((fp, -r, am, rm, r, h, rf, hrs, dict(bc)))
    pts.sort()
    seen_r = -1
    print(f"   {'FP/hour':>8} {'recall':>7}   {'a_min':>6} {'ratio':>6}   breakdown")
    for fp, negr, am, rm, r, h, rf, hrs, bc in pts:
        if r <= seen_r:
            continue
        seen_r = r
        print(f"   {fp/hrs:>8.0f} {r:>7.1%}   {am*1000:>4.0f}mg {rm:>6} "
              f"  {bc if bc else 'none'}")

    print("\n── T-012: held out BY DESK ──")
    print("   operating point chosen on the training desks for zero false")
    print("   positives, then maximum recall; reported on the held-out desk.\n")
    for held in desks:
        train = [s for s in sessions if s.desk != held]
        test = [s for s in sessions if s.desk == held]
        if not any(s.is_knock for s in test):
            continue
        best = None
        for am in A_MIN_GRID:
            for rm in RATIO_GRID:
                r, h, rf, fp, hrs, _ = score(train, am, rm)
                if fp == 0 and (best is None or r > best[0]):
                    best = (r, am, rm)
        if best is None:
            print(f"   hold out {held}: no zero-FP point on the training desks")
            continue
        _, am, rm = best
        r, h, rf, fp, hrs, bc = score(test, am, rm)
        train_neg = sum(sum(s.neg_dur.values()) for s in train) / 3600
        fph = fp / hrs if hrs else float("nan")
        print(f"   hold out {held}:  a_min={am*1000:.0f} mg  ratio_min={rm} "
              f"(chosen on {train_neg*60:.0f} min of training negatives)")
        print(f"      recall {r:5.1%} ({h}/{rf})", end="")
        if hrs:
            print(f"   false positives {fp} in {hrs*60:.1f} min = {fph:.1f}/hour"
                  + (f"   {dict(bc)}" if bc else ""))
        else:
            print("   (no negative data on this desk)")

    print("\nRecall is measured against an offline reference detector, not against")
    print("knock timestamps, which the corpus deliberately does not record (D-010).")
    print("False positives are exact. Negative coverage is minutes, not the hour")
    print("the Phase 1 gate requires.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data/sessions")
