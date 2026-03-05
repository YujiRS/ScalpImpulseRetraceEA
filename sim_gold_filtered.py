"""
sim_gold_filtered.py  –  Entry filter comparison for GOLD breakout
==================================================================
Tests entry filters identified by filter analysis:
  F1: EMA50 aligned (M15 EMA20 > EMA50 for LONG, < for SHORT)
  F2: Exceed <= 1.0 ATR (reject overextended breakouts)
  F3: Exceed < 0.6 ATR (only fresh breakouts)
  F4: EMA50 + Exceed<=1.0 ATR combo
  F5: EMA50 + Exceed<0.6 ATR combo
"""

import os, sys
import numpy as np
import pandas as pd

from sim_gold_breakout import (
    load_m1, resample_ohlc, atr_series, point,
    detect_daily_ranges, detect_breakout_and_enter, simulate_exit,
    collect_stats, Dir, TradeResult,
    ATR_PERIOD_M15, ATR_PERIOD_H1,
)


def apply_filters(results: list[TradeResult], m15: pd.DataFrame,
                   m15_atr: pd.Series, m15_ema20: pd.Series,
                   m15_ema50: pd.Series,
                   require_ema50: bool = False,
                   max_exceed_atr: float = 0.0) -> list[TradeResult]:
    """Filter entries; rejected trades get reject_stage set."""
    filtered = []
    for r in results:
        # Copy result
        fr = TradeResult(
            date=r.date,
            daily_range=r.daily_range,
            direction=r.direction,
            entry_time=r.entry_time,
            entry_price=r.entry_price,
            entry_spread=r.entry_spread,
            sl_price=r.sl_price,
            sl_distance=r.sl_distance,
            reject_stage=r.reject_stage,
            exit_time=r.exit_time,
            exit_price=r.exit_price,
            exit_reason=r.exit_reason,
            pnl_pts=r.pnl_pts,
            pnl_pips=r.pnl_pips,
            hold_bars_m15=r.hold_bars_m15,
            max_favorable=r.max_favorable,
            max_adverse=r.max_adverse,
            breakeven_hit=r.breakeven_hit,
        )

        if fr.entry_price == 0 or fr.direction is None:
            filtered.append(fr)
            continue

        entry_ts = pd.Timestamp(fr.entry_time)
        m15_loc = m15.index.get_indexer([entry_ts], method="ffill")[0]

        # ── EMA50 filter ──
        if require_ema50:
            e20 = m15_ema20.iloc[m15_loc]
            e50 = m15_ema50.iloc[m15_loc]
            if fr.direction == Dir.LONG and e20 <= e50:
                fr.reject_stage = "EMA50_CONTRA"
                fr.entry_price = 0
                fr.exit_price = 0
                fr.pnl_pts = 0
                filtered.append(fr)
                continue
            if fr.direction == Dir.SHORT and e20 >= e50:
                fr.reject_stage = "EMA50_CONTRA"
                fr.entry_price = 0
                fr.exit_price = 0
                fr.pnl_pts = 0
                filtered.append(fr)
                continue

        # ── Exceed filter ──
        if max_exceed_atr > 0:
            atr_loc = m15_atr.index.get_indexer([entry_ts], method="ffill")[0]
            atr_val = m15_atr.iloc[atr_loc]
            bar = m15.iloc[m15_loc]
            dr = fr.daily_range
            if fr.direction == Dir.LONG:
                exceed = bar["close"] - dr.range_high
            else:
                exceed = dr.range_low - bar["close"]
            exceed_atr = exceed / atr_val if atr_val > 0 else 0

            if exceed_atr > max_exceed_atr:
                fr.reject_stage = "EXCEED_TOO_FAR"
                fr.entry_price = 0
                fr.exit_price = 0
                fr.pnl_pts = 0
                filtered.append(fr)
                continue

        filtered.append(fr)
    return filtered


def print_summary(label: str, stats: dict):
    """Print one-line summary."""
    print(f"  {label:<40s} {stats['traded']:>4} {stats['win_rate']:>5.1f}% "
          f"{stats['pf']:>6.2f} {stats['net_pnl']:>+9.2f} "
          f"{stats['avg_win']:>7.2f} {stats['avg_loss']:>7.2f} "
          f"{stats['avg_mfe']:>7.2f} {stats['avg_mae']:>7.2f}")


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "GOLD#_M1_202509010100_202511282139.csv")

    print("=" * 80)
    print("sim_gold_filtered.py  –  Entry Filter Comparison")
    print("=" * 80)

    m1 = load_m1(data_path)
    m15 = resample_ohlc(m1, "15min")
    h1 = resample_ohlc(m1, "60min")
    m15_atr = atr_series(m15, ATR_PERIOD_M15)
    h1_atr = atr_series(h1, ATR_PERIOD_H1)
    m15_ema20 = m15["close"].ewm(span=20, adjust=False).mean()
    m15_ema50 = m15["close"].ewm(span=50, adjust=False).mean()

    print("\n[1] Generating base entries …")
    ranges = detect_daily_ranges(m15, h1_atr)
    base_results = []
    for dr in ranges:
        tr = detect_breakout_and_enter(dr, m15, m15_atr, m1)
        if tr.entry_price > 0:
            simulate_exit(tr, m15, m15_atr)
        base_results.append(tr)

    # ── Define filter variants ──
    variants = [
        ("BASE (no filter)", {}),
        ("F1: EMA50 aligned", {"require_ema50": True}),
        ("F2: Exceed <= 1.0 ATR", {"max_exceed_atr": 1.0}),
        ("F3: Exceed <= 0.6 ATR", {"max_exceed_atr": 0.6}),
        ("F4: Exceed <= 0.3 ATR", {"max_exceed_atr": 0.3}),
        ("F5: EMA50 + Exceed<=1.0", {"require_ema50": True, "max_exceed_atr": 1.0}),
        ("F6: EMA50 + Exceed<=0.6", {"require_ema50": True, "max_exceed_atr": 0.6}),
        ("F7: EMA50 + Exceed<=0.3", {"require_ema50": True, "max_exceed_atr": 0.3}),
    ]

    print(f"\n[2] Running {len(variants)} filter variants …\n")
    print(f"{'=' * 100}")
    print("FILTERED COMPARISON")
    print(f"{'=' * 100}\n")

    header = (f"  {'Variant':<40s} {'N':>4} {'WR%':>6} {'PF':>6} "
              f"{'Net':>9} {'AvgW':>7} {'AvgL':>7} "
              f"{'MFE':>7} {'MAE':>7}")
    print(header)
    print(f"  {'-' * 96}")

    all_stats = []
    for label, kwargs in variants:
        if not kwargs:
            # Base - no filter
            stats = collect_stats(base_results)
        else:
            filtered = apply_filters(base_results, m15, m15_atr,
                                     m15_ema20, m15_ema50, **kwargs)
            stats = collect_stats(filtered)
        stats["label"] = label
        all_stats.append(stats)
        print_summary(label, stats)

    # ── Best combo: EMA50 + Exceed<=1.0 + TP=RW×1.5 ──
    # Test adding TP to best filter
    print(f"\n{'─' * 80}")
    print("  + Adding TP=RW×1.5 to best filter combos:")
    print(f"{'─' * 80}\n")

    from sim_gold_compare import simulate_exit_variant, TRAIL_ATR_MULT

    for label, kwargs in [("F5: EMA50+Exceed<=1.0 + TP", {"require_ema50": True, "max_exceed_atr": 1.0}),
                          ("F6: EMA50+Exceed<=0.6 + TP", {"require_ema50": True, "max_exceed_atr": 0.6})]:
        filtered = apply_filters(base_results, m15, m15_atr,
                                 m15_ema20, m15_ema50, **kwargs)
        # Re-run exit with TP
        tp_results = []
        for r in filtered:
            tr = TradeResult(
                date=r.date, daily_range=r.daily_range, direction=r.direction,
                entry_time=r.entry_time, entry_price=r.entry_price,
                entry_spread=r.entry_spread, sl_price=r.sl_price,
                sl_distance=r.sl_distance, reject_stage=r.reject_stage,
            )
            if tr.entry_price > 0 and tr.direction is not None and tr.daily_range:
                fixed_tp = tr.daily_range.range_width * 1.5
                simulate_exit_variant(tr, m15, m15_atr,
                                      trail_mult=TRAIL_ATR_MULT,
                                      fixed_tp=fixed_tp)
            tp_results.append(tr)
        stats = collect_stats(tp_results)
        print_summary(label, stats)

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
        })
    csv_path = os.path.join(script_dir, "sim_dat", "sim_filter_gold.csv")
    pd.DataFrame(csv_rows).to_csv(csv_path, index=False)
    print(f"\nCSV written: {csv_path}")


if __name__ == "__main__":
    main()
