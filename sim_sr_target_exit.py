"""
sim_sr_target_exit.py  –  S/R Target Exit Strategy Simulator
=============================================================
Compares the current EMA-cross exit with an S/R-target-based exit.

Concept:
  - Detect H1 Swing High/Low → S/R levels (same algo as RoleReversalEA)
  - At entry time, find the nearest S/R level in the trade direction
  - Skip S/R levels that are within ATR × skip_mult of the current price
    (too close = already "at" the level → pick the next one beyond)
  - Use that S/R level as a hard TP target
  - If no valid S/R target exists → fall back to EMA-cross exit

Strategies compared:
  A) Conventional:  EMA13/21 cross (current 3-EA exit)
  B) SR-Target:     Nearest valid H1 S/R level as TP
  C) SR-Hybrid:     SR target TP, but if no valid level → fall back to EMA-cross

For all strategies, P1 (StructBreak) and P2 (TimeExit) remain active.

Usage:
  python sim_sr_target_exit.py <M1_CSV_PATH> [--market GOLD|FX|CRYPTO]
                               [--sr-skip-atr 1.0]
                               [--sr-swing-lookback 7]

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
    market: Market
    point: float
    spread_default: float
    time_exit_bars: int
    sl_atr_mult: float
    exit_ema_fast: int = 13
    exit_ema_slow: int = 21
    exit_confirm_bars: int = 1

PROFILES = {
    Market.GOLD: MarketProfile(
        market=Market.GOLD, point=0.01, spread_default=0.20,
        time_exit_bars=8, sl_atr_mult=0.8,
    ),
    Market.FX: MarketProfile(
        market=Market.FX, point=0.001, spread_default=0.0003,
        time_exit_bars=10, sl_atr_mult=0.7,
    ),
    Market.CRYPTO: MarketProfile(
        market=Market.CRYPTO, point=1.0, spread_default=50.0,
        time_exit_bars=6, sl_atr_mult=0.7,
    ),
}


# ═══════════════════════════════════════════════════════════════════════
# 1. Data Loading & Indicators
# ═══════════════════════════════════════════════════════════════════════

def load_m1(path: str) -> pd.DataFrame:
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


def resample_ohlc(m1: pd.DataFrame, rule: str) -> pd.DataFrame:
    agg = {"open": "first", "high": "max", "low": "min",
           "close": "last", "spread": "mean"}
    return m1.resample(rule).agg(agg).dropna(subset=["open"])


def detect_market(path: str) -> Market:
    name = os.path.basename(path).upper()
    if "XAU" in name or "GOLD" in name:
        return Market.GOLD
    elif "BTC" in name or "ETH" in name or "CRYPTO" in name:
        return Market.CRYPTO
    return Market.FX


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def sma(series: pd.Series, period: int) -> pd.Series:
    return series.rolling(period).mean()


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high, low = df["high"], df["low"]
    prev_close = df["close"].shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(span=period, adjust=False).mean()


# ═══════════════════════════════════════════════════════════════════════
# 2. H1 S/R Detection (ported from RoleReversalEA/SRDetector.mqh)
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class SRLevel:
    price: float
    level_type: str          # "resistance" or "support"
    detected_at_h1: int      # H1 bar index
    touch_count: int = 1


def detect_sr_levels(h1: pd.DataFrame, swing_lookback: int = 7,
                     merge_atr_mult: float = 0.5,
                     max_age_bars: int = 200,
                     min_touches: int = 2) -> List[SRLevel]:
    """
    Detect H1 swing highs/lows → S/R levels.
    Merge nearby, count touches, filter by min_touches.
    """
    highs = h1["high"].values
    lows = h1["low"].values
    h1_atr = atr(h1, 14).values

    raw_levels = []
    limit = min(len(h1) - swing_lookback, max_age_bars + swing_lookback)

    for i in range(swing_lookback, limit):
        # Swing High → Resistance
        is_sh = True
        for j in range(1, swing_lookback + 1):
            if highs[i] <= highs[i - j] or highs[i] <= highs[i + j]:
                is_sh = False
                break
        if is_sh:
            raw_levels.append(SRLevel(
                price=highs[i], level_type="resistance", detected_at_h1=i))

        # Swing Low → Support
        is_sl = True
        for j in range(1, swing_lookback + 1):
            if lows[i] >= lows[i - j] or lows[i] >= lows[i + j]:
                is_sl = False
                break
        if is_sl:
            raw_levels.append(SRLevel(
                price=lows[i], level_type="support", detected_at_h1=i))

    # Sort by price
    raw_levels.sort(key=lambda x: x.price)

    # Merge nearby levels
    if not raw_levels:
        return []

    avg_atr = np.nanmean(h1_atr[~np.isnan(h1_atr)]) if len(h1_atr) > 0 else 1.0
    merge_dist = avg_atr * merge_atr_mult

    merged = [raw_levels[0]]
    for lvl in raw_levels[1:]:
        if abs(lvl.price - merged[-1].price) < merge_dist:
            merged[-1].price = (merged[-1].price + lvl.price) / 2
            merged[-1].touch_count += 1
        else:
            merged.append(lvl)

    # Count touches on H1 bars
    for lvl in merged:
        touches = 0
        for i in range(len(h1)):
            zone = h1_atr[i] * 0.3 if i < len(h1_atr) and not np.isnan(h1_atr[i]) else avg_atr * 0.3
            if lows[i] <= lvl.price + zone and highs[i] >= lvl.price - zone:
                touches += 1
        lvl.touch_count = max(1, touches)

    # Filter by min_touches
    filtered = [lvl for lvl in merged if lvl.touch_count >= min_touches]

    return filtered


def find_sr_target(levels: List[SRLevel], current_price: float,
                   direction: str, atr_value: float,
                   skip_atr_mult: float) -> Optional[float]:
    """
    Find the nearest S/R level in trade direction.
    Skip levels within ATR × skip_atr_mult of current_price.

    LONG  → find nearest resistance/support ABOVE price (beyond skip zone)
    SHORT → find nearest support/resistance BELOW price (beyond skip zone)
    """
    skip_dist = atr_value * skip_atr_mult
    best_price = None
    best_dist = float("inf")

    for lvl in levels:
        if direction == "BUY":
            # Need level ABOVE current price + skip zone
            if lvl.price <= current_price + skip_dist:
                continue
            dist = lvl.price - current_price
        else:
            # Need level BELOW current price - skip zone
            if lvl.price >= current_price - skip_dist:
                continue
            dist = current_price - lvl.price

        if dist < best_dist:
            best_dist = dist
            best_price = lvl.price

    return best_price


# ═══════════════════════════════════════════════════════════════════════
# 3. Synthetic Position Generation
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class Position:
    entry_idx: int
    entry_datetime: pd.Timestamp
    direction: str       # "BUY" or "SELL"
    entry_price: float
    impulse_start: float = 0.0


def generate_positions(df: pd.DataFrame, profile: MarketProfile,
                       min_positions: int = 80) -> List[Position]:
    close = df["close"].values
    high = df["high"].values
    low = df["low"].values
    ma21 = sma(df["close"], 21).values
    atr14 = atr(df, 14).values

    positions = []
    cooldown = 0
    min_gap = 60

    for i in range(25, len(df) - 120):
        if cooldown > 0:
            cooldown -= 1
            continue

        if np.isnan(ma21[i]) or np.isnan(ma21[i - 5]) or np.isnan(atr14[i]):
            continue

        slope = ma21[i] - ma21[i - 5]
        slope_pts = abs(slope) / profile.point
        atr_pts = atr14[i] / profile.point

        if slope_pts < atr_pts * 0.3:
            continue

        if slope > 0:
            direction = "BUY"
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
    sr_target: float = 0.0   # S/R target used (0 = none)
    sr_dist_atr: float = 0.0 # Distance to S/R in ATR units


# ---------------------------------------------------------------
# 4A. Conventional Exit: EMA13/21 Cross + StructBreak + TimeExit
# ---------------------------------------------------------------

def sim_conventional_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
    atr_arr: np.ndarray,
) -> Optional[ExitResult]:
    close = df["close"].values
    is_long = pos.direction == "BUY"
    start = pos.entry_idx + 1
    max_bar = min(len(df) - 1, pos.entry_idx + 500)
    pt = profile.point

    exit_pending = False
    exit_pending_bars = 0
    position_bars = 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        # P1: StructBreak
        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars)

        # P2: TimeExit
        if position_bars >= profile.time_exit_bars:
            pnl = ((c - pos.entry_price) if is_long
                   else (pos.entry_price - c)) / pt
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars)

        # P3: EMA Cross
        if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
            continue

        ef1, es1 = ema_fast_arr[i], ema_slow_arr[i]
        ef2, es2 = ema_fast_arr[i - 1], ema_slow_arr[i - 1]

        if exit_pending:
            exit_pending_bars += 1
            cross_maintained = (is_long and ef1 < es1) or (not is_long and ef1 > es1)
            if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                pnl = ((c - pos.entry_price) if is_long
                       else (pos.entry_price - c)) / pt
                return ExitResult(i, c, "EMACross", pnl, position_bars)
            elif not cross_maintained:
                exit_pending = False
                exit_pending_bars = 0
        else:
            cross_detected = ((is_long and ef2 >= es2 and ef1 < es1) or
                              (not is_long and ef2 <= es2 and ef1 > es1))
            if cross_detected:
                exit_pending = True
                exit_pending_bars = 0

    return None


# ---------------------------------------------------------------
# 4B. S/R Target Exit: Hard TP at nearest valid S/R level
# ---------------------------------------------------------------

def sim_sr_target_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
    atr_arr: np.ndarray,
    sr_target: Optional[float],
) -> Optional[ExitResult]:
    """
    Exit when price reaches the S/R target level.
    If no S/R target → fall back to EMA-cross.
    P1 (StructBreak) and P2 (TimeExit) always active.
    """
    close = df["close"].values
    high_arr = df["high"].values
    low_arr = df["low"].values
    is_long = pos.direction == "BUY"
    start = pos.entry_idx + 1
    max_bar = min(len(df) - 1, pos.entry_idx + 500)
    pt = profile.point

    exit_pending = False
    exit_pending_bars = 0
    position_bars = 0

    has_target = sr_target is not None and sr_target > 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        # P1: StructBreak
        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars,
                                  sr_target or 0, 0)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars,
                                  sr_target or 0, 0)

        # P2: TimeExit
        if position_bars >= profile.time_exit_bars:
            pnl = ((c - pos.entry_price) if is_long
                   else (pos.entry_price - c)) / pt
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars,
                                  sr_target or 0, 0)

        # P3a: S/R Target TP hit
        if has_target:
            hit = False
            if is_long and high_arr[i] >= sr_target:
                hit = True
                exit_price = sr_target  # TP fill at target
            elif not is_long and low_arr[i] <= sr_target:
                hit = True
                exit_price = sr_target

            if hit:
                pnl = ((exit_price - pos.entry_price) if is_long
                       else (pos.entry_price - exit_price)) / pt
                return ExitResult(i, exit_price, "SR_TP", pnl, position_bars,
                                  sr_target, 0)

        # P3b: Fallback EMA Cross (always available, even with SR target)
        if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
            continue

        ef1, es1 = ema_fast_arr[i], ema_slow_arr[i]
        ef2, es2 = ema_fast_arr[i - 1], ema_slow_arr[i - 1]

        if exit_pending:
            exit_pending_bars += 1
            cross_maintained = (is_long and ef1 < es1) or (not is_long and ef1 > es1)
            if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                pnl = ((c - pos.entry_price) if is_long
                       else (pos.entry_price - c)) / pt
                reason = "EMACross(FB)" if has_target else "EMACross(NoSR)"
                return ExitResult(i, c, reason, pnl, position_bars,
                                  sr_target or 0, 0)
            elif not cross_maintained:
                exit_pending = False
                exit_pending_bars = 0
        else:
            cross_detected = ((is_long and ef2 >= es2 and ef1 < es1) or
                              (not is_long and ef2 <= es2 and ef1 > es1))
            if cross_detected:
                exit_pending = True
                exit_pending_bars = 0

    return None


# ---------------------------------------------------------------
# 4C. SR-Only Exit: No EMA fallback (pure SR target or P1/P2 only)
# ---------------------------------------------------------------

def sim_sr_only_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    atr_arr: np.ndarray,
    sr_target: Optional[float],
) -> Optional[ExitResult]:
    """
    Exit ONLY on S/R target hit.  No EMA fallback.
    If no S/R target → forced TimeExit after extended window.
    """
    close = df["close"].values
    high_arr = df["high"].values
    low_arr = df["low"].values
    is_long = pos.direction == "BUY"
    start = pos.entry_idx + 1
    max_bar = min(len(df) - 1, pos.entry_idx + 500)
    pt = profile.point

    has_target = sr_target is not None and sr_target > 0
    position_bars = 0

    for i in range(start, max_bar + 1):
        c = close[i]
        position_bars += 1

        # P1: StructBreak
        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars,
                                  sr_target or 0, 0)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars,
                                  sr_target or 0, 0)

        # P2: TimeExit (extended to 30 bars for SR mode)
        if position_bars >= 30:
            pnl = ((c - pos.entry_price) if is_long
                   else (pos.entry_price - c)) / pt
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars,
                                  sr_target or 0, 0)

        # S/R Target TP
        if has_target:
            hit = False
            if is_long and high_arr[i] >= sr_target:
                hit = True
                exit_price = sr_target
            elif not is_long and low_arr[i] <= sr_target:
                hit = True
                exit_price = sr_target

            if hit:
                pnl = ((exit_price - pos.entry_price) if is_long
                       else (pos.entry_price - exit_price)) / pt
                return ExitResult(i, exit_price, "SR_TP", pnl, position_bars,
                                  sr_target, 0)

    return None


# ═══════════════════════════════════════════════════════════════════════
# 5. Oracle
# ═══════════════════════════════════════════════════════════════════════

def calc_oracle(pos: Position, df: pd.DataFrame, profile: MarketProfile,
                window: int = 120) -> Tuple[float, int]:
    start = pos.entry_idx + 1
    end = min(len(df), pos.entry_idx + window + 1)
    pt = profile.point

    if pos.direction == "BUY":
        highs = df["high"].values[start:end]
        if len(highs) == 0:
            return 0.0, 0
        best_offset = int(np.argmax(highs))
        return (highs[best_offset] - pos.entry_price) / pt, best_offset + 1
    else:
        lows = df["low"].values[start:end]
        if len(lows) == 0:
            return 0.0, 0
        best_offset = int(np.argmin(lows))
        return (pos.entry_price - lows[best_offset]) / pt, best_offset + 1


# ═══════════════════════════════════════════════════════════════════════
# 6. Main Simulation
# ═══════════════════════════════════════════════════════════════════════

def run_simulation(df_m1: pd.DataFrame, profile: MarketProfile,
                   positions: List[Position],
                   sr_levels: List[SRLevel],
                   h1: pd.DataFrame,
                   skip_atr_mult: float = 1.0,
                   ) -> pd.DataFrame:
    """Run all exit strategies on each position, comparing with S/R target."""

    # Precompute M1 indicators
    ema_fast = ema(df_m1["close"], profile.exit_ema_fast).values
    ema_slow = ema(df_m1["close"], profile.exit_ema_slow).values
    atr_m1 = atr(df_m1, 14).values
    atr_h1 = atr(h1, 14).values

    results = []

    for pos in positions:
        # Oracle
        oracle_pnl, oracle_bar = calc_oracle(pos, df_m1, profile)

        # Find H1 ATR at entry time
        h1_idx = h1.index.searchsorted(pos.entry_datetime, side="right") - 1
        h1_idx = max(0, min(h1_idx, len(h1) - 1))
        h1_atr_val = atr_h1[h1_idx] if not np.isnan(atr_h1[h1_idx]) else np.nanmean(atr_h1)

        # Find S/R target for this position
        sr_target = find_sr_target(
            sr_levels, pos.entry_price, pos.direction,
            h1_atr_val, skip_atr_mult
        )

        sr_dist_atr = 0.0
        if sr_target is not None:
            sr_dist_atr = abs(sr_target - pos.entry_price) / h1_atr_val if h1_atr_val > 0 else 0

        # A: Conventional (EMA Cross)
        res_conv = sim_conventional_exit(
            pos, df_m1, profile, ema_fast, ema_slow, atr_m1)

        # B: SR-Target + EMA Fallback
        res_sr = sim_sr_target_exit(
            pos, df_m1, profile, ema_fast, ema_slow, atr_m1, sr_target)

        # C: SR-Only (no EMA fallback)
        res_sro = sim_sr_only_exit(
            pos, df_m1, profile, atr_m1, sr_target)

        row = {
            "entry_idx": pos.entry_idx,
            "entry_dt": pos.entry_datetime,
            "dir": pos.direction,
            "entry_price": pos.entry_price,
            "impulse_start": pos.impulse_start,
            "h1_atr": round(h1_atr_val, 5),
            "sr_target": sr_target if sr_target else 0,
            "sr_found": sr_target is not None,
            "sr_dist_atr": round(sr_dist_atr, 2),
            "oracle_pnl": oracle_pnl,
            "oracle_bar": oracle_bar,
        }

        for label, res in [("conv", res_conv), ("sr", res_sr), ("sro", res_sro)]:
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

def print_sr_info(sr_levels: List[SRLevel], rdf: pd.DataFrame):
    """Print S/R detection summary."""
    print(f"\n{'=' * 60}")
    print(f"  S/R LEVEL DETECTION")
    print(f"{'=' * 60}")
    print(f"  Total S/R levels:   {len(sr_levels)}")
    if sr_levels:
        prices = [lvl.price for lvl in sr_levels]
        print(f"  Price range:        {min(prices):.2f} – {max(prices):.2f}")
        touches = [lvl.touch_count for lvl in sr_levels]
        print(f"  Touch counts:       min={min(touches)}  max={max(touches)}  "
              f"med={np.median(touches):.0f}")
        res_count = sum(1 for lvl in sr_levels if lvl.level_type == "resistance")
        sup_count = len(sr_levels) - res_count
        print(f"  Resistance:         {res_count}")
        print(f"  Support:            {sup_count}")

    sr_found = rdf["sr_found"].sum()
    sr_pct = sr_found / len(rdf) * 100 if len(rdf) > 0 else 0
    print(f"\n  Positions with S/R target: {sr_found}/{len(rdf)} ({sr_pct:.1f}%)")
    valid_dist = rdf[rdf["sr_found"]]["sr_dist_atr"]
    if len(valid_dist) > 0:
        print(f"  S/R distance (ATR): min={valid_dist.min():.2f}  "
              f"max={valid_dist.max():.2f}  med={valid_dist.median():.2f}")


def print_pipeline(rdf: pd.DataFrame, label: str, prefix: str):
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
    print(f"\n{'=' * 70}")
    print(f"  COMPARISON SUMMARY")
    print(f"{'=' * 70}")

    labels_prefixes = [
        ("Conventional", "conv"),
        ("SR+EMA-FB", "sr"),
        ("SR-Only", "sro"),
    ]

    header = f"  {'Metric':25s}"
    for label, _ in labels_prefixes:
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
        ("Efficiency (med)", lambda e, p:
            f"{e[f'{p}_efficiency'].dropna().median():.1f}%"
            if len(e[f'{p}_efficiency'].dropna()) > 0 else "N/A"),
    ]:
        row = f"  {metric_name:25s}"
        for label, prefix in labels_prefixes:
            e = rdf[rdf[f"{prefix}_reason"] != "DataEnd"]
            if len(e) > 0:
                row += f"  {func(e, prefix):>14s}"
            else:
                row += f"  {'N/A':>14s}"
        print(row)


def print_head_to_head(rdf: pd.DataFrame):
    """Per-position: SR+FB vs Conventional."""
    both = rdf[(rdf["sr_reason"] != "DataEnd") & (rdf["conv_reason"] != "DataEnd")].copy()
    if len(both) == 0:
        print("\n  No positions with both exits to compare.")
        return

    both["pnl_diff"] = both["sr_pnl"] - both["conv_pnl"]
    both["bars_diff"] = both["sr_bars"] - both["conv_bars"]

    print(f"\n{'=' * 70}")
    print(f"  HEAD-TO-HEAD: SR+EMA-FB vs Conventional ({len(both)} positions)")
    print(f"{'=' * 70}")

    sr_better = (both["pnl_diff"] > 0).sum()
    conv_better = (both["pnl_diff"] < 0).sum()
    tied = (both["pnl_diff"] == 0).sum()

    print(f"  SR better:        {sr_better} ({sr_better/len(both)*100:.1f}%)")
    print(f"  Conv better:      {conv_better} ({conv_better/len(both)*100:.1f}%)")
    print(f"  Tied:             {tied}")
    print(f"  P&L diff median:  {both['pnl_diff'].median():+.1f} pips")
    print(f"  P&L diff mean:    {both['pnl_diff'].mean():+.1f} pips")
    print(f"  P&L diff total:   {both['pnl_diff'].sum():+.1f} pips")
    print(f"  Bars diff median: {both['bars_diff'].median():+.0f}")

    # Breakdown: positions WITH S/R target vs WITHOUT
    sr_has = both[both["sr_found"]]
    sr_no = both[~both["sr_found"]]

    if len(sr_has) > 0:
        d = sr_has["pnl_diff"]
        print(f"\n  [WITH S/R target] n={len(sr_has)}  "
              f"SR better={( d > 0).sum()}  Conv better={(d < 0).sum()}  "
              f"diff_med={d.median():+.1f}  diff_total={d.sum():+.1f}")

        # Breakdown by exit reason within SR group
        sr_tp_hit = sr_has[sr_has["sr_reason"] == "SR_TP"]
        sr_fb = sr_has[sr_has["sr_reason"].str.contains("EMACross", na=False)]
        if len(sr_tp_hit) > 0:
            print(f"    SR_TP hit:      n={len(sr_tp_hit)}  "
                  f"P&L med={sr_tp_hit['sr_pnl'].median():+.1f}  "
                  f"WR={(sr_tp_hit['sr_pnl'] > 0).mean()*100:.1f}%  "
                  f"bars_med={sr_tp_hit['sr_bars'].median():.0f}")
        if len(sr_fb) > 0:
            print(f"    EMA fallback:   n={len(sr_fb)}  "
                  f"P&L med={sr_fb['sr_pnl'].median():+.1f}  "
                  f"WR={(sr_fb['sr_pnl'] > 0).mean()*100:.1f}%")

    if len(sr_no) > 0:
        d = sr_no["pnl_diff"]
        print(f"\n  [NO S/R target]  n={len(sr_no)}  "
              f"diff_med={d.median():+.1f}  (should be ~0, same as Conv)")


def print_sr_distance_analysis(rdf: pd.DataFrame):
    """Analyze exit quality by S/R distance buckets."""
    sr_positions = rdf[rdf["sr_found"]].copy()
    if len(sr_positions) == 0:
        return

    print(f"\n{'=' * 70}")
    print(f"  S/R DISTANCE ANALYSIS (ATR units)")
    print(f"{'=' * 70}")

    # Bucket by S/R distance in ATR
    bins = [0, 1.5, 2.5, 4.0, float("inf")]
    labels = ["1.0-1.5", "1.5-2.5", "2.5-4.0", "4.0+"]
    sr_positions["dist_bucket"] = pd.cut(sr_positions["sr_dist_atr"],
                                          bins=bins, labels=labels, right=False)

    for bucket in labels:
        subset = sr_positions[sr_positions["dist_bucket"] == bucket]
        if len(subset) == 0:
            continue

        sr_exited = subset[subset["sr_reason"] != "DataEnd"]
        conv_exited = subset[subset["conv_reason"] != "DataEnd"]

        sr_pnl = sr_exited["sr_pnl"].median() if len(sr_exited) > 0 else 0
        conv_pnl = conv_exited["conv_pnl"].median() if len(conv_exited) > 0 else 0
        sr_wr = (sr_exited["sr_pnl"] > 0).mean() * 100 if len(sr_exited) > 0 else 0
        conv_wr = (conv_exited["conv_pnl"] > 0).mean() * 100 if len(conv_exited) > 0 else 0

        tp_hit = len(sr_exited[sr_exited["sr_reason"] == "SR_TP"]) if len(sr_exited) > 0 else 0

        print(f"  [{bucket:>7s} ATR]  n={len(subset):3d}  "
              f"SR med={sr_pnl:+7.1f} WR={sr_wr:5.1f}%  "
              f"Conv med={conv_pnl:+7.1f} WR={conv_wr:5.1f}%  "
              f"TP_hit={tp_hit}")


def print_skip_atr_sweep(df_m1, profile, positions, sr_levels, h1):
    """Sweep skip_atr_mult values to find optimal setting."""
    print(f"\n{'=' * 70}")
    print(f"  SKIP-ATR PARAMETER SWEEP")
    print(f"{'=' * 70}")
    print(f"  {'skip_mult':>10s}  {'SR_found':>8s}  {'SR_pnl_med':>10s}  "
          f"{'SR_pnl_tot':>10s}  {'SR_WR':>6s}  {'TP_hits':>7s}  "
          f"{'Conv_pnl_med':>12s}  {'Conv_WR':>7s}")
    print("  " + "-" * 85)

    for skip_mult in [0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0]:
        rdf = run_simulation(df_m1, profile, positions, sr_levels, h1,
                             skip_atr_mult=skip_mult)

        sr_exited = rdf[rdf["sr_reason"] != "DataEnd"]
        conv_exited = rdf[rdf["conv_reason"] != "DataEnd"]
        sr_found = rdf["sr_found"].sum()
        tp_hits = len(sr_exited[sr_exited["sr_reason"] == "SR_TP"]) if len(sr_exited) > 0 else 0

        sr_med = sr_exited["sr_pnl"].median() if len(sr_exited) > 0 else 0
        sr_tot = sr_exited["sr_pnl"].sum() if len(sr_exited) > 0 else 0
        sr_wr = (sr_exited["sr_pnl"] > 0).mean() * 100 if len(sr_exited) > 0 else 0
        conv_med = conv_exited["conv_pnl"].median() if len(conv_exited) > 0 else 0
        conv_wr = (conv_exited["conv_pnl"] > 0).mean() * 100 if len(conv_exited) > 0 else 0

        print(f"  {skip_mult:>10.2f}  {sr_found:>8d}  {sr_med:>+10.1f}  "
              f"{sr_tot:>+10.1f}  {sr_wr:>5.1f}%  {tp_hits:>7d}  "
              f"{conv_med:>+12.1f}  {conv_wr:>6.1f}%")


# ═══════════════════════════════════════════════════════════════════════
# 8. Entry Point
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="S/R Target Exit Strategy Simulator")
    parser.add_argument("csv_path", help="Path to M1 CSV data")
    parser.add_argument("--market", choices=["GOLD", "FX", "CRYPTO"],
                        help="Market type (auto-detected if not specified)")
    parser.add_argument("--sr-skip-atr", type=float, default=1.0,
                        help="Skip S/R levels within ATR × this of price "
                             "(default: 1.0)")
    parser.add_argument("--sr-swing-lookback", type=int, default=7,
                        help="H1 swing lookback bars (default: 7)")
    parser.add_argument("--sr-merge-atr", type=float, default=0.5,
                        help="Merge S/R levels within ATR × this (default: 0.5)")
    parser.add_argument("--sr-min-touches", type=int, default=2,
                        help="Minimum touches for S/R level (default: 2)")
    parser.add_argument("--sweep", action="store_true",
                        help="Run skip-ATR parameter sweep")
    parser.add_argument("--output-csv", default=None,
                        help="Save results to CSV")
    args = parser.parse_args()

    # Load M1 data
    print(f"Loading M1 data from: {args.csv_path}")
    df_m1 = load_m1(args.csv_path)
    print(f"  Loaded {len(df_m1)} bars: {df_m1.index[0]} → {df_m1.index[-1]}")

    # Detect market
    market = Market[args.market] if args.market else detect_market(args.csv_path)
    profile = PROFILES[market]
    print(f"  Market: {market.value}  point={profile.point}")

    # Resample to H1 for S/R detection
    print(f"\nResampling to H1 for S/R detection...")
    h1 = resample_ohlc(df_m1, "1h")
    print(f"  H1 bars: {len(h1)}")

    # Detect S/R levels
    print(f"  Detecting S/R levels (swing_lookback={args.sr_swing_lookback}, "
          f"merge_atr={args.sr_merge_atr}, min_touches={args.sr_min_touches})...")
    sr_levels = detect_sr_levels(
        h1, swing_lookback=args.sr_swing_lookback,
        merge_atr_mult=args.sr_merge_atr,
        min_touches=args.sr_min_touches)
    print(f"  Found {len(sr_levels)} S/R levels")

    # Generate positions
    print(f"\nGenerating synthetic positions...")
    positions = generate_positions(df_m1, profile)
    if len(positions) == 0:
        print("ERROR: No positions generated.")
        sys.exit(1)

    # Sweep mode
    if args.sweep:
        print_skip_atr_sweep(df_m1, profile, positions, sr_levels, h1)
        return

    # Run main simulation
    print(f"\nRunning simulation (skip_atr={args.sr_skip_atr})...")
    rdf = run_simulation(df_m1, profile, positions, sr_levels, h1,
                         skip_atr_mult=args.sr_skip_atr)

    # Reports
    print_sr_info(sr_levels, rdf)
    print_pipeline(rdf, "A) Conventional (EMA13/21 Cross)", "conv")
    print_pipeline(rdf, "B) SR-Target + EMA Fallback", "sr")
    print_pipeline(rdf, "C) SR-Only (no EMA fallback)", "sro")
    print_comparison(rdf)
    print_head_to_head(rdf)
    print_sr_distance_analysis(rdf)

    # Save CSV
    out = args.output_csv or f"sim_sr_target_{market.value.lower()}_results.csv"
    rdf.to_csv(out, index=False)
    print(f"\nResults saved to: {out}")


if __name__ == "__main__":
    main()
