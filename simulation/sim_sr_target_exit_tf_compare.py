"""
sim_sr_target_exit_tf_compare.py  –  H1 vs M15 S/R Target Exit Comparison
==========================================================================
Extends sim_sr_target_exit.py to compare S/R detection on H1 vs M15.
Runs the same exit strategies with S/R levels detected from both timeframes.

Usage:
  python sim_sr_target_exit_tf_compare.py sim_dat/GOLD#_M1_202509010100_202511282139.csv

Dependencies: pandas, numpy
"""

import os
import sys
import argparse
import numpy as np
import pandas as pd
from dataclasses import dataclass
from enum import Enum
from typing import Optional, List, Tuple


# ═══════════════════════════════════════════════════════════════════════
# 0. Market Profiles & Parameters (same as sim_sr_target_exit.py)
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


def detect_market(path: str) -> Market:
    name = os.path.basename(path).upper()
    if "XAU" in name or "GOLD" in name:
        return Market.GOLD
    elif "BTC" in name or "ETH" in name or "CRYPTO" in name:
        return Market.CRYPTO
    return Market.FX


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
# 2. S/R Detection (parameterized timeframe)
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class SRLevel:
    price: float
    level_type: str          # "resistance" or "support"
    detected_bar: int
    touch_count: int = 1


def detect_sr_levels(htf: pd.DataFrame, swing_lookback: int = 7,
                     merge_atr_mult: float = 0.5,
                     max_age_bars: int = 200,
                     min_touches: int = 2) -> List[SRLevel]:
    """Detect swing highs/lows → S/R levels on any timeframe."""
    highs = htf["high"].values
    lows = htf["low"].values
    htf_atr = atr(htf, 14).values

    raw_levels = []
    limit = min(len(htf) - swing_lookback, max_age_bars + swing_lookback)

    for i in range(swing_lookback, limit):
        # Swing High → Resistance
        is_sh = True
        for j in range(1, swing_lookback + 1):
            if highs[i] <= highs[i - j] or highs[i] <= highs[i + j]:
                is_sh = False
                break
        if is_sh:
            raw_levels.append(SRLevel(
                price=highs[i], level_type="resistance", detected_bar=i))

        # Swing Low → Support
        is_sl = True
        for j in range(1, swing_lookback + 1):
            if lows[i] >= lows[i - j] or lows[i] >= lows[i + j]:
                is_sl = False
                break
        if is_sl:
            raw_levels.append(SRLevel(
                price=lows[i], level_type="support", detected_bar=i))

    raw_levels.sort(key=lambda x: x.price)

    if not raw_levels:
        return []

    avg_atr = np.nanmean(htf_atr[~np.isnan(htf_atr)]) if len(htf_atr) > 0 else 1.0
    merge_dist = avg_atr * merge_atr_mult

    merged = [raw_levels[0]]
    for lvl in raw_levels[1:]:
        if abs(lvl.price - merged[-1].price) < merge_dist:
            merged[-1].price = (merged[-1].price + lvl.price) / 2
            merged[-1].touch_count += 1
        else:
            merged.append(lvl)

    # Count touches
    for lvl in merged:
        touches = 0
        for i in range(len(htf)):
            zone = htf_atr[i] * 0.3 if i < len(htf_atr) and not np.isnan(htf_atr[i]) else avg_atr * 0.3
            if lows[i] <= lvl.price + zone and highs[i] >= lvl.price - zone:
                touches += 1
        lvl.touch_count = max(1, touches)

    return [lvl for lvl in merged if lvl.touch_count >= min_touches]


def find_sr_target(levels: List[SRLevel], current_price: float,
                   direction: str, atr_value: float,
                   skip_atr_mult: float) -> Optional[float]:
    """Find nearest S/R level in trade direction, skipping levels in skip zone."""
    skip_dist = atr_value * skip_atr_mult
    best_price = None
    best_dist = float("inf")

    for lvl in levels:
        if direction == "BUY":
            if lvl.price <= current_price + skip_dist:
                continue
            dist = lvl.price - current_price
        else:
            if lvl.price >= current_price - skip_dist:
                continue
            dist = current_price - lvl.price

        if dist < best_dist:
            best_dist = dist
            best_price = lvl.price

    return best_price


# ═══════════════════════════════════════════════════════════════════════
# 3. Position Generation (same as original)
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
# 4. Exit Strategies
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class ExitResult:
    exit_idx: int
    exit_price: float
    exit_reason: str
    pnl_pips: float
    bars_held: int
    sr_target: float = 0.0
    sr_dist_atr: float = 0.0


def sim_conventional_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
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

        if pos.impulse_start > 0:
            if is_long and c < pos.impulse_start:
                pnl = (c - pos.entry_price) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars)

        if position_bars >= profile.time_exit_bars:
            pnl = ((c - pos.entry_price) if is_long else (pos.entry_price - c)) / pt
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars)

        if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
            continue

        ef1, es1 = ema_fast_arr[i], ema_slow_arr[i]
        ef2, es2 = ema_fast_arr[i - 1], ema_slow_arr[i - 1]

        if exit_pending:
            exit_pending_bars += 1
            cross_maintained = (is_long and ef1 < es1) or (not is_long and ef1 > es1)
            if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                pnl = ((c - pos.entry_price) if is_long else (pos.entry_price - c)) / pt
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


def sim_sr_target_exit(
    pos: Position, df: pd.DataFrame, profile: MarketProfile,
    ema_fast_arr: np.ndarray, ema_slow_arr: np.ndarray,
    sr_target: Optional[float],
) -> Optional[ExitResult]:
    """S/R target TP + EMA-cross fallback."""
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
                return ExitResult(i, c, "StructBreak", pnl, position_bars, sr_target or 0, 0)
            elif not is_long and c > pos.impulse_start:
                pnl = (pos.entry_price - c) / pt
                return ExitResult(i, c, "StructBreak", pnl, position_bars, sr_target or 0, 0)

        # P2: TimeExit
        if position_bars >= profile.time_exit_bars:
            pnl = ((c - pos.entry_price) if is_long else (pos.entry_price - c)) / pt
            if pnl <= 0:
                return ExitResult(i, c, "TimeExit", pnl, position_bars, sr_target or 0, 0)

        # P3a: S/R Target TP
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
                return ExitResult(i, exit_price, "SR_TP", pnl, position_bars, sr_target, 0)

        # P3b: Fallback EMA Cross
        if i < 2 or np.isnan(ema_fast_arr[i]) or np.isnan(ema_slow_arr[i]):
            continue

        ef1, es1 = ema_fast_arr[i], ema_slow_arr[i]
        ef2, es2 = ema_fast_arr[i - 1], ema_slow_arr[i - 1]

        if exit_pending:
            exit_pending_bars += 1
            cross_maintained = (is_long and ef1 < es1) or (not is_long and ef1 > es1)
            if cross_maintained and exit_pending_bars >= profile.exit_confirm_bars:
                pnl = ((c - pos.entry_price) if is_long else (pos.entry_price - c)) / pt
                reason = "EMACross(FB)" if has_target else "EMACross(NoSR)"
                return ExitResult(i, c, reason, pnl, position_bars, sr_target or 0, 0)
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
# 6. Simulation Runner (per timeframe)
# ═══════════════════════════════════════════════════════════════════════

def run_simulation_for_tf(
    df_m1: pd.DataFrame, profile: MarketProfile,
    positions: List[Position],
    sr_levels: List[SRLevel],
    htf_df: pd.DataFrame,
    skip_atr_mult: float,
    tf_label: str,
) -> pd.DataFrame:
    """Run exit strategies for one timeframe's S/R levels."""

    ema_fast = ema(df_m1["close"], profile.exit_ema_fast).values
    ema_slow = ema(df_m1["close"], profile.exit_ema_slow).values
    htf_atr_arr = atr(htf_df, 14).values

    results = []
    pf = f"{tf_label}"  # prefix for column names

    for pos in positions:
        oracle_pnl, oracle_bar = calc_oracle(pos, df_m1, profile)

        # Find HTF ATR at entry time
        htf_idx = htf_df.index.searchsorted(pos.entry_datetime, side="right") - 1
        htf_idx = max(0, min(htf_idx, len(htf_df) - 1))
        htf_atr_val = htf_atr_arr[htf_idx] if not np.isnan(htf_atr_arr[htf_idx]) else np.nanmean(htf_atr_arr)

        # Find S/R target
        sr_target = find_sr_target(sr_levels, pos.entry_price, pos.direction,
                                   htf_atr_val, skip_atr_mult)

        sr_dist_atr = 0.0
        if sr_target is not None:
            sr_dist_atr = abs(sr_target - pos.entry_price) / htf_atr_val if htf_atr_val > 0 else 0

        # Conventional (only compute once, but we include it for both)
        res_conv = sim_conventional_exit(pos, df_m1, profile, ema_fast, ema_slow)

        # SR + EMA fallback
        res_sr = sim_sr_target_exit(pos, df_m1, profile, ema_fast, ema_slow, sr_target)

        row = {
            "entry_idx": pos.entry_idx,
            "entry_dt": pos.entry_datetime,
            "dir": pos.direction,
            "entry_price": pos.entry_price,
            "oracle_pnl": oracle_pnl,
            f"{pf}_sr_target": sr_target if sr_target else 0,
            f"{pf}_sr_found": sr_target is not None,
            f"{pf}_sr_dist_atr": round(sr_dist_atr, 2),
            f"{pf}_htf_atr": round(htf_atr_val, 5),
        }

        # Conventional
        if res_conv:
            row["conv_reason"] = res_conv.exit_reason
            row["conv_pnl"] = res_conv.pnl_pips
            row["conv_bars"] = res_conv.bars_held
        else:
            row["conv_reason"] = "DataEnd"
            row["conv_pnl"] = np.nan
            row["conv_bars"] = np.nan

        # SR exit
        if res_sr:
            row[f"{pf}_reason"] = res_sr.exit_reason
            row[f"{pf}_pnl"] = res_sr.pnl_pips
            row[f"{pf}_bars"] = res_sr.bars_held
        else:
            row[f"{pf}_reason"] = "DataEnd"
            row[f"{pf}_pnl"] = np.nan
            row[f"{pf}_bars"] = np.nan

        results.append(row)

    return pd.DataFrame(results)


# ═══════════════════════════════════════════════════════════════════════
# 7. Comparison Reporting
# ═══════════════════════════════════════════════════════════════════════

def print_sr_summary(sr_levels: List[SRLevel], tf_label: str):
    print(f"\n  [{tf_label}] S/R levels: {len(sr_levels)}")
    if sr_levels:
        prices = [l.price for l in sr_levels]
        touches = [l.touch_count for l in sr_levels]
        print(f"    Price range:  {min(prices):.2f} – {max(prices):.2f}")
        print(f"    Touches:      min={min(touches)} max={max(touches)} "
              f"med={np.median(touches):.0f}")
        res_n = sum(1 for l in sr_levels if l.level_type == "resistance")
        print(f"    Resistance:   {res_n}   Support: {len(sr_levels) - res_n}")


def print_tf_results(rdf: pd.DataFrame, tf_label: str):
    """Print results for one timeframe."""
    pf = tf_label
    exited = rdf[rdf[f"{pf}_reason"] != "DataEnd"]
    n = len(exited)
    total = len(rdf)

    print(f"\n{'─' * 60}")
    print(f"  {tf_label} S/R + EMA Fallback  (n={n}/{total})")
    print(f"{'─' * 60}")

    if n == 0:
        print("  No exits.")
        return

    sr_found = rdf[f"{pf}_sr_found"].sum()
    print(f"  S/R found:        {sr_found}/{total} ({sr_found/total*100:.1f}%)")

    # Exit reasons
    reasons = exited[f"{pf}_reason"].value_counts()
    for reason, count in reasons.items():
        sub = exited[exited[f"{pf}_reason"] == reason]
        med_pnl = sub[f"{pf}_pnl"].median()
        wr = (sub[f"{pf}_pnl"] > 0).mean() * 100
        med_bars = sub[f"{pf}_bars"].median()
        print(f"    {reason:20s}  n={count:4d}  "
              f"P&L med={med_pnl:+8.1f}  WR={wr:5.1f}%  bars={med_bars:.0f}")

    med_pnl = exited[f"{pf}_pnl"].median()
    mean_pnl = exited[f"{pf}_pnl"].mean()
    sum_pnl = exited[f"{pf}_pnl"].sum()
    wr = (exited[f"{pf}_pnl"] > 0).mean() * 100

    print(f"\n  Overall:  P&L med={med_pnl:+.1f}  mean={mean_pnl:+.1f}  "
          f"total={sum_pnl:+.1f}  WR={wr:.1f}%")


def print_conv_results(rdf: pd.DataFrame):
    """Print conventional results."""
    exited = rdf[rdf["conv_reason"] != "DataEnd"]
    n = len(exited)

    print(f"\n{'─' * 60}")
    print(f"  Conventional (EMA13/21 Cross)  (n={n}/{len(rdf)})")
    print(f"{'─' * 60}")

    if n == 0:
        return

    reasons = exited["conv_reason"].value_counts()
    for reason, count in reasons.items():
        sub = exited[exited["conv_reason"] == reason]
        med_pnl = sub["conv_pnl"].median()
        wr = (sub["conv_pnl"] > 0).mean() * 100
        med_bars = sub["conv_bars"].median()
        print(f"    {reason:20s}  n={count:4d}  "
              f"P&L med={med_pnl:+8.1f}  WR={wr:5.1f}%  bars={med_bars:.0f}")

    med_pnl = exited["conv_pnl"].median()
    sum_pnl = exited["conv_pnl"].sum()
    wr = (exited["conv_pnl"] > 0).mean() * 100
    print(f"\n  Overall:  P&L med={med_pnl:+.1f}  total={sum_pnl:+.1f}  WR={wr:.1f}%")


def print_head_to_head(rdf: pd.DataFrame, tf_labels: List[str]):
    """Compare H1 vs M15 head-to-head."""
    print(f"\n{'=' * 70}")
    print(f"  HEAD-TO-HEAD COMPARISON: {' vs '.join(tf_labels)}")
    print(f"{'=' * 70}")

    # Header
    header = f"  {'Metric':25s}  {'Conventional':>14s}"
    for tf in tf_labels:
        header += f"  {tf:>14s}"
    print(header)
    print("  " + "─" * (25 + 16 + 16 * len(tf_labels)))

    conv_exited = rdf[rdf["conv_reason"] != "DataEnd"]

    metrics = [
        ("P&L median", lambda e, p: f"{e[f'{p}_pnl'].median():+.1f}" if len(e) > 0 else "N/A"),
        ("P&L mean", lambda e, p: f"{e[f'{p}_pnl'].mean():+.1f}" if len(e) > 0 else "N/A"),
        ("P&L total", lambda e, p: f"{e[f'{p}_pnl'].sum():+.1f}" if len(e) > 0 else "N/A"),
        ("Win rate", lambda e, p: f"{(e[f'{p}_pnl'] > 0).mean()*100:.1f}%" if len(e) > 0 else "N/A"),
        ("Bars (median)", lambda e, p: f"{e[f'{p}_bars'].median():.0f}" if len(e) > 0 else "N/A"),
        ("SR found", lambda e, p: f"{rdf[f'{p}_sr_found'].sum()}" if f"{p}_sr_found" in rdf.columns else "N/A"),
        ("SR_TP hits", lambda e, p: f"{(e[f'{p}_reason'] == 'SR_TP').sum()}" if len(e) > 0 else "0"),
    ]

    for metric_name, func in metrics:
        row = f"  {metric_name:25s}"
        # Conventional
        if len(conv_exited) > 0:
            if metric_name in ["SR found", "SR_TP hits"]:
                row += f"  {'─':>14s}"
            elif metric_name == "P&L median":
                row += f"  {conv_exited['conv_pnl'].median():+14.1f}"
            elif metric_name == "P&L mean":
                row += f"  {conv_exited['conv_pnl'].mean():+14.1f}"
            elif metric_name == "P&L total":
                row += f"  {conv_exited['conv_pnl'].sum():+14.1f}"
            elif metric_name == "Win rate":
                row += f"  {(conv_exited['conv_pnl'] > 0).mean()*100:13.1f}%"
            elif metric_name == "Bars (median)":
                row += f"  {conv_exited['conv_bars'].median():14.0f}"
        else:
            row += f"  {'N/A':>14s}"

        for tf in tf_labels:
            e = rdf[rdf[f"{tf}_reason"] != "DataEnd"]
            if len(e) > 0:
                row += f"  {func(e, tf):>14s}"
            else:
                row += f"  {'N/A':>14s}"
        print(row)

    # Per-position diff
    for tf in tf_labels:
        both = rdf[(rdf[f"{tf}_reason"] != "DataEnd") & (rdf["conv_reason"] != "DataEnd")].copy()
        if len(both) == 0:
            continue
        both["_diff"] = both[f"{tf}_pnl"] - both["conv_pnl"]
        sr_better = (both["_diff"] > 0).sum()
        conv_better = (both["_diff"] < 0).sum()
        print(f"\n  [{tf} vs Conv]  n={len(both)}  "
              f"SR better={sr_better} ({sr_better/len(both)*100:.1f}%)  "
              f"Conv better={conv_better} ({conv_better/len(both)*100:.1f}%)  "
              f"diff_total={both['_diff'].sum():+.1f}")

        # SR_TP hit detail
        tp_hits = both[both[f"{tf}_reason"] == "SR_TP"]
        if len(tp_hits) > 0:
            print(f"    SR_TP hits:   n={len(tp_hits)}  "
                  f"P&L med={tp_hits[f'{tf}_pnl'].median():+.1f}  "
                  f"WR={(tp_hits[f'{tf}_pnl'] > 0).mean()*100:.1f}%  "
                  f"bars_med={tp_hits[f'{tf}_bars'].median():.0f}")


def print_skip_atr_sweep(df_m1, profile, positions, sr_levels_dict, htf_dict, tf_labels):
    """Sweep skip_atr_mult for each timeframe."""
    print(f"\n{'=' * 90}")
    print(f"  SKIP-ATR SWEEP: {' | '.join(tf_labels)}")
    print(f"{'=' * 90}")

    skip_values = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]

    for tf in tf_labels:
        print(f"\n  ── {tf} ──")
        print(f"  {'skip':>6s}  {'SR_found':>8s}  {'TP_hits':>7s}  "
              f"{'SR_pnl_med':>10s}  {'SR_pnl_tot':>10s}  {'SR_WR':>6s}  "
              f"{'Conv_tot':>10s}  {'Diff_tot':>10s}")
        print("  " + "─" * 80)

        for skip in skip_values:
            rdf = run_simulation_for_tf(
                df_m1, profile, positions,
                sr_levels_dict[tf], htf_dict[tf],
                skip_atr_mult=skip, tf_label=tf)

            sr_e = rdf[rdf[f"{tf}_reason"] != "DataEnd"]
            conv_e = rdf[rdf["conv_reason"] != "DataEnd"]
            sr_found = rdf[f"{tf}_sr_found"].sum()
            tp_hits = (sr_e[f"{tf}_reason"] == "SR_TP").sum() if len(sr_e) > 0 else 0

            sr_med = sr_e[f"{tf}_pnl"].median() if len(sr_e) > 0 else 0
            sr_tot = sr_e[f"{tf}_pnl"].sum() if len(sr_e) > 0 else 0
            sr_wr = (sr_e[f"{tf}_pnl"] > 0).mean() * 100 if len(sr_e) > 0 else 0
            conv_tot = conv_e["conv_pnl"].sum() if len(conv_e) > 0 else 0
            diff_tot = sr_tot - conv_tot

            print(f"  {skip:>6.2f}  {sr_found:>8d}  {tp_hits:>7d}  "
                  f"{sr_med:>+10.1f}  {sr_tot:>+10.1f}  {sr_wr:>5.1f}%  "
                  f"{conv_tot:>+10.1f}  {diff_tot:>+10.1f}")


# ═══════════════════════════════════════════════════════════════════════
# 8. Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="H1 vs M15 S/R Target Exit Comparison")
    parser.add_argument("csv_path", help="Path to M1 CSV data")
    parser.add_argument("--market", choices=["GOLD", "FX", "CRYPTO"],
                        help="Market type (auto-detected if not specified)")
    parser.add_argument("--sr-skip-atr", type=float, default=0.5,
                        help="Skip S/R within ATR × this (default: 0.5)")
    parser.add_argument("--sr-swing-lookback", type=int, default=7,
                        help="Swing lookback bars (default: 7)")
    parser.add_argument("--sr-merge-atr", type=float, default=0.5,
                        help="Merge S/R within ATR × this (default: 0.5)")
    parser.add_argument("--sr-min-touches", type=int, default=2,
                        help="Min touches for S/R level (default: 2)")
    parser.add_argument("--sr-max-age-h1", type=int, default=200,
                        help="Max age for H1 S/R levels in bars (default: 200)")
    parser.add_argument("--sr-max-age-m15", type=int, default=800,
                        help="Max age for M15 S/R levels in bars (default: 800)")
    parser.add_argument("--sweep", action="store_true",
                        help="Run skip-ATR parameter sweep for both TFs")
    parser.add_argument("--output-csv", default=None,
                        help="Save results to CSV")
    args = parser.parse_args()

    market = Market[args.market] if args.market else detect_market(args.csv_path)
    profile = PROFILES[market]
    print(f"  Market: {market.value}  point={profile.point}")

    # Load M1 data
    print(f"Loading M1 data from: {args.csv_path}")
    df_m1 = load_m1(args.csv_path)
    print(f"  Loaded {len(df_m1)} bars: {df_m1.index[0]} → {df_m1.index[-1]}")

    # Resample to H1 and M15
    print(f"\nResampling...")
    h1 = resample_ohlc(df_m1, "1h")
    m15 = resample_ohlc(df_m1, "15min")
    print(f"  H1 bars:  {len(h1)}")
    print(f"  M15 bars: {len(m15)}")

    # Detect S/R levels for both timeframes
    print(f"\nDetecting S/R levels (swing_lookback={args.sr_swing_lookback}, "
          f"merge_atr={args.sr_merge_atr}, min_touches={args.sr_min_touches})...")

    sr_h1 = detect_sr_levels(h1, swing_lookback=args.sr_swing_lookback,
                             merge_atr_mult=args.sr_merge_atr,
                             max_age_bars=args.sr_max_age_h1,
                             min_touches=args.sr_min_touches)

    sr_m15 = detect_sr_levels(m15, swing_lookback=args.sr_swing_lookback,
                              merge_atr_mult=args.sr_merge_atr,
                              max_age_bars=args.sr_max_age_m15,
                              min_touches=args.sr_min_touches)

    print_sr_summary(sr_h1, "H1")
    print_sr_summary(sr_m15, "M15")

    # Generate positions
    print(f"\nGenerating synthetic positions...")
    positions = generate_positions(df_m1, profile)
    if not positions:
        print("ERROR: No positions generated.")
        sys.exit(1)

    tf_labels = ["H1", "M15"]
    sr_levels_dict = {"H1": sr_h1, "M15": sr_m15}
    htf_dict = {"H1": h1, "M15": m15}

    # Sweep mode
    if args.sweep:
        print_skip_atr_sweep(df_m1, profile, positions, sr_levels_dict, htf_dict, tf_labels)
        return

    # Run simulation for both TFs
    print(f"\nRunning simulation (skip_atr={args.sr_skip_atr})...")

    rdf_h1 = run_simulation_for_tf(df_m1, profile, positions, sr_h1, h1,
                                    args.sr_skip_atr, "H1")
    rdf_m15 = run_simulation_for_tf(df_m1, profile, positions, sr_m15, m15,
                                     args.sr_skip_atr, "M15")

    # Merge results (shared columns: entry_idx, entry_dt, dir, entry_price, oracle_pnl, conv_*)
    # H1-specific: H1_sr_target, H1_sr_found, H1_sr_dist_atr, H1_reason, H1_pnl, H1_bars
    # M15-specific: M15_sr_target, M15_sr_found, etc.
    rdf = rdf_h1.copy()
    m15_cols = [c for c in rdf_m15.columns if c.startswith("M15")]
    for c in m15_cols:
        rdf[c] = rdf_m15[c].values

    # Reports
    print_conv_results(rdf)
    print_tf_results(rdf, "H1")
    print_tf_results(rdf, "M15")
    print_head_to_head(rdf, tf_labels)

    # Save CSV
    out = args.output_csv or f"sim_sr_target_h1_vs_m15_{market.value.lower()}.csv"
    rdf.to_csv(out, index=False)
    print(f"\nResults saved to: {out}")


if __name__ == "__main__":
    main()
