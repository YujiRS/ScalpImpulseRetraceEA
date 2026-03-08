"""
sim_hybrid_exit.py  –  Hybrid Exit Strategy Simulator
=====================================================
Compares three exit strategies on the same synthetic positions:

  A) Conventional: EMA13/21 cross (current 3-EA exit)
  B) FlatRange: CloseByFlatRangeEA (MA flat → range lock → breakout/trail)
  C) Hybrid: FlatRange when 21MA direction matches position, else Conventional

For each market (GOLD, FX, CRYPTO), simulates on M1 CSV data.
Priority 1 (StructBreak) and Priority 2 (TimeExit) remain unchanged in all modes.

Usage:
  python sim_hybrid_exit.py <M1_CSV_PATH> [--market GOLD|FX|CRYPTO]
                            [--spread-override <pips>]
                            [--position-csv <path>]

Dependencies: pandas, numpy
"""

import os
import sys
import argparse
import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional, List, Tuple


# ═══════════════════════════════════════════════════════════════════════
# 0. Market Profiles & Parameters
# ═══════════════════════════════════════════════════════════════════════

class Market(Enum):
    GOLD = "GOLD"
    FX = "FX"
    CRYPTO = "CRYPTO"

@dataclass
class MarketProfile:
    """Parameters that vary by market."""
    market: Market
    point: float
    spread_default: float     # in price units
    time_exit_bars: int
    sl_atr_mult: float
    # FlatRange params
    flat_ma_method: str       # "SMA" or "EMA"
    flat_ma_period: int
    flat_slope_lookback: int
    flat_slope_atr_mult: float
    range_lookback: int
    trail_atr_mult: float
    wait_bars_after_flat: int
    # Conventional exit params
    exit_ema_fast: int = 13
    exit_ema_slow: int = 21
    exit_confirm_bars: int = 1
    # Hybrid: 21MA slope lookback for direction check
    hybrid_ma_lookback: int = 5
    # Hybrid: TimeExit bars when using FlatRange path (0 = use same as time_exit_bars)
    hybrid_time_exit_bars: int = 0

PROFILES = {
    Market.GOLD: MarketProfile(
        market=Market.GOLD, point=0.01, spread_default=0.20,
        time_exit_bars=8, sl_atr_mult=0.8,
        flat_ma_method="EMA", flat_ma_period=21,
        flat_slope_lookback=3, flat_slope_atr_mult=0.30,
        range_lookback=20, trail_atr_mult=1.0, wait_bars_after_flat=30,
    ),
    Market.FX: MarketProfile(
        market=Market.FX, point=0.001, spread_default=0.0003,
        time_exit_bars=10, sl_atr_mult=0.7,
        flat_ma_method="SMA", flat_ma_period=21,
        flat_slope_lookback=3, flat_slope_atr_mult=0.03,
        range_lookback=10, trail_atr_mult=1.0, wait_bars_after_flat=16,
    ),
    Market.CRYPTO: MarketProfile(
        market=Market.CRYPTO, point=1.0, spread_default=50.0,
        time_exit_bars=6, sl_atr_mult=0.7,
        flat_ma_method="EMA", flat_ma_period=13,
        flat_slope_lookback=8, flat_slope_atr_mult=0.03,
        range_lookback=20, trail_atr_mult=1.0, wait_bars_after_flat=40,
    ),
}


# ═══════════════════════════════════════════════════════════════════════
# 1. Data Loading
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
    if "spread" in df.columns:
        df["spread"] = pd.to_numeric(df["spread"], errors="coerce").fillna(0)
    return df


def detect_market(path: str) -> Market:
    """Guess market from filename."""
    name = os.path.basename(path).upper()
    if "XAU" in name or "GOLD" in name:
        return Market.GOLD
    elif "BTC" in name or "ETH" in name or "CRYPTO" in name:
        return Market.CRYPTO
    else:
        return Market.FX


# ═══════════════════════════════════════════════════════════════════════
# 2. Technical Indicators
# ═══════════════════════════════════════════════════════════════════════

def sma(series: pd.Series, period: int) -> pd.Series:
    return series.rolling(period).mean()

def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()

def ma(series: pd.Series, period: int, method: str) -> pd.Series:
    if method == "EMA":
        return ema(series, period)
    return sma(series, period)

def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high = df["high"]
    low = df["low"]
    prev_close = df["close"].shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(span=period, adjust=False).mean()


# ═══════════════════════════════════════════════════════════════════════
# 3. Synthetic Position Generation
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class Position:
    entry_idx: int
    entry_datetime: pd.Timestamp
    direction: str    # "BUY" or "SELL"
    entry_price: float
    impulse_start: float = 0.0  # for StructBreak check


def generate_positions(df: pd.DataFrame, profile: MarketProfile,
                       min_positions: int = 80) -> List[Position]:
    """
    Generate synthetic positions at trend start points.
    Uses SMA21 slope to detect trend initiation.
    """
    close = df["close"].values
    high = df["high"].values
    low = df["low"].values
    ma21 = sma(df["close"], 21).values
    atr14 = atr(df, 14).values

    positions = []
    cooldown = 0
    min_gap = 60  # min bars between entries

    for i in range(25, len(df) - 120):
        if cooldown > 0:
            cooldown -= 1
            continue

        if np.isnan(ma21[i]) or np.isnan(ma21[i - 5]) or np.isnan(atr14[i]):
            continue

        slope = ma21[i] - ma21[i - 5]
        slope_pts = abs(slope) / profile.point
        atr_pts = atr14[i] / profile.point

        # Require meaningful slope (> 0.3 ATR over 5 bars)
        if slope_pts < atr_pts * 0.3:
            continue

        if slope > 0:
            direction = "BUY"
            # Impulse start ~= recent swing low
            impulse_start = float(np.min(low[max(0, i-20):i]))
        else:
            direction = "SELL"
            impulse_start = float(np.max(high[max(0, i-20):i]))

        positions.append(Position(
            entry_idx=i,
            entry_datetime=df.index[i],
            direction=direction,
            entry_price=close[i],
            impulse_start=impulse_start,
        ))
        cooldown = min_gap

    print(f"  Generated {len(positions)} synthetic positions")
    if len(positions) < min_positions:
        print(f"  WARNING: fewer than {min_positions} positions. "
              f"Consider using more data.")
    return positions


def load_positions(path: str, df: pd.DataFrame) -> List[Position]:
    """Load positions from CSV: entry_bar_index, entry_datetime, direction, entry_price"""
    pdf = pd.read_csv(path)
    positions = []
    for _, row in pdf.iterrows():
        idx = int(row["entry_bar_index"])
        positions.append(Position(
            entry_idx=idx,
            entry_datetime=pd.Timestamp(row["entry_datetime"]),
            direction=row["direction"],
            entry_price=float(row["entry_price"]),
            impulse_start=float(row.get("impulse_start", 0.0)),
        ))
    return positions


# ═══════════════════════════════════════════════════════════════════════
# 4. Exit Strategy Implementations
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class ExitResult:
    exit_idx: int
    exit_price: float
    exit_reason: str
    pnl_pips: float
    bars_held: int


# ---------------------------------------------------------------
# 4A. Conventional Exit: EMA13/21 Cross + StructBreak + TimeExit
# ---------------------------------------------------------------

def sim_conventional_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
    atr_arr: np.ndarray,
) -> Optional[ExitResult]:
    """
    Simulate the current 3-EA exit logic:
      P1: StructBreak (close crosses impulse_start)
      P2: TimeExit (N bars, profit <= 0)
      P3: EMA13/21 cross + 1-bar confirm
    """
    close = df["close"].values
    is_long = pos.direction == "BUY"
    start = pos.entry_idx + 1  # skip entry bar
    max_bar = min(len(df) - 1, pos.entry_idx + 500)

    exit_pending = False
    exit_pending_bars = 0
    position_bars = 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        # P1: StructBreak (confirmed bar = i is shift=1 equivalent)
        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / profile.point
                return ExitResult(i, c, "StructBreak", pnl, position_bars)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / profile.point
                return ExitResult(i, c, "StructBreak", pnl, position_bars)

        # P2: TimeExit
        if position_bars >= profile.time_exit_bars:
            pnl = ((c - pos.entry_price) if is_long
                   else (pos.entry_price - c)) / profile.point
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars)

        # P3: EMA Cross
        if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
            continue

        ef1 = ema_fast_arr[i]      # shift=1 equivalent (confirmed bar)
        es1 = ema_slow_arr[i]
        ef2 = ema_fast_arr[i - 1]  # shift=2
        es2 = ema_slow_arr[i - 1]

        if exit_pending:
            exit_pending_bars += 1
            cross_maintained = False
            if is_long and ef1 < es1:
                cross_maintained = True
            elif not is_long and ef1 > es1:
                cross_maintained = True

            if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                pnl = ((c - pos.entry_price) if is_long
                       else (pos.entry_price - c)) / profile.point
                return ExitResult(i, c, "EMACross", pnl, position_bars)
            elif not cross_maintained:
                exit_pending = False
                exit_pending_bars = 0
        else:
            cross_detected = False
            if is_long and ef2 >= es2 and ef1 < es1:
                cross_detected = True
            elif not is_long and ef2 <= es2 and ef1 > es1:
                cross_detected = True

            if cross_detected:
                exit_pending = True
                exit_pending_bars = 0

    return None  # data ended


# ---------------------------------------------------------------
# 4B. FlatRange Exit: CloseByFlatRangeEA state machine
# ---------------------------------------------------------------

class FRState(Enum):
    WAIT_FLAT = auto()
    RANGE_LOCKED = auto()
    TRAILING = auto()
    CLOSED = auto()


def sim_flatrange_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ma_flat_arr: np.ndarray, atr_arr: np.ndarray,
) -> Optional[ExitResult]:
    """
    Simulate CloseByFlatRangeEA exit on confirmed bars.
    States: WAIT_FLAT → RANGE_LOCKED → TRAILING → CLOSED
    """
    close = df["close"].values
    high = df["high"].values
    low = df["low"].values
    is_long = pos.direction == "BUY"
    start = pos.entry_idx + 1
    max_bar = min(len(df) - 1, pos.entry_idx + 500)
    pt = profile.point

    state = FRState.WAIT_FLAT
    range_high = range_low = range_mid = 0.0
    trail_peak = trail_line = 0.0
    wait_bars_count = 0
    position_bars = 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        lb = profile.flat_slope_lookback
        if i < lb + 1 or np.isnan(ma_flat_arr[i]) or np.isnan(ma_flat_arr[i - lb]):
            continue
        if np.isnan(atr_arr[i]):
            continue

        # ── WAIT_FLAT ──
        if state == FRState.WAIT_FLAT:
            ma_curr = ma_flat_arr[i]
            ma_old = ma_flat_arr[i - lb]
            slope_pts = abs(ma_curr - ma_old) / pt
            atr_pts = atr_arr[i] / pt

            if slope_pts <= atr_pts * profile.flat_slope_atr_mult:
                # Flat detected → lock range
                rng_start = max(0, i - profile.range_lookback + 1)
                range_high = float(np.max(high[rng_start:i + 1]))
                range_low = float(np.min(low[rng_start:i + 1]))
                range_mid = (range_high + range_low) / 2.0
                wait_bars_count = 0
                state = FRState.RANGE_LOCKED

        # ── RANGE_LOCKED ──
        elif state == FRState.RANGE_LOCKED:
            wait_bars_count += 1

            # Breakout check
            breakout = 0
            if is_long:
                if c < range_low:
                    breakout = -1  # unfavorable
                elif c > range_high:
                    breakout = 1   # favorable
            else:
                if c > range_high:
                    breakout = -1
                elif c < range_low:
                    breakout = 1

            if breakout < 0:
                # Unfavorable breakout → close
                pnl = ((c - pos.entry_price) if is_long
                       else (pos.entry_price - c)) / pt
                return ExitResult(i, c, "UnfavBreak", pnl, position_bars)

            if breakout > 0:
                # Favorable breakout → start trailing
                if is_long:
                    trail_peak = float(np.max(high[pos.entry_idx:i + 1]))
                    trail_line = trail_peak - atr_arr[i] * profile.trail_atr_mult
                else:
                    trail_peak = float(np.min(low[pos.entry_idx:i + 1]))
                    trail_line = trail_peak + atr_arr[i] * profile.trail_atr_mult
                state = FRState.TRAILING
                continue

            # FailSafe: WaitBars exceeded
            if wait_bars_count > profile.wait_bars_after_flat:
                pnl = ((c - pos.entry_price) if is_long
                       else (pos.entry_price - c)) / pt
                return ExitResult(i, c, "FailSafe", pnl, position_bars)

        # ── TRAILING ──
        elif state == FRState.TRAILING:
            if is_long:
                trail_peak = max(trail_peak, high[i])
                trail_line = trail_peak - atr_arr[i] * profile.trail_atr_mult
                if c < trail_line:
                    pnl = (c - pos.entry_price) / pt
                    return ExitResult(i, c, "TrailStop", pnl, position_bars)
            else:
                trail_peak = min(trail_peak, low[i])
                trail_line = trail_peak + atr_arr[i] * profile.trail_atr_mult
                if c > trail_line:
                    pnl = (pos.entry_price - c) / pt
                    return ExitResult(i, c, "TrailStop", pnl, position_bars)

    return None  # data ended


# ---------------------------------------------------------------
# 4C. Hybrid Exit: FlatRange if 21MA aligns, else Conventional
# ---------------------------------------------------------------

def check_ma_direction_match(
    pos: Position, bar_idx: int,
    ma_arr: np.ndarray, lookback: int,
) -> Optional[bool]:
    """
    Check if 21MA slope direction matches position direction.
    Returns True=match, False=mismatch, None=cannot determine.
    """
    if bar_idx < lookback + 1:
        return None
    curr = ma_arr[bar_idx]
    old = ma_arr[bar_idx - lookback]
    if np.isnan(curr) or np.isnan(old):
        return None
    slope = curr - old
    if abs(slope) < 1e-10:
        return False  # flat = no match
    if pos.direction == "BUY":
        return bool(slope > 0)
    else:
        return bool(slope < 0)


def sim_hybrid_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
    ma_flat_arr: np.ndarray, atr_arr: np.ndarray,
) -> Optional[ExitResult]:
    """
    Hybrid exit: check 21MA direction at entry.
    If aligned → use FlatRange exit.
    If not aligned → use Conventional (EMA cross) exit.
    P1 (StructBreak) and P2 (TimeExit) are always active.
    """
    close = df["close"].values
    is_long = pos.direction == "BUY"

    # Determine which exit mode to use based on 21MA direction at entry
    ma_match = check_ma_direction_match(
        pos, pos.entry_idx, ma_flat_arr, profile.hybrid_ma_lookback
    )
    use_flatrange = (ma_match is True)

    start = pos.entry_idx + 1
    max_bar = min(len(df) - 1, pos.entry_idx + 500)
    pt = profile.point

    # ── State for FlatRange mode ──
    fr_state = FRState.WAIT_FLAT
    range_high = range_low = range_mid = 0.0
    trail_peak = trail_line = 0.0
    wait_bars_count = 0

    # ── State for Conventional mode ──
    exit_pending = False
    exit_pending_bars = 0

    position_bars = 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        # ── P1: StructBreak (always active) ──
        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / pt
                reason = "StructBreak" + ("+FR" if use_flatrange else "+Conv")
                return ExitResult(i, c, reason, pnl, position_bars)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                reason = "StructBreak" + ("+FR" if use_flatrange else "+Conv")
                return ExitResult(i, c, reason, pnl, position_bars)

        # ── P2: TimeExit (extended when FlatRange path is active) ──
        te_bars = (profile.hybrid_time_exit_bars if use_flatrange and profile.hybrid_time_exit_bars > 0
                   else profile.time_exit_bars)
        if position_bars >= te_bars:
            pnl = ((c - pos.entry_price) if is_long
                   else (pos.entry_price - c)) / pt
            if pnl <= 0:
                reason = "TimeExit" + ("+FR" if use_flatrange else "+Conv")
                return ExitResult(i, c, reason, pnl, position_bars)

        # ── P3: Mode-dependent exit ──
        if use_flatrange:
            # FlatRange logic
            lb = profile.flat_slope_lookback
            if i < lb + 1 or np.isnan(ma_flat_arr[i]) or np.isnan(atr_arr[i]):
                continue

            if fr_state == FRState.WAIT_FLAT:
                ma_curr = ma_flat_arr[i]
                ma_old = ma_flat_arr[i - lb]
                slope_pts = abs(ma_curr - ma_old) / pt
                atr_pts = atr_arr[i] / pt
                if slope_pts <= atr_pts * profile.flat_slope_atr_mult:
                    rng_start = max(0, i - profile.range_lookback + 1)
                    range_high = float(np.max(df["high"].values[rng_start:i + 1]))
                    range_low = float(np.min(df["low"].values[rng_start:i + 1]))
                    range_mid = (range_high + range_low) / 2.0
                    wait_bars_count = 0
                    fr_state = FRState.RANGE_LOCKED

            elif fr_state == FRState.RANGE_LOCKED:
                wait_bars_count += 1
                breakout = 0
                if is_long:
                    if c < range_low: breakout = -1
                    elif c > range_high: breakout = 1
                else:
                    if c > range_high: breakout = -1
                    elif c < range_low: breakout = 1

                if breakout < 0:
                    pnl = ((c - pos.entry_price) if is_long
                           else (pos.entry_price - c)) / pt
                    return ExitResult(i, c, "H:UnfavBreak", pnl, position_bars)

                if breakout > 0:
                    high_arr = df["high"].values
                    low_arr = df["low"].values
                    if is_long:
                        trail_peak = float(np.max(high_arr[pos.entry_idx:i + 1]))
                        trail_line = trail_peak - atr_arr[i] * profile.trail_atr_mult
                    else:
                        trail_peak = float(np.min(low_arr[pos.entry_idx:i + 1]))
                        trail_line = trail_peak + atr_arr[i] * profile.trail_atr_mult
                    fr_state = FRState.TRAILING
                    continue

                if wait_bars_count > profile.wait_bars_after_flat:
                    pnl = ((c - pos.entry_price) if is_long
                           else (pos.entry_price - c)) / pt
                    return ExitResult(i, c, "H:FailSafe", pnl, position_bars)

            elif fr_state == FRState.TRAILING:
                high_arr = df["high"].values
                low_arr = df["low"].values
                if is_long:
                    trail_peak = max(trail_peak, high_arr[i])
                    trail_line = trail_peak - atr_arr[i] * profile.trail_atr_mult
                    if c < trail_line:
                        pnl = (c - pos.entry_price) / pt
                        return ExitResult(i, c, "H:TrailStop", pnl, position_bars)
                else:
                    trail_peak = min(trail_peak, low_arr[i])
                    trail_line = trail_peak + atr_arr[i] * profile.trail_atr_mult
                    if c > trail_line:
                        pnl = (pos.entry_price - c) / pt
                        return ExitResult(i, c, "H:TrailStop", pnl, position_bars)
        else:
            # Conventional EMA cross logic
            if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
                continue

            ef1 = ema_fast_arr[i]
            es1 = ema_slow_arr[i]
            ef2 = ema_fast_arr[i - 1]
            es2 = ema_slow_arr[i - 1]

            if exit_pending:
                exit_pending_bars += 1
                cross_maintained = False
                if is_long and ef1 < es1:
                    cross_maintained = True
                elif not is_long and ef1 > es1:
                    cross_maintained = True

                if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                    pnl = ((c - pos.entry_price) if is_long
                           else (pos.entry_price - c)) / pt
                    return ExitResult(i, c, "H:EMACross", pnl, position_bars)
                elif not cross_maintained:
                    exit_pending = False
                    exit_pending_bars = 0
            else:
                cross_detected = False
                if is_long and ef2 >= es2 and ef1 < es1:
                    cross_detected = True
                elif not is_long and ef2 <= es2 and ef1 > es1:
                    cross_detected = True
                if cross_detected:
                    exit_pending = True
                    exit_pending_bars = 0

    return None


# ═══════════════════════════════════════════════════════════════════════
# 5. Oracle (Ideal Exit)
# ═══════════════════════════════════════════════════════════════════════

def calc_oracle(pos: Position, df: pd.DataFrame, profile: MarketProfile,
                window: int = 120) -> Tuple[float, int]:
    """
    Calculate best possible exit P&L within window bars.
    Returns (oracle_pnl_pips, oracle_bar_offset).
    """
    start = pos.entry_idx + 1
    end = min(len(df), pos.entry_idx + window + 1)
    pt = profile.point

    if pos.direction == "BUY":
        highs = df["high"].values[start:end]
        if len(highs) == 0:
            return 0.0, 0
        best_offset = int(np.argmax(highs))
        best_price = highs[best_offset]
        return (best_price - pos.entry_price) / pt, best_offset + 1
    else:
        lows = df["low"].values[start:end]
        if len(lows) == 0:
            return 0.0, 0
        best_offset = int(np.argmin(lows))
        best_price = lows[best_offset]
        return (pos.entry_price - best_price) / pt, best_offset + 1


# ═══════════════════════════════════════════════════════════════════════
# 6. Main Simulation
# ═══════════════════════════════════════════════════════════════════════

def run_simulation(df: pd.DataFrame, profile: MarketProfile,
                   positions: List[Position]) -> pd.DataFrame:
    """Run all three exit strategies on each position."""

    close = df["close"].values

    # Precompute indicators
    ema_fast = ema(df["close"], profile.exit_ema_fast).values
    ema_slow = ema(df["close"], profile.exit_ema_slow).values
    ma_flat = ma(df["close"], profile.flat_ma_period, profile.flat_ma_method).values
    atr_arr = atr(df, 14).values

    results = []

    for pos in positions:
        # Oracle
        oracle_pnl, oracle_bar = calc_oracle(pos, df, profile)

        # 21MA direction at entry
        ma_match = check_ma_direction_match(
            pos, pos.entry_idx, ma_flat, profile.hybrid_ma_lookback
        )

        # A: Conventional
        res_conv = sim_conventional_exit(pos, df, profile, ema_fast, ema_slow, atr_arr)

        # B: FlatRange
        res_fr = sim_flatrange_exit(pos, df, profile, ma_flat, atr_arr)

        # C: Hybrid
        res_hyb = sim_hybrid_exit(pos, df, profile, ema_fast, ema_slow, ma_flat, atr_arr)

        row = {
            "entry_idx": pos.entry_idx,
            "entry_dt": pos.entry_datetime,
            "dir": pos.direction,
            "entry_price": pos.entry_price,
            "impulse_start": pos.impulse_start,
            "ma_match": "MATCH" if ma_match is True else ("MISMATCH" if ma_match is False else "N/A"),
            "oracle_pnl": oracle_pnl,
            "oracle_bar": oracle_bar,
        }

        for label, res in [("conv", res_conv), ("fr", res_fr), ("hyb", res_hyb)]:
            if res:
                row[f"{label}_exit_idx"] = res.exit_idx
                row[f"{label}_reason"] = res.exit_reason
                row[f"{label}_pnl"] = res.pnl_pips
                row[f"{label}_bars"] = res.bars_held
                if oracle_pnl > 0:
                    row[f"{label}_efficiency"] = res.pnl_pips / oracle_pnl * 100
                else:
                    row[f"{label}_efficiency"] = np.nan
            else:
                row[f"{label}_exit_idx"] = np.nan
                row[f"{label}_reason"] = "DataEnd"
                row[f"{label}_pnl"] = np.nan
                row[f"{label}_bars"] = np.nan
                row[f"{label}_efficiency"] = np.nan

        results.append(row)

    return pd.DataFrame(results)


# ═══════════════════════════════════════════════════════════════════════
# 7. Reporting
# ═══════════════════════════════════════════════════════════════════════

def print_pipeline(rdf: pd.DataFrame, label: str, prefix: str):
    """Print exit pipeline summary."""
    total = len(rdf)
    col_reason = f"{prefix}_reason"
    col_pnl = f"{prefix}_pnl"
    col_bars = f"{prefix}_bars"
    col_eff = f"{prefix}_efficiency"

    exited = rdf[rdf[col_reason] != "DataEnd"]
    n_exited = len(exited)

    print(f"\n{'=' * 60}")
    print(f"  {label}")
    print(f"{'=' * 60}")
    print(f"  Total Positions:        {total}")
    print(f"  Exited:                 {n_exited} ({n_exited/total*100:.1f}%)")

    if n_exited == 0:
        return

    # Reason breakdown
    reasons = exited[col_reason].value_counts()
    print(f"\n  Exit Reasons:")
    for reason, count in reasons.items():
        subset = exited[exited[col_reason] == reason]
        med_pnl = subset[col_pnl].median()
        mean_pnl = subset[col_pnl].mean()
        winrate = (subset[col_pnl] > 0).mean() * 100
        med_bars = subset[col_bars].median()
        print(f"    {reason:20s}  n={count:4d} ({count/n_exited*100:5.1f}%)  "
              f"P&L med={med_pnl:+8.1f}  mean={mean_pnl:+8.1f}  "
              f"WR={winrate:5.1f}%  bars_med={med_bars:.0f}")

    # Overall stats
    med_pnl = exited[col_pnl].median()
    mean_pnl = exited[col_pnl].mean()
    sum_pnl = exited[col_pnl].sum()
    med_bars = exited[col_bars].median()
    winrate = (exited[col_pnl] > 0).mean() * 100
    valid_eff = exited[col_eff].dropna()
    med_eff = valid_eff.median() if len(valid_eff) > 0 else 0

    print(f"\n  Overall:")
    print(f"    P&L median:           {med_pnl:+.1f} pips")
    print(f"    P&L mean:             {mean_pnl:+.1f} pips")
    print(f"    P&L total:            {sum_pnl:+.1f} pips")
    print(f"    Bars held (median):   {med_bars:.0f}")
    print(f"    Win rate:             {winrate:.1f}%")
    print(f"    Exit efficiency:      {med_eff:.1f}% (n={len(valid_eff)})")


def print_comparison(rdf: pd.DataFrame):
    """Print side-by-side comparison."""
    print(f"\n{'=' * 70}")
    print(f"  COMPARISON SUMMARY")
    print(f"{'=' * 70}")

    exited = {}
    for label, prefix in [("Conventional", "conv"), ("FlatRange", "fr"), ("Hybrid", "hyb")]:
        e = rdf[rdf[f"{prefix}_reason"] != "DataEnd"]
        exited[label] = e

    header = f"  {'Metric':25s}"
    for label in ["Conventional", "FlatRange", "Hybrid"]:
        header += f"  {label:>14s}"
    print(header)
    print("  " + "-" * 68)

    for metric_name, func in [
        ("Exited", lambda e, p: f"{len(e)}"),
        ("P&L median", lambda e, p: f"{e[f'{p}_pnl'].median():+.1f}"),
        ("P&L mean", lambda e, p: f"{e[f'{p}_pnl'].mean():+.1f}"),
        ("P&L total", lambda e, p: f"{e[f'{p}_pnl'].sum():+.1f}"),
        ("Win rate", lambda e, p: f"{(e[f'{p}_pnl'] > 0).mean()*100:.1f}%"),
        ("Bars (median)", lambda e, p: f"{e[f'{p}_bars'].median():.0f}"),
        ("Efficiency (med)", lambda e, p: f"{e[f'{p}_efficiency'].dropna().median():.1f}%" if len(e[f'{p}_efficiency'].dropna()) > 0 else "N/A"),
    ]:
        row = f"  {metric_name:25s}"
        for label, prefix in [("Conventional", "conv"), ("FlatRange", "fr"), ("Hybrid", "hyb")]:
            e = exited[label]
            if len(e) > 0:
                row += f"  {func(e, prefix):>14s}"
            else:
                row += f"  {'N/A':>14s}"
        print(row)


def print_hybrid_breakdown(rdf: pd.DataFrame):
    """Show how Hybrid splits between FlatRange and Conventional paths."""
    print(f"\n{'=' * 70}")
    print(f"  HYBRID MODE BREAKDOWN (21MA direction at entry)")
    print(f"{'=' * 70}")

    for match_val, desc in [("MATCH", "21MA aligned → FlatRange path"),
                             ("MISMATCH", "21MA misaligned → Conventional path"),
                             ("N/A", "21MA undetermined")]:
        subset = rdf[rdf["ma_match"] == match_val]
        n = len(subset)
        pct = n / len(rdf) * 100 if len(rdf) > 0 else 0
        print(f"\n  {desc}: {n} positions ({pct:.1f}%)")

        if n == 0:
            continue

        exited = subset[subset["hyb_reason"] != "DataEnd"]
        if len(exited) == 0:
            print(f"    (no exits)")
            continue

        med_pnl = exited["hyb_pnl"].median()
        mean_pnl = exited["hyb_pnl"].mean()
        wr = (exited["hyb_pnl"] > 0).mean() * 100
        med_bars = exited["hyb_bars"].median()

        # Also show what conventional would have done for this subset
        conv_exited = subset[subset["conv_reason"] != "DataEnd"]
        if len(conv_exited) > 0:
            conv_med = conv_exited["conv_pnl"].median()
            conv_wr = (conv_exited["conv_pnl"] > 0).mean() * 100
        else:
            conv_med = 0
            conv_wr = 0

        print(f"    Hybrid:       P&L med={med_pnl:+.1f}  WR={wr:.1f}%  bars_med={med_bars:.0f}")
        print(f"    (vs Conv:     P&L med={conv_med:+.1f}  WR={conv_wr:.1f}%)")

        # Reason breakdown for this subset
        reasons = exited["hyb_reason"].value_counts()
        for reason, count in reasons.items():
            s = exited[exited["hyb_reason"] == reason]
            print(f"      {reason:20s}  n={count}")


def print_head_to_head(rdf: pd.DataFrame):
    """Per-position comparison: Hybrid vs Conventional."""
    both = rdf[(rdf["hyb_reason"] != "DataEnd") & (rdf["conv_reason"] != "DataEnd")].copy()
    if len(both) == 0:
        print("\n  No positions with both Hybrid and Conventional exits to compare.")
        return

    both["pnl_diff"] = both["hyb_pnl"] - both["conv_pnl"]
    both["bars_diff"] = both["hyb_bars"] - both["conv_bars"]

    print(f"\n{'=' * 70}")
    print(f"  HEAD-TO-HEAD: Hybrid vs Conventional ({len(both)} positions)")
    print(f"{'=' * 70}")

    hyb_better = (both["pnl_diff"] > 0).sum()
    conv_better = (both["pnl_diff"] < 0).sum()
    tied = (both["pnl_diff"] == 0).sum()

    print(f"  Hybrid better:    {hyb_better} ({hyb_better/len(both)*100:.1f}%)")
    print(f"  Conventional better: {conv_better} ({conv_better/len(both)*100:.1f}%)")
    print(f"  Tied:             {tied}")
    print(f"  P&L diff median:  {both['pnl_diff'].median():+.1f} pips")
    print(f"  P&L diff mean:    {both['pnl_diff'].mean():+.1f} pips")
    print(f"  P&L diff total:   {both['pnl_diff'].sum():+.1f} pips")
    print(f"  Bars diff median: {both['bars_diff'].median():+.0f}")

    # Breakdown by MA match
    for match_val in ["MATCH", "MISMATCH"]:
        sub = both[both["ma_match"] == match_val]
        if len(sub) == 0:
            continue
        hb = (sub["pnl_diff"] > 0).sum()
        cb = (sub["pnl_diff"] < 0).sum()
        print(f"\n  [{match_val}] n={len(sub)}  Hybrid better={hb}  Conv better={cb}  "
              f"diff_med={sub['pnl_diff'].median():+.1f}")


# ═══════════════════════════════════════════════════════════════════════
# 8. Entry Point
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Hybrid Exit Strategy Simulator")
    parser.add_argument("csv_path", help="Path to M1 CSV data")
    parser.add_argument("--market", choices=["GOLD", "FX", "CRYPTO"],
                        help="Market type (auto-detected if not specified)")
    parser.add_argument("--spread-override", type=float, default=None,
                        help="Override default spread (in price units)")
    parser.add_argument("--position-csv", default=None,
                        help="Path to position log CSV (optional)")
    parser.add_argument("--output-csv", default=None,
                        help="Save per-position results to CSV")
    parser.add_argument("--hybrid-time-exit-bars", type=int, default=30,
                        help="TimeExit bars for Hybrid FlatRange path (default: 30)")
    args = parser.parse_args()

    # Load data
    print(f"Loading M1 data from: {args.csv_path}")
    df = load_m1(args.csv_path)
    print(f"  Loaded {len(df)} bars: {df.index[0]} → {df.index[-1]}")

    # Detect market
    market = Market[args.market] if args.market else detect_market(args.csv_path)
    profile = PROFILES[market]
    if args.spread_override is not None:
        profile.spread_default = args.spread_override
    profile.hybrid_time_exit_bars = args.hybrid_time_exit_bars
    print(f"  Market: {market.value}  point={profile.point}  "
          f"hybrid_time_exit={profile.hybrid_time_exit_bars}")

    # Positions
    if args.position_csv:
        positions = load_positions(args.position_csv, df)
        print(f"  Loaded {len(positions)} positions from {args.position_csv}")
    else:
        print(f"  Generating synthetic positions...")
        positions = generate_positions(df, profile)

    if len(positions) == 0:
        print("ERROR: No positions generated. Need more data or adjust parameters.")
        sys.exit(1)

    # Run simulation
    print(f"\nRunning simulation ({len(positions)} positions × 3 strategies)...")
    rdf = run_simulation(df, profile, positions)

    # Reports
    print_pipeline(rdf, "A) Conventional (EMA13/21 Cross)", "conv")
    print_pipeline(rdf, "B) FlatRange (CloseByFlatRangeEA)", "fr")
    print_pipeline(rdf, "C) Hybrid (21MA-conditional)", "hyb")
    print_comparison(rdf)
    print_hybrid_breakdown(rdf)
    print_head_to_head(rdf)

    # Save CSV
    if args.output_csv:
        rdf.to_csv(args.output_csv, index=False)
        print(f"\nResults saved to: {args.output_csv}")
    else:
        default_out = f"sim_hybrid_exit_{market.value.lower()}_results.csv"
        rdf.to_csv(default_out, index=False)
        print(f"\nResults saved to: {default_out}")


if __name__ == "__main__":
    main()
