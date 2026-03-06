"""
sim_fx.py  –  FX M5-slope filter comparison simulation (Phase 1 + Phase 2)
==========================================================================
Phase 1: Touch1→Leave→Touch2→Confirm, SL=Fib0±ATR×0.7, StructBreak active
Phase 2: Touch1→Confirm (Touch2 abolished), SL=Entry±ATR×0.7, no StructBreak

Both phases share: Impulse detection, Freeze, Fib/Band, RiskGate, Filters, Exit
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
# 0. Constants / FX Parameters (DOC-CORE §10)
# ═══════════════════════════════════════════════════════════════════════

# -- Impulse detection
IMPULSE_ATR_PERIOD = 14
IMPULSE_ATR_MULT = 1.6
SMALL_BODY_RATIO = 0.35
CANCEL_WINDOW_BARS = 2          # Freeze-cancel window

# -- Fib / Band
FIB_PRIMARY = 0.50              # FX: 50 only
SPREAD_BAND_MULT = 2.0          # BandWidthPts = Spread * 2.0

# -- Touch / Leave / ReTouch
LEAVE_DIST_MULT = 1.5           # LeaveDistance = BandWidthPts * 1.5
LEAVE_MIN_BARS = 1
RETOUCH_TIME_LIMIT_BARS = 35
CONFIRM_TIME_LIMIT_BARS = 6

# -- Confirm (FX: Engulfing OR MicroBreak(fractal L/R=2))
FRACTAL_LR = 2

# -- Risk / SL
SL_ATR_MULT = 0.7
TP_EXT_RATIO = 0.382            # theoretical TP for RangeCost eval
MIN_RANGE_COST_MULT = 2.5

# -- Exit (CloseByFlatRangeEA FX preset)
EXIT_MA_PERIOD = 21             # SMA(21) on M5
EXIT_SLOPE_LOOKBACK = 3
EXIT_FLAT_SLOPE_ATR = 0.03
EXIT_ATR_PERIOD = 14
EXIT_RANGE_LOOKBACK = 10
EXIT_WAIT_BARS = 16
EXIT_TRAIL_ATR_MULT = 1.0

# -- M15 trend filter (Baseline = current EA)
M15_EMA_PERIOD = 50
M15_SLOPE_MIN_ATR_RATIO = 0.0   # any slope counts (DOC-CORE uses SlopeMin_FX)
                                 # We'll derive from ATR

# -- M5 slope filter (new proposal)
M5_MA_PERIOD = 21               # SMA(21)
M5_SLOPE_LOOKBACK = 3
M5_FLAT_THRESHOLD = 0.03        # |slope/ATR| < 1.0x this → FLAT
M5_STRONG_THRESHOLD = 0.06      # |slope/ATR| >= 2.0x FlatThreshold → STRONG

# ═══════════════════════════════════════════════════════════════════════
# 1. Data loading / resampling
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
    """Resample M1 to higher TF (e.g. '5min', '15min')."""
    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "spread": "mean",
    }
    df = m1.resample(rule).agg(agg).dropna(subset=["open"])
    return df

# ═══════════════════════════════════════════════════════════════════════
# 2. Technical helpers
# ═══════════════════════════════════════════════════════════════════════

def atr_series(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Compute ATR as a pandas Series aligned to df.index."""
    h = df["high"].values
    l = df["low"].values
    c = df["close"].values
    tr = np.empty(len(df))
    tr[0] = h[0] - l[0]
    for i in range(1, len(df)):
        tr[i] = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
    # Wilder-style smoothing
    atr = np.empty(len(df))
    atr[:period] = np.nan
    if len(df) >= period:
        atr[period - 1] = np.mean(tr[:period])
        for i in range(period, len(df)):
            atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return pd.Series(atr, index=df.index, name="atr")


def ema_series(s: pd.Series, period: int) -> pd.Series:
    """Exponential Moving Average (Wilder-style compatible via pandas)."""
    return s.ewm(span=period, adjust=False).mean()


def sma_series(s: pd.Series, period: int) -> pd.Series:
    return s.rolling(period).mean()


def point() -> float:
    """USDJPY point size (0.001 for 3-digit broker)."""
    return 0.001

# ═══════════════════════════════════════════════════════════════════════
# 3. Impulse detection (FX spec, DOC-CORE §2.1/§4)
# ═══════════════════════════════════════════════════════════════════════

class Dir(Enum):
    LONG = auto()
    SHORT = auto()


@dataclass
class Impulse:
    bar_idx: int                 # index into M1 array
    direction: Dir
    start_price: float           # Fib 0
    end_price: float             # Fib 100 (updated until Freeze)
    atr_at_impulse: float
    freeze_bar: Optional[int] = None
    freeze_end: Optional[float] = None
    cancelled: bool = False
    # band info (set at Freeze)
    spread_at_freeze: float = 0.0
    band_width: float = 0.0
    band_upper: float = 0.0
    band_lower: float = 0.0
    fib50: float = 0.0
    range_pts: float = 0.0


def detect_impulses(m1: pd.DataFrame, m1_atr: pd.Series) -> list[Impulse]:
    """Scan M1 bars for single-bar impulses (FX spec)."""
    opens = m1["open"].values
    highs = m1["high"].values
    lows = m1["low"].values
    closes = m1["close"].values
    atr_vals = m1_atr.values
    spreads = m1["spread"].values

    impulses: list[Impulse] = []

    for i in range(1, len(m1)):
        a = atr_vals[i]
        if np.isnan(a) or a <= 0:
            continue

        body = abs(closes[i] - opens[i])
        threshold = a * IMPULSE_ATR_MULT
        if body < threshold:
            continue

        # Determine direction
        if closes[i] > opens[i]:
            d = Dir.LONG
        else:
            d = Dir.SHORT

        # Origin correction: check previous bar
        start_adjusted = False
        if i >= 2:
            prev_body = abs(closes[i - 1] - opens[i - 1])
            prev_is_opposite = False
            if d == Dir.LONG and closes[i - 1] < opens[i - 1]:
                prev_is_opposite = True
            elif d == Dir.SHORT and closes[i - 1] > opens[i - 1]:
                prev_is_opposite = True
            if prev_is_opposite and prev_body <= a * SMALL_BODY_RATIO:
                start_adjusted = True

        if d == Dir.LONG:
            if start_adjusted:
                start_p = min(lows[i], lows[i - 1])
            else:
                start_p = lows[i]
            end_p = highs[i]
        else:
            if start_adjusted:
                start_p = max(highs[i], highs[i - 1])
            else:
                start_p = highs[i]
            end_p = lows[i]

        imp = Impulse(
            bar_idx=i,
            direction=d,
            start_price=start_p,
            end_price=end_p,
            atr_at_impulse=a,
        )
        impulses.append(imp)

    return impulses

# ═══════════════════════════════════════════════════════════════════════
# 4. Freeze / Fib / Touch / Leave / ReTouch / Confirm  (state machine)
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
    baseline_pass: bool = False
    base_pass: bool = False
    loose_pass: bool = False
    baseline_reason: str = ""
    base_reason: str = ""
    loose_reason: str = ""
    # entry/exit (only if filter passes, computed per filter)
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


def _in_band(price: float, band_lower: float, band_upper: float) -> bool:
    return band_lower <= price <= band_upper


def _check_engulfing(m1_o, m1_h, m1_l, m1_c, i: int, d: Dir) -> bool:
    """Engulfing on confirmed bar i (comparing i vs i-1)."""
    if i < 1:
        return False
    curr_body_lo = min(m1_o[i], m1_c[i])
    curr_body_hi = max(m1_o[i], m1_c[i])
    prev_body_lo = min(m1_o[i - 1], m1_c[i - 1])
    prev_body_hi = max(m1_o[i - 1], m1_c[i - 1])
    if curr_body_lo >= prev_body_lo or curr_body_hi <= prev_body_hi:
        return False
    if d == Dir.LONG:
        return m1_c[i] > m1_o[i]  # bullish engulfing
    else:
        return m1_c[i] < m1_o[i]  # bearish engulfing


def _check_microbreak(m1_h, m1_l, m1_c, i: int, d: Dir) -> bool:
    """MicroBreak via fractal (L/R=2). Need at least 5 bars before i."""
    if i < 5:
        return False
    # Find most recent fractal high/low (search backwards from i-1)
    micro_high = None
    micro_low = None
    for k in range(i - 3, FRACTAL_LR - 1, -1):  # need k-2 and k+1, k+2
        if k - 2 < 0 or k + 2 >= i:
            continue
        # MicroHigh
        if (m1_h[k] > m1_h[k - 1] and m1_h[k] > m1_h[k - 2] and
                m1_h[k] > m1_h[k + 1] and m1_h[k] > m1_h[k + 2]):
            if micro_high is None:
                micro_high = m1_h[k]
        # MicroLow
        if (m1_l[k] < m1_l[k - 1] and m1_l[k] < m1_l[k - 2] and
                m1_l[k] < m1_l[k + 1] and m1_l[k] < m1_l[k + 2]):
            if micro_low is None:
                micro_low = m1_l[k]
        if micro_high is not None and micro_low is not None:
            break

    if d == Dir.LONG and micro_high is not None:
        return m1_c[i] > micro_high
    if d == Dir.SHORT and micro_low is not None:
        return m1_c[i] < micro_low
    return False


def run_entry_logic(imp: Impulse, m1: pd.DataFrame, m1_atr: pd.Series) -> TradeResult:
    """Run state machine from Impulse detection through Confirm.
    Returns TradeResult with entry_bar set if Confirm succeeds."""
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

    # ── Freeze detection ──
    frozen_end = imp.end_price
    freeze_bar = None

    for i in range(imp.bar_idx + 1, min(imp.bar_idx + 200, n)):
        # Update end (100) while not frozen
        if d == Dir.LONG:
            if highs[i] > frozen_end:
                frozen_end = highs[i]
        else:
            if lows[i] < frozen_end:
                frozen_end = lows[i]

        # Freeze conditions (Level 2): update stop + opposite color
        update_stop = False
        if d == Dir.LONG and highs[i] <= frozen_end:
            update_stop = True
        if d == Dir.SHORT and lows[i] >= frozen_end:
            update_stop = True

        opposite_color = False
        if d == Dir.LONG and closes[i] < opens[i]:
            opposite_color = True
        if d == Dir.SHORT and closes[i] > opens[i]:
            opposite_color = True

        if update_stop and opposite_color:
            freeze_bar = i
            break

    if freeze_bar is None:
        result.reject_stage = "NO_FREEZE"
        return result

    # ── Freeze cancel check ──
    cancelled = False
    for j in range(freeze_bar + 1, min(freeze_bar + CANCEL_WINDOW_BARS + 1, n)):
        if d == Dir.LONG and highs[j] > frozen_end + point():
            cancelled = True
            break
        if d == Dir.SHORT and lows[j] < frozen_end - point():
            cancelled = True
            break

    if cancelled:
        result.reject_stage = "FREEZE_CANCEL"
        return result

    # ── Set Fib levels ──
    imp.freeze_bar = freeze_bar
    imp.freeze_end = frozen_end
    imp.end_price = frozen_end
    result.freeze_time = str(m1.index[freeze_bar])

    range_price = abs(frozen_end - imp.start_price)
    imp.range_pts = range_price / point()

    # BandWidthPts = Spread * 2.0 at freeze time
    sp = spreads[freeze_bar] if freeze_bar < n else spreads[-1]
    imp.spread_at_freeze = sp
    band_width_price = sp * point() * SPREAD_BAND_MULT
    imp.band_width = band_width_price

    # Fib50
    if d == Dir.LONG:
        fib50 = frozen_end - range_price * FIB_PRIMARY
    else:
        fib50 = frozen_end + range_price * FIB_PRIMARY
    imp.fib50 = fib50
    imp.band_upper = fib50 + band_width_price
    imp.band_lower = fib50 - band_width_price

    # ── RiskGate (simplified) ──
    band_dom_ratio = (2 * band_width_price) / range_price if range_price > 0 else 999
    if band_dom_ratio >= 0.85:
        result.reject_stage = "RISK_GATE_BAND_DOM"
        return result

    # ── Touch / Leave / ReTouch / Confirm state machine ──
    state = SimState.FIB_ACTIVE
    touch1_bar = None
    leave_bar = None
    leave_confirmed = False
    touch2_bar = None
    confirm_deadline = None
    retouch_deadline = freeze_bar + CANCEL_WINDOW_BARS + RETOUCH_TIME_LIMIT_BARS

    bu = imp.band_upper
    bl = imp.band_lower
    leave_dist = band_width_price * LEAVE_DIST_MULT

    search_start = freeze_bar + CANCEL_WINDOW_BARS + 1

    for i in range(search_start, min(search_start + RETOUCH_TIME_LIMIT_BARS + CONFIRM_TIME_LIMIT_BARS + 10, n)):
        if i >= retouch_deadline and state != SimState.TOUCH_2_WAIT_CONFIRM:
            result.reject_stage = "RETOUCH_TIMEOUT"
            return result

        # Structure break: price beyond 0/100
        if d == Dir.LONG:
            if closes[i] < imp.start_price:
                result.reject_stage = "STRUCTURE_BREAK"
                return result
        else:
            if closes[i] > imp.start_price:
                result.reject_stage = "STRUCTURE_BREAK"
                return result

        if state == SimState.FIB_ACTIVE:
            # Check touch 1 (侵入)
            touched = False
            if d == Dir.LONG and lows[i] <= bu:
                touched = True
            if d == Dir.SHORT and highs[i] >= bl:
                touched = True
            if touched:
                touch1_bar = i
                state = SimState.TOUCH_1

        elif state == SimState.TOUCH_1:
            # Check leave
            if d == Dir.LONG:
                if closes[i] > bu + leave_dist:
                    if leave_bar is None:
                        leave_bar = i
                    if i - leave_bar >= LEAVE_MIN_BARS:
                        leave_confirmed = True
                        state = SimState.LEAVE_WAIT
                else:
                    leave_bar = None  # reset
            else:
                if closes[i] < bl - leave_dist:
                    if leave_bar is None:
                        leave_bar = i
                    if i - leave_bar >= LEAVE_MIN_BARS:
                        leave_confirmed = True
                        state = SimState.LEAVE_WAIT
                else:
                    leave_bar = None

        elif state == SimState.LEAVE_WAIT:
            # Check re-touch (touch 2)
            retouched = False
            if d == Dir.LONG and lows[i] <= bu:
                retouched = True
            if d == Dir.SHORT and highs[i] >= bl:
                retouched = True
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

            # Check Engulfing first, then MicroBreak
            if _check_engulfing(opens, highs, lows, closes, i, d):
                result.entry_bar = i
                result.confirm_type = "Engulfing"
                break
            if _check_microbreak(highs, lows, closes, i, d):
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


def run_entry_logic_p2(imp: Impulse, m1: pd.DataFrame, m1_atr: pd.Series) -> TradeResult:
    """Phase 2: Touch1→Confirm (no Leave/Touch2), SL=Entry±ATR, no StructBreak."""
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

    # ── Freeze detection (identical to Phase 1) ──
    frozen_end = imp.end_price
    freeze_bar = None

    for i in range(imp.bar_idx + 1, min(imp.bar_idx + 200, n)):
        if d == Dir.LONG:
            if highs[i] > frozen_end:
                frozen_end = highs[i]
        else:
            if lows[i] < frozen_end:
                frozen_end = lows[i]

        update_stop = False
        if d == Dir.LONG and highs[i] <= frozen_end:
            update_stop = True
        if d == Dir.SHORT and lows[i] >= frozen_end:
            update_stop = True

        opposite_color = False
        if d == Dir.LONG and closes[i] < opens[i]:
            opposite_color = True
        if d == Dir.SHORT and closes[i] > opens[i]:
            opposite_color = True

        if update_stop and opposite_color:
            freeze_bar = i
            break

    if freeze_bar is None:
        result.reject_stage = "NO_FREEZE"
        return result

    # ── Freeze cancel check (identical) ──
    cancelled = False
    for j in range(freeze_bar + 1, min(freeze_bar + CANCEL_WINDOW_BARS + 1, n)):
        if d == Dir.LONG and highs[j] > frozen_end + point():
            cancelled = True
            break
        if d == Dir.SHORT and lows[j] < frozen_end - point():
            cancelled = True
            break

    if cancelled:
        result.reject_stage = "FREEZE_CANCEL"
        return result

    # ── Set Fib levels (identical) ──
    imp.freeze_bar = freeze_bar
    imp.freeze_end = frozen_end
    imp.end_price = frozen_end
    result.freeze_time = str(m1.index[freeze_bar])

    range_price = abs(frozen_end - imp.start_price)
    imp.range_pts = range_price / point()

    sp = spreads[freeze_bar] if freeze_bar < n else spreads[-1]
    imp.spread_at_freeze = sp
    band_width_price = sp * point() * SPREAD_BAND_MULT
    imp.band_width = band_width_price

    if d == Dir.LONG:
        fib50 = frozen_end - range_price * FIB_PRIMARY
    else:
        fib50 = frozen_end + range_price * FIB_PRIMARY
    imp.fib50 = fib50
    imp.band_upper = fib50 + band_width_price
    imp.band_lower = fib50 - band_width_price

    # ── RiskGate (identical) ──
    band_dom_ratio = (2 * band_width_price) / range_price if range_price > 0 else 999
    if band_dom_ratio >= 0.85:
        result.reject_stage = "RISK_GATE_BAND_DOM"
        return result

    # ── Phase 2: Touch1 → Confirm (no Leave/Touch2, no StructBreak) ──
    bu = imp.band_upper
    bl = imp.band_lower
    search_start = freeze_bar + CANCEL_WINDOW_BARS + 1
    touch1_bar = None
    confirm_deadline = None
    # Use same overall time window as Phase 1
    max_bar = min(search_start + RETOUCH_TIME_LIMIT_BARS + CONFIRM_TIME_LIMIT_BARS + 10, n)

    for i in range(search_start, max_bar):
        if touch1_bar is None:
            # Wait for Touch1
            touched = False
            if d == Dir.LONG and lows[i] <= bu:
                touched = True
            if d == Dir.SHORT and highs[i] >= bl:
                touched = True
            if touched:
                touch1_bar = i
                confirm_deadline = i + CONFIRM_TIME_LIMIT_BARS
        else:
            # Confirm phase (no StructBreak check in P2)
            if i > confirm_deadline:
                result.reject_stage = "NO_CONFIRM"
                return result

            if _check_engulfing(opens, highs, lows, closes, i, d):
                result.entry_bar = i
                result.confirm_type = "Engulfing"
                break
            if _check_microbreak(highs, lows, closes, i, d):
                result.entry_bar = i
                result.confirm_type = "MicroBreak"
                break

    if result.entry_bar is None:
        if result.reject_stage == "":
            if touch1_bar is None:
                result.reject_stage = "NO_TOUCH"
            else:
                result.reject_stage = "NO_CONFIRM"
        return result

    # ── Phase 2 SL: EntryPrice ± ATR × SLATRMult (detached from Fib0) ──
    eb = result.entry_bar
    result.entry_price = closes[eb]
    atr_at_entry = atr_vals[eb] if not np.isnan(atr_vals[eb]) else imp.atr_at_impulse
    if d == Dir.LONG:
        result.sl_price = result.entry_price - atr_at_entry * SL_ATR_MULT
    else:
        result.sl_price = result.entry_price + atr_at_entry * SL_ATR_MULT

    return result

# ═══════════════════════════════════════════════════════════════════════
# 5. Filter evaluation
# ═══════════════════════════════════════════════════════════════════════

def _m15_slope_dir(m15: pd.DataFrame, m15_ema50: pd.Series, m15_atr: pd.Series,
                   ts: pd.Timestamp) -> tuple[str, float]:
    """Return (direction_str, slope_value) for M15 EMA50 at given time."""
    loc = m15.index.get_indexer([ts], method="ffill")[0]
    if loc < 1 or np.isnan(m15_atr.iloc[loc]):
        return "FLAT", 0.0
    slope = m15_ema50.iloc[loc] - m15_ema50.iloc[loc - 1]
    a = m15_atr.iloc[loc]
    if a <= 0:
        return "FLAT", 0.0
    # DOC-CORE: SlopeMin_FX = ATR ratio (we use a small threshold)
    slope_ratio = slope / a
    if slope_ratio > 0.01:
        return "LONG", slope_ratio
    elif slope_ratio < -0.01:
        return "SHORT", slope_ratio
    else:
        return "FLAT", slope_ratio


def _m5_slope_eval(m5: pd.DataFrame, m5_sma: pd.Series, m5_atr: pd.Series,
                   ts: pd.Timestamp) -> tuple[str, str, float]:
    """Return (direction, strength, ratio) for M5 SMA21 slope.
    strength: FLAT / MID / STRONG
    """
    loc = m5.index.get_indexer([ts], method="ffill")[0]
    if loc < M5_SLOPE_LOOKBACK or np.isnan(m5_atr.iloc[loc]):
        return "FLAT", "FLAT", 0.0
    slope = m5_sma.iloc[loc] - m5_sma.iloc[loc - M5_SLOPE_LOOKBACK]
    a = m5_atr.iloc[loc]
    if a <= 0:
        return "FLAT", "FLAT", 0.0
    ratio = abs(slope / a)
    if slope > 0:
        direction = "LONG"
    elif slope < 0:
        direction = "SHORT"
    else:
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
                     m15: pd.DataFrame, m15_ema50: pd.Series, m15_atr: pd.Series,
                     m5: pd.DataFrame, m5_sma: pd.Series, m5_atr: pd.Series):
    """Evaluate 3 filter modes and set pass/fail + reasons on result."""
    imp = result.impulse
    d = imp.direction
    impulse_ts = m1.index[imp.bar_idx]
    dir_str = "LONG" if d == Dir.LONG else "SHORT"

    # ── M15 evaluation at IMPULSE_FOUND ──
    m15_dir, m15_slope = _m15_slope_dir(m15, m15_ema50, m15_atr, impulse_ts)

    # ── M5 evaluation at TOUCH_2 (or entry bar as proxy) ──
    eval_ts = impulse_ts  # fallback
    if result.entry_bar is not None:
        eval_ts = m1.index[result.entry_bar]
    m5_dir, m5_strength, m5_ratio = _m5_slope_eval(m5, m5_sma, m5_atr, eval_ts)

    # ════ Baseline (current EA): M15 EMA50 slope ════
    # FLAT → Reject, counter-trend → Reject
    if m15_dir == "FLAT":
        result.baseline_pass = False
        result.baseline_reason = "M15_FLAT"
    elif m15_dir != dir_str:
        result.baseline_pass = False
        result.baseline_reason = "M15_COUNTER"
    else:
        result.baseline_pass = True
        result.baseline_reason = "PASS"

    # ════ New(Loose): M15 counter only + M5 direction match ════
    if m15_dir != "FLAT" and m15_dir != dir_str:
        result.loose_pass = False
        result.loose_reason = "M15_COUNTER"
    elif m5_dir != dir_str:
        result.loose_pass = False
        result.loose_reason = f"M5_DIR_MISMATCH({m5_dir})"
    else:
        result.loose_pass = True
        result.loose_reason = "PASS"

    # ════ New(Base): M15 counter only + M5 MID+ required ════
    if m15_dir != "FLAT" and m15_dir != dir_str:
        result.base_pass = False
        result.base_reason = "M15_COUNTER"
    elif m5_strength == "FLAT":
        result.base_pass = False
        result.base_reason = "M5_FLAT"
    elif m5_dir != dir_str:
        result.base_pass = False
        result.base_reason = f"M5_DIR_MISMATCH({m5_dir})"
    else:
        # MID or STRONG (FX: MID allowed)
        result.base_pass = True
        result.base_reason = f"PASS({m5_strength})"

# ═══════════════════════════════════════════════════════════════════════
# 6. Exit simulation (CloseByFlatRangeEA FX preset)
# ═══════════════════════════════════════════════════════════════════════

def simulate_exit(result: TradeResult, m1: pd.DataFrame,
                  m5: pd.DataFrame, m5_sma: pd.Series, m5_atr: pd.Series):
    """Simulate CloseByFlatRangeEA exit logic on M5 from entry bar."""
    if result.entry_bar is None:
        return

    d = result.direction
    entry_price = result.entry_price
    sl_price = result.sl_price

    # Map entry bar M1 time to M5 bar index
    entry_ts = m1.index[result.entry_bar]
    m5_closes = m5["close"].values
    m5_highs = m5["high"].values
    m5_lows = m5["low"].values
    m5_times = m5.index
    m5_atr_vals = m5_atr.values
    m5_sma_vals = m5_sma.values
    n5 = len(m5)

    # Find M5 bar at/after entry
    start_loc = m5_times.get_indexer([entry_ts], method="bfill")[0]
    if start_loc < 0 or start_loc >= n5:
        result.exit_reason = "NO_M5_DATA"
        return

    # States: WAIT_FLAT -> RANGE_LOCKED -> TRAILING / closed
    state = "WAIT_FLAT"
    range_high = 0.0
    range_low = 0.0
    wait_bars = 0
    trail_peak = 0.0
    trail_line = 0.0

    for bi in range(start_loc + 1, n5):
        # SL check (every bar)
        if d == Dir.LONG and m5_lows[bi] <= sl_price:
            result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
            result.exit_price = sl_price
            result.exit_reason = "SL_Hit"
            break
        if d == Dir.SHORT and m5_highs[bi] >= sl_price:
            result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
            result.exit_price = sl_price
            result.exit_reason = "SL_Hit"
            break

        if state == "WAIT_FLAT":
            # Check flat on confirmed bar (shift=1 equivalent → use bi)
            if bi < EXIT_SLOPE_LOOKBACK + 1:
                continue
            if np.isnan(m5_sma_vals[bi]) or np.isnan(m5_atr_vals[bi]):
                continue
            slope_pts = abs(m5_sma_vals[bi] - m5_sma_vals[bi - EXIT_SLOPE_LOOKBACK]) / point()
            atr_pts = m5_atr_vals[bi] / point()
            if atr_pts > 0 and slope_pts <= atr_pts * EXIT_FLAT_SLOPE_ATR:
                # Flat detected → lock range
                rb_start = max(1, bi - EXIT_RANGE_LOOKBACK + 1)
                range_high = np.max(m5_highs[rb_start:bi + 1])
                range_low = np.min(m5_lows[rb_start:bi + 1])
                wait_bars = 0
                state = "RANGE_LOCKED"

        elif state == "RANGE_LOCKED":
            wait_bars += 1
            close_p = m5_closes[bi]
            if d == Dir.LONG:
                if close_p < range_low:  # unfavorable
                    result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
                    result.exit_price = close_p
                    result.exit_reason = "UnfavBreak"
                    break
                if close_p > range_high:  # favorable
                    trail_peak = m5_highs[bi]
                    a = m5_atr_vals[bi] if not np.isnan(m5_atr_vals[bi]) else 0
                    trail_line = trail_peak - a * EXIT_TRAIL_ATR_MULT
                    state = "TRAILING"
                    continue
            else:
                if close_p > range_high:  # unfavorable
                    result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
                    result.exit_price = close_p
                    result.exit_reason = "UnfavBreak"
                    break
                if close_p < range_low:  # favorable
                    trail_peak = m5_lows[bi]
                    a = m5_atr_vals[bi] if not np.isnan(m5_atr_vals[bi]) else 0
                    trail_line = trail_peak + a * EXIT_TRAIL_ATR_MULT
                    state = "TRAILING"
                    continue

            if wait_bars > EXIT_WAIT_BARS:
                result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
                result.exit_price = close_p
                result.exit_reason = "FailSafe"
                break

        elif state == "TRAILING":
            a = m5_atr_vals[bi] if not np.isnan(m5_atr_vals[bi]) else 0
            close_p = m5_closes[bi]
            if d == Dir.LONG:
                if m5_highs[bi] > trail_peak:
                    trail_peak = m5_highs[bi]
                trail_line = trail_peak - a * EXIT_TRAIL_ATR_MULT
                if close_p < trail_line:
                    result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
                    result.exit_price = close_p
                    result.exit_reason = "TrailStop"
                    break
            else:
                if m5_lows[bi] < trail_peak:
                    trail_peak = m5_lows[bi]
                trail_line = trail_peak + a * EXIT_TRAIL_ATR_MULT
                if close_p > trail_line:
                    result.exit_bar = _m5_to_m1_idx(m5_times[bi], m1)
                    result.exit_price = close_p
                    result.exit_reason = "TrailStop"
                    break
    else:
        # Data exhausted
        if result.exit_reason == "":
            last_i = n5 - 1
            result.exit_bar = _m5_to_m1_idx(m5_times[last_i], m1)
            result.exit_price = m5_closes[last_i]
            result.exit_reason = "DataEnd"

    # Calculate PnL
    if result.exit_price > 0 and result.entry_price > 0:
        if d == Dir.LONG:
            result.pnl_pips = (result.exit_price - result.entry_price) / point()
        else:
            result.pnl_pips = (result.entry_price - result.exit_price) / point()

    if result.entry_bar is not None and result.exit_bar is not None:
        result.hold_bars = result.exit_bar - result.entry_bar


def _m5_to_m1_idx(m5_ts: pd.Timestamp, m1: pd.DataFrame) -> int:
    """Map M5 timestamp to nearest M1 bar index."""
    loc = m1.index.get_indexer([m5_ts], method="ffill")[0]
    return max(loc, 0)

# ═══════════════════════════════════════════════════════════════════════
# 7. Main simulation
# ═══════════════════════════════════════════════════════════════════════

def _collect_stats(results: list[TradeResult], label: str) -> dict:
    """Compute summary stats dict for a phase's results."""
    total = len(results)
    has_entry = [r for r in results if r.entry_bar is not None]
    no_entry = [r for r in results if r.entry_bar is None]

    reject_counts: dict[str, int] = {}
    for r in no_entry:
        k = r.reject_stage or "UNKNOWN"
        reject_counts[k] = reject_counts.get(k, 0) + 1

    filter_stats: dict[str, dict] = {}
    for name, attr in [("Baseline", "baseline_pass"),
                       ("Base", "base_pass"),
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


def _print_phase(results: list[TradeResult], phase_label: str):
    """Print detailed results table and summary for one phase."""
    header = (f"{'Time':<22} {'Dir':<6} {'RangePts':>9} {'Sprd':>5} "
              f"{'Confirm':<11} {'Baseline':<15} {'Base':<20} {'Loose':<20} "
              f"{'PnL':>8} {'Hold':>5} {'Exit':<12} {'Reject':<20}")
    print(header)
    print("-" * len(header))

    for r in results:
        d_str = "LONG" if r.direction == Dir.LONG else "SHORT"
        t = r.impulse_time[:19] if r.impulse_time else ""
        rng = f"{r.impulse.range_pts:.1f}"
        sp = f"{r.impulse.spread_at_freeze:.0f}"
        conf = r.confirm_type if r.confirm_type else "-"
        bl = r.baseline_reason
        ba = r.base_reason
        lo = r.loose_reason
        pnl = f"{r.pnl_pips:.1f}" if r.entry_bar is not None else "-"
        hold = str(r.hold_bars) if r.hold_bars > 0 else "-"
        ex = r.exit_reason if r.exit_reason else "-"
        rej = r.reject_stage if r.reject_stage else "-"
        print(f"{t:<22} {d_str:<6} {rng:>9} {sp:>5} "
              f"{conf:<11} {bl:<15} {ba:<20} {lo:<20} "
              f"{pnl:>8} {hold:>5} {ex:<12} {rej:<20}")

    stats = _collect_stats(results, phase_label)
    total = stats["total"]
    print(f"\n  Total: {total}  Entry: {stats['entries']}  Rejected: {stats['rejects']}")

    if stats["reject_counts"]:
        print("  Reject breakdown:")
        for k, v in sorted(stats["reject_counts"].items(), key=lambda x: -x[1]):
            print(f"    {k:<25} {v:>4}  ({100*v/total:.1f}%)")

    print(f"\n  {'Filter':<12} {'Pass':>5} {'Trades':>7} {'Win':>5} {'WinRate':>8} "
          f"{'AvgPnL':>8} {'TotPnL':>9} {'PF':>6}")
    print("  " + "-" * 65)
    for name in ["Baseline", "Base", "Loose"]:
        fs = stats["filter_stats"][name]
        if fs["trades"] == 0:
            print(f"  {name:<12} {fs['pass']:>5} {'0':>7} {'-':>5} {'-':>8} "
                  f"{'-':>8} {'-':>9} {'-':>6}")
        else:
            print(f"  {name:<12} {fs['pass']:>5} {fs['trades']:>7} {fs['wins']:>5} "
                  f"{fs['win_rate']:>7.1f}% {fs['avg_pnl']:>8.1f} "
                  f"{fs['tot_pnl']:>9.1f} {fs['pf']:>6.2f}")


def _run_phase(impulses: list[Impulse], m1, m1_atr, m15, m15_ema50, m15_atr,
               m5, m5_sma, m5_atr, phase: int) -> list[TradeResult]:
    """Run one phase over all impulses. phase=1 or 2."""
    import copy
    results: list[TradeResult] = []
    last_done_bar = 0

    for imp_orig in impulses:
        imp = copy.deepcopy(imp_orig)
        if imp.bar_idx <= last_done_bar:
            continue

        if phase == 1:
            tr = run_entry_logic(imp, m1, m1_atr)
        else:
            tr = run_entry_logic_p2(imp, m1, m1_atr)

        evaluate_filters(tr, m1, m15, m15_ema50, m15_atr, m5, m5_sma, m5_atr)

        if tr.entry_bar is not None:
            simulate_exit(tr, m1, m5, m5_sma, m5_atr)
            if tr.exit_bar is not None:
                last_done_bar = tr.exit_bar
            else:
                last_done_bar = tr.entry_bar + 30
        else:
            last_done_bar = imp.bar_idx + 10

        results.append(tr)

    return results


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "sim_dat",
                             "USDJPY#_M1_202602020000_202602160000.csv")

    if not os.path.exists(data_path):
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    print("=" * 70)
    print("sim_fx.py  –  FX M5 slope filter comparison (Phase 1 + Phase 2)")
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
    m5_atr = atr_series(m5, EXIT_ATR_PERIOD)
    m5_sma = sma_series(m5["close"], M5_MA_PERIOD)
    m15_atr = atr_series(m15, 14)
    m15_ema50 = ema_series(m15["close"], M15_EMA_PERIOD)

    # ── Impulse detection ──
    print("[3] Detecting impulses …")
    impulses = detect_impulses(m1, m1_atr)
    print(f"    Raw impulses found: {len(impulses)}")

    # ── Phase 1 ──
    print("\n[4a] Phase 1: Touch1→Leave→Touch2→Confirm, SL=Fib0±ATR …")
    p1 = _run_phase(impulses, m1, m1_atr, m15, m15_ema50, m15_atr,
                    m5, m5_sma, m5_atr, phase=1)
    print(f"     Impulses processed: {len(p1)}")

    # ── Phase 2 ──
    print("[4b] Phase 2: Touch1→Confirm (A), SL=Entry±ATR (B) …")
    p2 = _run_phase(impulses, m1, m1_atr, m15, m15_ema50, m15_atr,
                    m5, m5_sma, m5_atr, phase=2)
    print(f"     Impulses processed: {len(p2)}")

    # ═══════════════════════════════════════════════════════════════════
    # Output
    # ═══════════════════════════════════════════════════════════════════
    print("\n" + "=" * 70)
    print("PHASE 1 DETAIL  (Touch1→Leave→Touch2→Confirm, SL=Fib0)")
    print("=" * 70 + "\n")
    _print_phase(p1, "Phase1")

    print("\n" + "=" * 70)
    print("PHASE 2 DETAIL  (Touch1→Confirm, SL=Entry±ATR)")
    print("=" * 70 + "\n")
    _print_phase(p2, "Phase2")

    # ═══════════════════════════════════════════════════════════════════
    # Phase 1 vs Phase 2 Comparison
    # ═══════════════════════════════════════════════════════════════════
    s1 = _collect_stats(p1, "Phase1")
    s2 = _collect_stats(p2, "Phase2")

    print("\n" + "=" * 70)
    print("PHASE 1 vs PHASE 2 COMPARISON")
    print("=" * 70)

    print(f"\n{'Metric':<28} {'Phase1':>10} {'Phase2':>10} {'Delta':>10}")
    print("-" * 62)
    print(f"{'Impulses processed':<28} {s1['total']:>10} {s2['total']:>10} "
          f"{s2['total']-s1['total']:>+10}")
    print(f"{'Entry signals':<28} {s1['entries']:>10} {s2['entries']:>10} "
          f"{s2['entries']-s1['entries']:>+10}")
    print(f"{'Entry rate':<28} "
          f"{100*s1['entries']/s1['total'] if s1['total'] else 0:>9.1f}% "
          f"{100*s2['entries']/s2['total'] if s2['total'] else 0:>9.1f}% "
          f"{100*(s2['entries']/s2['total']-s1['entries']/s1['total']) if s1['total'] and s2['total'] else 0:>+9.1f}%")

    # Per-filter comparison
    for fname in ["Baseline", "Base", "Loose"]:
        f1 = s1["filter_stats"][fname]
        f2 = s2["filter_stats"][fname]
        print(f"\n  ── {fname} ──")
        print(f"  {'Trades':<24} {f1['trades']:>10} {f2['trades']:>10} "
              f"{f2['trades']-f1['trades']:>+10}")
        print(f"  {'Wins':<24} {f1['wins']:>10} {f2['wins']:>10} "
              f"{f2['wins']-f1['wins']:>+10}")
        wr1 = f"{f1['win_rate']:.1f}%" if f1['trades'] else "-"
        wr2 = f"{f2['win_rate']:.1f}%" if f2['trades'] else "-"
        print(f"  {'WinRate':<24} {wr1:>10} {wr2:>10}")
        ap1 = f"{f1['avg_pnl']:.1f}" if f1['trades'] else "-"
        ap2 = f"{f2['avg_pnl']:.1f}" if f2['trades'] else "-"
        print(f"  {'AvgPnL (pips)':<24} {ap1:>10} {ap2:>10}")
        tp1 = f"{f1['tot_pnl']:.1f}" if f1['trades'] else "-"
        tp2 = f"{f2['tot_pnl']:.1f}" if f2['trades'] else "-"
        print(f"  {'TotPnL (pips)':<24} {tp1:>10} {tp2:>10}")
        pf1 = f"{f1['pf']:.2f}" if f1['trades'] else "-"
        pf2 = f"{f2['pf']:.2f}" if f2['trades'] else "-"
        print(f"  {'PF':<24} {pf1:>10} {pf2:>10}")

        # Exit reason distribution
        all_reasons = sorted(set(list(f1["exit_reasons"].keys()) +
                                 list(f2["exit_reasons"].keys())))
        if all_reasons:
            print(f"  Exit reasons:")
            for er in all_reasons:
                v1 = f1["exit_reasons"].get(er, 0)
                v2 = f2["exit_reasons"].get(er, 0)
                print(f"    {er:<22} {v1:>10} {v2:>10} {v2-v1:>+10}")

    # Reject stage comparison
    all_reject = sorted(set(list(s1["reject_counts"].keys()) +
                            list(s2["reject_counts"].keys())))
    if all_reject:
        print(f"\n  ── Reject Stage Comparison ──")
        print(f"  {'Stage':<28} {'Phase1':>10} {'Phase2':>10} {'Delta':>10}")
        print("  " + "-" * 60)
        for stage in all_reject:
            v1 = s1["reject_counts"].get(stage, 0)
            v2 = s2["reject_counts"].get(stage, 0)
            print(f"  {stage:<28} {v1:>10} {v2:>10} {v2-v1:>+10}")

    # ── CSV output (Phase 2) ──
    csv_path = os.path.join(script_dir, "sim_dat", "sim_results_fx_p2.csv")
    rows = []
    for r in p2:
        rows.append({
            "Phase": "P2",
            "ImpulseTime": r.impulse_time,
            "Direction": "LONG" if r.direction == Dir.LONG else "SHORT",
            "RangePts": round(r.impulse.range_pts, 1),
            "SpreadAtFreeze": round(r.impulse.spread_at_freeze, 0),
            "BandWidth": round(r.impulse.band_width / point(), 1),
            "ConfirmType": r.confirm_type,
            "RejectStage": r.reject_stage,
            "Baseline": r.baseline_reason,
            "Base": r.base_reason,
            "Loose": r.loose_reason,
            "EntryPrice": round(r.entry_price, 3) if r.entry_bar else "",
            "SL": round(r.sl_price, 3) if r.entry_bar else "",
            "ExitPrice": round(r.exit_price, 3) if r.exit_bar else "",
            "ExitReason": r.exit_reason,
            "PnL_pips": round(r.pnl_pips, 1) if r.entry_bar else "",
            "HoldBars_M1": r.hold_bars if r.hold_bars > 0 else "",
            "FreezeTime": r.freeze_time,
        })
    df_out = pd.DataFrame(rows)
    df_out.to_csv(csv_path, index=False)
    print(f"\nCSV written: {csv_path}  ({len(df_out)} rows)")


if __name__ == "__main__":
    main()
