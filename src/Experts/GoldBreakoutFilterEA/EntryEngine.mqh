//+------------------------------------------------------------------+
//| EntryEngine.mqh                                                   |
//| GOLD専用: Confirm判定・TrendFilter・ReversalGuard                   |
//| EMA Cross Filter・Impulse Exceed Filter                           |
//+------------------------------------------------------------------+
#ifndef __ENTRY_ENGINE_MQH__
#define __ENTRY_ENGINE_MQH__

//+------------------------------------------------------------------+
//| Confirm判定（GOLD: WickRejection OR MicroBreak）                   |
//+------------------------------------------------------------------+

// A) WickRejection（ヒゲ拒否）
bool CheckWickRejection()
{
   double open1  = iOpen(Symbol(), PERIOD_M1, 1);
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double high1  = iHigh(Symbol(), PERIOD_M1, 1);
   double low1   = iLow(Symbol(), PERIOD_M1, 1);

   double fullRange = high1 - low1;
   if(fullRange <= 0) return false;

   double bandUpper, bandLower;
   GetActiveBand(bandUpper, bandLower);

   if(g_impulseDir == DIR_LONG)
   {
      double lowerWick = MathMin(open1, close1) - low1;
      double wickRatio = lowerWick / fullRange;
      if(wickRatio < g_profile.wickRatioMin) return false;
      if(close1 >= bandLower) return true;
   }
   else
   {
      double upperWick = high1 - MathMax(open1, close1);
      double wickRatio = upperWick / fullRange;
      if(wickRatio < g_profile.wickRatioMin) return false;
      if(close1 <= bandUpper) return true;
   }

   return false;
}

// B) Engulfing（包み足）
bool CheckEngulfing()
{
   double open1  = iOpen(Symbol(), PERIOD_M1, 1);
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double open2  = iOpen(Symbol(), PERIOD_M1, 2);
   double close2 = iClose(Symbol(), PERIOD_M1, 2);

   double body1_upper = MathMax(open1, close1);
   double body1_lower = MathMin(open1, close1);
   double body2_upper = MathMax(open2, close2);
   double body2_lower = MathMin(open2, close2);

   if(g_impulseDir == DIR_LONG)
   {
      if(close1 > open1 &&
         body1_upper > body2_upper &&
         body1_lower < body2_lower)
         return true;
   }
   else
   {
      if(close1 < open1 &&
         body1_upper > body2_upper &&
         body1_lower < body2_lower)
         return true;
   }

   return false;
}

// C) MicroBreak（フラクタル型）
bool CheckMicroBreak()
{
   double close1 = iClose(Symbol(), PERIOD_M1, 1);

   UpdateFractalMicroLevels();

   if(g_impulseDir == DIR_LONG)
   {
      if(g_microHighValid && close1 > g_microHigh)
         return true;
   }
   else
   {
      if(g_microLowValid && close1 < g_microLow)
         return true;
   }

   return false;
}

// フラクタルMicroHigh/MicroLow更新
void UpdateFractalMicroLevels()
{
   for(int i = 3; i < 20; i++)
   {
      double h_i   = iHigh(Symbol(), PERIOD_M1, i);
      double h_im1 = iHigh(Symbol(), PERIOD_M1, i - 1);
      double h_im2 = iHigh(Symbol(), PERIOD_M1, i - 2);
      double h_ip1 = iHigh(Symbol(), PERIOD_M1, i + 1);
      double h_ip2 = iHigh(Symbol(), PERIOD_M1, i + 2);

      if(h_i > h_im1 && h_i > h_im2 && h_i > h_ip1 && h_i > h_ip2)
      {
         g_microHigh = h_i;
         g_microHighValid = true;
         break;
      }
   }

   for(int i = 3; i < 20; i++)
   {
      double l_i   = iLow(Symbol(), PERIOD_M1, i);
      double l_im1 = iLow(Symbol(), PERIOD_M1, i - 1);
      double l_im2 = iLow(Symbol(), PERIOD_M1, i - 2);
      double l_ip1 = iLow(Symbol(), PERIOD_M1, i + 1);
      double l_ip2 = iLow(Symbol(), PERIOD_M1, i + 2);

      if(l_i < l_im1 && l_i < l_im2 && l_i < l_ip1 && l_i < l_ip2)
      {
         g_microLow = l_i;
         g_microLowValid = true;
         break;
      }
   }
}

// GOLD Confirm判定: WickRejection OR MicroBreak
ENUM_CONFIRM_TYPE EvaluateConfirm()
{
   if(CheckWickRejection())
   {
      g_wickRejectionSeen = true;
      return CONFIRM_WICK_REJECTION;
   }
   if(CheckMicroBreak())
      return CONFIRM_MICRO_BREAK;

   return CONFIRM_NONE;
}

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
