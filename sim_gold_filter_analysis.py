"""
sim_gold_filter_analysis.py  –  Analyze winning vs losing trades for filter ideas
=================================================================================
Examines breakout trades across multiple dimensions to find edge.
"""

import os, sys
import numpy as np
import pandas as pd

from sim_gold_breakout import (
    load_m1, resample_ohlc, atr_series, point,
    detect_daily_ranges, detect_breakout_and_enter, simulate_exit,
    Dir, TradeResult,
    ATR_PERIOD_M15, ATR_PERIOD_H1,
)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "GOLD#_M1_202509010100_202511282139.csv")

    print("=" * 70)
    print("Filter Analysis – What separates winners from losers?")
    print("=" * 70)

    m1 = load_m1(data_path)
    m15 = resample_ohlc(m1, "15min")
    h1 = resample_ohlc(m1, "60min")
    m15_atr = atr_series(m15, ATR_PERIOD_M15)
    h1_atr = atr_series(h1, ATR_PERIOD_H1)

    # EMA for trend
    m15_ema20 = m15["close"].ewm(span=20, adjust=False).mean()
    m15_ema50 = m15["close"].ewm(span=50, adjust=False).mean()
    h1_ema20 = h1["close"].ewm(span=20, adjust=False).mean()

    ranges = detect_daily_ranges(m15, h1_atr)
    results = []
    for dr in ranges:
        tr = detect_breakout_and_enter(dr, m15, m15_atr, m1)
        if tr.entry_price > 0:
            simulate_exit(tr, m15, m15_atr)
        results.append(tr)

    # Build analysis DataFrame
    rows = []
    for r in results:
        if r.entry_price == 0 or r.exit_price == 0:
            continue

        entry_ts = pd.Timestamp(r.entry_time)
        dr = r.daily_range

        # Breakout bar info
        m15_loc = m15.index.get_indexer([entry_ts], method="ffill")[0]
        bar = m15.iloc[m15_loc]
        bar_range = bar["high"] - bar["low"]
        bar_body = abs(bar["close"] - bar["open"])
        body_ratio = bar_body / bar_range if bar_range > 0 else 0

        # ATR at entry
        atr_loc = m15_atr.index.get_indexer([entry_ts], method="ffill")[0]
        m15_atr_val = m15_atr.iloc[atr_loc]

        # Breakout strength: how far past range boundary
        if r.direction == Dir.LONG:
            exceed = bar["close"] - dr.range_high
        else:
            exceed = dr.range_low - bar["close"]
        exceed_atr = exceed / m15_atr_val if m15_atr_val > 0 else 0

        # EMA trend at entry
        ema20_val = m15_ema20.iloc[m15_loc]
        ema50_val = m15_ema50.iloc[m15_loc]
        h1_loc = h1_ema20.index.get_indexer([entry_ts], method="ffill")[0]
        h1_ema_val = h1_ema20.iloc[h1_loc]

        # Trend alignment
        if r.direction == Dir.LONG:
            ema_aligned = bar["close"] > ema20_val
            ema50_aligned = ema20_val > ema50_val
            h1_aligned = bar["close"] > h1_ema_val
        else:
            ema_aligned = bar["close"] < ema20_val
            ema50_aligned = ema20_val < ema50_val
            h1_aligned = bar["close"] < h1_ema_val

        # Range width / ATR ratio
        rw_atr_ratio = dr.range_width / dr.h1_atr if dr.h1_atr > 0 else 0

        # SL distance / ATR ratio
        sl_atr_ratio = r.sl_distance / m15_atr_val if m15_atr_val > 0 else 0

        # Entry hour
        entry_hour = entry_ts.hour

        # Day of week
        dow = entry_ts.dayofweek  # 0=Mon

        rows.append({
            "date": str(r.date.date()),
            "dir": r.direction.name,
            "pnl": r.pnl_pts,
            "win": 1 if r.pnl_pts > 0 else 0,
            "entry_hour": entry_hour,
            "dow": dow,
            "body_ratio": body_ratio,
            "bar_body": bar_body,
            "exceed": exceed,
            "exceed_atr": exceed_atr,
            "rw": dr.range_width,
            "rw_atr": rw_atr_ratio,
            "sl_dist": r.sl_distance,
            "sl_atr": sl_atr_ratio,
            "m15_atr": m15_atr_val,
            "h1_atr": dr.h1_atr,
            "ema20_aligned": ema_aligned,
            "ema50_aligned": ema50_aligned,
            "h1_ema_aligned": h1_aligned,
            "mfe": r.max_favorable,
            "mae": r.max_adverse,
            "hold": r.hold_bars_m15,
        })

    df = pd.DataFrame(rows)
    wins = df[df["win"] == 1]
    losses = df[df["win"] == 0]

    print(f"\nTotal trades: {len(df)}  W:{len(wins)}  L:{len(losses)}")

    # ── 1. Entry Hour ──
    print(f"\n{'─'*60}")
    print("1. ENTRY HOUR")
    print(f"{'─'*60}")
    for h in sorted(df["entry_hour"].unique()):
        sub = df[df["entry_hour"] == h]
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n if n > 0 else 0
        print(f"  Hour {h:2d}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 2. Day of Week ──
    print(f"\n{'─'*60}")
    print("2. DAY OF WEEK")
    print(f"{'─'*60}")
    dow_names = ["Mon", "Tue", "Wed", "Thu", "Fri"]
    for d in sorted(df["dow"].unique()):
        sub = df[df["dow"] == d]
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n if n > 0 else 0
        print(f"  {dow_names[d]}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 3. Direction ──
    print(f"\n{'─'*60}")
    print("3. DIRECTION")
    print(f"{'─'*60}")
    for d in ["LONG", "SHORT"]:
        sub = df[df["dir"] == d]
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n if n > 0 else 0
        avg_w = sub[sub["win"] == 1]["pnl"].mean() if w > 0 else 0
        avg_l = sub[sub["win"] == 0]["pnl"].mean() if n - w > 0 else 0
        print(f"  {d:5s}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}, AvgW={avg_w:+.2f}, AvgL={avg_l:+.2f}")

    # ── 4. EMA Alignment ──
    print(f"\n{'─'*60}")
    print("4. EMA ALIGNMENT (breakout direction matches trend)")
    print(f"{'─'*60}")
    for label, col in [("M15 EMA20", "ema20_aligned"),
                       ("M15 EMA20>50", "ema50_aligned"),
                       ("H1 EMA20", "h1_ema_aligned")]:
        aligned = df[df[col] == True]
        contra = df[df[col] == False]
        a_wr = 100 * aligned["win"].mean() if len(aligned) > 0 else 0
        c_wr = 100 * contra["win"].mean() if len(contra) > 0 else 0
        a_pnl = aligned["pnl"].sum()
        c_pnl = contra["pnl"].sum()
        a_pf = aligned[aligned["win"]==1]["pnl"].sum() / abs(aligned[aligned["win"]==0]["pnl"].sum()) if aligned[aligned["win"]==0]["pnl"].sum() != 0 else float("inf")
        c_pf = contra[contra["win"]==1]["pnl"].sum() / abs(contra[contra["win"]==0]["pnl"].sum()) if contra[contra["win"]==0]["pnl"].sum() != 0 else float("inf")
        print(f"  {label}:")
        print(f"    Aligned: {len(aligned):3d} trades, WR={a_wr:5.1f}%, PnL={a_pnl:+8.2f}, PF={a_pf:.2f}")
        print(f"    Contra:  {len(contra):3d} trades, WR={c_wr:5.1f}%, PnL={c_pnl:+8.2f}, PF={c_pf:.2f}")

    # ── 5. Breakout Exceed (strength) ──
    print(f"\n{'─'*60}")
    print("5. BREAKOUT EXCEED (how far past range in ATR units)")
    print(f"{'─'*60}")
    for lo, hi, label in [(0, 0.3, "<0.3 ATR"), (0.3, 0.6, "0.3-0.6"), (0.6, 1.0, "0.6-1.0"), (1.0, 99, ">1.0")]:
        sub = df[(df["exceed_atr"] >= lo) & (df["exceed_atr"] < hi)]
        if len(sub) == 0:
            continue
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n
        print(f"  {label:>10s}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 6. Body Ratio ──
    print(f"\n{'─'*60}")
    print("6. BODY RATIO (breakout candle)")
    print(f"{'─'*60}")
    for lo, hi, label in [(0.5, 0.6, "50-60%"), (0.6, 0.7, "60-70%"), (0.7, 0.8, "70-80%"), (0.8, 1.01, "80%+")]:
        sub = df[(df["body_ratio"] >= lo) & (df["body_ratio"] < hi)]
        if len(sub) == 0:
            continue
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n
        print(f"  {label:>10s}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 7. Range Width / H1 ATR ──
    print(f"\n{'─'*60}")
    print("7. RANGE WIDTH / H1 ATR ratio")
    print(f"{'─'*60}")
    for lo, hi, label in [(0, 1.5, "<1.5"), (1.5, 2.5, "1.5-2.5"), (2.5, 3.5, "2.5-3.5"), (3.5, 99, ">3.5")]:
        sub = df[(df["rw_atr"] >= lo) & (df["rw_atr"] < hi)]
        if len(sub) == 0:
            continue
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n
        print(f"  {label:>10s}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 8. SL Distance / ATR ──
    print(f"\n{'─'*60}")
    print("8. SL DISTANCE / M15 ATR ratio")
    print(f"{'─'*60}")
    for lo, hi, label in [(0, 2, "<2"), (2, 3, "2-3"), (3, 4, "3-4"), (4, 99, ">4")]:
        sub = df[(df["sl_atr"] >= lo) & (df["sl_atr"] < hi)]
        if len(sub) == 0:
            continue
        w = sub["win"].sum()
        n = len(sub)
        pnl = sub["pnl"].sum()
        wr = 100 * w / n
        print(f"  {label:>10s}: {n:3d} trades, WR={wr:5.1f}%, PnL={pnl:+8.2f}")

    # ── 9. Combined best filter candidates ──
    print(f"\n{'─'*60}")
    print("9. COMBINED FILTER CANDIDATES")
    print(f"{'─'*60}")

    filters = {
        "H1_EMA_aligned": df["h1_ema_aligned"] == True,
        "EMA20_aligned": df["ema20_aligned"] == True,
        "EMA50_aligned": df["ema50_aligned"] == True,
        "BodyRatio>=0.6": df["body_ratio"] >= 0.6,
        "BodyRatio>=0.7": df["body_ratio"] >= 0.7,
        "Exceed>=0.3ATR": df["exceed_atr"] >= 0.3,
        "Hour<=12": df["entry_hour"] <= 12,
        "RW_ATR<3.0": df["rw_atr"] < 3.0,
    }

    # Try all singles and pairs
    from itertools import combinations

    combos = []
    # Singles
    for name, mask in filters.items():
        sub = df[mask]
        if len(sub) < 10:
            continue
        w = sub["win"].sum()
        gl = abs(sub[sub["win"]==0]["pnl"].sum())
        gw = sub[sub["win"]==1]["pnl"].sum()
        pf = gw / gl if gl > 0 else float("inf")
        combos.append((name, len(sub), 100*w/len(sub), sub["pnl"].sum(), pf))

    # Pairs
    filter_names = list(filters.keys())
    for i, j in combinations(range(len(filter_names)), 2):
        n1, n2 = filter_names[i], filter_names[j]
        mask = filters[n1] & filters[n2]
        sub = df[mask]
        if len(sub) < 10:
            continue
        w = sub["win"].sum()
        gl = abs(sub[sub["win"]==0]["pnl"].sum())
        gw = sub[sub["win"]==1]["pnl"].sum()
        pf = gw / gl if gl > 0 else float("inf")
        combos.append((f"{n1} + {n2}", len(sub), 100*w/len(sub), sub["pnl"].sum(), pf))

    combos.sort(key=lambda x: x[4], reverse=True)
    print(f"  {'Filter':<45s} {'N':>4} {'WR%':>6} {'PnL':>9} {'PF':>6}")
    print(f"  {'-'*75}")
    for name, n, wr, pnl, pf in combos[:20]:
        print(f"  {name:<45s} {n:>4} {wr:>5.1f}% {pnl:>+9.2f} {pf:>6.2f}")


if __name__ == "__main__":
    main()
