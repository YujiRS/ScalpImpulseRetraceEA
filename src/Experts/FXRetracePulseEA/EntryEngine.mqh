//+------------------------------------------------------------------+
//| EntryEngine.mqh                                                   |
//| FX専用: Confirm判定・TrendFilter・ReversalGuard・M5SlopeFilter      |
//+------------------------------------------------------------------+
#ifndef __ENTRY_ENGINE_MQH__
#define __ENTRY_ENGINE_MQH__

//+------------------------------------------------------------------+
//| Confirm判定（FX: Engulfing OR MicroBreak）                         |
//+------------------------------------------------------------------+

// Engulfing（包み足）
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

// MicroBreak（フラクタル型）
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
   // MicroHighチェック（shift=3を中心、左右2本）
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

   // MicroLowチェック
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

// FX Confirm判定: Engulfing OR MicroBreak
ENUM_CONFIRM_TYPE EvaluateConfirm()
{
   if(CheckEngulfing())    return CONFIRM_ENGULFING;
   if(CheckMicroBreak())   return CONFIRM_MICRO_BREAK;
   return CONFIRM_NONE;
}

//+------------------------------------------------------------------+
//| TrendFilter / ReversalGuard                                       |
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

bool EvaluateTrendFilterAndGuard(string &rejectStageOut)
{
   rejectStageOut = "NONE";

   g_stats.TrendFilterEnable = TrendFilter_Enable ? 1 : 0;
   g_stats.TrendTF           = "M15";
   g_stats.TrendMethod       = "";
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
   g_stats.TrendMethod = "EMA50_SLOPE";
   double slopeMin = atr15 * TrendSlopeMult_FX;

   g_stats.TrendSlope       = slope;
   g_stats.TrendSlopeMin    = slopeMin;
   g_stats.TrendSlopeSet    = true;

   string trendDir = TrendDirFromSlope(slope, slopeMin);
   g_stats.TrendDir = trendDir;

   // FX: FLAT は通過（M5 slope フィルターに委ねる）
   if(trendDir == "FLAT")
   {
      g_stats.TrendAligned = 0;
      return true;
   }

   bool aligned = IsAlignedWithImpulse(trendDir);
   g_stats.TrendAligned = aligned ? 1 : 0;

   if(!aligned)
   {
      rejectStageOut = "TREND_MISMATCH";
      return false;
   }

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
   double bigBodyMult = ReversalBigBodyMult_FX;

   bool oppositeBigBody = (body >= (atr1 * bigBodyMult)) &&
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

   g_stats.ReversalGuardTriggered = 0;
   return true;
}

//+------------------------------------------------------------------+
//| M5 Slope Filter（FX P2 Base filter）                              |
//| STRONG かつ方向一致のみ PASS                                       |
//+------------------------------------------------------------------+
ENUM_M5_SLOPE ClassifyM5Slope(double slope, double threshold)
{
   double absSlope = MathAbs(slope);
   if(absSlope >= 2.0 * threshold) return M5_SLOPE_STRONG;
   if(absSlope >= threshold)       return M5_SLOPE_MID;
   return M5_SLOPE_FLAT;
}

bool EvaluateM5SlopeFilter(string &rejectReasonOut)
{
   rejectReasonOut = "NONE";

   double sma21[];
   ArraySetAsSeries(sma21, true);
   if(CopyBuffer(g_smaHandleM5_21, 0, 1, 2, sma21) != 2)
   {
      rejectReasonOut = "M5_SLOPE_DATA_ERROR";
      return false;
   }

   double slope = sma21[0] - sma21[1]; // SMA21[1] - SMA21[2] in series mode

   double atrM5[];
   ArraySetAsSeries(atrM5, true);
   if(CopyBuffer(g_atrHandleM5_14, 0, 1, 1, atrM5) != 1)
   {
      rejectReasonOut = "M5_SLOPE_DATA_ERROR";
      return false;
   }

   double threshold = atrM5[0] * 0.03;
   ENUM_M5_SLOPE classification = ClassifyM5Slope(slope, threshold);

   bool directionMatch = false;
   if(slope > 0 && g_impulseDir == DIR_LONG)  directionMatch = true;
   if(slope < 0 && g_impulseDir == DIR_SHORT) directionMatch = true;

   if(classification == M5_SLOPE_STRONG && directionMatch)
      return true;

   if(classification == M5_SLOPE_FLAT)
      rejectReasonOut = "M5_SLOPE_FLAT";
   else if(classification == M5_SLOPE_MID)
      rejectReasonOut = "M5_SLOPE_MID";
   else if(!directionMatch)
      rejectReasonOut = "M5_SLOPE_COUNTER";
   else
      rejectReasonOut = "M5_SLOPE_REJECT";

   return false;
}

#endif // __ENTRY_ENGINE_MQH__
