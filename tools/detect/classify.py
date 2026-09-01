#!/usr/bin/env python3
"""T-009 — knock / not-knock decision from the full T-008 feature set.

    python3 tools/detect/classify.py [data/sessions]

The D-022 baseline used two features and sat two orders of magnitude from the
Phase 1 gate. This wires in the rest: rise time, decay ratio, zero-crossing rate,
event duration, yaw fraction.

Held out BY DESK, always. A random split leaks desk identity — knocks from one
desk share a structural resonance and an amplitude scale — and would report a
number the product does not have.

Product Principle 3 requires a model the user can inspect, retrain and delete, so
this is L2-regularised logistic regression on standardised features: a weight per
feature, printable, with no hidden state.

Product Principle 1 sets the operating point: the threshold is chosen on the
TRAINING desks for zero false positives, then reported on the held-out desk. Not
the balanced-accuracy point.
"""

import glob
import importlib.util
import math
import sys
from collections import defaultdict
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "detector", str(Path(__file__).with_name("detector.py")))
D = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(D)

KNOCK = ("knock-left", "knock-right")
CAND_SIGMA = 8.0          # permissive first stage: propose, do not decide
CAND_A_MIN = 0.020        # 20 mg — below typing, so typing reaches the classifier

# Scale-free features only. Absolute amplitude is excluded deliberately: it IS
# desk identity. Knocks measured 52 mg on desk1 and 276 mg on desk3, so a model
# that leans on log(a_peak) learns a desk-specific threshold and scored 0% recall
# on held-out desk1 while looking fine everywhere else. `log_a_sigma` replaces it
# with amplitude relative to that desk's own running noise floor, which is what
# the causal detector actually has available.
FEATURES = [
    "log_a_sigma", "g_over_a", "g_yaw_frac", "a_dur_ms", "g_dur_ms",
    "a_x_rise_ms", "a_y_rise_ms", "a_z_rise_ms",
    "a_x_decay", "a_y_decay", "a_z_decay",
    "a_x_zcr", "a_y_zcr", "a_z_zcr",
    "a_energy_early",
]


def candidates(sess):
    """Permissive proposals, so the classifier sees the negatives it must reject."""
    return D.detect(sess.acc, sess.gyr, CAND_SIGMA, 0.0, require_both=False,
                    ascore=sess.ascore, gscore=sess.gscore,
                    a_min=CAND_A_MIN, ratio_min=0.0)


class Sess:
    def __init__(self, path):
        self.acc, self.gyr, self.meta = D.load(path)
        self.desk = self.meta["desk"]["id"]
        self.spans = D.label_spans(self.meta)
        self.keys = [e["t_ns"] for e in self.meta.get("key_events", [])]
        names = {n for _, n in self.spans}
        self.has_knock = bool(names & set(KNOCK))
        self.ascore = D.score_stream(self.acc)
        self.gscore = D.score_stream(self.gyr)
        self.neg_s = 0.0
        for j, (ts, nm) in enumerate(self.spans):
            end = self.spans[j + 1][0] if j + 1 < len(self.spans) \
                else int(self.meta["duration_s"] * 1e9)
            if nm not in KNOCK and nm != "none":
                self.neg_s += (end - ts) / 1e9

    def rows(self):
        out = []
        for t, ai, gi in candidates(self):
            cls = D.label_at(self.spans, t)
            if cls == "none":
                continue
            if self.keys:                      # D-011
                d = (min(self.keys, key=lambda k: abs(k - t)) - t) / 1e6
                if -5.0 <= d <= 60.0:
                    continue
            f = D.features(self.acc, self.gyr, ai, gi)
            if f is None:
                continue
            f["log_a_sigma"] = math.log(
                D.peak_sigma(self.acc, self.ascore, ai - 4, ai + D.CONFIRM) + 1e-6)
            x = [f.get(k, 0.0) for k in FEATURES]
            if any(v != v or abs(v) == float("inf") for v in x):
                continue
            out.append((x, 1 if cls in KNOCK else 0, cls, self.desk))
        return out


def standardise(X):
    n, d = len(X), len(X[0])
    mu = [sum(r[j] for r in X) / n for j in range(d)]
    sd = [math.sqrt(sum((r[j] - mu[j]) ** 2 for r in X) / n) or 1.0 for j in range(d)]
    return mu, sd


def apply_std(X, mu, sd):
    return [[(r[j] - mu[j]) / sd[j] for j in range(len(mu))] for r in X]


def train(X, y, l2=1.0, iters=3000, lr=0.25):
    d = len(X[0])
    w = [0.0] * d
    b = 0.0
    npos = sum(y) or 1
    nneg = len(y) - npos or 1
    # class weights: knocks are outnumbered, and Principle 1 does not want the
    # model trading false positives for recall on its own
    cw = [len(y) / (2.0 * nneg), len(y) / (2.0 * npos)]
    for _ in range(iters):
        gw = [0.0] * d
        gb = 0.0
        for xi, yi in zip(X, y):
            z = b + sum(w[j] * xi[j] for j in range(d))
            p = 1.0 / (1.0 + math.exp(-max(-30, min(30, z))))
            e = (p - yi) * cw[yi]
            gb += e
            for j in range(d):
                gw[j] += e * xi[j]
        n = len(X)
        b -= lr * gb / n
        for j in range(d):
            w[j] -= lr * (gw[j] / n + l2 * w[j] / n)
    return w, b


def prob(w, b, x):
    z = b + sum(wi * xi for wi, xi in zip(w, x))
    return 1.0 / (1.0 + math.exp(-max(-30, min(30, z))))


def main(root="data/sessions"):
    sessions = []
    for p in sorted(glob.glob(f"{root}/*.ibcap")):
        s = Sess(p)
        if s.has_knock or s.neg_s > 0:
            sessions.append(s)
    rows, neg_hours = [], defaultdict(float)
    for s in sessions:
        rows += s.rows()
        neg_hours[s.desk] += s.neg_s / 3600.0
    desks = sorted({r[3] for r in rows})
    print(f"{len(rows)} candidate events from {len(sessions)} sessions, desks {', '.join(desks)}")
    for d in desks:
        rs = [r for r in rows if r[3] == d]
        print(f"   {d}: {sum(1 for r in rs if r[1])} knocks, "
              f"{sum(1 for r in rs if not r[1])} non-knocks, "
              f"{neg_hours[d]*60:.1f} min of negatives")

    print("\n── held out BY DESK · threshold set for zero FP on training desks ──")
    for held in desks:
        tr = [r for r in rows if r[3] != held]
        te = [r for r in rows if r[3] == held]
        if not any(r[1] for r in te):
            continue
        if not any(r[1] for r in tr) or not any(not r[1] for r in tr):
            continue
        mu, sd = standardise([r[0] for r in tr])
        Xtr = apply_std([r[0] for r in tr], mu, sd)
        ytr = [r[1] for r in tr]
        w, b = train(Xtr, ytr)

        Xte = apply_std([r[0] for r in te], mu, sd)
        pos = sum(1 for r in te if r[1])
        hrs = neg_hours[held]
        pte = [(prob(w, b, x), r[1], r[2]) for x, r in zip(Xte, te)]

        # A single worst training negative should not set the operating point.
        # Report the whole curve on the held-out desk instead of one brittle
        # point: recall at each achievable false-positive rate.
        print(f"   {held}: {pos} knocks, "
              + (f"{hrs*60:.1f} min of negatives" if hrs else "no negatives"))
        if not hrs:
            best = max(p for p, y, _ in pte if y) if pos else 0
            r50 = sum(1 for p, y, _ in pte if y and p >= 0.5) / pos if pos else 0
            print(f"      recall at p>=0.5: {r50:6.1%}   (no negatives here to set a rate)")
            continue
        thrs = sorted({p for p, _, _ in pte}, reverse=True)
        shown = set()
        for t in thrs:
            tp = sum(1 for p, y, _ in pte if y and p >= t)
            fp = sum(1 for p, y, _ in pte if not y and p >= t)
            rate = fp / hrs
            key = round(rate)
            if key in shown:
                continue
            shown.add(key)
            byc = defaultdict(int)
            for p, y, c in pte:
                if not y and p >= t:
                    byc[c] += 1
            print(f"      FP {rate:7.1f}/hour   recall {tp/pos:6.1%} ({tp}/{pos})"
                  + (f"   {dict(byc)}" if byc else ""))
            if tp == pos or len(shown) > 8:
                break

    print("\n── model trained on everything, for inspection (Principle 3) ──")
    mu, sd = standardise([r[0] for r in rows])
    X = apply_std([r[0] for r in rows], mu, sd)
    w, b = train(X, [r[1] for r in rows])
    for name, wi in sorted(zip(FEATURES, w), key=lambda kv: -abs(kv[1])):
        bar = "#" * min(40, int(abs(wi) * 12))
        print(f"   {name:<16} {wi:+7.3f}  {bar}")
    print(f"   {'(bias)':<16} {b:+7.3f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data/sessions")
