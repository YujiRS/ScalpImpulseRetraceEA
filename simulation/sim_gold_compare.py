"""
sim_gold_compare.py  –  Parameter comparison for GOLD breakout strategy
=======================================================================
Runs multiple parameter variants in a single pass over shared data.
Variants:
  A) TrailMult sweep: 0.8, 1.0, 1.2, 1.5(base)
  B) Fixed TP: RangeWidth × 1.0, 1.5, 2.0 (full close at TP)
  C) SL cap: max SL distance = ATR(H1) × 2.0, 2.5, 3.0
"""

import os, sys, copy
import numpy as np
import pandas as pd

# Import everything from the base sim
from sim_gold_breakout import (
    load_m1, resample_ohlc, atr_series, point,
    detect_daily_ranges, detect_breakout_and_enter, collect_stats,
    Dir, TradeResult,
    ATR_PERIOD_M15, ATR_PERIOD_H1, FORCE_CLOSE_HOUR, TRAIL_ATR_MULT,
    BREAKEVEN_ATR_MULT, EMA_FAST_PERIOD, EMA_SLOW_PERIOD,
)


def simulate_exit_variant(result: TradeResult, m15: pd.DataFrame,
                          m15_atr: pd.Series,
                          trail_mult: float = TRAIL_ATR_MULT,
                          be_mult: float = BREAKEVEN_ATR_MULT,
                          fixed_tp: float = 0.0,
                          sl_cap: float = 0.0):
    """Exit sim with configurable trail/TP/SL-cap."""
    if result.entry_price == 0 or result.direction is None:
        return

    d = result.direction
    entry_price = result.entry_price
    sl = result.sl_price

    # ── SL cap: clamp SL distance ──
    if sl_cap > 0:
        if d == Dir.LONG:
            max_sl = entry_price - sl_cap
            if sl < max_sl:
                sl = max_sl
                result.sl_price = sl
                result.sl_distance = entry_price - sl
        else:
            max_sl = entry_price + sl_cap
            if sl > max_sl:
                sl = max_sl
                result.sl_price = sl
                result.sl_distance = sl - entry_price

    # ── Fixed TP price ──
    tp_price = 0.0
    if fixed_tp > 0:
        if d == Dir.LONG:
            tp_price = entry_price + fixed_tp
        else:
            tp_price = entry_price - fixed_tp

    entry_ts = pd.Timestamp(result.entry_time)
    force_close_ts = result.date + pd.Timedelta(hours=FORCE_CLOSE_HOUR)

    mask = (m15.index > entry_ts) & (m15.index <= force_close_ts)
    exit_bars = m15.loc[mask]

    if len(exit_bars) == 0:
        result.exit_reason = "NO_EXIT_DATA"
        return

    closes = exit_bars["close"].values
    highs = exit_bars["high"].values
    lows = exit_bars["low"].values
    opens = exit_bars["open"].values
    times = exit_bars.index

    breakeven_done = False
    max_fav = 0.0
    max_adv = 0.0

    for i in range(len(exit_bars)):
        ts = times[i]
        c = closes[i]
        h = highs[i]
        l = lows[i]

        atr_loc = m15_atr.index.get_indexer([ts], method="ffill")[0]
        atr_val = m15_atr.iloc[atr_loc] if atr_loc >= 0 and not np.isnan(m15_atr.iloc[atr_loc]) else 0

        # Track excursions
        if d == Dir.LONG:
            fav = h - entry_price
            adv = entry_price - l
        else:
            fav = entry_price - l
            adv = h - entry_price
        max_fav = max(max_fav, fav)
        max_adv = max(max_adv, adv)

        # ── TP check (intra-bar) ──
        if tp_price > 0:
            if d == Dir.LONG and h >= tp_price:
                result.exit_time = str(ts)
                result.exit_price = tp_price
                result.exit_reason = "TP_Hit"
                break
            if d == Dir.SHORT and l <= tp_price:
                result.exit_time = str(ts)
                result.exit_price = tp_price
                result.exit_reason = "TP_Hit"
                break

        # ── SL check (intra-bar) ──
        if d == Dir.LONG and l <= sl:
            result.exit_time = str(ts)
            result.exit_price = sl
            result.exit_reason = "SL_Hit"
            break
        if d == Dir.SHORT and h >= sl:
            result.exit_time = str(ts)
            result.exit_price = sl
            result.exit_reason = "SL_Hit"
            break

        # ── Reverse candle ──
        if atr_val > 0:
            bar_body = abs(c - opens[i])
            if d == Dir.LONG and c < opens[i] and bar_body >= atr_val * 2.0:
                result.exit_time = str(ts)
                result.exit_price = c
                result.exit_reason = "ReverseCandle"
                break
            if d == Dir.SHORT and c > opens[i] and bar_body >= atr_val * 2.0:
                result.exit_time = str(ts)
                result.exit_price = c
                result.exit_reason = "ReverseCandle"
                break

        # ── Breakeven ──
        if not breakeven_done and atr_val > 0:
            be_trigger = atr_val * be_mult
            if d == Dir.LONG and (c - entry_price) >= be_trigger:
                sl = entry_price + result.entry_spread * point()
                breakeven_done = True
                result.breakeven_hit = True
            elif d == Dir.SHORT and (entry_price - c) >= be_trigger:
                sl = entry_price - result.entry_spread * point()
                breakeven_done = True
                result.breakeven_hit = True

        # ── Trailing stop ──
        if atr_val > 0:
            trail_dist = atr_val * trail_mult
            if d == Dir.LONG:
                new_sl = c - trail_dist
                if new_sl > sl:
                    sl = new_sl
            else:
                new_sl = c + trail_dist
                if new_sl < sl:
                    sl = new_sl

        # ── Force close ──
        if ts.hour >= FORCE_CLOSE_HOUR:
            result.exit_time = str(ts)
            result.exit_price = c
            result.exit_reason = "SessionEnd"
            break
    else:
        last_i = len(exit_bars) - 1
        result.exit_time = str(times[last_i])
        result.exit_price = closes[last_i]
        result.exit_reason = "DataEnd"

    result.max_favorable = max_fav
    result.max_adverse = max_adv

    if result.exit_price > 0:
        if d == Dir.LONG:
            result.pnl_pts = result.exit_price - entry_price
        else:
            result.pnl_pts = entry_price - result.exit_price
        result.pnl_pips = result.pnl_pts / point()

    if result.exit_time and result.entry_time:
        entry_ts = pd.Timestamp(result.entry_time)
        exit_ts = pd.Timestamp(result.exit_time)
        mask_hold = (m15.index > entry_ts) & (m15.index <= exit_ts)
        result.hold_bars_m15 = mask_hold.sum()


def run_variant(label: str, base_results: list[TradeResult],
                m15: pd.DataFrame, m15_atr: pd.Series,
                trail_mult: float = TRAIL_ATR_MULT,
                fixed_tp_rw_mult: float = 0.0,
                sl_cap_atr_mult: float = 0.0,
                h1_atr_series=None) -> dict:
    """Run one variant over pre-computed entry signals."""
    variant_results = []
    for r in base_results:
        vr = TradeResult(
            date=r.date,
            daily_range=r.daily_range,
            direction=r.direction,
            entry_time=r.entry_time,
            entry_price=r.entry_price,
            entry_spread=r.entry_spread,
            sl_price=r.sl_price,
            sl_distance=r.sl_distance,
            reject_stage=r.reject_stage,
        )
        if vr.entry_price > 0 and vr.direction is not None:
            # Compute fixed TP from range width
            fixed_tp = 0.0
            if fixed_tp_rw_mult > 0 and vr.daily_range:
                fixed_tp = vr.daily_range.range_width * fixed_tp_rw_mult

            # Compute SL cap from H1 ATR
            sl_cap = 0.0
            if sl_cap_atr_mult > 0 and h1_atr_series is not None and vr.daily_range:
                sl_cap = vr.daily_range.h1_atr * sl_cap_atr_mult

            simulate_exit_variant(vr, m15, m15_atr,
                                  trail_mult=trail_mult,
                                  fixed_tp=fixed_tp,
                                  sl_cap=sl_cap)
        variant_results.append(vr)

    stats = collect_stats(variant_results)
    stats["label"] = label
    return stats


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "GOLD#_M1_202509010100_202511282139.csv")

    if not os.path.exists(data_path):
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    print("=" * 80)
    print("sim_gold_compare.py  –  Parameter Comparison")
    print("=" * 80)

    # ── Load ──
    print("\n[1] Loading data …")
    m1 = load_m1(data_path)
    m15 = resample_ohlc(m1, "15min")
    h1 = resample_ohlc(m1, "60min")
    m15_atr = atr_series(m15, ATR_PERIOD_M15)
    h1_atr = atr_series(h1, ATR_PERIOD_H1)
    m15_ema_fast = m15["close"].ewm(span=EMA_FAST_PERIOD, adjust=False).mean()
    m15_ema_slow = m15["close"].ewm(span=EMA_SLOW_PERIOD, adjust=False).mean()

    # ── Generate entry signals (shared across all variants) ──
    print("[2] Generating entry signals …")
    ranges = detect_daily_ranges(m15, h1_atr)
    base_results = []
    for dr in ranges:
        tr = detect_breakout_and_enter(dr, m15, m15_atr, m1,
                                       m15_ema_fast, m15_ema_slow)
        base_results.append(tr)

    traded = sum(1 for r in base_results if r.entry_price > 0)
    print(f"    {len(ranges)} days, {traded} entries")

    # ── Define variants ──
    variants = []

    # A) Trail multiplier sweep
    for tm in [0.8, 1.0, 1.2, 1.5]:
        tag = "BASE" if tm == 1.5 else ""
        variants.append({
            "label": f"Trail={tm:.1f} {tag}".strip(),
            "trail_mult": tm,
        })

    # B) Fixed TP (with base trail)
    for tp_m in [1.0, 1.5, 2.0]:
        variants.append({
            "label": f"TP=RW×{tp_m:.1f}",
            "trail_mult": TRAIL_ATR_MULT,
            "fixed_tp_rw_mult": tp_m,
        })

    # C) SL cap (with base trail)
    for sc in [2.0, 2.5, 3.0]:
        variants.append({
            "label": f"SLcap=H1×{sc:.1f}",
            "trail_mult": TRAIL_ATR_MULT,
            "sl_cap_atr_mult": sc,
        })

    # D) Combos: best trail + TP
    for tm in [0.8, 1.0]:
        for tp_m in [1.0, 1.5]:
            variants.append({
                "label": f"Trail={tm:.1f}+TP=RW×{tp_m:.1f}",
                "trail_mult": tm,
                "fixed_tp_rw_mult": tp_m,
            })

    # ── Run all variants ──
    print(f"\n[3] Running {len(variants)} variants …")
    all_stats = []
    for v in variants:
        s = run_variant(
            label=v["label"],
            base_results=base_results,
            m15=m15,
            m15_atr=m15_atr,
            trail_mult=v.get("trail_mult", TRAIL_ATR_MULT),
            fixed_tp_rw_mult=v.get("fixed_tp_rw_mult", 0.0),
            sl_cap_atr_mult=v.get("sl_cap_atr_mult", 0.0),
            h1_atr_series=h1_atr,
        )
        all_stats.append(s)

    # ── Results table ──
    print(f"\n{'=' * 100}")
    print("COMPARISON RESULTS")
    print(f"{'=' * 100}\n")

    header = (f"{'Variant':<28} {'Trades':>6} {'WR%':>6} {'PF':>6} "
              f"{'Net':>9} {'AvgW':>7} {'AvgL':>7} "
              f"{'MFE':>7} {'MAE':>7} {'BE%':>5} {'AvgHold':>7}")
    print(header)
    print("-" * len(header))

    # Sort by PF descending
    all_stats.sort(key=lambda s: s["pf"], reverse=True)

    for s in all_stats:
        print(f"{s['label']:<28} {s['traded']:>6} {s['win_rate']:>5.1f}% "
              f"{s['pf']:>6.2f} {s['net_pnl']:>+9.2f} "
              f"{s['avg_win']:>7.2f} {s['avg_loss']:>7.2f} "
              f"{s['avg_mfe']:>7.2f} {s['avg_mae']:>7.2f} "
              f"{s['breakeven_pct']:>4.0f}% {s['avg_hold_bars']:>7.1f}")

    # ── CSV ──
    csv_rows = []
    for s in all_stats:
        csv_rows.append({
            "Variant": s["label"],
            "Trades": s["traded"],
            "Wins": s["wins"],
            "Losses": s["losses"],
            "WinRate": f"{s['win_rate']:.1f}",
            "PF": f"{s['pf']:.2f}",
            "NetPnL": f"{s['net_pnl']:.2f}",
            "AvgWin": f"{s['avg_win']:.2f}",
            "AvgLoss": f"{s['avg_loss']:.2f}",
            "AvgMFE": f"{s['avg_mfe']:.2f}",
            "AvgMAE": f"{s['avg_mae']:.2f}",
            "BE_pct": f"{s['breakeven_pct']:.0f}",
            "AvgHold": f"{s['avg_hold_bars']:.1f}",
        })
    csv_path = os.path.join(script_dir, "sim_dat", "sim_compare_gold.csv")
    pd.DataFrame(csv_rows).to_csv(csv_path, index=False)
    print(f"\nCSV written: {csv_path}")


if __name__ == "__main__":
    main()
