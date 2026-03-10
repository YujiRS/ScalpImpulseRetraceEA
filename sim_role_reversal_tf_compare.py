"""
sim_role_reversal_tf_compare.py  –  H1 vs M15 S/R Detection for RoleReversalEA
================================================================================
Runs the existing sim_role_reversal.py simulation twice:
  1) S/R detection on H1 (current default)
  2) S/R detection on M15
Then compares trade count, win rate, PF, and total PnL.

Usage:
  python sim_role_reversal_tf_compare.py [--market GOLD|FX|CRYPTO]
"""

import os
import sys
import io
import numpy as np

# Import the existing simulation module
import sim_role_reversal as rr


def run_with_sr_timeframe(m1_path: str, market: str, sr_tf: str) -> dict:
    """
    Run role reversal simulation with S/R detected on specified timeframe.
    sr_tf: "H1" or "M15"
    """
    # Save original globals
    orig_max_age = rr.SR_MAX_AGE_BARS

    if sr_tf == "M15":
        # M15 has 4x more bars per hour, so scale max_age accordingly
        rr.SR_MAX_AGE_BARS = orig_max_age * 4  # 200 H1 → 800 M15

    # Suppress output during simulation
    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    try:
        trades = run_simulation_with_tf(m1_path, market, sr_tf)
    finally:
        sys.stdout = old_stdout

    # Restore
    rr.SR_MAX_AGE_BARS = orig_max_age

    # Calculate stats
    closed = [t for t in trades if t.exit_reason != "END_OF_DATA"]
    total = len(closed)
    wins = [t for t in closed if t.pnl_pips > 0]
    losses = [t for t in closed if t.pnl_pips <= 0]
    win_count = len(wins)
    wr = win_count / total * 100 if total > 0 else 0
    total_pnl = sum(t.pnl_pips for t in closed)
    gp = sum(t.pnl_pips for t in wins) if wins else 0
    gl = abs(sum(t.pnl_pips for t in losses)) if losses else 0
    pf = gp / gl if gl > 0 else float("inf")
    avg_win = np.mean([t.pnl_pips for t in wins]) if wins else 0
    avg_loss = np.mean([t.pnl_pips for t in losses]) if losses else 0

    # Max DD
    max_dd = 0
    running = 0
    peak = 0
    for t in closed:
        running += t.pnl_pips
        peak = max(peak, running)
        max_dd = max(max_dd, peak - running)

    # Exit reason breakdown
    reasons = {}
    for t in closed:
        r = t.exit_reason
        if r not in reasons:
            reasons[r] = {"n": 0, "pnl": 0}
        reasons[r]["n"] += 1
        reasons[r]["pnl"] += t.pnl_pips

    return {
        "sr_tf": sr_tf,
        "trades": total,
        "wins": win_count,
        "losses": len(losses),
        "win_rate": wr,
        "total_pnl": total_pnl,
        "profit_factor": pf,
        "avg_win": avg_win,
        "avg_loss": avg_loss,
        "max_dd": max_dd,
        "reasons": reasons,
    }


def run_simulation_with_tf(m1_path: str, market: str, sr_tf: str):
    """
    Modified version of rr.run_simulation that uses specified TF for S/R detection.
    """
    global POINT_VALUE, SL_BUFFER_PIPS

    if market == "GOLD":
        rr.POINT_VALUE = 0.01
        rr.SL_BUFFER_PIPS = 50
    elif market == "FX":
        rr.POINT_VALUE = 0.001
        rr.SL_BUFFER_PIPS = 5
    elif market == "CRYPTO":
        rr.POINT_VALUE = 0.01
        rr.SL_BUFFER_PIPS = 50

    m1 = rr.load_m1(m1_path)
    m5 = rr.resample_ohlc(m1, "5min")
    m15 = rr.resample_ohlc(m1, "15min")
    h1 = rr.resample_ohlc(m1, "1h")

    m5_atr = rr.calc_atr(m5, rr.ATR_PERIOD)
    m5_ema = rr.calc_ema(m5["close"], rr.EMA_PERIOD)
    h1_atr = rr.calc_atr(h1, rr.ATR_PERIOD)
    m15_ema = rr.calc_ema(m15["close"], 50)

    # S/R detection on selected timeframe
    if sr_tf == "M15":
        sr_df = m15
        sr_atr = rr.calc_atr(m15, rr.ATR_PERIOD)
    else:
        sr_df = h1
        sr_atr = h1_atr

    raw_levels = rr.detect_swing_highs_lows(sr_df, rr.SR_SWING_LOOKBACK)
    avg_sr_atr = sr_atr.mean()
    levels = rr.merge_nearby_levels(raw_levels, avg_sr_atr, rr.SR_MERGE_TOLERANCE_ATR)
    rr.count_touches(levels, sr_df, sr_atr, rr.SR_MERGE_TOLERANCE_ATR)

    # Filter by min touches
    levels = [l for l in levels if l.touch_count >= rr.SR_MIN_TOUCHES]

    print(f"  [{sr_tf}] S/R: {len(raw_levels)} raw → {len(levels)} merged (min_touches={rr.SR_MIN_TOUCHES})")

    # Run simulation loop (same as original)
    trades = []
    state = rr.SimState()
    reject_counts = {
        "time_filter": 0, "no_ema_trend": 0, "no_ema_support": 0,
        "no_confirm": 0, "candle_too_large": 0, "rr_invalid": 0,
        "m15_against": 0, "pullback_timeout": 0,
    }

    warmup = max(rr.ATR_PERIOD, rr.EMA_PERIOD, rr.KR_LOOKBACK) + 5

    for i in range(warmup, len(m5)):
        bar = m5.iloc[i]
        bar_time = m5.index[i]
        atr_val = m5_atr.iloc[i]

        # Manage open position
        if state.in_position and state.current_trade:
            trade = state.current_trade
            ref_sl = trade.original_sl if trade.original_sl != 0 else trade.sl

            if rr.ENABLE_BREAKEVEN and not trade.breakeven_triggered:
                risk = abs(trade.entry_price - ref_sl)
                if trade.direction == "long":
                    reward = bar["high"] - trade.entry_price
                else:
                    reward = trade.entry_price - bar["low"]
                if risk > 0 and reward > 0 and (reward / risk) >= rr.BE_RR_THRESHOLD:
                    trade.breakeven_triggered = True
                    trade.sl = trade.entry_price

            if trade.direction == "long":
                if bar["low"] <= trade.sl:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.sl
                    trade.exit_reason = "BE" if trade.breakeven_triggered and trade.sl == trade.entry_price else "SL"
                    trade.pnl_pips = (trade.sl - trade.entry_price) / rr.POINT_VALUE
                    sl_dist = trade.entry_price - ref_sl
                    trade.rr_achieved = (trade.sl - trade.entry_price) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
                if bar["high"] >= trade.tp:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.tp
                    trade.exit_reason = "TP"
                    trade.pnl_pips = (trade.tp - trade.entry_price) / rr.POINT_VALUE
                    sl_dist = trade.entry_price - ref_sl
                    trade.rr_achieved = (trade.tp - trade.entry_price) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
            else:
                if bar["high"] >= trade.sl:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.sl
                    trade.exit_reason = "BE" if trade.breakeven_triggered and trade.sl == trade.entry_price else "SL"
                    trade.pnl_pips = (trade.entry_price - trade.sl) / rr.POINT_VALUE
                    sl_dist = ref_sl - trade.entry_price
                    trade.rr_achieved = (trade.entry_price - trade.sl) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
                if bar["low"] <= trade.tp:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.tp
                    trade.exit_reason = "TP"
                    trade.pnl_pips = (trade.entry_price - trade.tp) / rr.POINT_VALUE
                    sl_dist = ref_sl - trade.entry_price
                    trade.rr_achieved = (trade.entry_price - trade.tp) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
            continue

        if not rr.is_trading_hour(bar_time):
            if state.active_breakout:
                pass
            continue

        # Check for new breakouts
        if not state.active_breakout:
            # For breakout detection, we need to map bar_time to the S/R TF index
            if sr_tf == "M15":
                sr_idx = sr_df.index.searchsorted(bar_time, side="right") - 1
                sr_idx = max(0, min(sr_idx, len(sr_df) - 1))
                current_sr_atr = sr_atr.iloc[sr_idx] if sr_idx < len(sr_atr) else avg_sr_atr
            else:
                h1_idx = rr.find_h1_bar_index(h1, bar_time)
                current_sr_atr = h1_atr.iloc[h1_idx] if h1_idx < len(h1_atr) else avg_sr_atr
                sr_idx = h1_idx

            for lvl in levels:
                if lvl.broken or lvl.used:
                    continue
                if sr_idx - lvl.detected_at > rr.SR_MAX_AGE_BARS:
                    continue

                prev_close = m5["close"].iloc[i - 1] if i > 0 else bar["close"]

                # Bullish breakout
                if bar["close"] > lvl.price and prev_close <= lvl.price:
                    body = abs(bar["close"] - bar["open"])
                    rng = bar["high"] - bar["low"]
                    if rng > 0 and body / rng >= rr.BREAKOUT_BODY_RATIO:
                        m15_idx = m15.index.searchsorted(bar_time, side="right") - 1
                        if 0 <= m15_idx < len(m15_ema):
                            if m15["close"].iloc[m15_idx] < m15_ema.iloc[m15_idx]:
                                reject_counts["m15_against"] += 1
                                continue

                        state.active_breakout = True
                        state.breakout_level = lvl
                        state.breakout_direction = "up"
                        state.breakout_bar = i
                        state.confirm_count = 1
                        lvl.broken = True
                        lvl.broken_direction = "up"
                        lvl.broken_at_m5_idx = i
                        break

                # Bearish breakout
                if bar["close"] < lvl.price and prev_close >= lvl.price:
                    body = abs(bar["close"] - bar["open"])
                    rng = bar["high"] - bar["low"]
                    if rng > 0 and body / rng >= rr.BREAKOUT_BODY_RATIO:
                        m15_idx = m15.index.searchsorted(bar_time, side="right") - 1
                        if 0 <= m15_idx < len(m15_ema):
                            if m15["close"].iloc[m15_idx] > m15_ema.iloc[m15_idx]:
                                reject_counts["m15_against"] += 1
                                continue

                        state.active_breakout = True
                        state.breakout_level = lvl
                        state.breakout_direction = "down"
                        state.breakout_bar = i
                        state.confirm_count = 1
                        lvl.broken = True
                        lvl.broken_direction = "down"
                        lvl.broken_at_m5_idx = i
                        break

        # Breakout confirmation
        elif state.active_breakout and state.confirm_count < rr.BREAKOUT_CONFIRM_BARS:
            lvl = state.breakout_level
            if state.breakout_direction == "up":
                if bar["close"] > lvl.price:
                    state.confirm_count += 1
                else:
                    lvl.broken = False
                    state.reset()
            else:
                if bar["close"] < lvl.price:
                    state.confirm_count += 1
                else:
                    lvl.broken = False
                    state.reset()

        # Wait for pullback
        elif state.active_breakout and state.confirm_count >= rr.BREAKOUT_CONFIRM_BARS:
            lvl = state.breakout_level
            bars_since = i - state.breakout_bar

            if bars_since > rr.PULLBACK_MAX_BARS:
                reject_counts["pullback_timeout"] += 1
                lvl.used = True
                state.reset()
                continue

            if bars_since < rr.PULLBACK_MIN_BARS:
                continue

            zone = atr_val * rr.PULLBACK_ZONE_ATR
            price_at_level = False

            if state.breakout_direction == "up":
                if bar["low"] <= lvl.price + zone and bar["close"] >= lvl.price - zone * 0.5:
                    price_at_level = True
            else:
                if bar["high"] >= lvl.price - zone and bar["close"] <= lvl.price + zone * 0.5:
                    price_at_level = True

            if not price_at_level:
                if state.breakout_direction == "up" and bar["close"] < lvl.price - zone * 2:
                    lvl.used = True
                    state.reset()
                elif state.breakout_direction == "down" and bar["close"] > lvl.price + zone * 2:
                    lvl.used = True
                    state.reset()
                continue

            trade_direction = "long" if state.breakout_direction == "up" else "short"

            if not rr.check_ema_trend(m5_ema, i, state.breakout_direction, lookback=rr.EMA_TREND_LOOKBACK):
                reject_counts["no_ema_trend"] += 1
                continue

            if not rr.check_ema_support(m5, m5_ema, i, state.breakout_direction,
                                         tolerance_atr=0.5, atr_val=atr_val):
                reject_counts["no_ema_support"] += 1
                continue

            if trade_direction == "long":
                confirm = rr.check_bullish_confirm(m5, i)
            else:
                confirm = rr.check_bearish_confirm(m5, i)

            if not confirm:
                reject_counts["no_confirm"] += 1
                continue

            next_level = rr.find_next_h1_level(levels, bar["close"], trade_direction)
            sl, tp, is_valid = rr.calculate_sl_tp(
                m5, i, trade_direction, lvl.price, atr_val,
                next_level, rr.POINT_VALUE
            )
            if not is_valid:
                reject_counts["candle_too_large"] += 1
                continue

            entry_price = bar["close"]
            trade = rr.Trade(
                entry_time=bar_time,
                entry_price=entry_price,
                direction=trade_direction,
                sl=sl,
                tp=tp,
                sr_level=lvl.price,
                signal_candle_idx=i,
                confirm_pattern=confirm,
                original_sl=sl,
            )
            state.in_position = True
            state.current_trade = trade
            lvl.used = True

    # Close remaining
    if state.in_position and state.current_trade:
        trade = state.current_trade
        last_bar = m5.iloc[-1]
        trade.exit_time = m5.index[-1]
        trade.exit_price = last_bar["close"]
        trade.exit_reason = "END_OF_DATA"
        if trade.direction == "long":
            trade.pnl_pips = (last_bar["close"] - trade.entry_price) / rr.POINT_VALUE
        else:
            trade.pnl_pips = (trade.entry_price - last_bar["close"]) / rr.POINT_VALUE
        trades.append(trade)

    return trades


def print_comparison(results: list):
    """Print side-by-side comparison."""
    print(f"\n{'=' * 70}")
    print(f"  RoleReversalEA: S/R Timeframe Comparison")
    print(f"{'=' * 70}")

    header = f"  {'Metric':25s}"
    for r in results:
        header += f"  {r['sr_tf']:>14s}"
    print(header)
    print("  " + "─" * (25 + 16 * len(results)))

    metrics = [
        ("Trades", lambda r: f"{r['trades']}"),
        ("Wins", lambda r: f"{r['wins']}"),
        ("Losses", lambda r: f"{r['losses']}"),
        ("Win Rate", lambda r: f"{r['win_rate']:.1f}%"),
        ("Profit Factor", lambda r: f"{r['profit_factor']:.2f}"),
        ("Total PnL (pips)", lambda r: f"{r['total_pnl']:+.1f}"),
        ("Avg Win (pips)", lambda r: f"{r['avg_win']:+.1f}"),
        ("Avg Loss (pips)", lambda r: f"{r['avg_loss']:+.1f}"),
        ("Max DD (pips)", lambda r: f"{r['max_dd']:.1f}"),
    ]

    for name, func in metrics:
        row = f"  {name:25s}"
        for r in results:
            row += f"  {func(r):>14s}"
        print(row)

    # Exit reason breakdown
    all_reasons = set()
    for r in results:
        all_reasons.update(r["reasons"].keys())

    if all_reasons:
        print(f"\n  Exit Reasons:")
        for reason in sorted(all_reasons):
            row = f"    {reason:20s}"
            for r in results:
                rd = r["reasons"].get(reason, {"n": 0, "pnl": 0})
                row += f"  n={rd['n']:3d} pnl={rd['pnl']:+8.1f}"
            print(row)


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="RoleReversalEA: H1 vs M15 S/R Detection Comparison")
    parser.add_argument("--market", default="GOLD",
                        choices=["GOLD", "FX", "CRYPTO"])
    parser.add_argument("--data", type=str, default=None)
    args = parser.parse_args()

    # Apply market breakeven defaults
    be_defaults = rr.MARKET_BREAKEVEN_DEFAULTS.get(args.market, {})
    rr.ENABLE_BREAKEVEN = be_defaults.get("enable", True)
    rr.BE_RR_THRESHOLD = be_defaults.get("threshold", 1.0)

    data_paths = {
        "GOLD": os.path.join("sim_dat", "GOLD#_M1_202509010100_202511282139.csv"),
        "FX": os.path.join("sim_dat", "USDJPY#_M1_202512010000_202602270000.csv"),
        "CRYPTO": os.path.join("sim_dat", "BTCUSD#_M1_202512010000_202602270000.csv"),
    }
    data_path = args.data or data_paths.get(args.market)

    if not os.path.exists(data_path):
        print(f"ERROR: {data_path} not found")
        sys.exit(1)

    print(f"Market: {args.market}")
    print(f"Data:   {data_path}")

    results = []
    for tf in ["H1", "M15"]:
        print(f"\nRunning simulation with {tf} S/R detection...")
        r = run_with_sr_timeframe(data_path, args.market, tf)
        results.append(r)
        print(f"  {tf}: Trades={r['trades']} WR={r['win_rate']:.1f}% "
              f"PF={r['profit_factor']:.2f} PnL={r['total_pnl']:+.1f}")

    print_comparison(results)


if __name__ == "__main__":
    main()
