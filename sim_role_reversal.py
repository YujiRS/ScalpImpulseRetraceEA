"""
sim_role_reversal.py  –  5M Role-Reversal + MTF Analysis Simulation
====================================================================
Strategy: H1 S/R breakout → M5 pullback (role reversal) → EMA25 + Key Reversal confirm
Independent from existing Impulse→Retrace EAs.

Dependencies: pandas, numpy
"""

import os
import sys
import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional, List, Tuple

# ═══════════════════════════════════════════════════════════════════════
# 0. Parameters
# ═══════════════════════════════════════════════════════════════════════

# -- H1 S/R Detection
SR_SWING_LOOKBACK = 7           # Bars on each side for swing detection (optimized)
SR_MERGE_TOLERANCE_ATR = 0.5    # Merge S/R levels within this ATR fraction
SR_MAX_AGE_BARS = 200           # Max age of S/R level in H1 bars
SR_MIN_TOUCHES = 2              # Minimum touches to qualify as significant

# -- Breakout Detection (on M5)
BREAKOUT_BODY_RATIO = 0.3       # Minimum body/range ratio for breakout candle
BREAKOUT_CONFIRM_BARS = 2       # Consecutive closes beyond level to confirm

# -- Pullback / Role Reversal Zone
PULLBACK_ZONE_ATR = 0.5         # Zone around level: level ± ATR * this (optimized)
PULLBACK_MAX_BARS = 120         # Max M5 bars to wait for pullback (10h)
PULLBACK_MIN_BARS = 2           # Min bars after breakout before pullback valid

# -- EMA
EMA_PERIOD = 25                 # M5 EMA period

# -- Key Reversal / Confirm Detection
KR_LOOKBACK = 5                 # Bars to look back for new high/low
KR_BODY_MIN_RATIO = 0.3         # Minimum body/range for reversal candle
KR_CLOSE_POSITION = 0.45        # Close must be in upper/lower portion

# -- EMA Trend Check
EMA_TREND_LOOKBACK = 3          # Bars to check EMA direction

# -- Confirm: Engulfing pattern (alternative to Key Reversal)
ENGULF_BODY_RATIO = 0.5         # Engulfing candle body ratio minimum

# -- Confirm: Pin Bar (alternative)
PIN_WICK_RATIO = 2.0            # Wick must be >= body * this
PIN_BODY_MAX_RATIO = 0.35       # Body must be <= range * this

# -- Risk/Reward
MIN_RR_RATIO = 2.0              # Minimum reward:risk
MAX_SL_ATR_MULT = 2.0           # Reject if SL > ATR * this (candle too large)
SL_BUFFER_PIPS = 5.0            # Buffer beyond signal candle for SL

# -- ATR
ATR_PERIOD = 14

# -- Time Filter (UTC hours)
# London: 08:00-16:00, NY: 13:00-21:00 → combined: 08:00-21:00
TRADE_HOUR_START = 8
TRADE_HOUR_END = 21

# -- Position Management
USE_FIXED_RR_TP = True          # True: fixed R:R TP, False: next H1 level TP
ENABLE_BREAKEVEN = True         # Enable breakeven (SL → Entry) at threshold
BE_RR_THRESHOLD = 1.0           # R:R threshold to trigger breakeven

# -- Market-specific
POINT_VALUE = 0.01              # GOLD: 0.01, FX: 0.001 or 0.01


# ═══════════════════════════════════════════════════════════════════════
# 1. Data Loading / Resampling
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
    """Resample M1 to higher TF (e.g. '5min', '15min', '1h')."""
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


# ═══════════════════════════════════════════════════════════════════════
# 2. H1 Support/Resistance Detection
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class SRLevel:
    """A horizontal support/resistance level detected on H1."""
    price: float
    level_type: str          # "resistance" or "support"
    detected_at: int         # H1 bar index where detected
    touch_count: int = 1
    broken: bool = False
    broken_direction: str = ""  # "up" or "down"
    broken_at_m5_idx: int = -1
    used: bool = False       # Already traded on this level's role reversal


def detect_swing_highs_lows(h1: pd.DataFrame, lookback: int = 5
                             ) -> List[SRLevel]:
    """Detect swing highs and lows on H1 as S/R levels."""
    levels = []
    highs = h1["high"].values
    lows = h1["low"].values

    for i in range(lookback, len(h1) - lookback):
        # Swing high → resistance
        is_swing_high = True
        for j in range(1, lookback + 1):
            if highs[i] <= highs[i - j] or highs[i] <= highs[i + j]:
                is_swing_high = False
                break
        if is_swing_high:
            levels.append(SRLevel(
                price=highs[i],
                level_type="resistance",
                detected_at=i,
            ))

        # Swing low → support
        is_swing_low = True
        for j in range(1, lookback + 1):
            if lows[i] >= lows[i - j] or lows[i] >= lows[i + j]:
                is_swing_low = False
                break
        if is_swing_low:
            levels.append(SRLevel(
                price=lows[i],
                level_type="support",
                detected_at=i,
            ))

    return levels


def merge_nearby_levels(levels: List[SRLevel], atr: float,
                         tolerance: float = 0.3) -> List[SRLevel]:
    """Merge S/R levels that are within tolerance * ATR of each other."""
    if not levels:
        return []
    sorted_levels = sorted(levels, key=lambda x: x.price)
    merged = [sorted_levels[0]]
    for lvl in sorted_levels[1:]:
        if abs(lvl.price - merged[-1].price) < atr * tolerance:
            # Merge: keep the one with more touches or average price
            merged[-1].touch_count += lvl.touch_count
            merged[-1].price = (merged[-1].price + lvl.price) / 2
        else:
            merged.append(lvl)
    return merged


def count_touches(levels: List[SRLevel], h1: pd.DataFrame,
                   atr_series: pd.Series, tolerance_atr: float = 0.3):
    """Count how many times price touched each S/R level on H1."""
    for lvl in levels:
        touches = 0
        for i in range(lvl.detected_at + 1, len(h1)):
            atr_val = atr_series.iloc[i] if i < len(atr_series) else atr_series.iloc[-1]
            zone = atr_val * tolerance_atr
            high_i = h1["high"].iloc[i]
            low_i = h1["low"].iloc[i]
            # Price touched the level if high/low is within zone
            if low_i <= lvl.price + zone and high_i >= lvl.price - zone:
                touches += 1
        lvl.touch_count = max(1, touches)


# ═══════════════════════════════════════════════════════════════════════
# 3. Breakout Detection (on M5)
# ═══════════════════════════════════════════════════════════════════════

def find_h1_bar_index(h1: pd.DataFrame, m5_time: pd.Timestamp) -> int:
    """Find the H1 bar index that contains or precedes the given M5 time."""
    idx = h1.index.searchsorted(m5_time, side="right") - 1
    return max(0, min(idx, len(h1) - 1))


def is_breakout_candle(candle, level_price: float, direction: str,
                        body_ratio_min: float = 0.5) -> bool:
    """Check if M5 candle is a valid breakout candle."""
    o, h, l, c = candle["open"], candle["high"], candle["low"], candle["close"]
    rng = h - l
    if rng <= 0:
        return False
    body = abs(c - o)
    body_ratio = body / rng

    if body_ratio < body_ratio_min:
        return False

    if direction == "up":
        # Bullish breakout: close above level, open below or near level
        return c > level_price and o < level_price + rng * 0.3
    else:
        # Bearish breakout: close below level, open above or near level
        return c < level_price and o > level_price - rng * 0.3


# ═══════════════════════════════════════════════════════════════════════
# 4. Key Reversal Detection
# ═══════════════════════════════════════════════════════════════════════

def is_bullish_key_reversal(m5: pd.DataFrame, idx: int,
                             lookback: int = 5) -> bool:
    """
    Bullish Key Reversal:
    - Makes a new low relative to recent N bars
    - Closes above previous bar's close
    - Closes in upper portion of candle range
    """
    if idx < lookback or idx >= len(m5):
        return False

    curr = m5.iloc[idx]
    prev = m5.iloc[idx - 1]
    o, h, l, c = curr["open"], curr["high"], curr["low"], curr["close"]
    rng = h - l
    if rng <= 0:
        return False

    body = abs(c - o)
    if body / rng < KR_BODY_MIN_RATIO:
        return False

    # New low in lookback period
    recent_lows = m5["low"].iloc[max(0, idx - lookback):idx].values
    if len(recent_lows) == 0:
        return False
    is_new_low = l <= min(recent_lows)

    # Close above previous close
    closes_above_prev = c > prev["close"]

    # Close in upper portion
    close_position = (c - l) / rng
    in_upper = close_position >= KR_CLOSE_POSITION

    # Bullish candle (close > open)
    is_bullish = c > o

    return is_new_low and closes_above_prev and in_upper and is_bullish


def is_bearish_key_reversal(m5: pd.DataFrame, idx: int,
                             lookback: int = 5) -> bool:
    """
    Bearish Key Reversal:
    - Makes a new high relative to recent N bars
    - Closes below previous bar's close
    - Closes in lower portion of candle range
    """
    if idx < lookback or idx >= len(m5):
        return False

    curr = m5.iloc[idx]
    prev = m5.iloc[idx - 1]
    o, h, l, c = curr["open"], curr["high"], curr["low"], curr["close"]
    rng = h - l
    if rng <= 0:
        return False

    body = abs(c - o)
    if body / rng < KR_BODY_MIN_RATIO:
        return False

    # New high in lookback period
    recent_highs = m5["high"].iloc[max(0, idx - lookback):idx].values
    if len(recent_highs) == 0:
        return False
    is_new_high = h >= max(recent_highs)

    # Close below previous close
    closes_below_prev = c < prev["close"]

    # Close in lower portion
    close_position = (c - l) / rng
    in_lower = close_position <= (1.0 - KR_CLOSE_POSITION)

    # Bearish candle (close < open)
    is_bearish = c < o

    return is_new_high and closes_below_prev and in_lower and is_bearish


def is_bullish_engulfing(m5: pd.DataFrame, idx: int) -> bool:
    """Bullish engulfing: current body engulfs previous body, close > open."""
    if idx < 1 or idx >= len(m5):
        return False
    curr = m5.iloc[idx]
    prev = m5.iloc[idx - 1]
    c_o, c_c = curr["open"], curr["close"]
    p_o, p_c = prev["open"], prev["close"]
    rng = curr["high"] - curr["low"]
    if rng <= 0:
        return False
    body = abs(c_c - c_o)
    if body / rng < ENGULF_BODY_RATIO:
        return False
    # Current bullish, previous bearish
    if c_c <= c_o or p_c >= p_o:
        return False
    # Body engulfs
    return c_o <= min(p_o, p_c) and c_c >= max(p_o, p_c)


def is_bearish_engulfing(m5: pd.DataFrame, idx: int) -> bool:
    """Bearish engulfing: current body engulfs previous body, close < open."""
    if idx < 1 or idx >= len(m5):
        return False
    curr = m5.iloc[idx]
    prev = m5.iloc[idx - 1]
    c_o, c_c = curr["open"], curr["close"]
    p_o, p_c = prev["open"], prev["close"]
    rng = curr["high"] - curr["low"]
    if rng <= 0:
        return False
    body = abs(c_c - c_o)
    if body / rng < ENGULF_BODY_RATIO:
        return False
    # Current bearish, previous bullish
    if c_c >= c_o or p_c <= p_o:
        return False
    return c_o >= max(p_o, p_c) and c_c <= min(p_o, p_c)


def is_bullish_pin_bar(m5: pd.DataFrame, idx: int) -> bool:
    """Bullish pin bar: long lower wick, small body in upper part."""
    if idx >= len(m5):
        return False
    curr = m5.iloc[idx]
    o, h, l, c = curr["open"], curr["high"], curr["low"], curr["close"]
    rng = h - l
    if rng <= 0:
        return False
    body = abs(c - o)
    if body / rng > PIN_BODY_MAX_RATIO:
        return False
    lower_wick = min(o, c) - l
    if body > 0 and lower_wick / body < PIN_WICK_RATIO:
        return False
    # Close in upper portion
    return (c - l) / rng >= 0.6


def is_bearish_pin_bar(m5: pd.DataFrame, idx: int) -> bool:
    """Bearish pin bar: long upper wick, small body in lower part."""
    if idx >= len(m5):
        return False
    curr = m5.iloc[idx]
    o, h, l, c = curr["open"], curr["high"], curr["low"], curr["close"]
    rng = h - l
    if rng <= 0:
        return False
    body = abs(c - o)
    if body / rng > PIN_BODY_MAX_RATIO:
        return False
    upper_wick = h - max(o, c)
    if body > 0 and upper_wick / body < PIN_WICK_RATIO:
        return False
    # Close in lower portion
    return (c - l) / rng <= 0.4


def check_bullish_confirm(m5: pd.DataFrame, idx: int) -> str:
    """Check any bullish confirm pattern. Returns pattern name or empty."""
    if is_bullish_key_reversal(m5, idx, KR_LOOKBACK):
        return "KeyReversal"
    if is_bullish_engulfing(m5, idx):
        return "Engulfing"
    if is_bullish_pin_bar(m5, idx):
        return "PinBar"
    return ""


def check_bearish_confirm(m5: pd.DataFrame, idx: int) -> str:
    """Check any bearish confirm pattern. Returns pattern name or empty."""
    if is_bearish_key_reversal(m5, idx, KR_LOOKBACK):
        return "KeyReversal"
    if is_bearish_engulfing(m5, idx):
        return "Engulfing"
    if is_bearish_pin_bar(m5, idx):
        return "PinBar"
    return ""


# ═══════════════════════════════════════════════════════════════════════
# 5. Confluence Check (EMA + Level + Key Reversal)
# ═══════════════════════════════════════════════════════════════════════

def check_ema_support(m5: pd.DataFrame, ema: pd.Series, idx: int,
                       direction: str, tolerance_atr: float = 0.3,
                       atr_val: float = 1.0) -> bool:
    """Check if EMA25 is acting as dynamic support/resistance."""
    if idx >= len(m5) or idx >= len(ema):
        return False

    curr = m5.iloc[idx]
    ema_val = ema.iloc[idx]
    zone = atr_val * tolerance_atr

    if direction == "up":
        # EMA should be below price, acting as support
        # Price low should be near or above EMA
        return curr["low"] >= ema_val - zone and curr["close"] > ema_val
    else:
        # EMA should be above price, acting as resistance
        return curr["high"] <= ema_val + zone and curr["close"] < ema_val


def check_ema_trend(ema: pd.Series, idx: int, direction: str,
                     lookback: int = 5) -> bool:
    """Check if EMA is trending in the expected direction."""
    if idx < lookback or idx >= len(ema):
        return False
    ema_now = ema.iloc[idx]
    ema_prev = ema.iloc[idx - lookback]
    if direction == "up":
        return ema_now > ema_prev
    else:
        return ema_now < ema_prev


# ═══════════════════════════════════════════════════════════════════════
# 6. Time Filter
# ═══════════════════════════════════════════════════════════════════════

def is_trading_hour(dt: pd.Timestamp) -> bool:
    """Check if the time is within London/NY trading hours (UTC)."""
    return TRADE_HOUR_START <= dt.hour < TRADE_HOUR_END


# ═══════════════════════════════════════════════════════════════════════
# 7. Trade Execution & Management
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class Trade:
    """A single trade record."""
    entry_time: pd.Timestamp
    entry_price: float
    direction: str              # "long" or "short"
    sl: float
    tp: float
    sr_level: float             # The S/R level that was traded
    signal_candle_idx: int
    confirm_pattern: str = ""     # KeyReversal, Engulfing, PinBar
    exit_time: Optional[pd.Timestamp] = None
    exit_price: Optional[float] = None
    exit_reason: str = ""
    pnl_pips: float = 0.0
    rr_achieved: float = 0.0
    original_sl: float = 0.0        # SL before breakeven
    breakeven_triggered: bool = False


def calculate_sl_tp(m5: pd.DataFrame, signal_idx: int, direction: str,
                     sr_level: float, atr_val: float,
                     next_h1_level: Optional[float] = None,
                     pip_value: float = 0.01) -> Tuple[float, float, bool]:
    """
    Calculate SL and TP.
    Returns (sl, tp, is_valid) where is_valid checks R:R >= MIN_RR_RATIO.
    """
    candle = m5.iloc[signal_idx]
    buffer = SL_BUFFER_PIPS * pip_value

    if direction == "long":
        entry = candle["close"]
        sl = candle["low"] - buffer
        sl_dist = entry - sl

        # Check SL not too wide
        if sl_dist > atr_val * MAX_SL_ATR_MULT:
            return sl, entry, False

        if USE_FIXED_RR_TP:
            tp = entry + sl_dist * MIN_RR_RATIO
        else:
            if next_h1_level and next_h1_level > entry:
                tp = next_h1_level
                if (tp - entry) / sl_dist < MIN_RR_RATIO:
                    tp = entry + sl_dist * MIN_RR_RATIO
            else:
                tp = entry + sl_dist * MIN_RR_RATIO

    else:  # short
        entry = candle["close"]
        sl = candle["high"] + buffer
        sl_dist = sl - entry

        if sl_dist > atr_val * MAX_SL_ATR_MULT:
            return sl, entry, False

        if USE_FIXED_RR_TP:
            tp = entry - sl_dist * MIN_RR_RATIO
        else:
            if next_h1_level and next_h1_level < entry:
                tp = next_h1_level
                if (entry - tp) / sl_dist < MIN_RR_RATIO:
                    tp = entry - sl_dist * MIN_RR_RATIO
            else:
                tp = entry - sl_dist * MIN_RR_RATIO

    is_valid = True
    return sl, tp, is_valid


def find_next_h1_level(levels: List[SRLevel], current_price: float,
                        direction: str) -> Optional[float]:
    """Find the next H1 S/R level in the trade direction."""
    if direction == "long":
        candidates = [l.price for l in levels
                      if l.price > current_price and not l.broken]
        return min(candidates) if candidates else None
    else:
        candidates = [l.price for l in levels
                      if l.price < current_price and not l.broken]
        return max(candidates) if candidates else None


# ═══════════════════════════════════════════════════════════════════════
# 8. Main Simulation Engine
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class SimState:
    """State machine for the simulation."""
    # Active breakout tracking
    active_breakout: bool = False
    breakout_level: Optional[SRLevel] = None
    breakout_direction: str = ""
    breakout_bar: int = -1
    confirm_count: int = 0

    # Pullback tracking
    pullback_started: bool = False
    pullback_bar: int = -1

    # Position
    in_position: bool = False
    current_trade: Optional[Trade] = None

    def reset(self):
        self.active_breakout = False
        self.breakout_level = None
        self.breakout_direction = ""
        self.breakout_bar = -1
        self.confirm_count = 0
        self.pullback_started = False
        self.pullback_bar = -1


def run_simulation(m1_path: str, market: str = "GOLD") -> List[Trade]:
    """
    Run the Role Reversal simulation.

    Flow:
    1. Load M1, resample to M5/M15/H1
    2. Detect H1 S/R levels
    3. For each M5 bar:
       a. Check for breakouts of H1 levels
       b. Track pullbacks to broken levels
       c. Check for Key Reversal + EMA confluence at pullback
       d. Execute trade if all conditions met
       e. Manage open position (SL/TP check)
    """
    # -- Setup market parameters
    global POINT_VALUE, SL_BUFFER_PIPS
    if market == "GOLD":
        POINT_VALUE = 0.01
        SL_BUFFER_PIPS = 50       # 50 points = $0.50
    elif market == "FX":
        POINT_VALUE = 0.001
        SL_BUFFER_PIPS = 5        # 5 pips = 0.005
    elif market == "CRYPTO":
        POINT_VALUE = 0.01
        SL_BUFFER_PIPS = 50

    print(f"Loading M1 data from {m1_path}...")
    m1 = load_m1(m1_path)
    print(f"  M1 bars: {len(m1)}, range: {m1.index[0]} → {m1.index[-1]}")

    # Resample
    m5 = resample_ohlc(m1, "5min")
    m15 = resample_ohlc(m1, "15min")
    h1 = resample_ohlc(m1, "1h")
    print(f"  M5 bars: {len(m5)}, M15 bars: {len(m15)}, H1 bars: {len(h1)}")

    # Calculate indicators
    m5_atr = calc_atr(m5, ATR_PERIOD)
    m5_ema = calc_ema(m5["close"], EMA_PERIOD)
    h1_atr = calc_atr(h1, ATR_PERIOD)
    m15_ema = calc_ema(m15["close"], 50)  # M15 EMA50 for trend

    # Detect H1 S/R levels
    raw_levels = detect_swing_highs_lows(h1, SR_SWING_LOOKBACK)
    avg_h1_atr = h1_atr.mean()
    levels = merge_nearby_levels(raw_levels, avg_h1_atr, SR_MERGE_TOLERANCE_ATR)
    count_touches(levels, h1, h1_atr, SR_MERGE_TOLERANCE_ATR)
    print(f"  H1 S/R levels detected: {len(raw_levels)} raw → {len(levels)} merged")
    for lvl in sorted(levels, key=lambda x: x.price):
        print(f"    {lvl.level_type:12s} @ {lvl.price:.2f}  "
              f"(touches={lvl.touch_count}, bar={lvl.detected_at})")

    # -- Simulation loop
    trades: List[Trade] = []
    state = SimState()
    reject_counts = {
        "time_filter": 0,
        "no_ema_trend": 0,
        "no_ema_support": 0,
        "no_confirm": 0,
        "candle_too_large": 0,
        "rr_invalid": 0,
        "m15_against": 0,
        "pullback_timeout": 0,
    }

    warmup = max(ATR_PERIOD, EMA_PERIOD, KR_LOOKBACK) + 5

    for i in range(warmup, len(m5)):
        bar = m5.iloc[i]
        bar_time = m5.index[i]
        atr_val = m5_atr.iloc[i]

        # -- Manage open position
        if state.in_position and state.current_trade:
            trade = state.current_trade
            # Use original_sl for R:R calculation (immutable reference)
            ref_sl = trade.original_sl if trade.original_sl != 0 else trade.sl

            # -- Breakeven check (before SL/TP evaluation)
            if ENABLE_BREAKEVEN and not trade.breakeven_triggered:
                risk = abs(trade.entry_price - ref_sl)
                if trade.direction == "long":
                    reward = bar["high"] - trade.entry_price  # Intra-bar peak
                else:
                    reward = trade.entry_price - bar["low"]
                if risk > 0 and reward > 0 and (reward / risk) >= BE_RR_THRESHOLD:
                    trade.breakeven_triggered = True
                    trade.sl = trade.entry_price

            if trade.direction == "long":
                # Check SL hit
                if bar["low"] <= trade.sl:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.sl
                    trade.exit_reason = "BE" if trade.breakeven_triggered and trade.sl == trade.entry_price else "SL"
                    trade.pnl_pips = (trade.sl - trade.entry_price) / POINT_VALUE
                    sl_dist = trade.entry_price - ref_sl
                    trade.rr_achieved = (trade.sl - trade.entry_price) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
                # Check TP hit
                if bar["high"] >= trade.tp:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.tp
                    trade.exit_reason = "TP"
                    trade.pnl_pips = (trade.tp - trade.entry_price) / POINT_VALUE
                    sl_dist = trade.entry_price - ref_sl
                    trade.rr_achieved = (trade.tp - trade.entry_price) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
            else:  # short
                if bar["high"] >= trade.sl:
                    trade.exit_time = bar_time
                    trade.exit_price = trade.sl
                    trade.exit_reason = "BE" if trade.breakeven_triggered and trade.sl == trade.entry_price else "SL"
                    trade.pnl_pips = (trade.entry_price - trade.sl) / POINT_VALUE
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
                    trade.pnl_pips = (trade.entry_price - trade.tp) / POINT_VALUE
                    sl_dist = ref_sl - trade.entry_price
                    trade.rr_achieved = (trade.entry_price - trade.tp) / sl_dist if sl_dist > 0 else 0
                    trades.append(trade)
                    state.in_position = False
                    state.current_trade = None
                    state.reset()
                    continue
            continue  # Skip signal detection while in position

        # -- Time filter
        if not is_trading_hour(bar_time):
            if state.active_breakout:
                pass  # Keep tracking breakout but don't enter
            continue

        # -- Check for new breakouts
        if not state.active_breakout:
            h1_idx = find_h1_bar_index(h1, bar_time)
            current_h1_atr = h1_atr.iloc[h1_idx] if h1_idx < len(h1_atr) else avg_h1_atr

            for lvl in levels:
                if lvl.broken or lvl.used:
                    continue
                # Check age
                if h1_idx - lvl.detected_at > SR_MAX_AGE_BARS:
                    continue

                # Check prior bar was on the other side (level crossed)
                prev_close = m5["close"].iloc[i - 1] if i > 0 else bar["close"]

                # Bullish breakout: close crosses above level
                if bar["close"] > lvl.price and prev_close <= lvl.price:
                    # Body must have meaningful size
                    body = abs(bar["close"] - bar["open"])
                    rng = bar["high"] - bar["low"]
                    if rng > 0 and body / rng >= BREAKOUT_BODY_RATIO:
                        # Check M15 trend alignment (soft filter)
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

                # Bearish breakout: close crosses below level
                if bar["close"] < lvl.price and prev_close >= lvl.price:
                    body = abs(bar["close"] - bar["open"])
                    rng = bar["high"] - bar["low"]
                    if rng > 0 and body / rng >= BREAKOUT_BODY_RATIO:
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

        # -- Breakout confirmation (consecutive closes)
        elif state.active_breakout and state.confirm_count < BREAKOUT_CONFIRM_BARS:
            lvl = state.breakout_level
            if state.breakout_direction == "up":
                if bar["close"] > lvl.price:
                    state.confirm_count += 1
                else:
                    # Breakout failed
                    lvl.broken = False
                    state.reset()
            else:
                if bar["close"] < lvl.price:
                    state.confirm_count += 1
                else:
                    lvl.broken = False
                    state.reset()

        # -- Wait for pullback
        elif state.active_breakout and state.confirm_count >= BREAKOUT_CONFIRM_BARS:
            lvl = state.breakout_level
            bars_since_breakout = i - state.breakout_bar

            # Timeout check
            if bars_since_breakout > PULLBACK_MAX_BARS:
                reject_counts["pullback_timeout"] += 1
                lvl.used = True  # Don't re-use this level
                state.reset()
                continue

            # Too early for pullback
            if bars_since_breakout < PULLBACK_MIN_BARS:
                continue

            zone = atr_val * PULLBACK_ZONE_ATR
            price_at_level = False

            if state.breakout_direction == "up":
                # Price pulled back to level from above
                if bar["low"] <= lvl.price + zone and bar["close"] >= lvl.price - zone * 0.5:
                    price_at_level = True
            else:
                # Price pulled back to level from below
                if bar["high"] >= lvl.price - zone and bar["close"] <= lvl.price + zone * 0.5:
                    price_at_level = True

            if not price_at_level:
                # Check if price has gone too far against breakout (full retracement)
                if state.breakout_direction == "up" and bar["close"] < lvl.price - zone * 2:
                    lvl.used = True
                    state.reset()
                elif state.breakout_direction == "down" and bar["close"] > lvl.price + zone * 2:
                    lvl.used = True
                    state.reset()
                continue

            # Price is at the role reversal zone — check confluence
            trade_direction = "long" if state.breakout_direction == "up" else "short"

            # (A) EMA trend check
            if not check_ema_trend(m5_ema, i, state.breakout_direction, lookback=EMA_TREND_LOOKBACK):
                reject_counts["no_ema_trend"] += 1
                continue

            # (B) EMA support/resistance check
            if not check_ema_support(m5, m5_ema, i, state.breakout_direction,
                                      tolerance_atr=0.5, atr_val=atr_val):
                reject_counts["no_ema_support"] += 1
                continue

            # (C) Confirm pattern check (Key Reversal, Engulfing, or Pin Bar)
            if trade_direction == "long":
                confirm = check_bullish_confirm(m5, i)
            else:
                confirm = check_bearish_confirm(m5, i)

            if not confirm:
                reject_counts["no_confirm"] += 1
                continue

            # (D) Calculate SL/TP and check R:R
            next_level = find_next_h1_level(levels, bar["close"], trade_direction)
            sl, tp, is_valid = calculate_sl_tp(
                m5, i, trade_direction, lvl.price, atr_val,
                next_level, POINT_VALUE
            )
            if not is_valid:
                reject_counts["candle_too_large"] += 1
                continue

            # All conditions met → ENTER
            entry_price = bar["close"]
            trade = Trade(
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

    # Close any remaining open position at last bar
    if state.in_position and state.current_trade:
        trade = state.current_trade
        last_bar = m5.iloc[-1]
        trade.exit_time = m5.index[-1]
        trade.exit_price = last_bar["close"]
        trade.exit_reason = "END_OF_DATA"
        if trade.direction == "long":
            trade.pnl_pips = (last_bar["close"] - trade.entry_price) / POINT_VALUE
        else:
            trade.pnl_pips = (trade.entry_price - last_bar["close"]) / POINT_VALUE
        trades.append(trade)

    # -- Print results
    print("\n" + "=" * 70)
    print("SIMULATION RESULTS: 5M Role Reversal + MTF Analysis")
    print("=" * 70)
    print(f"\nReject Counts:")
    for reason, count in sorted(reject_counts.items(), key=lambda x: -x[1]):
        print(f"  {reason:25s}: {count}")

    if not trades:
        print("\nNo trades generated.")
        return trades

    # Stats
    wins = [t for t in trades if t.pnl_pips > 0 and t.exit_reason != "END_OF_DATA"]
    losses = [t for t in trades if t.pnl_pips <= 0 and t.exit_reason != "END_OF_DATA"]
    closed_trades = [t for t in trades if t.exit_reason != "END_OF_DATA"]

    total = len(closed_trades)
    win_count = len(wins)
    loss_count = len(losses)
    win_rate = win_count / total * 100 if total > 0 else 0

    total_pnl = sum(t.pnl_pips for t in closed_trades)
    avg_win = np.mean([t.pnl_pips for t in wins]) if wins else 0
    avg_loss = np.mean([t.pnl_pips for t in losses]) if losses else 0
    gross_profit = sum(t.pnl_pips for t in wins) if wins else 0
    gross_loss = abs(sum(t.pnl_pips for t in losses)) if losses else 0
    pf = gross_profit / gross_loss if gross_loss > 0 else float("inf")

    avg_rr = np.mean([t.rr_achieved for t in wins]) if wins else 0
    max_dd_pips = 0
    running_pnl = 0
    peak_pnl = 0
    for t in closed_trades:
        running_pnl += t.pnl_pips
        peak_pnl = max(peak_pnl, running_pnl)
        dd = peak_pnl - running_pnl
        max_dd_pips = max(max_dd_pips, dd)

    print(f"\n{'Metric':<30s} {'Value':>15s}")
    print("-" * 47)
    print(f"{'Total Trades':<30s} {total:>15d}")
    print(f"{'Wins':<30s} {win_count:>15d}")
    print(f"{'Losses':<30s} {loss_count:>15d}")
    print(f"{'Win Rate':<30s} {win_rate:>14.1f}%")
    print(f"{'Profit Factor':<30s} {pf:>15.2f}")
    print(f"{'Total PnL (pips)':<30s} {total_pnl:>15.1f}")
    print(f"{'Avg Win (pips)':<30s} {avg_win:>15.1f}")
    print(f"{'Avg Loss (pips)':<30s} {avg_loss:>15.1f}")
    print(f"{'Avg R:R (wins)':<30s} {avg_rr:>15.2f}")
    print(f"{'Max Drawdown (pips)':<30s} {max_dd_pips:>15.1f}")

    # Breakeven stats
    be_trades = [t for t in closed_trades if t.breakeven_triggered]
    be_exits = [t for t in closed_trades if t.exit_reason == "BE"]
    if ENABLE_BREAKEVEN:
        print(f"\n{'--- Breakeven Stats ---':<30s}")
        print(f"{'BE Triggered':<30s} {len(be_trades):>15d}")
        print(f"{'BE Exit (SL=Entry)':<30s} {len(be_exits):>15d}")
        be_then_tp = [t for t in be_trades if t.exit_reason == "TP"]
        print(f"{'BE → TP':<30s} {len(be_then_tp):>15d}")
        # Losses saved by BE (trades that would have hit original SL)
        be_saved_pnl = sum(
            abs(t.entry_price - t.original_sl) / POINT_VALUE
            for t in be_exits
        )
        print(f"{'Loss Saved by BE (pips)':<30s} {be_saved_pnl:>15.1f}")

    # Confirm pattern breakdown
    pattern_stats = {}
    for t in closed_trades:
        p = t.confirm_pattern or "Unknown"
        if p not in pattern_stats:
            pattern_stats[p] = {"wins": 0, "losses": 0}
        if t.pnl_pips > 0:
            pattern_stats[p]["wins"] += 1
        else:
            pattern_stats[p]["losses"] += 1
    if pattern_stats:
        print(f"\nConfirm Pattern Breakdown:")
        for p, s in pattern_stats.items():
            t = s["wins"] + s["losses"]
            wr = s["wins"] / t * 100 if t > 0 else 0
            print(f"  {p:15s}: {t:3d} trades, WR={wr:.0f}%")

    # Trade list
    fmt = "GOLD" if market in ("GOLD", "CRYPTO") else "FX"
    dp = 2 if fmt == "GOLD" else 3
    print(f"\n{'#':>3} {'Entry Time':>20} {'Dir':>5} {'Entry':>10} "
          f"{'SL':>10} {'TP':>10} {'Exit':>10} {'PnL':>8} {'R:R':>6} "
          f"{'Pattern':>12} {'Reason':>10}")
    print("-" * 120)
    for idx, t in enumerate(trades, 1):
        entry_str = f"{t.entry_price:.{dp}f}"
        sl_str = f"{t.sl:.{dp}f}"
        tp_str = f"{t.tp:.{dp}f}"
        exit_str = f"{t.exit_price:.{dp}f}" if t.exit_price else "---"
        print(f"{idx:>3} {str(t.entry_time):>20} {t.direction:>5} {entry_str:>10} "
              f"{sl_str:>10} {tp_str:>10} {exit_str:>10} {t.pnl_pips:>8.1f} "
              f"{t.rr_achieved:>6.2f} {t.confirm_pattern:>12} {t.exit_reason:>10}")

    # Save results
    results_data = []
    for t in trades:
        results_data.append({
            "entry_time": t.entry_time,
            "direction": t.direction,
            "entry_price": t.entry_price,
            "original_sl": t.original_sl,
            "sl": t.sl,
            "tp": t.tp,
            "sr_level": t.sr_level,
            "exit_time": t.exit_time,
            "exit_price": t.exit_price,
            "exit_reason": t.exit_reason,
            "pnl_pips": t.pnl_pips,
            "rr_achieved": t.rr_achieved,
            "confirm_pattern": t.confirm_pattern,
            "breakeven_triggered": t.breakeven_triggered,
        })
    results_df = pd.DataFrame(results_data)
    out_path = os.path.join("sim_dat", f"sim_results_role_reversal_{market.lower()}.csv")
    results_df.to_csv(out_path, index=False)
    print(f"\nResults saved to {out_path}")

    return trades


# ═══════════════════════════════════════════════════════════════════════
# 9. Parameter Sweep
# ═══════════════════════════════════════════════════════════════════════

def run_param_sweep(m1_path: str, market: str = "GOLD"):
    """Run parameter sweep to find optimal settings."""
    global SR_SWING_LOOKBACK, PULLBACK_ZONE_ATR, KR_LOOKBACK
    global EMA_PERIOD, MIN_RR_RATIO, PULLBACK_MAX_BARS, KR_BODY_MIN_RATIO
    global EMA_TREND_LOOKBACK

    sweep_results = []

    # Key parameters to sweep
    swing_lookbacks = [3, 5, 7]
    pullback_zones = [0.3, 0.5, 0.7]
    ema_trend_lookbacks = [2, 3, 5]
    kr_body_ratios = [0.2, 0.3, 0.4]

    total_combos = (len(swing_lookbacks) * len(pullback_zones) *
                    len(ema_trend_lookbacks) * len(kr_body_ratios))
    combo = 0

    for sl_lb in swing_lookbacks:
        for pz in pullback_zones:
            for etl in ema_trend_lookbacks:
                for kr_br in kr_body_ratios:
                    combo += 1
                    SR_SWING_LOOKBACK = sl_lb
                    PULLBACK_ZONE_ATR = pz
                    EMA_TREND_LOOKBACK = etl
                    KR_BODY_MIN_RATIO = kr_br

                    # Suppress output during sweep
                    import io
                    old_stdout = sys.stdout
                    sys.stdout = io.StringIO()

                    try:
                        trades = run_simulation(m1_path, market)
                    except Exception as e:
                        sys.stdout = old_stdout
                        print(f"  [{combo}/{total_combos}] ERROR: {e}")
                        continue
                    finally:
                        sys.stdout = old_stdout

                    closed = [t for t in trades if t.exit_reason != "END_OF_DATA"]
                    total = len(closed)
                    wins = len([t for t in closed if t.pnl_pips > 0])
                    wr = wins / total * 100 if total > 0 else 0
                    total_pnl = sum(t.pnl_pips for t in closed)
                    gp = sum(t.pnl_pips for t in closed if t.pnl_pips > 0)
                    gl = abs(sum(t.pnl_pips for t in closed if t.pnl_pips <= 0))
                    pf = gp / gl if gl > 0 else 0

                    result = {
                        "swing_lb": sl_lb,
                        "pullback_zone": pz,
                        "ema_trend_lb": etl,
                        "kr_body_ratio": kr_br,
                        "trades": total,
                        "wins": wins,
                        "win_rate": wr,
                        "total_pnl": total_pnl,
                        "profit_factor": pf,
                    }
                    sweep_results.append(result)
                    print(f"  [{combo}/{total_combos}] SL={sl_lb} PZ={pz:.1f} "
                          f"ETL={etl} KR={kr_br:.1f} → "
                          f"T={total} W={wr:.0f}% PF={pf:.2f} PnL={total_pnl:.0f}")

    # Sort by profit factor (with minimum trade count filter)
    min_trades = 5
    valid = [r for r in sweep_results if r["trades"] >= min_trades]
    valid.sort(key=lambda x: x["profit_factor"], reverse=True)

    print("\n" + "=" * 70)
    print("TOP 10 PARAMETER COMBINATIONS")
    print("=" * 70)
    for idx, r in enumerate(valid[:10], 1):
        print(f"{idx:>2}. SL={r['swing_lb']} PZ={r['pullback_zone']:.1f} "
              f"ETL={r['ema_trend_lb']} KR={r['kr_body_ratio']:.1f} | "
              f"Trades={r['trades']} WR={r['win_rate']:.0f}% "
              f"PF={r['profit_factor']:.2f} PnL={r['total_pnl']:.0f}")

    # Save sweep results
    sweep_df = pd.DataFrame(sweep_results)
    out_path = os.path.join("sim_dat", f"sim_sweep_role_reversal_{market.lower()}.csv")
    sweep_df.to_csv(out_path, index=False)
    print(f"\nSweep results saved to {out_path}")

    return sweep_results


# ═══════════════════════════════════════════════════════════════════════
# 10. Main
# ═══════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(
        description="5M Role Reversal + MTF Analysis Simulation")
    parser.add_argument("--market", default="GOLD",
                        choices=["GOLD", "FX", "CRYPTO"],
                        help="Market to simulate")
    parser.add_argument("--sweep", action="store_true",
                        help="Run parameter sweep")
    parser.add_argument("--data", type=str, default=None,
                        help="Path to M1 CSV data file")
    parser.add_argument("--no-breakeven", action="store_true",
                        help="Disable breakeven logic (baseline)")
    parser.add_argument("--be-threshold", type=float, default=None,
                        help="Breakeven R:R threshold (overrides BE_RR_THRESHOLD)")
    args = parser.parse_args()

    # Apply breakeven CLI overrides
    if args.no_breakeven:
        ENABLE_BREAKEVEN = False
    if args.be_threshold is not None:
        ENABLE_BREAKEVEN = True
        BE_RR_THRESHOLD = args.be_threshold

    # Default data paths
    data_paths = {
        "GOLD": os.path.join("sim_dat",
                             "GOLD#_M1_202509010100_202511282139.csv"),
        "FX": os.path.join("sim_dat",
                           "USDJPY#_M1_202512010000_202602270000.csv"),
        "CRYPTO": os.path.join("sim_dat",
                               "BTCUSD#_M1_202512010000_202602270000.csv"),
    }
    data_path = args.data or data_paths.get(args.market)

    if not os.path.exists(data_path):
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    if args.sweep:
        run_param_sweep(data_path, args.market)
    else:
        run_simulation(data_path, args.market)
