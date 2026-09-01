#!/usr/bin/env python3
"""Direction separability and cross-session transfer — the analysis of record.

    python3 tools/analyze/transfer.py [data/sessions]

This file exists because the transfer analysis was changed twice after seeing
results, which is how a finding gets talked into existence (D-016). The
parameters below are frozen. Changing any of them invalidates comparison with
every number already recorded in RESEARCH.md, so a change means a new decision
entry and a re-run of everything, not a quiet edit.

FROZEN PARAMETERS — as of 2026-08-30, D-016
-------------------------------------------
channel            gyroscope x (roll). Chosen in the fifth pass; accel x/y sit
                   at 4-5x the noise floor and separated nothing.
onset detection    on the gyroscope itself, never the accelerometer — a
                   cross-device t_ns alignment error of +/-2 ms is a large
                   fraction of a 15-20 ms structural period (D-012).
                   trigger  max(|gx|,|gy|) >= 8 robust sigma
                   backtrack to the last sample above 2.5 sigma
                   refractory 250 ms
window             0 to 100 ms after onset (80 samples at 800 Hz)
event scaling      unit L2 norm. Template norms vary by 5x across sessions;
                   without this, a source threshold lands arbitrarily on a
                   target at a different amplitude scale (D-016).
template           unit-normalised (mean_left - mean_right) of the source
threshold          the TARGET's own median projection. Uses no target labels,
                   and is valid because every session is near class-balanced.
polarity           resolved by taking the better of the two sign assignments;
                   label-free thresholding cannot identify sign.
score              BALANCED accuracy, (TPR_left + TPR_right) / 2, reported as an
                   equivalent count. Plain accuracy degenerates: on an imbalanced
                   session, max(correct, n - correct) returns the majority-class
                   count for every template, which is what made an entire column
                   of the first transfer matrix read 12/16 regardless of source.
null               CIRCULAR SHIFT of the label sequence in event order, which
                   preserves the contiguous left-block / right-block structure
                   and moves only the boundary. A label SHUFFLE is not a valid
                   null here: the classes were collected as contiguous blocks, so
                   any projection with a slow drift component separates them, and
                   shuffling destroys exactly the structure that needs
                   controlling. Under the shuffle null these sessions read
                   p = 0.003; under the correct null they read p = 0.02-0.05.
significance       p < 0.05 against the circular-shift null

CORRECTION, 2026-08-30: the two entries above replace a plain-accuracy score with
a 300-shuffle null. Both were demonstrated wrong, not merely disliked - the
degeneracy is arithmetic, and the shift-median of ~75% shows contiguous blocks
separate under almost any projection. Every figure recorded before this change
was computed the old way.

These are exploratory separability figures on a small number of desks. None of
them is a product accuracy number, and none may enter PRODUCT.md or any copy
until the T-012 harness produces one on real hardware.
"""

import glob
import json
import math
import random
import struct
import sys
from pathlib import Path

REC = "<QIBBBBiiiI"
RECSZ = 32
SCALE = 65536.0
W = 80                    # 100 ms at 800 Hz
TRIGGER_SIGMA = 8.0
BACKTRACK_SIGMA = 2.5
REFRACTORY = 200          # samples
N_SHUFFLE = 300
ALPHA = 0.05
SEED = 1729

CLASSES = ("knock-left", "knock-right")


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def robust_sigma(v):
    m = median(v)
    return 1.4826 * median([abs(x - m) for x in v]) or 1e-12


def load_session(path):
    """Return (name, [(label, unit_norm_waveform), ...]) or None if unusable."""
    side = Path(path).with_suffix(".json")
    if not side.exists():
        return None
    meta = json.loads(side.read_text())
    spans = [(e["t_ns"], e["name"]) for e in meta.get("label_events", []) if "label" in e]
    if len({n for _, n in spans} & set(CLASSES)) < 2:
        return None                      # single-label session, not a transfer case

    raw = Path(path).read_bytes()
    gyr = []
    for i in range(len(raw) // RECSZ):
        t, seq, chan, lab, frc, mk, x, y, z, tmp = struct.unpack_from(REC, raw, i * RECSZ)
        if chan == 1:
            gyr.append((t, x / SCALE, y / SCALE, z / SCALE, seq))

    G = [[r[k] for r in gyr] for k in (1, 2, 3)]
    base = [median(g) for g in G]
    sig = [robust_sigma(g) for g in G]

    # Windows are indexed by array position, so a dropped report silently
    # compresses real time inside the window. Mark every discontinuity and
    # reject any event whose window spans one. seq is 16-bit — mod 65536.
    gaps = {i for i in range(1, len(gyr))
            if (gyr[i][4] - gyr[i - 1][4]) % 65536 != 1}

    def label_at(t):
        cur = "none"
        for ts, nm in spans:
            if ts <= t:
                cur = nm
        return cur

    onsets, last = [], -10 ** 9
    for i in range(len(G[0])):
        if max(abs(G[k][i] - base[k]) / sig[k] for k in (0, 1)) >= TRIGGER_SIGMA \
                and i - last > REFRACTORY:
            j = i
            while j > 0 and max(abs(G[k][j - 1] - base[k]) / sig[k]
                                for k in (0, 1)) > BACKTRACK_SIGMA:
                j -= 1
            onsets.append(j)
            last = i

    keys = [e["t_ns"] for e in meta.get("key_events", [])]
    events = []
    dropped_for_gaps = 0
    for i in onsets:
        if i + W >= len(G[0]):
            continue
        if any(g in gaps for g in range(i, i + W + 1)):
            dropped_for_gaps += 1
            continue
        t = gyr[i][0]
        if keys:                          # D-011: drop the operator's own keystrokes
            d = (min(keys, key=lambda k: abs(k - t)) - t) / 1e6
            if -5.0 <= d <= 60.0:
                continue
        lab = label_at(t)
        if lab not in CLASSES:
            continue
        w = [G[0][i + k] - base[0] for k in range(W)]
        n = math.sqrt(sum(v * v for v in w)) or 1e-12
        blk = max(sum(1 for ts, _ in spans if ts <= t) - 1, 0)   # which label span
        events.append((lab, [v / n for v in w], blk))

    d = meta["desk"]
    name = f"{d['id']}.{meta['pose']}"
    if dropped_for_gaps:
        print(f"   note: {name} — {dropped_for_gaps} event(s) rejected for spanning "
              f"a dropped report")
    return name, events, meta


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def mean_wave(ws):
    return [sum(w[k] for w in ws) / len(ws) for k in range(W)]


def template(events, labels):
    left = [e[1] for e, l in zip(events, labels) if l == "knock-left"]
    right = [e[1] for e, l in zip(events, labels) if l == "knock-right"]
    if not left or not right:
        return None
    t = [a - b for a, b in zip(mean_wave(left), mean_wave(right))]
    n = math.sqrt(dot(t, t)) or 1e-12
    return [v / n for v in t]


def evaluate(events, labels, t):
    """Balanced accuracy as an equivalent count, after label-free thresholding.

    Balanced rather than plain: plain accuracy lets a template that predicts one
    class everywhere score the majority-class rate, which is not separation.
    """
    proj = [dot(e[1], t) for e in events]
    th = median(proj)
    n = len(events)
    best = 0.0
    for flip in (False, True):
        tp = {c: 0 for c in CLASSES}
        tot = {c: 0 for c in CLASSES}
        for p, l in zip(proj, labels):
            hi = (p > th) != flip
            pred = "knock-left" if hi else "knock-right"
            tot[l] += 1
            tp[l] += (pred == l)
        if all(tot[c] for c in CLASSES):
            ba = 0.5 * sum(tp[c] / tot[c] for c in CLASSES)
            best = max(best, ba)
    return int(round(best * n))


def shift_p(events, labels, t, observed):
    """Circular-shift null: keeps the contiguous block structure, moves the boundary."""
    n = len(labels)
    ge = tot = 0
    for k in range(1, n):
        rot = labels[k:] + labels[:k]
        if len(set(rot)) < 2:
            continue
        tot += 1
        ge += (evaluate(events, rot, t) >= observed)
    return (ge + 1) / (tot + 1) if tot else 1.0


def in_sample(events, labels):
    """Score a session against a template built from those same labels."""
    t = template(events, labels)
    return evaluate(events, labels, t) if t else 0


def block_report(sessions, order):
    """Leave-one-block-out CV with a block-label permutation null.

    Added 2026-08-30 for sessions collected under D-017 (many short randomised
    blocks). Knocks inside one block share hand position and a moment in time, so
    they are not independent; holding out whole blocks is the honest estimate.
    The null permutes BLOCK labels, keeping each block intact — the block-aware
    analogue of the circular shift used for two-block sessions.

    Resolution floor is 1 / C(n_blocks, n_left_blocks): six blocks split 3/3 give
    p >= 0.05, eight split 4/4 give p >= 0.014. More blocks buy more resolution.
    """
    from itertools import combinations
    print("\nLEAVE-ONE-BLOCK-OUT — sessions with 4+ label blocks (D-017 protocol)")
    shown = False
    for name in order:
        ev, meta = sessions[name]
        blocks = sorted({e[2] for e in ev})
        if len(blocks) < 4:
            continue
        shown = True
        blab = {}
        for b in blocks:
            ls = [e[0] for e in ev if e[2] == b]
            blab[b] = max(set(ls), key=ls.count)

        def lobo(assign):
            per = {c: [0, 0] for c in CLASSES}
            tot = 0
            for held in blocks:
                tr = [e for e in ev if e[2] != held]
                trl = [assign[e[2]] for e in tr]
                if len(set(trl)) < 2:
                    continue
                t = template(tr, trl)
                if t is None:
                    continue
                pr = sorted(dot(e[1], t) for e in tr)
                th = pr[len(pr) // 2]
                truth = assign[held]
                for e in (x for x in ev if x[2] == held):
                    pred = "knock-left" if dot(e[1], t) > th else "knock-right"
                    per[truth][1] += 1
                    per[truth][0] += (pred == truth)
                    tot += 1
            if not all(per[c][1] for c in CLASSES):
                return 0.0, tot
            ba = 0.5 * sum(per[c][0] / per[c][1] for c in CLASSES)
            return max(ba, 1 - ba), tot

        obs, tot = lobo(blab)
        nleft = len([b for b in blocks if blab[b] == "knock-left"])
        nulls = sorted(lobo({b: ("knock-left" if b in combo else "knock-right")
                             for b in blocks})[0]
                       for combo in combinations(blocks, nleft))
        ge = sum(1 for v in nulls if v >= obs - 1e-9)
        p = ge / len(nulls)
        seq = "".join("L" if blab[b] == "knock-left" else "R" for b in blocks)
        print(f"   {name:<18} blocks {len(blocks)} [{seq}]  events {tot}")
        print(f"      leave-one-block-out balanced accuracy {obs:.3f}"
              f"   null median {nulls[len(nulls)//2]:.3f}  max {nulls[-1]:.3f}")
        print(f"      p = {p:.3f} over {len(nulls)} block-label assignments"
              f" (floor {1/len(nulls):.3f})"
              f"   {'SEPARATES' if p < 0.05 else 'not significant'}")
    if not shown:
        print("   (none — every session has fewer than 4 label blocks)")


def main(root="data/sessions"):
    rng = random.Random(SEED)
    sessions = {}
    order = []
    for p in sorted(glob.glob(f"{root}/*.ibcap")):
        r = load_session(p)
        if r is None:
            continue
        name, ev, meta = r
        if len(ev) < 8:
            continue
        if name in sessions:            # later session of the same desk+pose
            name = f"{name}#{sum(1 for o in order if o.startswith(name)) + 1}"
        sessions[name] = (ev, meta)
        order.append(name)

    print("sessions (single-label sessions are skipped as untestable)\n")
    for n in order:
        ev, meta = sessions[n]
        lb = [e[0] for e in ev]
        print(f"   {n:<18} n={len(ev):3}  left={lb.count('knock-left'):3} "
              f"right={lb.count('knock-right'):3}  "
              f"{meta['desk']['material']}/{meta['desk']['compliance']}  "
              f"{meta['channels'][0]['temp_c_min']:.1f}°C")

    print("\nWITHIN SESSION — own template, circular-shift null (balanced accuracy)")
    for n in order:
        ev, _ = sessions[n]
        lb = [e[0] for e in ev]
        o = in_sample(ev, lb)
        t = template(ev, lb)
        shifts = sorted(evaluate(ev, lb[k:] + lb[:k], t)
                        for k in range(1, len(lb)) if len(set(lb[k:] + lb[:k])) > 1)
        p = shift_p(ev, lb, t, o)
        print(f"   {n:<18} {o:>3}/{len(ev):<3}  shift med {shifts[len(shifts)//2]:>3}"
              f"  shift max {shifts[-1]:>3}   p={p:.3f}"
              f"   {'SEPARATES' if p < 0.05 else 'not significant'}")

    print(f"\nTRANSFER MATRIX — rows are the profile source, columns the test session")
    print(f"   * = p < {ALPHA} against the circular-shift null\n")
    print(f"{'':<20}" + "".join(f"{n:>16}" for n in order))
    tmpl = {n: template(sessions[n][0], [e[0] for e in sessions[n][0]]) for n in order}
    for a in order:
        row = []
        for b in order:
            ev = sessions[b][0]
            lb = [e[0] for e in ev]
            o = evaluate(ev, lb, tmpl[a])
            p = shift_p(ev, lb, tmpl[a], o)
            row.append(f"{o}/{len(ev)}" + ("*" if p < ALPHA else " "))
        print(f"   {a:<17}" + "".join(f"{c:>16}" for c in row))

    block_report(sessions, order)

    print("\nCOSINE BETWEEN TEMPLATES")
    print(f"{'':<20}" + "".join(f"{n:>16}" for n in order))
    for a in order:
        print(f"   {a:<17}" + "".join(f"{dot(tmpl[a], tmpl[b]):>16.3f}" for b in order))

    print("\nExploratory separability on a small number of desks. Not product accuracy.")
    print("No number here enters PRODUCT.md or any copy until T-012 measures one.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data/sessions")
