//+------------------------------------------------------------------+
//| RoleReversalEA.mq5                                                |
//| 5M Role-Reversal + MTF Analysis EA v1.0                          |
//| H1 S/R breakout → M5 pullback → EMA25+Confirm → Entry            |
//| Independent EA (not part of Impulse→Retrace family)               |
//+------------------------------------------------------------------+
#property copyright "RoleReversalEA"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Module Includes                                                    |
//+------------------------------------------------------------------+
#include "RoleReversalEA/Constants.mqh"
#include "RoleReversalEA/SRDetector.mqh"
#include "RoleReversalEA/ConfirmEngine.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+

// === G1: Operation ===
input bool              EnableTrading          = true;           // Enable Trading
input ENUM_RR_LOT_MODE  LotMode                = RR_LOT_FIXED;  // Lot Mode
input double            FixedLot               = 0.01;          // Fixed Lot
input double            RiskPercent            = 1.0;            // Risk % (of equity)
input ENUM_RR_LOG_LEVEL LogLevel               = RR_LOG_NORMAL; // Log Level
input int               MagicOffset            = 0;              // Magic Number Offset

// === G2: S/R Detection ===
input int               SR_SwingLookback       = 7;              // H1 Swing Lookback (bars each side)
input double            SR_MergeTolerance      = 0.5;            // Merge Tolerance (ATR fraction)
input int               SR_MaxAge              = 200;            // Max S/R Age (H1 bars)
input int               SR_MinTouches          = 2;              // Min Touches to qualify
input int               SR_RefreshInterval     = 12;             // Refresh S/R every N H1 bars

// === G3: Breakout Detection ===
input double            BO_BodyRatio           = 0.3;            // Min Body/Range for breakout candle
input int               BO_ConfirmBars         = 2;              // Consecutive closes for confirmation

// === G4: Pullback / Role Reversal ===
input double            PB_ZoneATR             = 0.5;            // Pullback Zone (ATR fraction)
input int               PB_MaxBars             = 120;            // Max M5 bars to wait
input int               PB_MinBars             = 2;              // Min bars after breakout

// === G5: EMA ===
input int               EMA_Period             = 25;             // M5 EMA Period
input int               EMA_TrendLookback      = 3;              // EMA Trend Lookback (bars)

// === G6: Confirm Patterns ===
input int               KR_Lookback            = 5;              // Key Reversal Lookback
input double            KR_BodyMinRatio        = 0.3;            // Key Reversal Body Min Ratio
input double            KR_ClosePosition       = 0.45;           // Key Reversal Close Position
input double            Engulf_BodyMinRatio    = 0.5;            // Engulfing Body Min Ratio
input double            Pin_BodyMaxRatio       = 0.35;           // Pin Bar Body Max Ratio
input double            Pin_WickRatio          = 2.0;            // Pin Bar Wick/Body Ratio

// === G7: Risk/Reward ===
input double            MinRR                  = 2.0;            // Minimum Reward:Risk
input double            MaxSL_ATR              = 2.0;            // Max SL (ATR multiple)
input double            SL_BufferPoints        = 50;             // SL Buffer (points)
input bool              UseFixedRR_TP          = true;           // Use Fixed R:R for TP

// === G8: Time Filter (Server Time / UTC) ===
input int               TradeHourStart         = 8;              // Trading Start Hour (UTC)
input int               TradeHourEnd           = 21;             // Trading End Hour (UTC)

// === G9: M15 Trend Filter ===
input bool              M15_TrendFilter        = true;           // Enable M15 Trend Filter
input int               M15_EMA_Period         = 50;             // M15 EMA Period

// === G10: Notification ===
input bool              EnableAlert            = true;           // Alert on entry
input bool              EnablePush             = false;          // Push notification on entry

// === G11: Visualization ===
input bool              EnableSRLines          = true;           // Draw S/R lines on chart
input bool              EnableStatusPanel      = true;           // On-chart status display (左下)

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
ENUM_RR_STATE g_state = RR_IDLE;
int           g_magic = RR_MAGIC_BASE;

// Indicator handles
int           g_emaM5Handle = INVALID_HANDLE;
int           g_atrM5Handle = INVALID_HANDLE;
int           g_emaM15Handle = INVALID_HANDLE;
int           g_atrH1Handle = INVALID_HANDLE;

// State tracking
int           g_breakoutLevelIdx = -1;      // Index into g_srLevels
int           g_breakoutDir = 0;            // 1=up, -1=down
int           g_breakoutBar = 0;            // M5 bar count at breakout
int           g_confirmCount = 0;
int           g_m5BarCount = 0;             // Running M5 bar count
datetime      g_lastM5Bar = 0;              // Last processed M5 bar time
datetime      g_lastH1Bar = 0;              // Last H1 bar for S/R refresh
int           g_h1BarsSinceRefresh = 0;
ENUM_CONFIRM_PATTERN g_lastConfirm = CONFIRM_NONE;

// Position
ulong         g_posTicket = 0;
double        g_posSL = 0;
double        g_posTP = 0;

//+------------------------------------------------------------------+
//| Module Includes (グローバル変数定義後)                               |
//+------------------------------------------------------------------+
#include "RoleReversalEA/Visualization.mqh"

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magic = RR_MAGIC_BASE + MagicOffset;

   // Create indicator handles
   g_emaM5Handle = iMA(Symbol(), PERIOD_M5, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_atrM5Handle = iATR(Symbol(), PERIOD_M5, 14);
   g_emaM15Handle = iMA(Symbol(), PERIOD_M15, M15_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_atrH1Handle = iATR(Symbol(), PERIOD_H1, 14);

   if(g_emaM5Handle == INVALID_HANDLE || g_atrM5Handle == INVALID_HANDLE ||
      g_emaM15Handle == INVALID_HANDLE || g_atrH1Handle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initial S/R detection
   double h1ATR[];
   ArraySetAsSeries(h1ATR, true);
   CopyBuffer(g_atrH1Handle, 0, 0, 20, h1ATR);
   double avgATR = 0;
   for(int i = 0; i < ArraySize(h1ATR); i++) avgATR += h1ATR[i];
   avgATR /= MathMax(1, ArraySize(h1ATR));

   DetectSRLevels(SR_SwingLookback, avgATR * SR_MergeTolerance, SR_MaxAge);
   CountSRTouches(SR_MergeTolerance);

   Print("RoleReversalEA v1.0 initialized. S/R levels: ", g_srCount, " Magic: ", g_magic);
   for(int i = 0; i < g_srCount; i++)
   {
      Print("  ", (g_srLevels[i].is_resistance ? "RES" : "SUP"),
            " @ ", DoubleToString(g_srLevels[i].price, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
            " touches=", g_srLevels[i].touch_count);
   }

   // Draw S/R levels on chart
   DrawSRLevels();

   // Check for existing position
   CheckExistingPosition();

   g_state = (g_posTicket > 0) ? RR_IN_POSITION : RR_IDLE;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ClearChartStatusPanel();

   if(g_emaM5Handle != INVALID_HANDLE) IndicatorRelease(g_emaM5Handle);
   if(g_atrM5Handle != INVALID_HANDLE) IndicatorRelease(g_atrM5Handle);
   if(g_emaM15Handle != INVALID_HANDLE) IndicatorRelease(g_emaM15Handle);
   if(g_atrH1Handle != INVALID_HANDLE) IndicatorRelease(g_atrH1Handle);
   Print("RoleReversalEA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process on new M5 bar only
   datetime m5Times[];
   ArraySetAsSeries(m5Times, true);
   CopyTime(Symbol(), PERIOD_M5, 0, 2, m5Times);
   if(ArraySize(m5Times) < 2) return;

   if(m5Times[0] == g_lastM5Bar)
      return;  // Same bar
   g_lastM5Bar = m5Times[0];
   g_m5BarCount++;

   // Refresh S/R periodically
   datetime h1Times[];
   ArraySetAsSeries(h1Times, true);
   CopyTime(Symbol(), PERIOD_H1, 0, 2, h1Times);
   if(ArraySize(h1Times) >= 1 && h1Times[0] != g_lastH1Bar)
   {
      g_lastH1Bar = h1Times[0];
      g_h1BarsSinceRefresh++;
      if(g_h1BarsSinceRefresh >= SR_RefreshInterval)
      {
         // リフレッシュ前: アクティブなブレイクアウトレベルの価格を保存
         double savedBreakoutPrice = 0;
         bool hasActiveBreakout = (g_breakoutLevelIdx >= 0 && g_breakoutLevelIdx < g_srCount &&
                                   g_state >= RR_BREAKOUT_DETECTED && g_state <= RR_PULLBACK_AT_LEVEL);
         if(hasActiveBreakout)
            savedBreakoutPrice = g_srLevels[g_breakoutLevelIdx].price;

         RefreshSRLevels();
         DrawSRLevels();

         // リフレッシュ後: g_breakoutLevelIdx を価格ベースで再同期
         if(hasActiveBreakout)
         {
            double h1ATR[];
            ArraySetAsSeries(h1ATR, true);
            CopyBuffer(g_atrH1Handle, 0, 0, 5, h1ATR);
            double tolerance = (ArraySize(h1ATR) > 0) ? h1ATR[0] * 0.1 : 0;
            int newIdx = -1;
            for(int si = 0; si < g_srCount; si++)
            {
               if(MathAbs(g_srLevels[si].price - savedBreakoutPrice) < tolerance)
               {
                  newIdx = si;
                  break;
               }
            }
            if(newIdx >= 0)
            {
               g_breakoutLevelIdx = newIdx;
               // アクティブなPullback Zoneを再描画
               double atrBuf[];
               ArraySetAsSeries(atrBuf, true);
               CopyBuffer(g_atrM5Handle, 0, 0, 2, atrBuf);
               if(ArraySize(atrBuf) > 0)
                  DrawPullbackZone(newIdx, atrBuf[0]);
            }
            else
            {
               // レベルがリフレッシュで消えた → ステート破棄
               if(LogLevel >= RR_LOG_DEBUG)
                  Print("BREAKOUT LEVEL LOST after S/R refresh. Resetting state.");
               ResetState();
            }
         }

         g_h1BarsSinceRefresh = 0;
      }
   }

   // State machine
   switch(g_state)
   {
      case RR_IN_POSITION:
         ManagePosition();
         break;
      case RR_IDLE:
         ScanForBreakout();
         break;
      case RR_BREAKOUT_DETECTED:
         ConfirmBreakout();
         break;
      case RR_WAITING_PULLBACK:
      case RR_PULLBACK_AT_LEVEL:
         WaitForPullbackAndConfirm();
         break;
      case RR_COOLDOWN:
         // Simple cooldown: wait 1 bar then go IDLE
         g_state = RR_IDLE;
         break;
      default:
         g_state = RR_IDLE;
         break;
   }

   // Pullback Zone の右端を追従
   if(g_state >= RR_WAITING_PULLBACK && g_state <= RR_PULLBACK_AT_LEVEL
      && g_breakoutLevelIdx >= 0)
   {
      UpdatePullbackZoneEnd(g_breakoutLevelIdx);
   }

   // Status Panel 更新
   UpdateChartStatusPanel();
}

//+------------------------------------------------------------------+
//| Refresh S/R levels (periodic)                                      |
//+------------------------------------------------------------------+
void RefreshSRLevels()
{
   // Preserve broken/used status
   double oldBroken[];
   bool   oldUsed[];
   int    oldCount = g_srCount;
   ArrayResize(oldBroken, oldCount);
   ArrayResize(oldUsed, oldCount);
   for(int i = 0; i < oldCount; i++)
   {
      oldBroken[i] = g_srLevels[i].price;
      oldUsed[i] = g_srLevels[i].used || g_srLevels[i].broken;
   }

   double h1ATR[];
   ArraySetAsSeries(h1ATR, true);
   CopyBuffer(g_atrH1Handle, 0, 0, 20, h1ATR);
   double avgATR = 0;
   for(int i = 0; i < ArraySize(h1ATR); i++) avgATR += h1ATR[i];
   avgATR /= MathMax(1, ArraySize(h1ATR));

   DetectSRLevels(SR_SwingLookback, avgATR * SR_MergeTolerance, SR_MaxAge);

   // Re-apply broken/used status for matching levels
   for(int i = 0; i < g_srCount; i++)
   {
      for(int j = 0; j < oldCount; j++)
      {
         if(MathAbs(g_srLevels[i].price - oldBroken[j]) < avgATR * 0.1 && oldUsed[j])
         {
            g_srLevels[i].used = true;
            g_srLevels[i].broken = true;
            break;
         }
      }
   }

   if(LogLevel >= RR_LOG_DEBUG)
      Print("S/R refreshed: ", g_srCount, " levels");
}

//+------------------------------------------------------------------+
//| Scan for breakout of S/R levels                                    |
//+------------------------------------------------------------------+
void ScanForBreakout()
{
   // Time filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < TradeHourStart || dt.hour >= TradeHourEnd)
      return;

   // Get current M5 data
   double m5Close[], m5Open[], m5Atr[];
   ArraySetAsSeries(m5Close, true);
   ArraySetAsSeries(m5Open, true);
   ArraySetAsSeries(m5Atr, true);
   CopyClose(Symbol(), PERIOD_M5, 0, 3, m5Close);
   CopyOpen(Symbol(), PERIOD_M5, 0, 3, m5Open);
   CopyBuffer(g_atrM5Handle, 0, 0, 3, m5Atr);

   if(ArraySize(m5Close) < 3) return;

   // Current bar [1] (completed), previous [2]
   double currClose = m5Close[1];
   double prevClose = m5Close[2];

   for(int i = 0; i < g_srCount; i++)
   {
      if(g_srLevels[i].broken || g_srLevels[i].used)
         continue;

      double levelPrice = g_srLevels[i].price;

      // Bullish breakout: previous close was at/below level, current close above
      if(currClose > levelPrice && prevClose <= levelPrice)
      {
         double body = MathAbs(m5Close[1] - m5Open[1]);
         double rng = 0;
         double h[], l[];
         ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
         CopyHigh(Symbol(), PERIOD_M5, 0, 3, h);
         CopyLow(Symbol(), PERIOD_M5, 0, 3, l);
         rng = h[1] - l[1];
         if(rng <= 0 || body / rng < BO_BodyRatio)
            continue;

         // M15 trend filter
         if(M15_TrendFilter && !CheckM15Trend(RR_DIR_LONG))
            continue;

         g_breakoutLevelIdx = i;
         g_breakoutDir = RR_DIR_LONG;
         g_breakoutBar = g_m5BarCount;
         g_confirmCount = 1;
         g_srLevels[i].broken = true;
         g_srLevels[i].broken_direction = RR_DIR_LONG;
         g_srLevels[i].broken_time = TimeCurrent();
         g_state = RR_BREAKOUT_DETECTED;

         // S/Rライン更新＋プルバックゾーン描画
         DrawSRLevels();
         double atrBuf[];
         ArraySetAsSeries(atrBuf, true);
         CopyBuffer(g_atrM5Handle, 0, 0, 2, atrBuf);
         if(ArraySize(atrBuf) > 0) DrawPullbackZone(i, atrBuf[0]);

         if(LogLevel >= RR_LOG_DEBUG)
            Print("BREAKOUT UP detected @ ", DoubleToString(levelPrice, _Digits),
                  " bar=", g_m5BarCount);
         return;
      }

      // Bearish breakout
      if(currClose < levelPrice && prevClose >= levelPrice)
      {
         double body = MathAbs(m5Close[1] - m5Open[1]);
         double h[], l[];
         ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
         CopyHigh(Symbol(), PERIOD_M5, 0, 3, h);
         CopyLow(Symbol(), PERIOD_M5, 0, 3, l);
         double rng = h[1] - l[1];
         if(rng <= 0 || body / rng < BO_BodyRatio)
            continue;

         if(M15_TrendFilter && !CheckM15Trend(RR_DIR_SHORT))
            continue;

         g_breakoutLevelIdx = i;
         g_breakoutDir = RR_DIR_SHORT;
         g_breakoutBar = g_m5BarCount;
         g_confirmCount = 1;
         g_srLevels[i].broken = true;
         g_srLevels[i].broken_direction = RR_DIR_SHORT;
         g_srLevels[i].broken_time = TimeCurrent();
         g_state = RR_BREAKOUT_DETECTED;

         DrawSRLevels();
         double atrBuf2[];
         ArraySetAsSeries(atrBuf2, true);
         CopyBuffer(g_atrM5Handle, 0, 0, 2, atrBuf2);
         if(ArraySize(atrBuf2) > 0) DrawPullbackZone(i, atrBuf2[0]);

         if(LogLevel >= RR_LOG_DEBUG)
            Print("BREAKOUT DOWN detected @ ", DoubleToString(levelPrice, _Digits),
                  " bar=", g_m5BarCount);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Confirm breakout (consecutive closes)                              |
//+------------------------------------------------------------------+
void ConfirmBreakout()
{
   if(g_breakoutLevelIdx < 0 || g_breakoutLevelIdx >= g_srCount)
   {
      ResetState();
      return;
   }

   double m5Close[];
   ArraySetAsSeries(m5Close, true);
   CopyClose(Symbol(), PERIOD_M5, 0, 2, m5Close);
   if(ArraySize(m5Close) < 2) return;

   double levelPrice = g_srLevels[g_breakoutLevelIdx].price;

   if(g_breakoutDir == RR_DIR_LONG)
   {
      if(m5Close[1] > levelPrice)
         g_confirmCount++;
      else
      {
         // Breakout failed
         g_srLevels[g_breakoutLevelIdx].broken = false;
         ResetState();
         return;
      }
   }
   else
   {
      if(m5Close[1] < levelPrice)
         g_confirmCount++;
      else
      {
         g_srLevels[g_breakoutLevelIdx].broken = false;
         ResetState();
         return;
      }
   }

   if(g_confirmCount >= BO_ConfirmBars)
   {
      g_state = RR_WAITING_PULLBACK;
      if(LogLevel >= RR_LOG_DEBUG)
         Print("BREAKOUT CONFIRMED. Waiting for pullback...");
   }
}

//+------------------------------------------------------------------+
//| Wait for pullback to broken level + check confluence               |
//+------------------------------------------------------------------+
void WaitForPullbackAndConfirm()
{
   if(g_breakoutLevelIdx < 0 || g_breakoutLevelIdx >= g_srCount)
   {
      ResetState();
      return;
   }

   int barsSinceBreakout = g_m5BarCount - g_breakoutBar;

   // Timeout
   if(barsSinceBreakout > PB_MaxBars)
   {
      if(LogLevel >= RR_LOG_DEBUG)
         Print("PULLBACK TIMEOUT after ", barsSinceBreakout, " bars");
      g_srLevels[g_breakoutLevelIdx].used = true;
      ResetState();
      return;
   }

   // Too early
   if(barsSinceBreakout < PB_MinBars)
      return;

   // Time filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < TradeHourStart || dt.hour >= TradeHourEnd)
      return;

   // Get data
   double m5Close[], m5High[], m5Low[], m5Atr[], m5Ema[];
   ArraySetAsSeries(m5Close, true);
   ArraySetAsSeries(m5High, true);
   ArraySetAsSeries(m5Low, true);
   ArraySetAsSeries(m5Atr, true);
   ArraySetAsSeries(m5Ema, true);

   CopyClose(Symbol(), PERIOD_M5, 0, 10, m5Close);
   CopyHigh(Symbol(), PERIOD_M5, 0, 10, m5High);
   CopyLow(Symbol(), PERIOD_M5, 0, 10, m5Low);
   CopyBuffer(g_atrM5Handle, 0, 0, 10, m5Atr);
   CopyBuffer(g_emaM5Handle, 0, 0, EMA_TrendLookback + 3, m5Ema);

   if(ArraySize(m5Close) < 3 || ArraySize(m5Atr) < 2 || ArraySize(m5Ema) < EMA_TrendLookback + 2)
      return;

   double levelPrice = g_srLevels[g_breakoutLevelIdx].price;
   double atrVal = m5Atr[1];
   double zone = atrVal * PB_ZoneATR;

   // Check if price is at the role reversal zone (completed bar [1])
   bool priceAtLevel = false;
   if(g_breakoutDir == RR_DIR_LONG)
   {
      // Pulled back from above
      if(m5Low[1] <= levelPrice + zone && m5Close[1] >= levelPrice - zone * 0.5)
         priceAtLevel = true;

      // Full retracement → abandon
      if(m5Close[1] < levelPrice - zone * 2)
      {
         g_srLevels[g_breakoutLevelIdx].used = true;
         ResetState();
         return;
      }
   }
   else
   {
      // Pulled back from below
      if(m5High[1] >= levelPrice - zone && m5Close[1] <= levelPrice + zone * 0.5)
         priceAtLevel = true;

      if(m5Close[1] > levelPrice + zone * 2)
      {
         g_srLevels[g_breakoutLevelIdx].used = true;
         ResetState();
         return;
      }
   }

   if(!priceAtLevel)
      return;

   // --- Confluence checks ---
   int tradeDir = g_breakoutDir;

   // (A) EMA trend check
   if(ArraySize(m5Ema) >= EMA_TrendLookback + 2)
   {
      double emaNow = m5Ema[1];
      double emaPrev = m5Ema[1 + EMA_TrendLookback];
      bool emaTrendOK = (tradeDir == RR_DIR_LONG) ? (emaNow > emaPrev) : (emaNow < emaPrev);
      if(!emaTrendOK)
      {
         if(LogLevel >= RR_LOG_ANALYZE)
            Print("REJECT: EMA trend against direction");
         return;
      }
   }

   // (B) EMA support/resistance check
   double emaVal = m5Ema[1];
   if(tradeDir == RR_DIR_LONG)
   {
      if(!(m5Low[1] >= emaVal - zone && m5Close[1] > emaVal))
      {
         if(LogLevel >= RR_LOG_ANALYZE)
            Print("REJECT: EMA not supporting long");
         return;
      }
   }
   else
   {
      if(!(m5High[1] <= emaVal + zone && m5Close[1] < emaVal))
      {
         if(LogLevel >= RR_LOG_ANALYZE)
            Print("REJECT: EMA not supporting short");
         return;
      }
   }

   // (C) Confirm pattern (on completed bar, shift=1)
   ENUM_CONFIRM_PATTERN confirm = CONFIRM_NONE;
   if(tradeDir == RR_DIR_LONG)
      confirm = CheckBullishConfirm(1, KR_Lookback, KR_BodyMinRatio, KR_ClosePosition,
                                     Engulf_BodyMinRatio, Pin_BodyMaxRatio, Pin_WickRatio);
   else
      confirm = CheckBearishConfirm(1, KR_Lookback, KR_BodyMinRatio, KR_ClosePosition,
                                     Engulf_BodyMinRatio, Pin_BodyMaxRatio, Pin_WickRatio);

   if(confirm == CONFIRM_NONE)
   {
      if(LogLevel >= RR_LOG_ANALYZE)
         Print("REJECT: No confirm pattern");
      return;
   }

   // (D) Calculate SL/TP and check R:R
   double entry = m5Close[1];
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double buffer = SL_BufferPoints * point;
   double sl, tp, slDist;

   if(tradeDir == RR_DIR_LONG)
   {
      sl = m5Low[1] - buffer;
      slDist = entry - sl;
   }
   else
   {
      sl = m5High[1] + buffer;
      slDist = sl - entry;
   }

   // Check SL not too wide
   if(slDist > atrVal * MaxSL_ATR || slDist <= 0)
   {
      if(LogLevel >= RR_LOG_DEBUG)
         Print("REJECT: SL too wide. slDist=", DoubleToString(slDist, _Digits),
               " limit=", DoubleToString(atrVal * MaxSL_ATR, _Digits));
      return;
   }

   // TP calculation
   if(UseFixedRR_TP)
   {
      tp = (tradeDir == RR_DIR_LONG) ?
           entry + slDist * MinRR :
           entry - slDist * MinRR;
   }
   else
   {
      double nextLevel = FindNextSRLevel(entry, tradeDir);
      if(nextLevel > 0)
      {
         tp = nextLevel;
         double tpDist = MathAbs(tp - entry);
         if(tpDist / slDist < MinRR)
            tp = (tradeDir == RR_DIR_LONG) ?
                 entry + slDist * MinRR :
                 entry - slDist * MinRR;
      }
      else
      {
         tp = (tradeDir == RR_DIR_LONG) ?
              entry + slDist * MinRR :
              entry - slDist * MinRR;
      }
   }

   // === ALL CONDITIONS MET → EXECUTE ===
   g_lastConfirm = confirm;
   if(EnableTrading)
   {
      if(ExecuteEntry(tradeDir, sl, tp, confirm))
      {
         g_srLevels[g_breakoutLevelIdx].used = true;
         g_state = RR_IN_POSITION;

         // エントリー確定 → Pullback Zone削除 + SR線を最新状態に更新
         DeletePullbackZone(g_breakoutLevelIdx);
         DrawSRLevels();

         string confirmName = ConfirmPatternName(confirm);
         string msg = StringFormat("RoleReversal ENTRY: %s @ %s SL=%s TP=%s Pattern=%s Level=%s",
                                    (tradeDir == RR_DIR_LONG ? "LONG" : "SHORT"),
                                    DoubleToString(entry, _Digits),
                                    DoubleToString(sl, _Digits),
                                    DoubleToString(tp, _Digits),
                                    confirmName,
                                    DoubleToString(levelPrice, _Digits));
         Print(msg);

         if(EnableAlert) Alert(msg);
         if(EnablePush) SendNotification(msg);
      }
      else
      {
         Print("ENTRY FAILED: Order execution error");
         ResetState();
      }
   }
   else
   {
      Print("SIGNAL (no trade): ", (tradeDir == RR_DIR_LONG ? "LONG" : "SHORT"),
            " @ ", DoubleToString(entry, _Digits),
            " Confirm=", ConfirmPatternName(confirm));
      g_srLevels[g_breakoutLevelIdx].used = true;
      ResetState();
   }
}

//+------------------------------------------------------------------+
//| Execute entry order                                                |
//+------------------------------------------------------------------+
bool ExecuteEntry(int direction, double sl, double tp, ENUM_CONFIRM_PATTERN confirm)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = Symbol();
   request.type = (direction == RR_DIR_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = (direction == RR_DIR_LONG) ?
                    SymbolInfoDouble(Symbol(), SYMBOL_ASK) :
                    SymbolInfoDouble(Symbol(), SYMBOL_BID);
   request.volume = CalculateLot(request.price, sl);
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 20;
   request.magic = g_magic;
   request.comment = "RR_" + ConfirmPatternName(confirm);

   // Filling mode
   long fillMode = SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(request, result))
   {
      Print("OrderSend failed: ", result.retcode, " ", result.comment);
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      g_posTicket = result.deal;
      g_posSL = sl;
      g_posTP = tp;
      return true;
   }

   Print("OrderSend retcode: ", result.retcode, " ", result.comment);
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                 |
//+------------------------------------------------------------------+
double CalculateLot(double entryPrice, double slPrice)
{
   if(LotMode == RR_LOT_FIXED)
      return FixedLot;

   // Risk-based lot calculation
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double slDistance = MathAbs(entryPrice - slPrice);

   if(tickValue <= 0 || tickSize <= 0 || slDistance <= 0)
      return FixedLot;

   double lot = riskAmount / (slDistance / tickSize * tickValue);

   // Normalize to symbol constraints
   double lotMin = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double lotMax = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lot = MathMax(lotMin, MathMin(lotMax, lot));

   //--- FreeMargin上限チェック: 算出ロットが実際に建てられるか検証
   ENUM_ORDER_TYPE orderType = (entryPrice > slPrice) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin = 0;
   if(freeMargin > 0 && OrderCalcMargin(orderType, Symbol(), lot, entryPrice, margin))
   {
      if(margin > freeMargin * 0.95)
      {
         double maxAffordLot = lot * (freeMargin * 0.95) / margin;
         maxAffordLot = MathFloor(maxAffordLot / lotStep) * lotStep;
         lot = MathMax(lotMin, maxAffordLot);
      }
   }

   lot = MathFloor(lot / lotStep) * lotStep;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Manage open position                                               |
//+------------------------------------------------------------------+
void ManagePosition()
{
   // Check if position still exists
   if(!CheckExistingPosition())
   {
      Print("Position closed externally or by SL/TP");
      g_state = RR_COOLDOWN;
      g_posTicket = 0;
      ResetState();
      return;
   }
}

//+------------------------------------------------------------------+
//| Check if we have an existing position with our magic              |
//+------------------------------------------------------------------+
bool CheckExistingPosition()
{
   g_posTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == g_magic &&
         PositionGetString(POSITION_SYMBOL) == Symbol())
      {
         g_posTicket = ticket;
         g_posSL = PositionGetDouble(POSITION_SL);
         g_posTP = PositionGetDouble(POSITION_TP);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check M15 trend alignment                                          |
//+------------------------------------------------------------------+
bool CheckM15Trend(int direction)
{
   double m15Close[], m15Ema[];
   ArraySetAsSeries(m15Close, true);
   ArraySetAsSeries(m15Ema, true);

   CopyClose(Symbol(), PERIOD_M15, 0, 3, m15Close);
   CopyBuffer(g_emaM15Handle, 0, 0, 3, m15Ema);

   if(ArraySize(m15Close) < 2 || ArraySize(m15Ema) < 2)
      return true;  // Allow if data unavailable

   if(direction == RR_DIR_LONG)
      return m15Close[1] > m15Ema[1];
   else
      return m15Close[1] < m15Ema[1];
}

//+------------------------------------------------------------------+
//| Reset state machine                                                |
//+------------------------------------------------------------------+
void ResetState()
{
   if(g_breakoutLevelIdx >= 0)
   {
      DeletePullbackZone(g_breakoutLevelIdx);
      DrawSRLevels();
   }
   g_breakoutLevelIdx = -1;
   g_breakoutDir = 0;
   g_breakoutBar = 0;
   g_confirmCount = 0;
   g_lastConfirm = CONFIRM_NONE;
   g_state = RR_IDLE;
}

//+------------------------------------------------------------------+
//| Confirm pattern name                                               |
//+------------------------------------------------------------------+
string ConfirmPatternName(ENUM_CONFIRM_PATTERN p)
{
   switch(p)
   {
      case CONFIRM_KEY_REVERSAL: return "KeyReversal";
      case CONFIRM_ENGULFING:    return "Engulfing";
      case CONFIRM_PIN_BAR:      return "PinBar";
      default:                   return "None";
   }
}

//+------------------------------------------------------------------+
