"""
sim_crypto.py  –  CRYPTO Impulse-Retrace simulation (DOC-CORE CRYPTO spec)
==========================================================================
CRYPTO-specific parameters (DOC-CORE §10):
  - ImpulseATRMult=2.0, SmallBodyRatio=0.45
  - Freeze Level2, CancelWindowBars=1, Cancel=0.1% update
  - BandWidthPts = ATR(M1) × 0.08
  - RetraceBand: 50–61.8 (always ON, single band)
  - LeaveDistanceMult=1.2, RetouchTimeLimitBars=25, ConfirmTimeLimitBars=4
  - Confirm: MicroBreak only (Lookback=3, swing extraction)
  - Trend: EMA21+EMA50 cross + EMA50 slope on M15
  - SLATRMult=0.7, TimeExitBars=6

Dependencies: pandas, numpy
"""

import os
import sys
import numpy as np
import pandas as pd
from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional

# ═══════════════════════════════════════════════════════════════════════
# 0. CRYPTO Parameters (DOC-CORE §10)
# ═══════════════════════════════════════════════════════════════════════

# -- Impulse detection
IMPULSE_ATR_PERIOD = 14
IMPULSE_ATR_MULT = 2.0            # CRYPTO: 2.0 (vs FX 1.6)
SMALL_BODY_RATIO = 0.45           # CRYPTO: 0.45 (vs FX 0.35)
CANCEL_WINDOW_BARS = 1            # CRYPTO: 1 (vs FX 2)
FREEZE_CANCEL_PCT = 0.001         # CRYPTO: 0.1% update cancels freeze

# -- Fib / Band  (50–61.8 as single band)
FIB_50 = 0.50
FIB_618 = 0.618
BAND_ATR_MULT = 0.08              # BandWidthPts = ATR(M1) × 0.08

# -- Touch / Leave / ReTouch
LEAVE_DIST_MULT = 1.2             # CRYPTO: 1.2 (vs FX 1.5)
LEAVE_MIN_BARS = 1
RETOUCH_TIME_LIMIT_BARS = 25      # CRYPTO: 25 (vs FX 35)
CONFIRM_TIME_LIMIT_BARS = 4       # CRYPTO: 4 (vs FX 6)

# -- Confirm: MicroBreak only (Lookback extraction, L=3)
LOOKBACK_MICRO_BARS = 3

# -- Risk / SL
SL_ATR_MULT = 0.7
TP_EXT_RATIO = 0.382
MIN_RANGE_COST_MULT = 2.0         # CRYPTO: 2.0 (vs FX 2.5)

# -- Exit (EMA cross on M1, DOC-CORE §9.2)
EXIT_MA_FAST = 13
EXIT_MA_SLOW = 21
EXIT_CONFIRM_BARS = 1
TIME_EXIT_BARS = 6                # CRYPTO: 6 (vs FX 10)

# -- M15 Trend filter (EMA21 + EMA50)
M15_EMA21_PERIOD = 21
M15_EMA50_PERIOD = 50
M15_SLOPE_MIN_ATR_RATIO = 0.01

# -- M5 slope filter (same structure as FX for comparison)
M5_MA_PERIOD = 21
M5_SLOPE_LOOKBACK = 3
M5_FLAT_THRESHOLD = 0.03
M5_STRONG_THRESHOLD = 0.06


def point() -> float:
    """BTCUSD point size (0.01 for 2-digit broker)."""
    return 0.01

# ═══════════════════════════════════════════════════════════════════════
# 1. Data loading / resampling
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
    df["spread"] = df["spread"].astype(float)
    return df


def resample_ohlc(m1: pd.DataFrame, rule: str) -> pd.DataFrame:
    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "spread": "mean",
    }
    return m1.resample(rule).agg(agg).dropna(subset=["open"])

# ═══════════════════════════════════════════════════════════════════════
# 2. Technical helpers
# ═══════════════════════════════════════════════════════════════════════

def atr_series(df: pd.DataFrame, period: int = 14) -> pd.Series:
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


def ema_series(s: pd.Series, period: int) -> pd.Series:
    return s.ewm(span=period, adjust=False).mean()


def sma_series(s: pd.Series, period: int) -> pd.Series:
    return s.rolling(period).mean()

# ═══════════════════════════════════════════════════════════════════════
# 3. Impulse detection (CRYPTO spec)
# ═══════════════════════════════════════════════════════════════════════

class Dir(Enum):
    LONG = auto()
    SHORT = auto()


@dataclass
class Impulse:
    bar_idx: int
    direction: Dir
    start_price: float           # Fib 0
    end_price: float             # Fib 100
    atr_at_impulse: float
    freeze_bar: Optional[int] = None
    freeze_end: Optional[float] = None
    cancelled: bool = False
    # band info
    band_width: float = 0.0
    band_upper: float = 0.0      # top of 50–61.8 band + BandWidth
    band_lower: float = 0.0      # bottom of 50–61.8 band - BandWidth
    fib50: float = 0.0
    fib618: float = 0.0
    range_pts: float = 0.0
    spread_at_freeze: float = 0.0


def detect_impulses(m1: pd.DataFrame, m1_atr: pd.Series) -> list[Impulse]:
    opens = m1["open"].values
    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values
    atr_vals = m1_atr.values

    impulses: list[Impulse] = []

    for i in range(1, len(m1)):
        a = atr_vals[i]
        if np.isnan(a) or a <= 0:
            continue

        body = abs(closes[i] - opens[i])
        if body < a * IMPULSE_ATR_MULT:
            continue

        d = Dir.LONG if closes[i] > opens[i] else Dir.SHORT

        # Origin correction (DOC-CORE §2.1)
        start_adjusted = False
        if i >= 2:
            prev_body = abs(closes[i - 1] - opens[i - 1])
            prev_opposite = ((d == Dir.LONG and closes[i - 1] < opens[i - 1]) or
                             (d == Dir.SHORT and closes[i - 1] > opens[i - 1]))
            if prev_opposite and prev_body <= a * SMALL_BODY_RATIO:
                start_adjusted = True

        if d == Dir.LONG:
            start_p = min(lows[i], lows[i - 1]) if start_adjusted else lows[i]
            end_p = highs[i]
        else:
            start_p = max(highs[i], highs[i - 1]) if start_adjusted else highs[i]
            end_p = lows[i]

        impulses.append(Impulse(
            bar_idx=i, direction=d,
            start_price=start_p, end_price=end_p,
            atr_at_impulse=a,
        ))

    return impulses

# ═══════════════════════════════════════════════════════════════════════
# 4. State machine: Freeze → Fib → Touch → Leave → ReTouch → Confirm
# ═══════════════════════════════════════════════════════════════════════

class SimState(Enum):
    IMPULSE_FOUND = auto()
    WAIT_FREEZE = auto()
    FIB_ACTIVE = auto()
    TOUCH_1 = auto()
    LEAVE_WAIT = auto()
    TOUCH_2_WAIT_CONFIRM = auto()
    ENTRY = auto()
    DONE = auto()


@dataclass
class TradeResult:
    impulse: Impulse
    # filter results
    baseline_pass: bool = False    # M15 EMA50 slope only
    base_pass: bool = False        # M15 EMA21×EMA50 cross + slope
    loose_pass: bool = False       # M15 counter only + M5 dir match
    baseline_reason: str = ""
    base_reason: str = ""
    loose_reason: str = ""
    # entry/exit
    entry_bar: Optional[int] = None
    entry_price: float = 0.0
    sl_price: float = 0.0
    direction: Optional[Dir] = None
    confirm_type: str = ""
    exit_bar: Optional[int] = None
    exit_price: float = 0.0
    exit_reason: str = ""
    pnl_pips: float = 0.0
    hold_bars: int = 0
    reject_stage: str = ""
    # timing
    freeze_time: str = ""
    impulse_time: str = ""


def _check_microbreak_crypto(m1_h, m1_l, m1_c, i: int, d: Dir) -> bool:
    """CRYPTO MicroBreak: Lookback extraction (DOC-CORE §7.2C CRYPTO)."""
    if i < LOOKBACK_MICRO_BARS:
        return False
    # MicroHigh = max of last 3 bars' High
    micro_high = max(m1_h[i - k] for k in range(1, LOOKBACK_MICRO_BARS + 1) if i - k >= 0)
    # MicroLow = min of last 3 bars' Low
    micro_low = min(m1_l[i - k] for k in range(1, LOOKBACK_MICRO_BARS + 1) if i - k >= 0)

    if d == Dir.LONG:
        return m1_c[i] > micro_high
    else:
        return m1_c[i] < micro_low


def run_entry_logic(imp: Impulse, m1: pd.DataFrame, m1_atr: pd.Series,
                    retouch_limit: int = RETOUCH_TIME_LIMIT_BARS,
                    band_mode: str = "50_618",
                    atr_retrace_mult: float = 0.0) -> TradeResult:
    """CRYPTO state machine.
    band_mode: '50_618' | '50_only' | 'atr_retrace'
    atr_retrace_mult: used when band_mode='atr_retrace' — band center = frozen_end ± ATR×mult
    """
    result = TradeResult(impulse=imp, direction=imp.direction)
    result.impulse_time = str(m1.index[imp.bar_idx])

    opens = m1["open"].values
    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values
    atr_vals = m1_atr.values
    spreads = m1["spread"].values
    n = len(m1)
    d = imp.direction

    # ── Freeze detection (Level2: update stop + opposite color) ──
    frozen_end = imp.end_price
    freeze_bar = None

    for i in range(imp.bar_idx + 1, min(imp.bar_idx + 200, n)):
        if d == Dir.LONG:
            if highs[i] > frozen_end:
                frozen_end = highs[i]
        else:
            if lows[i] < frozen_end:
                frozen_end = lows[i]

        update_stop = ((d == Dir.LONG and highs[i] <= frozen_end) or
                       (d == Dir.SHORT and lows[i] >= frozen_end))
        opposite_color = ((d == Dir.LONG and closes[i] < opens[i]) or
                          (d == Dir.SHORT and closes[i] > opens[i]))

        if update_stop and opposite_color:
            freeze_bar = i
            break

    if freeze_bar is None:
        result.reject_stage = "NO_FREEZE"
        return result

    # ── Freeze cancel: 0.1% update within CancelWindowBars ──
    cancelled = False
    cancel_threshold = frozen_end * FREEZE_CANCEL_PCT
    for j in range(freeze_bar + 1, min(freeze_bar + CANCEL_WINDOW_BARS + 1, n)):
        if d == Dir.LONG and highs[j] > frozen_end + cancel_threshold:
            cancelled = True
            break
        if d == Dir.SHORT and lows[j] < frozen_end - cancel_threshold:
            cancelled = True
            break

    if cancelled:
        result.reject_stage = "FREEZE_CANCEL"
        return result

    # ── Set Fib levels (50–61.8 band) ──
    imp.freeze_bar = freeze_bar
    imp.freeze_end = frozen_end
    imp.end_price = frozen_end
    result.freeze_time = str(m1.index[freeze_bar])

    range_price = abs(frozen_end - imp.start_price)
    imp.range_pts = range_price / point()

    sp = spreads[freeze_bar] if freeze_bar < n else spreads[-1]
    imp.spread_at_freeze = sp

    # BandWidthPts = ATR(M1) × 0.08 at freeze
    atr_at_freeze = atr_vals[freeze_bar] if not np.isnan(atr_vals[freeze_bar]) else imp.atr_at_impulse
    band_width_price = atr_at_freeze * BAND_ATR_MULT
    imp.band_width = band_width_price

    # ── Band position (mode-dependent) ──
    if band_mode == "atr_retrace":
        # ATR-based: band center = frozen_end ± ATR × mult (retrace direction)
        retrace_dist = atr_at_freeze * atr_retrace_mult
        if d == Dir.LONG:
            band_center = frozen_end - retrace_dist
        else:
            band_center = frozen_end + retrace_dist
        imp.band_upper = band_center + band_width_price
        imp.band_lower = band_center - band_width_price
        imp.fib50 = band_center   # store center for reference
        imp.fib618 = 0.0
    else:
        # Fib-based
        if d == Dir.LONG:
            fib50 = frozen_end - range_price * FIB_50
            fib618 = frozen_end - range_price * FIB_618
            if band_mode == "50_only":
                imp.band_upper = fib50 + band_width_price
                imp.band_lower = fib50 - band_width_price
            else:  # 50_618
                imp.band_upper = fib50 + band_width_price
                imp.band_lower = fib618 - band_width_price
        else:
            fib50 = frozen_end + range_price * FIB_50
            fib618 = frozen_end + range_price * FIB_618
            if band_mode == "50_only":
                imp.band_upper = fib50 + band_width_price
                imp.band_lower = fib50 - band_width_price
            else:  # 50_618
                imp.band_upper = fib618 + band_width_price
                imp.band_lower = fib50 - band_width_price
        imp.fib50 = fib50
        imp.fib618 = fib618

    # ── RiskGate (simplified) ──
    band_total = imp.band_upper - imp.band_lower
    band_dom_ratio = band_total / range_price if range_price > 0 else 999
    if band_dom_ratio >= 0.85:
        result.reject_stage = "RISK_GATE_BAND_DOM"
        return result

    # ── Touch / Leave / ReTouch / Confirm ──
    state = SimState.FIB_ACTIVE
    touch1_bar = None
    leave_bar = None
    touch2_bar = None
    confirm_deadline = None
    retouch_deadline = freeze_bar + CANCEL_WINDOW_BARS + retouch_limit

    bu = imp.band_upper
    bl = imp.band_lower
    leave_dist = band_width_price * LEAVE_DIST_MULT

    search_start = freeze_bar + CANCEL_WINDOW_BARS + 1
    search_end = min(search_start + retouch_limit + CONFIRM_TIME_LIMIT_BARS + 10, n)

    for i in range(search_start, search_end):
        if i >= retouch_deadline and state != SimState.TOUCH_2_WAIT_CONFIRM:
            result.reject_stage = "RETOUCH_TIMEOUT"
            return result

        # Structure break: price beyond 0/100
        if d == Dir.LONG and closes[i] < imp.start_price:
            result.reject_stage = "STRUCTURE_BREAK"
            return result
        if d == Dir.SHORT and closes[i] > imp.start_price:
            result.reject_stage = "STRUCTURE_BREAK"
            return result

        # 78.6 invalidation (CRYPTO: close beyond 78.6)
        fib786_price = (frozen_end - range_price * 0.786) if d == Dir.LONG else (frozen_end + range_price * 0.786)
        if d == Dir.LONG and closes[i] < fib786_price:
            result.reject_stage = "FIB786_BREAK"
            return result
        if d == Dir.SHORT and closes[i] > fib786_price:
            result.reject_stage = "FIB786_BREAK"
            return result

        if state == SimState.FIB_ACTIVE:
            touched = ((d == Dir.LONG and lows[i] <= bu) or
                       (d == Dir.SHORT and highs[i] >= bl))
            if touched:
                touch1_bar = i
                state = SimState.TOUCH_1

        elif state == SimState.TOUCH_1:
            # Leave check
            if d == Dir.LONG:
                if closes[i] > bu + leave_dist:
                    if leave_bar is None:
                        leave_bar = i
                    if i - leave_bar >= LEAVE_MIN_BARS:
                        state = SimState.LEAVE_WAIT
                else:
                    leave_bar = None
            else:
                if closes[i] < bl - leave_dist:
                    if leave_bar is None:
                        leave_bar = i
                    if i - leave_bar >= LEAVE_MIN_BARS:
                        state = SimState.LEAVE_WAIT
                else:
                    leave_bar = None

        elif state == SimState.LEAVE_WAIT:
            retouched = ((d == Dir.LONG and lows[i] <= bu) or
                         (d == Dir.SHORT and highs[i] >= bl))
            if retouched:
                touch2_bar = i
                confirm_deadline = i + CONFIRM_TIME_LIMIT_BARS
                state = SimState.TOUCH_2_WAIT_CONFIRM

        elif state == SimState.TOUCH_2_WAIT_CONFIRM:
            if i > confirm_deadline:
                result.reject_stage = "NO_CONFIRM"
                return result
            if i >= retouch_deadline:
                result.reject_stage = "RETOUCH_TIMEOUT"
                return result

            # CRYPTO: MicroBreak only
            if _check_microbreak_crypto(highs, lows, closes, i, d):
                result.entry_bar = i
                result.confirm_type = "MicroBreak"
                break

    if result.entry_bar is None:
        if result.reject_stage == "":
            result.reject_stage = "NO_CONFIRM"
        return result

    # ── Entry price & SL ──
    eb = result.entry_bar
    result.entry_price = closes[eb]
    atr_at_entry = atr_vals[eb] if not np.isnan(atr_vals[eb]) else imp.atr_at_impulse
    if d == Dir.LONG:
        result.sl_price = imp.start_price - atr_at_entry * SL_ATR_MULT
    else:
        result.sl_price = imp.start_price + atr_at_entry * SL_ATR_MULT

    return result

# ═══════════════════════════════════════════════════════════════════════
# 5. Filter evaluation (CRYPTO trend: EMA21×EMA50)
# ═══════════════════════════════════════════════════════════════════════

def _m15_trend_crypto(m15_ema21: pd.Series, m15_ema50: pd.Series,
                      m15_atr: pd.Series, ts: pd.Timestamp) -> tuple[str, float]:
    """CRYPTO trend: EMA21>EMA50 + EMA50 slope (DOC-CORE §7.0.5)."""
    loc = m15_ema50.index.get_indexer([ts], method="ffill")[0]
    if loc < 1 or np.isnan(m15_atr.iloc[loc]):
        return "FLAT", 0.0
    e21 = m15_ema21.iloc[loc]
    e50 = m15_ema50.iloc[loc]
    slope = m15_ema50.iloc[loc] - m15_ema50.iloc[loc - 1]
    a = m15_atr.iloc[loc]
    if a <= 0:
        return "FLAT", 0.0
    slope_ratio = slope / a

    if e21 > e50 and slope_ratio >= M15_SLOPE_MIN_ATR_RATIO:
        return "LONG", slope_ratio
    elif e21 < e50 and slope_ratio <= -M15_SLOPE_MIN_ATR_RATIO:
        return "SHORT", slope_ratio
    else:
        return "FLAT", slope_ratio


def _m15_slope_only(m15_ema50: pd.Series, m15_atr: pd.Series,
                    ts: pd.Timestamp) -> tuple[str, float]:
    """Baseline: M15 EMA50 slope only."""
    loc = m15_ema50.index.get_indexer([ts], method="ffill")[0]
    if loc < 1 or np.isnan(m15_atr.iloc[loc]):
        return "FLAT", 0.0
    slope = m15_ema50.iloc[loc] - m15_ema50.iloc[loc - 1]
    a = m15_atr.iloc[loc]
    if a <= 0:
        return "FLAT", 0.0
    r = slope / a
    if r > 0.01:
        return "LONG", r
    elif r < -0.01:
        return "SHORT", r
    return "FLAT", r


def _m5_slope_eval(m5_sma: pd.Series, m5_atr: pd.Series,
                   ts: pd.Timestamp) -> tuple[str, str, float]:
    loc = m5_sma.index.get_indexer([ts], method="ffill")[0]
    if loc < M5_SLOPE_LOOKBACK or np.isnan(m5_atr.iloc[loc]):
        return "FLAT", "FLAT", 0.0
    slope = m5_sma.iloc[loc] - m5_sma.iloc[loc - M5_SLOPE_LOOKBACK]
    a = m5_atr.iloc[loc]
    if a <= 0:
        return "FLAT", "FLAT", 0.0
    ratio = abs(slope / a)
    direction = "LONG" if slope > 0 else ("SHORT" if slope < 0 else "FLAT")
    if direction == "FLAT":
        return "FLAT", "FLAT", 0.0
    if ratio < M5_FLAT_THRESHOLD:
        strength = "FLAT"
    elif ratio < M5_STRONG_THRESHOLD:
        strength = "MID"
    else:
        strength = "STRONG"
    return direction, strength, ratio


def evaluate_filters(result: TradeResult,
                     m1: pd.DataFrame,
                     m15_ema21: pd.Series, m15_ema50: pd.Series, m15_atr: pd.Series,
                     m5_sma: pd.Series, m5_atr: pd.Series):
    d = result.impulse.direction
    impulse_ts = m1.index[result.impulse.bar_idx]
    dir_str = "LONG" if d == Dir.LONG else "SHORT"

    # M15 evaluations
    m15_dir_baseline, _ = _m15_slope_only(m15_ema50, m15_atr, impulse_ts)
    m15_dir_crypto, _ = _m15_trend_crypto(m15_ema21, m15_ema50, m15_atr, impulse_ts)

    # M5 evaluation
    eval_ts = m1.index[result.entry_bar] if result.entry_bar is not None else impulse_ts
    m5_dir, m5_strength, _ = _m5_slope_eval(m5_sma, m5_atr, eval_ts)

    # ═══ Baseline: M15 EMA50 slope only ═══
    if m15_dir_baseline == "FLAT":
        result.baseline_pass = False
        result.baseline_reason = "M15_FLAT"
    elif m15_dir_baseline != dir_str:
        result.baseline_pass = False
        result.baseline_reason = "M15_COUNTER"
    else:
        result.baseline_pass = True
        result.baseline_reason = "PASS"

    # ═══ Base: CRYPTO spec (EMA21×EMA50 cross + slope) ═══
    if m15_dir_crypto == "FLAT":
        result.base_pass = False
        result.base_reason = "M15_FLAT"
    elif m15_dir_crypto != dir_str:
        result.base_pass = False
        result.base_reason = "M15_COUNTER"
    else:
        result.base_pass = True
        result.base_reason = "PASS"

    # ═══ Loose: M15 counter only + M5 dir match ═══
    if m15_dir_crypto != "FLAT" and m15_dir_crypto != dir_str:
        result.loose_pass = False
        result.loose_reason = "M15_COUNTER"
    elif m5_dir != dir_str:
        result.loose_pass = False
        result.loose_reason = f"M5_DIR_MISMATCH({m5_dir})"
    else:
        result.loose_pass = True
        result.loose_reason = "PASS"

# ═══════════════════════════════════════════════════════════════════════
# 6. Exit simulation (EMA cross on M1 + StructBreak + TimeExit)
# ═══════════════════════════════════════════════════════════════════════

def simulate_exit(result: TradeResult, m1: pd.DataFrame, m1_atr: pd.Series,
                  time_exit_bars: int = TIME_EXIT_BARS):
    """DOC-CORE §9.2: StructBreak(Fib0) > TimeExit > Breakeven > EMACross."""
    if result.entry_bar is None:
        return

    d = result.direction
    entry_price = result.entry_price
    sl_price = result.sl_price

    opens = m1["open"].values
    closes = m1["close"].values
    highs = m1["high"].values
    lows = m1["low"].values
    atr_vals = m1_atr.values
    n = len(m1)

    # EMA for exit
    ema_fast = ema_series(pd.Series(closes, index=m1.index), EXIT_MA_FAST).values
    ema_slow = ema_series(pd.Series(closes, index=m1.index), EXIT_MA_SLOW).values

    start = result.entry_bar + 1
    fib0 = result.impulse.start_price
    breakeven_done = False
    exit_pending = False
    exit_pending_bars = 0

    for i in range(start, min(start + 500, n)):
        # ── SL check ──
        if d == Dir.LONG and lows[i] <= sl_price:
            result.exit_bar = i
            result.exit_price = sl_price
            result.exit_reason = "SL_Hit"
            break
        if d == Dir.SHORT and highs[i] >= sl_price:
            result.exit_bar = i
            result.exit_price = sl_price
            result.exit_reason = "SL_Hit"
            break

        c = closes[i]

        # ── 1) StructBreak (Fib0) ──
        if d == Dir.LONG and c < fib0:
            result.exit_bar = i
            result.exit_price = c
            result.exit_reason = "StructBreak_Fib0"
            break
        if d == Dir.SHORT and c > fib0:
            result.exit_bar = i
            result.exit_price = c
            result.exit_reason = "StructBreak_Fib0"
            break

        # ── 2) TimeExit ──
        bars_held = i - result.entry_bar
        current_pnl = (c - entry_price) if d == Dir.LONG else (entry_price - c)
        if bars_held >= time_exit_bars and current_pnl <= 0:
            result.exit_bar = i
            result.exit_price = c
            result.exit_reason = "TimeExit"
            break

        # ── 3) Breakeven (RR >= 1.0) ──
        if not breakeven_done:
            sl_dist = abs(entry_price - sl_price)
            if sl_dist > 0:
                rr = current_pnl / sl_dist
                if rr >= 1.0:
                    sl_price = entry_price
                    breakeven_done = True

        # ── 4) EMA cross exit ──
        if i >= 2:
            if d == Dir.LONG:
                # Dead cross
                cross = ema_fast[i - 1] >= ema_slow[i - 1] and ema_fast[i] < ema_slow[i]
                cross_maintained = ema_fast[i] < ema_slow[i]
            else:
                # Golden cross
                cross = ema_fast[i - 1] <= ema_slow[i - 1] and ema_fast[i] > ema_slow[i]
                cross_maintained = ema_fast[i] > ema_slow[i]

            if not exit_pending and cross:
                exit_pending = True
                exit_pending_bars = 0
            elif exit_pending:
                exit_pending_bars += 1
                if cross_maintained and exit_pending_bars >= EXIT_CONFIRM_BARS:
                    result.exit_bar = i
                    result.exit_price = c
                    result.exit_reason = "EMACross_Exit"
                    break
                elif not cross_maintained:
                    exit_pending = False
                    exit_pending_bars = 0
    else:
        last = min(start + 499, n - 1)
        result.exit_bar = last
        result.exit_price = closes[last]
        result.exit_reason = "DataEnd"

    # PnL
    if result.exit_price > 0 and result.entry_price > 0:
        if d == Dir.LONG:
            result.pnl_pips = (result.exit_price - result.entry_price) / point()
        else:
            result.pnl_pips = (result.entry_price - result.exit_price) / point()

    if result.entry_bar is not None and result.exit_bar is not None:
        result.hold_bars = result.exit_bar - result.entry_bar

# ═══════════════════════════════════════════════════════════════════════
# 7. Statistics & output
# ═══════════════════════════════════════════════════════════════════════

def _collect_stats(results: list[TradeResult], label: str) -> dict:
    total = len(results)
    has_entry = [r for r in results if r.entry_bar is not None]
    no_entry = [r for r in results if r.entry_bar is None]

    reject_counts: dict[str, int] = {}
    for r in no_entry:
        k = r.reject_stage or "UNKNOWN"
        reject_counts[k] = reject_counts.get(k, 0) + 1

    filter_stats: dict[str, dict] = {}
    for name, attr in [("Baseline", "baseline_pass"),
                       ("Base(CRYPTO)", "base_pass"),
                       ("Loose", "loose_pass")]:
        trades = [r for r in has_entry if getattr(r, attr) and r.exit_reason]
        wins = [t for t in trades if t.pnl_pips > 0]
        losses = [t for t in trades if t.pnl_pips <= 0]
        gross_win = sum(t.pnl_pips for t in wins) if wins else 0
        gross_loss = abs(sum(t.pnl_pips for t in losses)) if losses else 0

        exit_reasons: dict[str, int] = {}
        for t in trades:
            exit_reasons[t.exit_reason] = exit_reasons.get(t.exit_reason, 0) + 1

        filter_stats[name] = {
            "pass": sum(1 for r in has_entry if getattr(r, attr)),
            "trades": len(trades),
            "wins": len(wins),
            "win_rate": 100 * len(wins) / len(trades) if trades else 0,
            "avg_pnl": float(np.mean([t.pnl_pips for t in trades])) if trades else 0,
            "tot_pnl": sum(t.pnl_pips for t in trades),
            "pf": gross_win / gross_loss if gross_loss > 0 else float("inf"),
            "exit_reasons": exit_reasons,
        }

    return {
        "label": label,
        "total": total,
        "entries": len(has_entry),
        "rejects": len(no_entry),
        "reject_counts": reject_counts,
        "filter_stats": filter_stats,
    }


def _print_results(results: list[TradeResult], label: str):
    header = (f"{'Time':<22} {'Dir':<6} {'RangePts':>9} {'Sprd':>7} "
              f"{'Confirm':<11} {'Baseline':<15} {'Base(CRYPTO)':<15} {'Loose':<20} "
              f"{'PnL':>10} {'Hold':>5} {'Exit':<18} {'Reject':<20}")
    print(header)
    print("-" * len(header))

    for r in results:
        d_str = "LONG" if r.direction == Dir.LONG else "SHORT"
        t = r.impulse_time[:19] if r.impulse_time else ""
        rng = f"{r.impulse.range_pts:.1f}"
        sp = f"{r.impulse.spread_at_freeze:.0f}"
        conf = r.confirm_type or "-"
        bl = r.baseline_reason
        ba = r.base_reason
        lo = r.loose_reason
        pnl = f"{r.pnl_pips:.1f}" if r.entry_bar is not None else "-"
        hold = str(r.hold_bars) if r.hold_bars > 0 else "-"
        ex = r.exit_reason or "-"
        rej = r.reject_stage or "-"
        print(f"{t:<22} {d_str:<6} {rng:>9} {sp:>7} "
              f"{conf:<11} {bl:<15} {ba:<15} {lo:<20} "
              f"{pnl:>10} {hold:>5} {ex:<18} {rej:<20}")

    stats = _collect_stats(results, label)
    total = stats["total"]
    print(f"\n  Total impulses: {total}  Entry: {stats['entries']}  Rejected: {stats['rejects']}")

    if stats["reject_counts"]:
        print("  Reject breakdown:")
        for k, v in sorted(stats["reject_counts"].items(), key=lambda x: -x[1]):
            print(f"    {k:<25} {v:>4}  ({100*v/total:.1f}%)")

    print(f"\n  {'Filter':<15} {'Pass':>5} {'Trades':>7} {'Win':>5} {'WinRate':>8} "
          f"{'AvgPnL':>10} {'TotPnL':>12} {'PF':>6}")
    print("  " + "-" * 75)
    for name in ["Baseline", "Base(CRYPTO)", "Loose"]:
        fs = stats["filter_stats"][name]
        if fs["trades"] == 0:
            print(f"  {name:<15} {fs['pass']:>5} {'0':>7} {'-':>5} {'-':>8} "
                  f"{'-':>10} {'-':>12} {'-':>6}")
        else:
            print(f"  {name:<15} {fs['pass']:>5} {fs['trades']:>7} {fs['wins']:>5} "
                  f"{fs['win_rate']:>7.1f}% {fs['avg_pnl']:>10.1f} "
                  f"{fs['tot_pnl']:>12.1f} {fs['pf']:>6.2f}")

        if fs["exit_reasons"]:
            for er, cnt in sorted(fs["exit_reasons"].items(), key=lambda x: -x[1]):
                print(f"    exit: {er:<22} {cnt:>4}  ({100*cnt/fs['trades']:.1f}%)")

    return stats

# ═══════════════════════════════════════════════════════════════════════
# 8. Main simulation
# ═══════════════════════════════════════════════════════════════════════

def main():
    import copy
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "BTCUSD#_M1_202512010000_202602270000.csv")

    if not os.path.exists(data_path):
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    print("=" * 70)
    print("sim_crypto.py  –  CRYPTO Impulse-Retrace (BTCUSD, DOC-CORE spec)")
    print("=" * 70)

    # ── Load & resample ──
    print("\n[1] Loading M1 data …")
    m1 = load_m1(data_path)
    print(f"    M1 bars: {len(m1)}  range: {m1.index[0]} → {m1.index[-1]}")

    m5 = resample_ohlc(m1, "5min")
    m15 = resample_ohlc(m1, "15min")
    print(f"    M5 bars: {len(m5)},  M15 bars: {len(m15)}")

    # ── Indicators ──
    print("[2] Computing indicators …")
    m1_atr = atr_series(m1, IMPULSE_ATR_PERIOD)
    m5_atr = atr_series(m5, 14)
    m5_sma = sma_series(m5["close"], M5_MA_PERIOD)
    m15_atr = atr_series(m15, 14)
    m15_ema21 = ema_series(m15["close"], M15_EMA21_PERIOD)
    m15_ema50 = ema_series(m15["close"], M15_EMA50_PERIOD)

    # ── Impulse detection ──
    print("[3] Detecting impulses …")
    impulses = detect_impulses(m1, m1_atr)
    print(f"    Raw impulses found: {len(impulses)}")

    # ── Fib vs ATR retrace comparison, TE=12 fixed, RT=25 fixed ──
    TIME_EXIT_FIXED = 12
    RT_FIXED = 25

    # Variants: Fib baseline + ATR retrace with different multipliers
    variants: list[dict] = [
        {"label": "Fib50-618", "band_mode": "50_618", "atr_mult": 0.0},
        {"label": "ATR×1.5",   "band_mode": "atr_retrace", "atr_mult": 1.5},
        {"label": "ATR×2.0",   "band_mode": "atr_retrace", "atr_mult": 2.0},
        {"label": "ATR×2.5",   "band_mode": "atr_retrace", "atr_mult": 2.5},
        {"label": "ATR×3.0",   "band_mode": "atr_retrace", "atr_mult": 3.0},
        {"label": "ATR×3.5",   "band_mode": "atr_retrace", "atr_mult": 3.5},
    ]

    print(f"[4] Fib vs ATR retrace comparison (RT={RT_FIXED}, TE={TIME_EXIT_FIXED})")

    all_stats: dict[str, dict] = {}

    for v in variants:
        label = v["label"]
        print(f"\n{'=' * 70}")
        print(f"  {label}  (RT={RT_FIXED}, TE={TIME_EXIT_FIXED})")
        print(f"{'=' * 70}\n")

        results: list[TradeResult] = []
        last_done_bar = 0

        for imp_orig in impulses:
            imp = copy.deepcopy(imp_orig)
            if imp.bar_idx <= last_done_bar:
                continue

            tr = run_entry_logic(imp, m1, m1_atr,
                                 retouch_limit=RT_FIXED,
                                 band_mode=v["band_mode"],
                                 atr_retrace_mult=v["atr_mult"])
            evaluate_filters(tr, m1, m15_ema21, m15_ema50, m15_atr, m5_sma, m5_atr)

            if tr.entry_bar is not None:
                simulate_exit(tr, m1, m1_atr, time_exit_bars=TIME_EXIT_FIXED)
                last_done_bar = tr.exit_bar if tr.exit_bar is not None else tr.entry_bar + 30
            else:
                last_done_bar = imp.bar_idx + 10

            results.append(tr)

        stats = _print_results(results, label)
        all_stats[label] = stats

    # ── Comparison table (Base(CRYPTO) filter) ──
    print("\n" + "=" * 90)
    print("FIB vs ATR RETRACE COMPARISON  (Base(CRYPTO), RT=25, TE=12)")
    print("=" * 90)

    col_keys = [v["label"] for v in variants]
    col_width = 13

    print(f"\n  {'Metric':<14}", end="")
    for k in col_keys:
        print(f" {k:>{col_width}}", end="")
    print()
    print("  " + "-" * (14 + (col_width + 1) * len(col_keys)))

    for metric in ["trades", "wins", "win_rate", "avg_pnl", "tot_pnl", "pf"]:
        print(f"  {metric:<14}", end="")
        for k in col_keys:
            fs = all_stats[k]["filter_stats"]["Base(CRYPTO)"]
            if metric == "win_rate":
                print(f" {fs[metric]:>{col_width - 1}.1f}%", end="")
            elif metric in ("avg_pnl", "tot_pnl"):
                print(f" {fs[metric]:>{col_width}.1f}", end="")
            elif metric == "pf":
                print(f" {fs[metric]:>{col_width}.2f}", end="")
            else:
                print(f" {fs[metric]:>{col_width}}", end="")
        print()

    # Reject breakdown
    print(f"\n  {'Rejects':<14}", end="")
    for k in col_keys:
        print(f" {all_stats[k]['rejects']:>{col_width}}", end="")
    print()

    all_rej = set()
    for s in all_stats.values():
        all_rej.update(s["reject_counts"].keys())
    for stage in sorted(all_rej):
        print(f"  {stage:<14}", end="")
        for k in col_keys:
            cnt = all_stats[k]["reject_counts"].get(stage, 0)
            print(f" {cnt:>{col_width}}", end="")
        print()

    # Exit reason
    print(f"\n  {'Exit':<14}", end="")
    for k in col_keys:
        print(f" {k:>{col_width}}", end="")
    print()
    print("  " + "-" * (14 + (col_width + 1) * len(col_keys)))

    all_exits = set()
    for s in all_stats.values():
        all_exits.update(s["filter_stats"]["Base(CRYPTO)"]["exit_reasons"].keys())
    for er in sorted(all_exits):
        print(f"  {er:<14}", end="")
        for k in col_keys:
            cnt = all_stats[k]["filter_stats"]["Base(CRYPTO)"]["exit_reasons"].get(er, 0)
            print(f" {cnt:>{col_width}}", end="")
        print()

    # ── CSV output (best) ──
    csv_path = os.path.join(script_dir, "sim_dat", "sim_results_crypto.csv")
    best_key = max(col_keys, key=lambda k: all_stats[k]["filter_stats"]["Base(CRYPTO)"]["pf"]
                   if all_stats[k]["filter_stats"]["Base(CRYPTO)"]["trades"] > 0 else 0)
    best_fs = all_stats[best_key]["filter_stats"]["Base(CRYPTO)"]
    print(f"\n  Best: {best_key}  (PF={best_fs['pf']:.2f}, WR={best_fs['win_rate']:.1f}%, "
          f"TotPnL={best_fs['tot_pnl']:.0f})")

    # Find best variant params
    best_v = [v for v in variants if v["label"] == best_key][0]
    csv_results: list[TradeResult] = []
    last_done_bar = 0
    for imp_orig in impulses:
        imp = copy.deepcopy(imp_orig)
        if imp.bar_idx <= last_done_bar:
            continue
        tr = run_entry_logic(imp, m1, m1_atr, retouch_limit=RT_FIXED,
                             band_mode=best_v["band_mode"],
                             atr_retrace_mult=best_v["atr_mult"])
        evaluate_filters(tr, m1, m15_ema21, m15_ema50, m15_atr, m5_sma, m5_atr)
        if tr.entry_bar is not None:
            simulate_exit(tr, m1, m1_atr, time_exit_bars=TIME_EXIT_FIXED)
            last_done_bar = tr.exit_bar if tr.exit_bar is not None else tr.entry_bar + 30
        else:
            last_done_bar = imp.bar_idx + 10
        csv_results.append(tr)

    rows = []
    for r in csv_results:
        rows.append({
            "ImpulseTime": r.impulse_time,
            "Direction": "LONG" if r.direction == Dir.LONG else "SHORT",
            "RangePts": round(r.impulse.range_pts, 1),
            "SpreadAtFreeze": round(r.impulse.spread_at_freeze, 0),
            "BandWidth": round(r.impulse.band_width / point(), 1),
            "BandCenter": round(r.impulse.fib50, 2),
            "BandMode": best_v["band_mode"],
            "ConfirmType": r.confirm_type,
            "RejectStage": r.reject_stage,
            "Baseline": r.baseline_reason,
            "Base_CRYPTO": r.base_reason,
            "Loose": r.loose_reason,
            "EntryPrice": round(r.entry_price, 2) if r.entry_bar else "",
            "SL": round(r.sl_price, 2) if r.entry_bar else "",
            "ExitPrice": round(r.exit_price, 2) if r.exit_bar else "",
            "ExitReason": r.exit_reason,
            "PnL_pips": round(r.pnl_pips, 1) if r.entry_bar else "",
            "HoldBars_M1": r.hold_bars if r.hold_bars > 0 else "",
            "FreezeTime": r.freeze_time,
        })
    df_out = pd.DataFrame(rows)
    df_out.to_csv(csv_path, index=False)
    print(f"\nCSV written ({best_key}): {csv_path}  ({len(df_out)} rows)")


if __name__ == "__main__":
    main()
