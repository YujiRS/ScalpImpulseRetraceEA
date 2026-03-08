"""
sim_ma_bounce.py  –  MA Bounce Entry Simulation (Impulse → MA Pullback → Entry)
================================================================================
Strategy:
  1. M1 impulse detection (body ≥ ATR × impulse_mult)
  2. Price pulls back to 13EMA or 21EMA on M5 or M15
  3. MA direction must align with impulse direction
  4. Bounce confirmation (wick rejection / close bounce) → Entry

Tests multiple combinations:
  - MA periods: 13, 21
  - Timeframes: M5, M15
  - Touch zone: MA ± ATR × band_mult (dynamic band around MA)
  - Confirmation: WickRejection, CloseAboveMA, Engulfing

Dependencies: pandas, numpy
"""

import os
import sys
import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional, List, Tuple, Dict
from itertools import product

# ═══════════════════════════════════════════════════════════════════════
# 0. Parameters
# ═══════════════════════════════════════════════════════════════════════

# -- Impulse Detection (on M1)
IMPULSE_ATR_PERIOD = 14

# Market-specific impulse multipliers
MARKET_PARAMS = {
    "GOLD": {
        "impulse_atr_mult": 1.8,
        "small_body_ratio": 0.40,
        "point_value": 0.01,
        "sl_buffer_pts": 50,       # 50 points = $0.50
        "data_file": "GOLD#_M1_202509010100_202511282139.csv",
        "trade_hours": (8, 21),    # London+NY
    },
    "USDJPY": {
        "impulse_atr_mult": 1.6,
        "small_body_ratio": 0.35,
        "point_value": 0.001,
        "sl_buffer_pts": 30,
        "data_file": "USDJPY#_M1_202512010000_202602270000.csv",
        "trade_hours": (8, 21),
    },
    "BTCUSD": {
        "impulse_atr_mult": 2.0,
        "small_body_ratio": 0.45,
        "point_value": 0.01,
        "sl_buffer_pts": 100,
        "data_file": "BTCUSD#_M1_202512010000_202602270000.csv",
        "trade_hours": (0, 24),    # 24h market
    },
}

# -- MA Bounce Parameters (sweep)
MA_PERIODS = [13, 21]
MA_TIMEFRAMES = ["5min", "15min"]
BAND_ATR_MULTS = [0.2, 0.3, 0.5]    # Touch zone: MA ± ATR(htf) × mult

# -- Pullback Timing
PULLBACK_MAX_BARS_M1 = 120           # Max M1 bars to wait for MA touch
PULLBACK_MIN_BARS_M1 = 3             # Min bars after impulse before valid

# -- Confirm Patterns
WICK_REJECT_RATIO = 0.55             # Wick must be ≥ this fraction of range
ENGULF_BODY_RATIO = 0.5              # Engulfing candle body ratio minimum

# -- Risk / Reward
MIN_RR_RATIO = 2.0
SL_ATR_MAX_MULT = 2.0               # Reject if SL > ATR × this

# -- ATR
ATR_PERIOD_HTF = 14                  # For MA band width calc

# -- Trend Filter (M15 EMA50 slope)
TREND_EMA_PERIOD = 50
TREND_SLOPE_ATR_MULT = 0.07

# -- Cooldown
COOLDOWN_BARS_M1 = 15                # Min bars between entries


# ═══════════════════════════════════════════════════════════════════════
# 1. Data Loading / Resampling / Indicators
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
    """Resample M1 to higher TF."""
    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "spread": "mean",
    }
    df = m1.resample(rule).agg(agg).dropna(subset=["open"])
    return df


def calc_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Calculate ATR on any timeframe DataFrame."""
    high = df["high"]
    low = df["low"]
    close = df["close"]
    prev_close = close.shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(span=period, adjust=False).mean()


def calc_ema(series: pd.Series, period: int) -> pd.Series:
    """Calculate EMA."""
    return series.ewm(span=period, adjust=False).mean()


def add_indicators(m1: pd.DataFrame, htf: pd.DataFrame,
                   ma_period: int, htf_rule: str) -> None:
    """Add MA and ATR columns to htf, and M15 trend filter to m1."""
    htf[f"ema{ma_period}"] = calc_ema(htf["close"], ma_period)
    htf["atr"] = calc_atr(htf, ATR_PERIOD_HTF)

    # Trend filter: M15 EMA50 slope
    m15 = resample_ohlc(m1, "15min") if htf_rule != "15min" else htf
    if "ema50" not in m15.columns:
        m15["ema50"] = calc_ema(m15["close"], TREND_EMA_PERIOD)
    if "atr_m15" not in m15.columns:
        m15["atr_m15"] = calc_atr(m15, 14)

    return m15


# ═══════════════════════════════════════════════════════════════════════
# 2. Impulse Detection (M1)
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class Impulse:
    """Detected impulse on M1."""
    idx: int                    # M1 bar index
    timestamp: pd.Timestamp
    direction: str              # "LONG" or "SHORT"
    impulse_open: float
    impulse_close: float
    impulse_high: float
    impulse_low: float
    body: float
    atr: float
    origin: float               # Adjusted origin for SL


def detect_impulses(m1: pd.DataFrame, params: dict) -> List[Impulse]:
    """Detect all impulses on M1 data."""
    opens = m1["open"].values
    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values
    atr_vals = calc_atr(m1, IMPULSE_ATR_PERIOD).values
    impulses = []

    hour_start, hour_end = params["trade_hours"]

    for i in range(1, len(m1)):
        # Time filter
        hour = m1.index[i].hour
        if hour_end <= 24:
            if not (hour_start <= hour < hour_end):
                continue
        # else 24h market, no filter

        atr = atr_vals[i]
        if atr <= 0 or np.isnan(atr):
            continue

        body = abs(closes[i] - opens[i])
        if body < atr * params["impulse_atr_mult"]:
            continue

        direction = "LONG" if closes[i] > opens[i] else "SHORT"

        # Origin adjustment (small prev bar)
        origin = lows[i] if direction == "LONG" else highs[i]
        if i >= 2:
            prev_body = abs(closes[i-1] - opens[i-1])
            prev_is_opposite = (closes[i-1] < opens[i-1]) if direction == "LONG" else (closes[i-1] > opens[i-1])
            if prev_body <= atr * params["small_body_ratio"] and prev_is_opposite:
                if direction == "LONG":
                    origin = min(lows[i], lows[i-1])
                else:
                    origin = max(highs[i], highs[i-1])

        impulses.append(Impulse(
            idx=i,
            timestamp=m1.index[i],
            direction=direction,
            impulse_open=opens[i],
            impulse_close=closes[i],
            impulse_high=highs[i],
            impulse_low=lows[i],
            body=body,
            atr=atr,
            origin=origin,
        ))

    return impulses


# ═══════════════════════════════════════════════════════════════════════
# 3. MA Bounce Detection
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class MABounceSignal:
    """A detected MA bounce entry signal."""
    impulse: Impulse
    entry_bar_idx: int          # HTF bar index of entry
    entry_time: pd.Timestamp
    entry_price: float
    sl_price: float
    tp_price: float
    ma_value: float
    ma_period: int
    htf_rule: str
    band_mult: float
    confirm_type: str           # "wick_reject", "close_bounce", "engulfing"
    rr_ratio: float


def find_htf_idx_at_time(htf: pd.DataFrame, timestamp: pd.Timestamp) -> int:
    """Find the HTF bar index that contains a given M1 timestamp."""
    pos = htf.index.searchsorted(timestamp, side="right") - 1
    return max(0, pos)


def check_trend_filter(m15: pd.DataFrame, timestamp: pd.Timestamp,
                       direction: str) -> bool:
    """Check M15 EMA50 slope trend filter."""
    idx = m15.index.searchsorted(timestamp, side="right") - 1
    if idx < 2:
        return False

    ema50 = m15["ema50"].values
    atr_m15 = m15["atr_m15"].values

    slope = ema50[idx] - ema50[idx - 1]
    atr_val = atr_m15[idx]
    if atr_val <= 0 or np.isnan(atr_val):
        return False

    slope_min = atr_val * TREND_SLOPE_ATR_MULT

    if direction == "LONG":
        return slope >= slope_min
    else:
        return slope <= -slope_min


def check_ma_direction(htf: pd.DataFrame, bar_idx: int,
                       ma_col: str, direction: str) -> bool:
    """Check that MA is pointing in the same direction as impulse."""
    if bar_idx < 2:
        return False
    ma_vals = htf[ma_col].values
    # Check last 2 bars for MA direction
    ma_slope = ma_vals[bar_idx] - ma_vals[bar_idx - 2]
    if direction == "LONG":
        return ma_slope > 0
    else:
        return ma_slope < 0


def check_wick_rejection(htf: pd.DataFrame, bar_idx: int,
                         direction: str) -> bool:
    """Check for wick rejection at MA level."""
    o = htf["open"].values[bar_idx]
    h = htf["high"].values[bar_idx]
    l = htf["low"].values[bar_idx]
    c = htf["close"].values[bar_idx]
    rng = h - l
    if rng <= 0:
        return False

    if direction == "LONG":
        # Lower wick should be long (rejection of downside)
        lower_wick = min(o, c) - l
        return (lower_wick / rng) >= WICK_REJECT_RATIO
    else:
        # Upper wick should be long (rejection of upside)
        upper_wick = h - max(o, c)
        return (upper_wick / rng) >= WICK_REJECT_RATIO


def check_close_bounce(htf: pd.DataFrame, bar_idx: int,
                       ma_val: float, direction: str) -> bool:
    """Check if candle closed on the right side of MA (bounced)."""
    c = htf["close"].values[bar_idx]
    o = htf["open"].values[bar_idx]
    if direction == "LONG":
        # Close above MA, and bullish candle
        return c > ma_val and c > o
    else:
        # Close below MA, and bearish candle
        return c < ma_val and c < o


def check_engulfing(htf: pd.DataFrame, bar_idx: int,
                    direction: str) -> bool:
    """Check for engulfing pattern."""
    if bar_idx < 1:
        return False
    o = htf["open"].values[bar_idx]
    c = htf["close"].values[bar_idx]
    po = htf["open"].values[bar_idx - 1]
    pc = htf["close"].values[bar_idx - 1]
    rng = htf["high"].values[bar_idx] - htf["low"].values[bar_idx]
    if rng <= 0:
        return False

    body = abs(c - o)
    prev_body = abs(pc - po)
    if body < rng * ENGULF_BODY_RATIO:
        return False

    if direction == "LONG":
        return c > o and body > prev_body and c > max(po, pc)
    else:
        return c < o and body > prev_body and c < min(po, pc)


def scan_ma_bounce(impulse: Impulse, m1: pd.DataFrame,
                   htf: pd.DataFrame, m15: pd.DataFrame,
                   ma_period: int, htf_rule: str, band_mult: float,
                   params: dict) -> Optional[MABounceSignal]:
    """
    After an impulse, scan HTF bars for MA touch + bounce confirmation.
    Returns the first valid signal or None.
    """
    ma_col = f"ema{ma_period}"

    # Trend filter
    if not check_trend_filter(m15, impulse.timestamp, impulse.direction):
        return None

    # Find HTF bar at impulse time
    imp_htf_idx = find_htf_idx_at_time(htf, impulse.timestamp)

    # Determine how many HTF bars correspond to the pullback window
    # M1 bars → HTF bars (approximate)
    if htf_rule == "5min":
        htf_max_bars = PULLBACK_MAX_BARS_M1 // 5
        htf_min_bars = max(1, PULLBACK_MIN_BARS_M1 // 5)
    else:  # 15min
        htf_max_bars = PULLBACK_MAX_BARS_M1 // 15
        htf_min_bars = max(1, PULLBACK_MIN_BARS_M1 // 15)

    ma_vals = htf[ma_col].values
    atr_vals = htf["atr"].values
    highs = htf["high"].values
    lows = htf["low"].values
    opens = htf["open"].values
    closes = htf["close"].values

    for offset in range(htf_min_bars, htf_max_bars + 1):
        bar_idx = imp_htf_idx + offset
        if bar_idx >= len(htf):
            break

        ma_val = ma_vals[bar_idx]
        atr_val = atr_vals[bar_idx]
        if np.isnan(ma_val) or np.isnan(atr_val) or atr_val <= 0:
            continue

        # Check MA direction aligns with impulse
        if not check_ma_direction(htf, bar_idx, ma_col, impulse.direction):
            continue

        band_width = atr_val * band_mult

        # Check if price touched the MA band
        h = highs[bar_idx]
        l = lows[bar_idx]

        touched = False
        if impulse.direction == "LONG":
            # Price should pull back DOWN to MA band
            # Low should reach into MA + band_width zone (from below/at MA)
            if l <= ma_val + band_width:
                touched = True
        else:
            # Price should pull back UP to MA band
            if h >= ma_val - band_width:
                touched = True

        if not touched:
            continue

        # Check confirmation patterns (priority order)
        confirm_type = None
        if check_wick_rejection(htf, bar_idx, impulse.direction):
            confirm_type = "wick_reject"
        elif check_close_bounce(htf, bar_idx, ma_val, impulse.direction):
            confirm_type = "close_bounce"
        elif check_engulfing(htf, bar_idx, impulse.direction):
            confirm_type = "engulfing"

        if confirm_type is None:
            continue

        # Calculate entry, SL, TP
        c = closes[bar_idx]
        entry_price = c  # Enter at close of confirmation bar

        if impulse.direction == "LONG":
            sl_price = l - params["sl_buffer_pts"] * params["point_value"]
            risk = entry_price - sl_price
        else:
            sl_price = h + params["sl_buffer_pts"] * params["point_value"]
            risk = sl_price - entry_price

        if risk <= 0:
            continue

        # SL too wide check
        if risk > atr_val * SL_ATR_MAX_MULT:
            continue

        tp_dist = risk * MIN_RR_RATIO
        if impulse.direction == "LONG":
            tp_price = entry_price + tp_dist
        else:
            tp_price = entry_price - tp_dist

        rr_ratio = tp_dist / risk

        return MABounceSignal(
            impulse=impulse,
            entry_bar_idx=bar_idx,
            entry_time=htf.index[bar_idx],
            entry_price=entry_price,
            sl_price=sl_price,
            tp_price=tp_price,
            ma_value=ma_val,
            ma_period=ma_period,
            htf_rule=htf_rule,
            band_mult=band_mult,
            confirm_type=confirm_type,
            rr_ratio=rr_ratio,
        )

    return None


# ═══════════════════════════════════════════════════════════════════════
# 4. Trade Simulation
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class TradeResult:
    """Result of a simulated trade."""
    signal: MABounceSignal
    exit_time: pd.Timestamp
    exit_price: float
    pnl_r: float               # P&L in R units
    outcome: str                # "TP", "SL", "TIMEOUT"
    hold_bars_m1: int


def simulate_trade(signal: MABounceSignal, m1: pd.DataFrame,
                   max_hold_bars: int = 300) -> TradeResult:
    """Simulate a single trade on M1 data."""
    # Find M1 bar at or after entry time
    entry_m1_idx = m1.index.searchsorted(signal.entry_time, side="right")
    if entry_m1_idx >= len(m1):
        return TradeResult(
            signal=signal, exit_time=signal.entry_time,
            exit_price=signal.entry_price, pnl_r=0.0,
            outcome="TIMEOUT", hold_bars_m1=0,
        )

    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values

    for i in range(entry_m1_idx, min(entry_m1_idx + max_hold_bars, len(m1))):
        h = highs[i]
        l = lows[i]

        if signal.impulse.direction == "LONG":
            risk = signal.entry_price - signal.sl_price
            # Check SL first (conservative)
            if l <= signal.sl_price:
                return TradeResult(
                    signal=signal, exit_time=m1.index[i],
                    exit_price=signal.sl_price, pnl_r=-1.0,
                    outcome="SL", hold_bars_m1=i - entry_m1_idx,
                )
            # Check TP
            if h >= signal.tp_price:
                return TradeResult(
                    signal=signal, exit_time=m1.index[i],
                    exit_price=signal.tp_price,
                    pnl_r=(signal.tp_price - signal.entry_price) / risk,
                    outcome="TP", hold_bars_m1=i - entry_m1_idx,
                )
        else:
            risk = signal.sl_price - signal.entry_price
            # Check SL first
            if h >= signal.sl_price:
                return TradeResult(
                    signal=signal, exit_time=m1.index[i],
                    exit_price=signal.sl_price, pnl_r=-1.0,
                    outcome="SL", hold_bars_m1=i - entry_m1_idx,
                )
            # Check TP
            if l <= signal.tp_price:
                return TradeResult(
                    signal=signal, exit_time=m1.index[i],
                    exit_price=signal.tp_price,
                    pnl_r=(signal.entry_price - signal.tp_price) / risk,
                    outcome="TP", hold_bars_m1=i - entry_m1_idx,
                )

    # Timeout – exit at last bar close
    last_idx = min(entry_m1_idx + max_hold_bars - 1, len(m1) - 1)
    final_close = closes[last_idx]
    if signal.impulse.direction == "LONG":
        risk = signal.entry_price - signal.sl_price
        pnl_r = (final_close - signal.entry_price) / risk if risk > 0 else 0
    else:
        risk = signal.sl_price - signal.entry_price
        pnl_r = (signal.entry_price - final_close) / risk if risk > 0 else 0

    return TradeResult(
        signal=signal, exit_time=m1.index[last_idx],
        exit_price=final_close, pnl_r=pnl_r,
        outcome="TIMEOUT", hold_bars_m1=last_idx - entry_m1_idx,
    )


# ═══════════════════════════════════════════════════════════════════════
# 5. Fib Retracement Baseline (for comparison)
# ═══════════════════════════════════════════════════════════════════════

def scan_fib_retracement(impulse: Impulse, m1: pd.DataFrame,
                         m15: pd.DataFrame, params: dict,
                         fib_level: float = 0.5,
                         ) -> Optional[MABounceSignal]:
    """
    Baseline Fib retracement scan for comparison.
    Uses M1 bars directly (matching current EA logic more closely).
    """
    if not check_trend_filter(m15, impulse.timestamp, impulse.direction):
        return None

    imp_range = abs(impulse.impulse_close - impulse.origin)
    if imp_range <= 0:
        return None

    # Fib level
    if impulse.direction == "LONG":
        fib_price = impulse.impulse_close - imp_range * fib_level
    else:
        fib_price = impulse.impulse_close + imp_range * fib_level

    band_width = impulse.atr * 0.05  # Matches GOLD spec

    opens = m1["open"].values
    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values

    touch_count = 0
    left_band = False

    for offset in range(PULLBACK_MIN_BARS_M1, PULLBACK_MAX_BARS_M1):
        bar_idx = impulse.idx + offset
        if bar_idx >= len(m1):
            break

        h = highs[bar_idx]
        l = lows[bar_idx]
        c = closes[bar_idx]

        in_band = False
        if impulse.direction == "LONG":
            in_band = l <= fib_price + band_width and h >= fib_price - band_width
        else:
            in_band = h >= fib_price - band_width and l <= fib_price + band_width

        if touch_count == 0 and in_band:
            touch_count = 1
            left_band = False
            continue

        if touch_count == 1 and not in_band:
            # Check if left band sufficiently
            if impulse.direction == "LONG":
                if c > fib_price + band_width * 2.5:
                    left_band = True
            else:
                if c < fib_price - band_width * 2.5:
                    left_band = True

        if touch_count == 1 and left_band and in_band:
            touch_count = 2
            # Check wick rejection on this bar
            rng = h - l
            if rng > 0:
                if impulse.direction == "LONG":
                    lower_wick = min(opens[bar_idx], c) - l
                    if lower_wick / rng >= WICK_REJECT_RATIO:
                        # Valid entry
                        entry_price = c
                        sl_price = l - params["sl_buffer_pts"] * params["point_value"]
                        risk = entry_price - sl_price
                        if risk > 0 and risk <= impulse.atr * SL_ATR_MAX_MULT:
                            tp_price = entry_price + risk * MIN_RR_RATIO
                            return MABounceSignal(
                                impulse=impulse,
                                entry_bar_idx=bar_idx,
                                entry_time=m1.index[bar_idx],
                                entry_price=entry_price,
                                sl_price=sl_price,
                                tp_price=tp_price,
                                ma_value=fib_price,
                                ma_period=0,  # Fib marker
                                htf_rule="fib500",
                                band_mult=0.05,
                                confirm_type="wick_reject",
                                rr_ratio=MIN_RR_RATIO,
                            )
                else:
                    upper_wick = h - max(opens[bar_idx], c)
                    if upper_wick / rng >= WICK_REJECT_RATIO:
                        entry_price = c
                        sl_price = h + params["sl_buffer_pts"] * params["point_value"]
                        risk = sl_price - entry_price
                        if risk > 0 and risk <= impulse.atr * SL_ATR_MAX_MULT:
                            tp_price = entry_price - risk * MIN_RR_RATIO
                            return MABounceSignal(
                                impulse=impulse,
                                entry_bar_idx=bar_idx,
                                entry_time=m1.index[bar_idx],
                                entry_price=entry_price,
                                sl_price=sl_price,
                                tp_price=tp_price,
                                ma_value=fib_price,
                                ma_period=0,
                                htf_rule="fib500",
                                band_mult=0.05,
                                confirm_type="wick_reject",
                                rr_ratio=MIN_RR_RATIO,
                            )

    return None


# ═══════════════════════════════════════════════════════════════════════
# 6. Main Simulation Runner
# ═══════════════════════════════════════════════════════════════════════

def run_simulation(market: str, params: dict,
                   ma_period: int, htf_rule: str, band_mult: float,
                   m1: pd.DataFrame, htf: pd.DataFrame,
                   m15: pd.DataFrame, impulses: List[Impulse],
                   ) -> List[TradeResult]:
    """Run full simulation for one parameter combination."""
    results = []
    last_entry_m1_idx = -COOLDOWN_BARS_M1 - 1

    for impulse in impulses:
        # Cooldown check
        if impulse.idx - last_entry_m1_idx < COOLDOWN_BARS_M1:
            continue

        signal = scan_ma_bounce(
            impulse, m1, htf, m15,
            ma_period, htf_rule, band_mult, params,
        )
        if signal is None:
            continue

        trade = simulate_trade(signal, m1)
        results.append(trade)
        last_entry_m1_idx = impulse.idx

    return results


def run_fib_baseline(market: str, params: dict,
                     m1: pd.DataFrame, m15: pd.DataFrame,
                     impulses: List[Impulse]) -> List[TradeResult]:
    """Run Fib retracement baseline for comparison."""
    results = []
    last_entry_m1_idx = -COOLDOWN_BARS_M1 - 1

    for impulse in impulses:
        if impulse.idx - last_entry_m1_idx < COOLDOWN_BARS_M1:
            continue

        signal = scan_fib_retracement(impulse, m1, m15, params)
        if signal is None:
            continue

        trade = simulate_trade(signal, m1)
        results.append(trade)
        last_entry_m1_idx = impulse.idx

    return results


def summarize_results(results: List[TradeResult]) -> Dict:
    """Generate summary statistics from trade results."""
    if not results:
        return {
            "trades": 0, "win_rate": 0, "avg_rr": 0,
            "total_r": 0, "max_dd_r": 0, "profit_factor": 0,
            "tp": 0, "sl": 0, "timeout": 0,
            "avg_hold_bars": 0,
            "confirms": {},
        }

    wins = [r for r in results if r.pnl_r > 0]
    losses = [r for r in results if r.pnl_r <= 0]
    total_r = sum(r.pnl_r for r in results)

    # Max drawdown in R
    cumulative = 0.0
    peak = 0.0
    max_dd = 0.0
    for r in results:
        cumulative += r.pnl_r
        peak = max(peak, cumulative)
        dd = peak - cumulative
        max_dd = max(max_dd, dd)

    # Profit factor
    gross_profit = sum(r.pnl_r for r in results if r.pnl_r > 0)
    gross_loss = abs(sum(r.pnl_r for r in results if r.pnl_r < 0))
    pf = gross_profit / gross_loss if gross_loss > 0 else float("inf")

    # Confirm type breakdown
    confirms = {}
    for r in results:
        ct = r.signal.confirm_type
        if ct not in confirms:
            confirms[ct] = {"trades": 0, "wins": 0, "total_r": 0}
        confirms[ct]["trades"] += 1
        if r.pnl_r > 0:
            confirms[ct]["wins"] += 1
        confirms[ct]["total_r"] += r.pnl_r

    return {
        "trades": len(results),
        "win_rate": len(wins) / len(results) * 100,
        "avg_rr": total_r / len(results),
        "total_r": total_r,
        "max_dd_r": max_dd,
        "profit_factor": pf,
        "tp": sum(1 for r in results if r.outcome == "TP"),
        "sl": sum(1 for r in results if r.outcome == "SL"),
        "timeout": sum(1 for r in results if r.outcome == "TIMEOUT"),
        "avg_hold_bars": np.mean([r.hold_bars_m1 for r in results]),
        "confirms": confirms,
    }


# ═══════════════════════════════════════════════════════════════════════
# 7. Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    data_dir = os.path.join(os.path.dirname(__file__), "sim_dat")

    markets = list(MARKET_PARAMS.keys())
    if len(sys.argv) > 1:
        markets = [m.upper() for m in sys.argv[1:] if m.upper() in MARKET_PARAMS]

    all_results = []

    for market in markets:
        params = MARKET_PARAMS[market]
        data_path = os.path.join(data_dir, params["data_file"])

        if not os.path.exists(data_path):
            print(f"[SKIP] {market}: data file not found: {data_path}")
            continue

        print(f"\n{'='*70}")
        print(f"  {market} – Loading data...")
        print(f"{'='*70}")

        m1 = load_m1(data_path)
        print(f"  M1 bars: {len(m1):,}  ({m1.index[0]} → {m1.index[-1]})")

        # Detect impulses
        impulses = detect_impulses(m1, params)
        print(f"  Impulses detected: {len(impulses)}")
        long_count = sum(1 for imp in impulses if imp.direction == "LONG")
        print(f"    LONG: {long_count}, SHORT: {len(impulses) - long_count}")

        # Precompute M15 for trend filter
        m15 = resample_ohlc(m1, "15min")
        m15["ema50"] = calc_ema(m15["close"], TREND_EMA_PERIOD)
        m15["atr_m15"] = calc_atr(m15, 14)

        # ── Fib baseline ──
        print(f"\n  --- Fib500 Baseline ---")
        fib_results = run_fib_baseline(market, params, m1, m15, impulses)
        fib_summary = summarize_results(fib_results)
        print(f"  Trades: {fib_summary['trades']}, "
              f"Win%: {fib_summary['win_rate']:.1f}, "
              f"Total R: {fib_summary['total_r']:.1f}, "
              f"PF: {fib_summary['profit_factor']:.2f}, "
              f"MaxDD: {fib_summary['max_dd_r']:.1f}R")

        all_results.append({
            "market": market,
            "method": "Fib500",
            "ma_period": 0,
            "htf": "M1",
            "band_mult": 0.05,
            **fib_summary,
        })

        # ── MA Bounce sweep ──
        for ma_period, htf_rule, band_mult in product(
            MA_PERIODS, MA_TIMEFRAMES, BAND_ATR_MULTS
        ):
            htf = resample_ohlc(m1, htf_rule)
            add_indicators(m1, htf, ma_period, htf_rule)

            tf_label = "M5" if htf_rule == "5min" else "M15"
            label = f"EMA{ma_period}@{tf_label} band={band_mult}"

            results = run_simulation(
                market, params, ma_period, htf_rule, band_mult,
                m1, htf, m15, impulses,
            )
            summary = summarize_results(results)

            marker = ""
            if summary["trades"] > 0 and summary["profit_factor"] > 1.5:
                marker = " ★"
            if summary["trades"] > 0 and summary["win_rate"] >= 55:
                marker += " ◆"

            print(f"  {label:30s} | Trades: {summary['trades']:3d} | "
                  f"Win%: {summary['win_rate']:5.1f} | "
                  f"TotalR: {summary['total_r']:+7.1f} | "
                  f"PF: {summary['profit_factor']:5.2f} | "
                  f"MaxDD: {summary['max_dd_r']:5.1f}R{marker}")

            all_results.append({
                "market": market,
                "method": f"EMA{ma_period}",
                "htf": tf_label,
                "ma_period": ma_period,
                "band_mult": band_mult,
                **summary,
            })

    # ── Summary table ──
    if all_results:
        print(f"\n{'='*70}")
        print(f"  SUMMARY – All Markets × All Methods")
        print(f"{'='*70}")

        df = pd.DataFrame(all_results)
        # Sort by total_r descending
        df_sorted = df.sort_values("total_r", ascending=False)

        print(f"\n  Top 10 by Total R:")
        print(f"  {'Market':<8} {'Method':<10} {'HTF':<5} {'Band':<6} "
              f"{'Trades':>6} {'Win%':>6} {'TotalR':>8} {'PF':>6} {'MaxDD':>6}")
        print(f"  {'-'*65}")

        for _, row in df_sorted.head(10).iterrows():
            print(f"  {row['market']:<8} {row['method']:<10} {row['htf']:<5} "
                  f"{row['band_mult']:<6.2f} {row['trades']:>6} "
                  f"{row['win_rate']:>5.1f}% {row['total_r']:>+7.1f}R "
                  f"{row['profit_factor']:>5.2f} {row['max_dd_r']:>5.1f}R")

        # Confirm type breakdown for top 3
        print(f"\n  Confirm Type Breakdown (Top 3):")
        for _, row in df_sorted.head(3).iterrows():
            confirms = row.get("confirms", {})
            if confirms:
                print(f"  {row['market']} {row['method']}@{row['htf']} band={row['band_mult']}:")
                for ct, stats in confirms.items():
                    wr = stats["wins"] / stats["trades"] * 100 if stats["trades"] > 0 else 0
                    print(f"    {ct:15s}: {stats['trades']:3d} trades, "
                          f"{wr:5.1f}% win, {stats['total_r']:+.1f}R")

        # Save detailed results
        out_path = os.path.join(data_dir, "sim_results_ma_bounce.csv")
        df.to_csv(out_path, index=False)
        print(f"\n  Results saved to: {out_path}")

        # ── MA vs Fib comparison per market ──
        print(f"\n{'='*70}")
        print(f"  MA Bounce vs Fib500 – Per-Market Best")
        print(f"{'='*70}")
        for market in markets:
            if market not in df["market"].values:
                continue
            mdf = df[df["market"] == market]
            fib_row = mdf[mdf["method"] == "Fib500"]
            ma_rows = mdf[mdf["method"] != "Fib500"]
            if len(fib_row) == 0 or len(ma_rows) == 0:
                continue
            fib_row = fib_row.iloc[0]
            best_ma = ma_rows.sort_values("total_r", ascending=False).iloc[0]

            print(f"\n  {market}:")
            print(f"    Fib500:  {fib_row['trades']:3.0f} trades, "
                  f"{fib_row['win_rate']:5.1f}% win, "
                  f"{fib_row['total_r']:+.1f}R, PF={fib_row['profit_factor']:.2f}")
            print(f"    Best MA: {best_ma['method']}@{best_ma['htf']} "
                  f"band={best_ma['band_mult']:.2f} → "
                  f"{best_ma['trades']:3.0f} trades, "
                  f"{best_ma['win_rate']:5.1f}% win, "
                  f"{best_ma['total_r']:+.1f}R, PF={best_ma['profit_factor']:.2f}")

            if best_ma["total_r"] > fib_row["total_r"]:
                diff = best_ma["total_r"] - fib_row["total_r"]
                print(f"    → MA wins by {diff:+.1f}R ✓")
            else:
                diff = fib_row["total_r"] - best_ma["total_r"]
                print(f"    → Fib wins by {diff:+.1f}R")


if __name__ == "__main__":
    main()
