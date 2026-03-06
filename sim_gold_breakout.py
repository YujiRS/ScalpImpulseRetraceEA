"""
sim_gold_breakout.py  –  GOLD Asian-Range Breakout × Momentum Trail simulation
================================================================================
Strategy:
  1. Asian session (configurable hours) → detect Range (High/Low on M15)
  2. London/NY session → M15 close breaks Range → Entry (market)
  3. ATR-based trailing stop on M15 → hold until trail hit or session end
  4. Max 1 trade per day, 1 direction only

Dependencies: pandas, numpy
"""

import os
import sys
import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional

# ═══════════════════════════════════════════════════════════════════════
# 0. Parameters
# ═══════════════════════════════════════════════════════════════════════

# -- Session hours (server time, XMTrading = GMT+2/+3)
# Asian "quiet" window narrowed: skip late-NY spillover (00-01) and
# early-London pre-market (06-07). Core quiet = 01:00–06:00 server.
RANGE_START_HOUR = 1       # Asian range start
RANGE_END_HOUR = 6         # Asian range end (exclusive: last bar is 05:45)
TRADE_START_HOUR = 7       # Breakout monitoring start
TRADE_END_HOUR = 20        # No new entries after this
FORCE_CLOSE_HOUR = 23      # Force close all positions

# -- Range quality filter
# GOLD is volatile even in Asian session → wider tolerance than FX
MIN_RANGE_ATR_MULT = 0.3   # RangeWidth >= ATR(H1) * this → valid
MAX_RANGE_ATR_MULT = 4.0   # RangeWidth <= ATR(H1) * this → valid (was 1.5)

# -- Breakout confirmation
BREAKOUT_BODY_RATIO = 0.50  # Breakout candle body >= 50% of bar range
BREAKOUT_SPREAD_MULT = 2.0  # Close must exceed range boundary by Spread * this

# -- SL
SL_BUFFER_ATR_MULT = 0.3   # SL = opposite range edge ± ATR(M15) * this

# -- Trailing stop
TRAIL_ATR_MULT = 1.5        # TrailDistance = ATR(M15) * this
BREAKEVEN_ATR_MULT = 1.0    # Move SL to entry when profit >= ATR * this

# -- Spread filter
MAX_SPREAD_MULT = 3.0       # Entry rejected if spread > median(15min) * this

# -- Entry filters (added from filter analysis)
EMA_FAST_PERIOD = 20        # M15 EMA fast period
EMA_SLOW_PERIOD = 50        # M15 EMA slow period
USE_EMA50_FILTER = True     # Require EMA20 > EMA50 for LONG (< for SHORT)
MAX_EXCEED_ATR = 1.0        # Reject if breakout exceeds range by > this × ATR(M15)
                            # 0 = disabled. 1.0 filters overextended breakouts.

# -- ATR periods
ATR_PERIOD_M15 = 14
ATR_PERIOD_H1 = 14

# -- Risk (for P&L tracking, not position sizing in sim)
RISK_PERCENT = 1.0

# ═══════════════════════════════════════════════════════════════════════
# 1. Data loading / resampling (shared with sim_fx.py)
# ═══════════════════════════════════════════════════════════════════════

def load_m1(path: str) -> pd.DataFrame:
    """Load M1 OHLC from tab-separated CSV exported by MT5."""
    df = pd.read_csv(
        path, sep="\t",
        names=["date", "time", "open", "high", "low", "close",
               "tickvol", "vol", "spread"],
        skiprows=1,
    )
    df["datetime"] = pd.to_datetime(df["date"] + " " + df["time"],
                                     format="%Y.%m.%d %H:%M:%S")
    df.set_index("datetime", inplace=True)
    df.sort_index(inplace=True)
    for c in ["open", "high", "low", "close"]:
        df[c] = df[c].astype(float)
    df["spread"] = df["spread"].astype(float)
    return df


def resample_ohlc(m1: pd.DataFrame, rule: str) -> pd.DataFrame:
    """Resample M1 to higher TF (e.g. '15min', '60min')."""
    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "spread": "mean",
    }
    df = m1.resample(rule).agg(agg).dropna(subset=["open"])
    return df


def point() -> float:
    """XAUUSD point size (0.01 for typical 2-digit broker)."""
    return 0.01

# ═══════════════════════════════════════════════════════════════════════
# 2. Technical helpers
# ═══════════════════════════════════════════════════════════════════════

def atr_series(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Compute ATR (Wilder smoothing) as pandas Series."""
    h = df["high"].values
    l = df["low"].values
    c = df["close"].values
    tr = np.empty(len(df))
    tr[0] = h[0] - l[0]
    for i in range(1, len(df)):
        tr[i] = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
    atr = np.empty(len(df))
    atr[:period] = np.nan
    if len(df) >= period:
        atr[period - 1] = np.mean(tr[:period])
        for i in range(period, len(df)):
            atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return pd.Series(atr, index=df.index, name="atr")


def median_spread_pts(m1: pd.DataFrame, ts: pd.Timestamp, window_min: int = 15) -> float:
    """Median spread (in points) over the last `window_min` minutes."""
    start = ts - pd.Timedelta(minutes=window_min)
    window = m1.loc[start:ts, "spread"]
    if len(window) == 0:
        return m1["spread"].median()
    return window.median()

# ═══════════════════════════════════════════════════════════════════════
# 3. Daily range detection
# ═══════════════════════════════════════════════════════════════════════

class Dir(Enum):
    LONG = auto()
    SHORT = auto()


@dataclass
class DailyRange:
    date: pd.Timestamp           # Trading date
    range_high: float
    range_low: float
    range_width: float           # range_high - range_low
    h1_atr: float                # ATR(H1) at range end for quality check
    valid: bool = True
    reject_reason: str = ""
    # M15 bar indices for the range period
    range_start_idx: int = 0
    range_end_idx: int = 0


@dataclass
class TradeResult:
    date: pd.Timestamp
    daily_range: Optional[DailyRange] = None
    direction: Optional[Dir] = None
    # Entry
    entry_time: str = ""
    entry_price: float = 0.0
    entry_spread: float = 0.0
    # SL
    sl_price: float = 0.0
    sl_distance: float = 0.0
    # Exit
    exit_time: str = ""
    exit_price: float = 0.0
    exit_reason: str = ""
    # Result
    pnl_pts: float = 0.0         # in price (not points)
    pnl_pips: float = 0.0        # pnl_pts / point()
    hold_bars_m15: int = 0
    # Tracking
    max_favorable: float = 0.0   # Max favorable excursion (price)
    max_adverse: float = 0.0     # Max adverse excursion (price)
    breakeven_hit: bool = False
    # Rejection
    reject_stage: str = ""


def detect_daily_ranges(m15: pd.DataFrame, h1_atr: pd.Series) -> list[DailyRange]:
    """For each trading day, compute the Asian session range on M15."""
    ranges = []
    dates = m15.index.normalize().unique()

    for day in dates:
        range_start = day + pd.Timedelta(hours=RANGE_START_HOUR)
        range_end = day + pd.Timedelta(hours=RANGE_END_HOUR)

        # Get M15 bars in Asian session
        mask = (m15.index >= range_start) & (m15.index < range_end)
        session = m15.loc[mask]

        if len(session) < 4:  # Need at least 4 M15 bars (1 hour)
            continue

        rh = session["high"].max()
        rl = session["low"].min()
        rw = rh - rl

        # Get H1 ATR at range end
        h1_loc = h1_atr.index.get_indexer([range_end], method="ffill")[0]
        h1_a = h1_atr.iloc[h1_loc] if h1_loc >= 0 and not np.isnan(h1_atr.iloc[h1_loc]) else np.nan

        dr = DailyRange(
            date=day,
            range_high=rh,
            range_low=rl,
            range_width=rw,
            h1_atr=h1_a,
        )

        # Quality filter
        if np.isnan(h1_a) or h1_a <= 0:
            dr.valid = False
            dr.reject_reason = "NO_ATR"
        elif rw < h1_a * MIN_RANGE_ATR_MULT:
            dr.valid = False
            dr.reject_reason = "RANGE_TOO_NARROW"
        elif rw > h1_a * MAX_RANGE_ATR_MULT:
            dr.valid = False
            dr.reject_reason = "RANGE_TOO_WIDE"

        # Store M15 index positions
        m15_indices = m15.index.get_indexer(session.index)
        if len(m15_indices) > 0:
            dr.range_start_idx = m15_indices[0]
            dr.range_end_idx = m15_indices[-1]

        ranges.append(dr)

    return ranges

# ═══════════════════════════════════════════════════════════════════════
# 4. Breakout detection + Entry
# ═══════════════════════════════════════════════════════════════════════

def detect_breakout_and_enter(dr: DailyRange, m15: pd.DataFrame,
                               m15_atr: pd.Series, m1: pd.DataFrame,
                               m15_ema_fast: Optional[pd.Series] = None,
                               m15_ema_slow: Optional[pd.Series] = None) -> TradeResult:
    """Scan M15 bars after Asian session for breakout of daily range."""
    result = TradeResult(date=dr.date, daily_range=dr)

    if not dr.valid:
        result.reject_stage = dr.reject_reason
        return result

    day = dr.date
    trade_start = day + pd.Timedelta(hours=TRADE_START_HOUR)
    trade_end = day + pd.Timedelta(hours=TRADE_END_HOUR)

    # Get M15 bars in trade window
    mask = (m15.index >= trade_start) & (m15.index < trade_end)
    trade_bars = m15.loc[mask]

    if len(trade_bars) == 0:
        result.reject_stage = "NO_TRADE_BARS"
        return result

    opens = trade_bars["open"].values
    highs = trade_bars["high"].values
    lows = trade_bars["low"].values
    closes = trade_bars["close"].values
    times = trade_bars.index

    rh = dr.range_high
    rl = dr.range_low

    for i in range(len(trade_bars)):
        ts = times[i]
        c = closes[i]
        o = opens[i]
        h = highs[i]
        l = lows[i]
        bar_range = h - l

        if bar_range <= 0:
            continue

        # Body ratio check
        body = abs(c - o)
        body_ratio = body / bar_range

        # Get current spread (from M1 nearest to this M15 bar)
        spread_pts = median_spread_pts(m1, ts)
        spread_price = spread_pts * point()
        min_exceed = spread_price * BREAKOUT_SPREAD_MULT

        # ATR at this bar
        atr_loc = m15_atr.index.get_indexer([ts], method="ffill")[0]
        atr_val = m15_atr.iloc[atr_loc] if atr_loc >= 0 and not np.isnan(m15_atr.iloc[atr_loc]) else dr.h1_atr

        # ── Check Long breakout ──
        if c > rh + min_exceed and body_ratio >= BREAKOUT_BODY_RATIO and c > o:
            # Spread filter
            if spread_pts > median_spread_pts(m1, ts) * MAX_SPREAD_MULT:
                result.reject_stage = "SPREAD_TOO_WIDE"
                return result

            # EMA50 trend filter: require EMA_fast > EMA_slow for LONG
            if USE_EMA50_FILTER and m15_ema_fast is not None and m15_ema_slow is not None:
                ef = m15_ema_fast.iloc[m15_atr.index.get_indexer([ts], method="ffill")[0]]
                es = m15_ema_slow.iloc[m15_atr.index.get_indexer([ts], method="ffill")[0]]
                if ef <= es:
                    result.reject_stage = "EMA50_CONTRA"
                    return result

            # Exceed filter: reject if price overextended past range
            if MAX_EXCEED_ATR > 0 and atr_val > 0:
                exceed = c - rh
                if exceed > atr_val * MAX_EXCEED_ATR:
                    result.reject_stage = "EXCEED_TOO_FAR"
                    return result

            result.direction = Dir.LONG
            result.entry_price = c
            result.entry_time = str(ts)
            result.entry_spread = spread_pts
            result.sl_price = rl - atr_val * SL_BUFFER_ATR_MULT
            result.sl_distance = result.entry_price - result.sl_price
            return result

        # ── Check Short breakout ──
        if c < rl - min_exceed and body_ratio >= BREAKOUT_BODY_RATIO and c < o:
            if spread_pts > median_spread_pts(m1, ts) * MAX_SPREAD_MULT:
                result.reject_stage = "SPREAD_TOO_WIDE"
                return result

            # EMA50 trend filter: require EMA_fast < EMA_slow for SHORT
            if USE_EMA50_FILTER and m15_ema_fast is not None and m15_ema_slow is not None:
                ef = m15_ema_fast.iloc[m15_atr.index.get_indexer([ts], method="ffill")[0]]
                es = m15_ema_slow.iloc[m15_atr.index.get_indexer([ts], method="ffill")[0]]
                if ef >= es:
                    result.reject_stage = "EMA50_CONTRA"
                    return result

            # Exceed filter: reject if price overextended past range
            if MAX_EXCEED_ATR > 0 and atr_val > 0:
                exceed = rl - c
                if exceed > atr_val * MAX_EXCEED_ATR:
                    result.reject_stage = "EXCEED_TOO_FAR"
                    return result

            result.direction = Dir.SHORT
            result.entry_price = c
            result.entry_time = str(ts)
            result.entry_spread = spread_pts
            result.sl_price = rh + atr_val * SL_BUFFER_ATR_MULT
            result.sl_distance = result.sl_price - result.entry_price
            return result

    # No breakout found
    result.reject_stage = "NO_BREAKOUT"
    return result

# ═══════════════════════════════════════════════════════════════════════
# 5. Exit simulation (ATR trailing on M15)
# ═══════════════════════════════════════════════════════════════════════

def simulate_exit(result: TradeResult, m15: pd.DataFrame, m15_atr: pd.Series):
    """Simulate trailing stop exit on M15 from entry time."""
    if result.entry_price == 0 or result.direction is None:
        return

    d = result.direction
    entry_price = result.entry_price
    sl = result.sl_price

    # Find M15 bar at/after entry
    entry_ts = pd.Timestamp(result.entry_time)
    force_close_ts = result.date + pd.Timedelta(hours=FORCE_CLOSE_HOUR)

    # Get bars from entry to force close
    mask = (m15.index > entry_ts) & (m15.index <= force_close_ts)
    exit_bars = m15.loc[mask]

    if len(exit_bars) == 0:
        result.exit_reason = "NO_EXIT_DATA"
        return

    closes = exit_bars["close"].values
    highs = exit_bars["high"].values
    lows = exit_bars["low"].values
    times = exit_bars.index

    trail_active = False
    breakeven_done = False
    max_fav = 0.0
    max_adv = 0.0

    for i in range(len(exit_bars)):
        ts = times[i]
        c = closes[i]
        h = highs[i]
        l = lows[i]

        # ATR at this bar
        atr_loc = m15_atr.index.get_indexer([ts], method="ffill")[0]
        atr_val = m15_atr.iloc[atr_loc] if atr_loc >= 0 and not np.isnan(m15_atr.iloc[atr_loc]) else 0

        # Track excursions
        if d == Dir.LONG:
            fav = h - entry_price
            adv = entry_price - l
            if fav > max_fav:
                max_fav = fav
            if adv > max_adv:
                max_adv = adv
        else:
            fav = entry_price - l
            adv = h - entry_price
            if fav > max_fav:
                max_fav = fav
            if adv > max_adv:
                max_adv = adv

        # ── SL check (intra-bar) ──
        if d == Dir.LONG and l <= sl:
            result.exit_time = str(ts)
            result.exit_price = sl  # Assume fill at SL
            result.exit_reason = "SL_Hit"
            break
        if d == Dir.SHORT and h >= sl:
            result.exit_time = str(ts)
            result.exit_price = sl
            result.exit_reason = "SL_Hit"
            break

        # ── Reverse candle check (ATR × 2 opposite bar) ──
        if atr_val > 0:
            bar_body = abs(c - exit_bars["open"].values[i])
            if d == Dir.LONG and c < exit_bars["open"].values[i] and bar_body >= atr_val * 2.0:
                result.exit_time = str(ts)
                result.exit_price = c
                result.exit_reason = "ReverseCandle"
                break
            if d == Dir.SHORT and c > exit_bars["open"].values[i] and bar_body >= atr_val * 2.0:
                result.exit_time = str(ts)
                result.exit_price = c
                result.exit_reason = "ReverseCandle"
                break

        # ── Breakeven move ──
        if not breakeven_done and atr_val > 0:
            be_trigger = atr_val * BREAKEVEN_ATR_MULT
            if d == Dir.LONG and (c - entry_price) >= be_trigger:
                sl = entry_price + result.entry_spread * point()
                breakeven_done = True
                result.breakeven_hit = True
            elif d == Dir.SHORT and (entry_price - c) >= be_trigger:
                sl = entry_price - result.entry_spread * point()
                breakeven_done = True
                result.breakeven_hit = True

        # ── Trailing stop update (on bar close) ──
        if atr_val > 0:
            trail_dist = atr_val * TRAIL_ATR_MULT
            if d == Dir.LONG:
                new_sl = c - trail_dist
                if new_sl > sl:
                    sl = new_sl
                    trail_active = True
            else:
                new_sl = c + trail_dist
                if new_sl < sl:
                    sl = new_sl
                    trail_active = True

        # ── Force close check ──
        if ts.hour >= FORCE_CLOSE_HOUR:
            result.exit_time = str(ts)
            result.exit_price = c
            result.exit_reason = "SessionEnd"
            break
    else:
        # Data exhausted
        last_i = len(exit_bars) - 1
        result.exit_time = str(times[last_i])
        result.exit_price = closes[last_i]
        result.exit_reason = "DataEnd"

    # ── P&L calculation ──
    result.max_favorable = max_fav
    result.max_adverse = max_adv

    if result.exit_price > 0:
        if d == Dir.LONG:
            result.pnl_pts = result.exit_price - entry_price
        else:
            result.pnl_pts = entry_price - result.exit_price
        result.pnl_pips = result.pnl_pts / point()

    # Hold bars
    if result.exit_time and result.entry_time:
        entry_ts = pd.Timestamp(result.entry_time)
        exit_ts = pd.Timestamp(result.exit_time)
        mask_hold = (m15.index > entry_ts) & (m15.index <= exit_ts)
        result.hold_bars_m15 = mask_hold.sum()

# ═══════════════════════════════════════════════════════════════════════
# 6. Statistics & output
# ═══════════════════════════════════════════════════════════════════════

def collect_stats(results: list[TradeResult]) -> dict:
    """Compute summary statistics."""
    total = len(results)
    traded = [r for r in results if r.entry_price > 0 and r.exit_price > 0]
    rejected = [r for r in results if r.entry_price == 0]

    # Reject breakdown
    reject_counts: dict[str, int] = {}
    for r in rejected:
        k = r.reject_stage or "UNKNOWN"
        reject_counts[k] = reject_counts.get(k, 0) + 1

    # Trade stats
    wins = [t for t in traded if t.pnl_pts > 0]
    losses = [t for t in traded if t.pnl_pts <= 0]
    gross_win = sum(t.pnl_pts for t in wins)
    gross_loss = abs(sum(t.pnl_pts for t in losses))

    # Exit reason breakdown
    exit_reasons: dict[str, int] = {}
    for t in traded:
        exit_reasons[t.exit_reason] = exit_reasons.get(t.exit_reason, 0) + 1

    return {
        "total_days": total,
        "traded": len(traded),
        "rejected": len(rejected),
        "reject_counts": reject_counts,
        "wins": len(wins),
        "losses": len(losses),
        "win_rate": 100 * len(wins) / len(traded) if traded else 0,
        "gross_win": gross_win,
        "gross_loss": gross_loss,
        "net_pnl": gross_win - gross_loss,
        "net_pnl_pips": (gross_win - gross_loss) / point(),
        "avg_win": gross_win / len(wins) if wins else 0,
        "avg_loss": gross_loss / len(losses) if losses else 0,
        "pf": gross_win / gross_loss if gross_loss > 0 else float("inf"),
        "avg_hold_bars": np.mean([t.hold_bars_m15 for t in traded]) if traded else 0,
        "avg_mfe": np.mean([t.max_favorable for t in traded]) if traded else 0,
        "avg_mae": np.mean([t.max_adverse for t in traded]) if traded else 0,
        "breakeven_pct": 100 * sum(1 for t in traded if t.breakeven_hit) / len(traded) if traded else 0,
        "exit_reasons": exit_reasons,
    }


def print_results(results: list[TradeResult]):
    """Print detailed trade-by-trade results and summary."""
    # Detail table
    header = (f"{'Date':<12} {'Dir':<6} {'RangeW':>8} {'H1ATR':>8} "
              f"{'Entry':>10} {'SL':>10} {'Exit':>10} "
              f"{'PnL':>9} {'Hold':>5} {'BE':>3} {'MFE':>8} {'MAE':>8} "
              f"{'ExitReason':<15} {'Reject':<20}")
    print(header)
    print("-" * len(header))

    for r in results:
        d_str = r.direction.name if r.direction else "-"
        dt = str(r.date.date()) if r.date is not None else "-"
        rw = f"{r.daily_range.range_width:.2f}" if r.daily_range else "-"
        h1a = f"{r.daily_range.h1_atr:.2f}" if r.daily_range and not np.isnan(r.daily_range.h1_atr) else "-"
        ep = f"{r.entry_price:.2f}" if r.entry_price > 0 else "-"
        sl = f"{r.sl_price:.2f}" if r.sl_price > 0 else "-"
        xp = f"{r.exit_price:.2f}" if r.exit_price > 0 else "-"
        pnl = f"{r.pnl_pts:+.2f}" if r.entry_price > 0 else "-"
        hold = str(r.hold_bars_m15) if r.hold_bars_m15 > 0 else "-"
        be = "Y" if r.breakeven_hit else "-"
        mfe = f"{r.max_favorable:.2f}" if r.max_favorable > 0 else "-"
        mae = f"{r.max_adverse:.2f}" if r.max_adverse > 0 else "-"
        ex = r.exit_reason if r.exit_reason else "-"
        rej = r.reject_stage if r.reject_stage else "-"

        print(f"{dt:<12} {d_str:<6} {rw:>8} {h1a:>8} "
              f"{ep:>10} {sl:>10} {xp:>10} "
              f"{pnl:>9} {hold:>5} {be:>3} {mfe:>8} {mae:>8} "
              f"{ex:<15} {rej:<20}")

    # Summary
    stats = collect_stats(results)
    print(f"\n{'='*70}")
    print("SUMMARY")
    print(f"{'='*70}")
    print(f"  Total trading days:  {stats['total_days']}")
    print(f"  Trades executed:     {stats['traded']}")
    print(f"  Rejected:            {stats['rejected']}")

    if stats["reject_counts"]:
        print(f"\n  Reject breakdown:")
        for k, v in sorted(stats["reject_counts"].items(), key=lambda x: -x[1]):
            print(f"    {k:<25} {v:>4}  ({100*v/stats['total_days']:.1f}%)")

    if stats["traded"] > 0:
        print(f"\n  Wins:     {stats['wins']}  ({stats['win_rate']:.1f}%)")
        print(f"  Losses:   {stats['losses']}")
        print(f"  Avg win:  {stats['avg_win']:.2f}  ({stats['avg_win']/point():.0f} pips)")
        print(f"  Avg loss: {stats['avg_loss']:.2f}  ({stats['avg_loss']/point():.0f} pips)")
        print(f"  PF:       {stats['pf']:.2f}")
        print(f"  Net P&L:  {stats['net_pnl']:+.2f}  ({stats['net_pnl_pips']:+.0f} pips)")
        print(f"  Avg hold: {stats['avg_hold_bars']:.1f} M15 bars")
        print(f"  Avg MFE:  {stats['avg_mfe']:.2f}")
        print(f"  Avg MAE:  {stats['avg_mae']:.2f}")
        print(f"  BE hit:   {stats['breakeven_pct']:.0f}%")

        if stats["exit_reasons"]:
            print(f"\n  Exit reasons:")
            for k, v in sorted(stats["exit_reasons"].items(), key=lambda x: -x[1]):
                print(f"    {k:<20} {v:>4}  ({100*v/stats['traded']:.1f}%)")

    return stats

# ═══════════════════════════════════════════════════════════════════════
# 7. Main simulation
# ═══════════════════════════════════════════════════════════════════════

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "GOLD#_M1_202509010100_202511282139.csv")

    if not os.path.exists(data_path):
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    print("=" * 70)
    print("sim_gold_breakout.py  –  GOLD Asian-Range Breakout × Momentum Trail")
    print("=" * 70)

    # ── Load & resample ──
    print("\n[1] Loading M1 data …")
    m1 = load_m1(data_path)
    print(f"    M1 bars: {len(m1)}  range: {m1.index[0]} → {m1.index[-1]}")

    m15 = resample_ohlc(m1, "15min")
    h1 = resample_ohlc(m1, "60min")
    print(f"    M15 bars: {len(m15)},  H1 bars: {len(h1)}")

    # ── Indicators ──
    print("[2] Computing indicators …")
    m15_atr = atr_series(m15, ATR_PERIOD_M15)
    h1_atr = atr_series(h1, ATR_PERIOD_H1)
    m15_ema_fast = m15["close"].ewm(span=EMA_FAST_PERIOD, adjust=False).mean()
    m15_ema_slow = m15["close"].ewm(span=EMA_SLOW_PERIOD, adjust=False).mean()

    # ── Range detection ──
    print("[3] Detecting daily Asian ranges …")
    ranges = detect_daily_ranges(m15, h1_atr)
    print(f"    Days found: {len(ranges)}")
    valid = sum(1 for r in ranges if r.valid)
    print(f"    Valid ranges: {valid}")

    for dr in ranges:
        status = "OK" if dr.valid else dr.reject_reason
        print(f"    {dr.date.date()}  H={dr.range_high:.2f}  L={dr.range_low:.2f}  "
              f"W={dr.range_width:.2f}  ATR(H1)={dr.h1_atr:.2f}  [{status}]")

    # ── Breakout detection + Entry + Exit ──
    print("\n[4] Running breakout detection & exit simulation …")
    results: list[TradeResult] = []

    for dr in ranges:
        tr = detect_breakout_and_enter(dr, m15, m15_atr, m1,
                                       m15_ema_fast, m15_ema_slow)
        if tr.entry_price > 0:
            simulate_exit(tr, m15, m15_atr)
        results.append(tr)

    # ── Output ──
    print("\n" + "=" * 70)
    print("TRADE DETAIL")
    print("=" * 70 + "\n")
    stats = print_results(results)

    # ── CSV output ──
    csv_path = os.path.join(script_dir, "sim_dat", "sim_results_gold_breakout.csv")
    rows = []
    for r in results:
        rows.append({
            "Date": str(r.date.date()) if r.date is not None else "",
            "Direction": r.direction.name if r.direction else "",
            "RangeHigh": f"{r.daily_range.range_high:.2f}" if r.daily_range else "",
            "RangeLow": f"{r.daily_range.range_low:.2f}" if r.daily_range else "",
            "RangeWidth": f"{r.daily_range.range_width:.2f}" if r.daily_range else "",
            "H1_ATR": f"{r.daily_range.h1_atr:.2f}" if r.daily_range else "",
            "EntryTime": r.entry_time,
            "EntryPrice": f"{r.entry_price:.2f}" if r.entry_price > 0 else "",
            "SL": f"{r.sl_price:.2f}" if r.sl_price > 0 else "",
            "SL_Distance": f"{r.sl_distance:.2f}" if r.sl_distance > 0 else "",
            "ExitTime": r.exit_time,
            "ExitPrice": f"{r.exit_price:.2f}" if r.exit_price > 0 else "",
            "ExitReason": r.exit_reason,
            "PnL_price": f"{r.pnl_pts:+.2f}" if r.entry_price > 0 else "",
            "PnL_pips": f"{r.pnl_pips:+.0f}" if r.entry_price > 0 else "",
            "HoldBars_M15": r.hold_bars_m15 if r.hold_bars_m15 > 0 else "",
            "MFE": f"{r.max_favorable:.2f}" if r.max_favorable > 0 else "",
            "MAE": f"{r.max_adverse:.2f}" if r.max_adverse > 0 else "",
            "Breakeven": "Y" if r.breakeven_hit else "",
            "Spread": f"{r.entry_spread:.0f}" if r.entry_spread > 0 else "",
            "RejectStage": r.reject_stage,
        })
    df_out = pd.DataFrame(rows)
    df_out.to_csv(csv_path, index=False)
    print(f"\nCSV written: {csv_path}  ({len(df_out)} rows)")


if __name__ == "__main__":
    main()
