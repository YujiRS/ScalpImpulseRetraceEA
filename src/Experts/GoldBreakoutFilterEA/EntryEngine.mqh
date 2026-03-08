//+------------------------------------------------------------------+
//| EntryEngine.mqh                                                   |
//| GOLD専用: TrendFilter・ReversalGuard                               |
//| EMA Cross Filter・Impulse Exceed Filter                           |
//| v2.1: Confirm判定はMABounceEngine.mqhに移行                        |
//+------------------------------------------------------------------+
#ifndef __ENTRY_ENGINE_MQH__
#define __ENTRY_ENGINE_MQH__

//+------------------------------------------------------------------+
//| TrendFilter / ReversalGuard (GOLD専用)                            |
//+------------------------------------------------------------------+

string TrendDirFromSlope(double slope, double slopeMin)
{
   if(slope >= slopeMin)  return "LONG";
   if(slope <= -slopeMin) return "SHORT";
   return "FLAT";
}

bool IsAlignedWithImpulse(string trendDir)
{
   if(g_impulseDir == DIR_LONG  && trendDir == "LONG")  return true;
   if(g_impulseDir == DIR_SHORT && trendDir == "SHORT") return true;
   return false;
}

bool IsBearishEngulfing(string sym, ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1);
   double c1 = iClose(sym, tf, 1);
   double o2 = iOpen(sym, tf, 2);
   double c2 = iClose(sym, tf, 2);

   if(c1 >= o1) return false;

   double bodyHi1 = MathMax(o1, c1);
   double bodyLo1 = MathMin(o1, c1);
   double bodyHi2 = MathMax(o2, c2);
   double bodyLo2 = MathMin(o2, c2);

   return (bodyHi1 >= bodyHi2 && bodyLo1 <= bodyLo2);
}

bool IsBullishEngulfing(string sym, ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1);
   double c1 = iClose(sym, tf, 1);
   double o2 = iOpen(sym, tf, 2);
   double c2 = iClose(sym, tf, 2);

   if(c1 <= o1) return false;

   double bodyHi1 = MathMax(o1, c1);
   double bodyLo1 = MathMin(o1, c1);
   double bodyHi2 = MathMax(o2, c2);
   double bodyLo2 = MathMin(o2, c2);

   return (bodyHi1 >= bodyHi2 && bodyLo1 <= bodyLo2);
}

bool WickRejectOpposite_GOLD(bool impulseLong)
{
   double o = iOpen(Symbol(), PERIOD_H1, 1);
   double c = iClose(Symbol(), PERIOD_H1, 1);
   double h = iHigh(Symbol(), PERIOD_H1, 1);
   double l = iLow(Symbol(), PERIOD_H1, 1);

   double range = h - l;
   if(range <= 0) return false;

   double upper = h - MathMax(o, c);
   double lower = MathMin(o, c) - l;

   if(impulseLong)
      return (upper / range) >= ReversalWickRatioMin_GOLD;
   else
      return (lower / range) >= ReversalWickRatioMin_GOLD;
}

bool EvaluateTrendFilterAndGuard(string &rejectStageOut)
{
   rejectStageOut = "NONE";

   g_stats.TrendFilterEnable = TrendFilter_Enable ? 1 : 0;
   g_stats.TrendTF           = "M15";
   g_stats.TrendMethod       = "EMA50_SLOPE";
   g_stats.TrendDir          = "";
   g_stats.TrendSlope        = 0.0;
   g_stats.TrendSlopeMin     = 0.0;
   g_stats.TrendSlopeSet     = false;
   g_stats.TrendATRFloor     = 0.0;
   g_stats.TrendATRFloorSet  = false;
   g_stats.TrendAligned      = -1;

   g_stats.ReversalGuardEnable     = ReversalGuard_Enable ? 1 : 0;
   g_stats.ReversalTF             = "H1";
   g_stats.ReversalGuardTriggered = -1;
   g_stats.ReversalReason         = "";

   if(!TrendFilter_Enable)
      return true;

   string sym = Symbol();

   double ema50_1 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_2 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 2);
   double atr15   = GetATRValue(sym, PERIOD_M15, 14, 1);

   if(ema50_1 == EMPTY_VALUE || ema50_2 == EMPTY_VALUE || atr15 == EMPTY_VALUE)
   {
      g_stats.TrendDir = "FLAT";
      g_stats.TrendAligned = 0;
      rejectStageOut = "TREND_FLAT";
      return false;
   }

   double slope    = ema50_1 - ema50_2;
   double slopeMin = atr15 * TrendSlopeMult_GOLD;

   g_stats.TrendSlope       = slope;
   g_stats.TrendSlopeMin    = slopeMin;
   g_stats.TrendSlopeSet    = true;

   // GOLD ATR Floor: ATR(M15)がFloor未満→FLAT扱い
   double atrPts = (atr15 / _Point);
   g_stats.TrendATRFloor    = TrendATRFloorPts_GOLD;
   g_stats.TrendATRFloorSet = true;

   string trendDir = "FLAT";
   if(atrPts < TrendATRFloorPts_GOLD)
      trendDir = "FLAT";
   else
      trendDir = TrendDirFromSlope(slope, slopeMin);

   g_stats.TrendDir = trendDir;

   if(trendDir == "FLAT")
   {
      g_stats.TrendAligned = 0;
      rejectStageOut = "TREND_FLAT";
      return false;
   }

   bool aligned = IsAlignedWithImpulse(trendDir);
   g_stats.TrendAligned = aligned ? 1 : 0;

   if(!aligned)
   {
      rejectStageOut = "TREND_MISMATCH";
      return false;
   }

   // ── EMA Cross Filter (EMA20 vs EMA50 position) ──
   if(EMACrossFilter_Enable_GOLD)
   {
      g_stats.EMACrossFilterEnable = 1;

      double emaFast = GetMAValue(sym, PERIOD_M15, EMACrossFilter_FastPeriod_GOLD,
                                  MODE_EMA, PRICE_CLOSE, 1);
      g_stats.EMACrossFastVal = emaFast;
      g_stats.EMACrossSlowVal = ema50_1;

      if(emaFast == EMPTY_VALUE)
      {
         g_stats.EMACrossDir = "FLAT";
         g_stats.EMACrossAligned = 0;
         rejectStageOut = "EMA_CROSS_NODATA";
         return false;
      }

      string crossDir = "FLAT";
      if(emaFast > ema50_1)       crossDir = "LONG";
      else if(emaFast < ema50_1)  crossDir = "SHORT";

      g_stats.EMACrossDir = crossDir;

      bool crossAligned = IsAlignedWithImpulse(crossDir);
      g_stats.EMACrossAligned = crossAligned ? 1 : 0;

      if(!crossAligned)
      {
         rejectStageOut = "EMA_CROSS_MISMATCH";
         return false;
      }
   }
   else
   {
      g_stats.EMACrossFilterEnable = 0;
   }

   // ReversalGuard
   if(!ReversalGuard_Enable)
   {
      g_stats.ReversalGuardTriggered = 0;
      return true;
   }

   bool impulseLong = (g_impulseDir == DIR_LONG);

   double o1 = iOpen(sym, PERIOD_H1, 1);
   double c1 = iClose(sym, PERIOD_H1, 1);
   double atr1= GetATRValue(sym, PERIOD_H1, 14, 1);

   if(atr1 == EMPTY_VALUE)
   {
      g_stats.ReversalGuardTriggered = 0;
      return true;
   }

   double body = MathAbs(c1 - o1);

   bool oppositeBigBody = (body >= (atr1 * ReversalBigBodyMult_GOLD)) &&
                          ((impulseLong && (c1 < o1)) || (!impulseLong && (c1 > o1)));

   if(oppositeBigBody)
   {
      g_stats.ReversalGuardTriggered = 1;
      g_stats.ReversalReason = "BIG_BODY";
      rejectStageOut = "REVERSAL_GUARD";
      return false;
   }

   if(ReversalEngulfing_Enable)
   {
      bool oppEng = impulseLong ? IsBearishEngulfing(sym, PERIOD_H1) : IsBullishEngulfing(sym, PERIOD_H1);
      if(oppEng)
      {
         g_stats.ReversalGuardTriggered = 1;
         g_stats.ReversalReason = "ENGULFING";
         rejectStageOut = "REVERSAL_GUARD";
         return false;
      }
   }

   if(ReversalWickReject_Enable_GOLD)
   {
      if(WickRejectOpposite_GOLD(impulseLong))
      {
         g_stats.ReversalGuardTriggered = 1;
         g_stats.ReversalReason = "WICK_REJECT";
         rejectStageOut = "REVERSAL_GUARD";
         return false;
      }
   }

   g_stats.ReversalGuardTriggered = 0;
   return true;
}

//+------------------------------------------------------------------+
//| Impulse Exceed Filter (overextension guard)                      |
//+------------------------------------------------------------------+
bool EvaluateImpulseExceedFilter(string &rejectStageOut)
{
   if(!ImpulseExceed_Enable_GOLD)
   {
      g_stats.ImpulseExceedEnable = 0;
      return true;
   }

   g_stats.ImpulseExceedEnable = 1;
   g_stats.ImpulseExceedMax = ImpulseExceed_MaxATR_GOLD;

   string sym = Symbol();
   double atr15 = GetATRValue(sym, PERIOD_M15, 14, 1);

   if(atr15 == EMPTY_VALUE || atr15 <= 0)
   {
      g_stats.ImpulseExceedTriggered = 0;
      return true;
   }

   double impulseRange = MathAbs(g_impulseEnd - g_impulseStart);
   double ratio = impulseRange / atr15;

   g_stats.ImpulseRangeATR = ratio;

   if(ratio > ImpulseExceed_MaxATR_GOLD)
   {
      g_stats.ImpulseExceedTriggered = 1;
      rejectStageOut = "IMPULSE_EXCEED";
      return false;
   }

   g_stats.ImpulseExceedTriggered = 0;
   return true;
}

#endif // __ENTRY_ENGINE_MQH__
