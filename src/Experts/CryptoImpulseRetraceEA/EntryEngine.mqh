//+------------------------------------------------------------------+
//| EntryEngine.mqh                                                   |
//| CRYPTO専用: MicroBreak Confirm・TrendFilter(EMA21×EMA50)           |
//| ReversalGuard(軽量)・FlatFilter(M5 range-based)                    |
//+------------------------------------------------------------------+
#ifndef __ENTRY_ENGINE_MQH__
#define __ENTRY_ENGINE_MQH__

//+------------------------------------------------------------------+
//| MicroBreak（CRYPTO: 3-bar lookback、フラクタルではなく直近3本max/min） |
//+------------------------------------------------------------------+
void UpdateLookbackMicroLevels()
{
   // CRYPTO MicroBreak: LookbackMicroBars=3
   // MicroHigh = max(High[2..4]), MicroLow = min(Low[2..4])
   g_microHigh = -DBL_MAX;
   g_microLow  = DBL_MAX;

   for(int i = 2; i <= 4; i++)
   {
      double h = iHigh(Symbol(), PERIOD_M1, i);
      double l = iLow(Symbol(), PERIOD_M1, i);
      if(h > g_microHigh) g_microHigh = h;
      if(l < g_microLow)  g_microLow = l;
   }

   g_microHighValid = (g_microHigh > -DBL_MAX);
   g_microLowValid  = (g_microLow < DBL_MAX);
}

bool CheckMicroBreak()
{
   double close1 = iClose(Symbol(), PERIOD_M1, 1);

   UpdateLookbackMicroLevels();

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

// CRYPTO Confirm判定: MicroBreak ONLY
ENUM_CONFIRM_TYPE EvaluateConfirm()
{
   if(CheckMicroBreak())
      return CONFIRM_MICRO_BREAK;

   return CONFIRM_NONE;
}

//+------------------------------------------------------------------+
//| TrendFilter: CRYPTO = EMA21 vs EMA50 + EMA50 slope               |
//| ReversalGuard: 軽量（BigBody + Engulfingのみ）                      |
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
   g_stats.TrendMethod       = "EMA21_EMA50_CROSS_SLOPE";
   g_stats.TrendDir          = "";
   g_stats.TrendSlope        = 0.0;
   g_stats.TrendSlopeMin     = 0.0;
   g_stats.TrendSlopeSet     = false;
   g_stats.TrendAligned      = -1;

   g_stats.ReversalGuardEnable     = ReversalGuard_Enable ? 1 : 0;
   g_stats.ReversalTF             = "H1";
   g_stats.ReversalGuardTriggered = -1;
   g_stats.ReversalReason         = "";

   if(!TrendFilter_Enable)
      return true;

   string sym = Symbol();

   // CRYPTO TrendFilter: EMA21 vs EMA50 cross + EMA50 slope
   double ema21_1 = GetMAValue(sym, PERIOD_M15, 21, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_1 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_2 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 2);
   double atr15   = GetATRValue(sym, PERIOD_M15, 14, 1);

   if(ema21_1 == EMPTY_VALUE || ema50_1 == EMPTY_VALUE ||
      ema50_2 == EMPTY_VALUE || atr15 == EMPTY_VALUE)
   {
      g_stats.TrendDir = "FLAT";
      g_stats.TrendAligned = 0;
      rejectStageOut = "TREND_FLAT";
      return false;
   }

   double slope    = ema50_1 - ema50_2;
   double slopeMin = atr15 * TrendSlopeMult_CRYPTO;

   g_stats.TrendSlope    = slope;
   g_stats.TrendSlopeMin = slopeMin;
   g_stats.TrendSlopeSet = true;

   // EMA Cross stats
   g_stats.EMACrossFilterEnable = 1;
   g_stats.EMACrossFastVal = ema21_1;
   g_stats.EMACrossSlowVal = ema50_1;

   // CRYPTO TrendDir: EMA21/EMA50 cross + EMA50 slope
   string trendDir = "FLAT";
   if(ema21_1 > ema50_1 && slope >= slopeMin)
      trendDir = "LONG";
   else if(ema21_1 < ema50_1 && slope <= -slopeMin)
      trendDir = "SHORT";

   g_stats.TrendDir = trendDir;
   g_stats.EMACrossDir = trendDir;

   if(trendDir == "FLAT")
   {
      g_stats.TrendAligned = 0;
      g_stats.EMACrossAligned = 0;
      rejectStageOut = "TREND_FLAT";
      return false;
   }

   bool aligned = IsAlignedWithImpulse(trendDir);
   g_stats.TrendAligned = aligned ? 1 : 0;
   g_stats.EMACrossAligned = aligned ? 1 : 0;

   if(!aligned)
   {
      rejectStageOut = "TREND_MISMATCH";
      return false;
   }

   // CRYPTO ReversalGuard: 軽量（BigBody + Engulfingのみ）
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

   // BigBody check
   bool oppositeBigBody = (body >= (atr1 * ReversalBigBodyMult_CRYPTO)) &&
                          ((impulseLong && (c1 < o1)) || (!impulseLong && (c1 > o1)));

   if(oppositeBigBody)
   {
      g_stats.ReversalGuardTriggered = 1;
      g_stats.ReversalReason = "BIG_BODY";
      rejectStageOut = "REVERSAL_GUARD";
      return false;
   }

   // Engulfing check
   bool oppEng = impulseLong ? IsBearishEngulfing(sym, PERIOD_H1) : IsBullishEngulfing(sym, PERIOD_H1);
   if(oppEng)
   {
      g_stats.ReversalGuardTriggered = 1;
      g_stats.ReversalReason = "ENGULFING";
      rejectStageOut = "REVERSAL_GUARD";
      return false;
   }

   g_stats.ReversalGuardTriggered = 0;
   return true;
}

//+------------------------------------------------------------------+
//| M5 Range-based Flat Detection & Flat Filter                       |
//| M5の直近N本のレンジ(高値-安値) <= ATR(M5,14)×RangeMult → FLAT       |
//| ブレイクアウト方向: close vs range high/low                          |
//+------------------------------------------------------------------+
void EvaluateFlatFilter(string &flatDir, string &matchResult,
                        int &flatDuration, int &barsSince)
{
   flatDir = "NONE";
   matchResult = "NO_FLAT";
   flatDuration = 0;
   barsSince = 0;

   if(FlatFilterMode == FLAT_FILTER_OFF) return;

   string sym = Symbol();
   int scanDepth = 24; // M5足で24本=2時間遡る

   // ATR(M5,14) at shift=1
   double atrM5 = GetATRValue(sym, PERIOD_M5, 14, 1);
   if(atrM5 == EMPTY_VALUE || atrM5 <= 0) return;

   double rangeThreshold = atrM5 * FlatRangeATRMult;

   // M5足を遡り、フラットレンジを探す
   int flatStart = -1;
   int flatEnd   = -1;

   for(int start = 1; start <= scanDepth; start++)
   {
      double rangeHigh = -DBL_MAX;
      double rangeLow  = DBL_MAX;
      bool isFlat = true;

      for(int j = 0; j < FlatRangeLookback; j++)
      {
         int idx = start + j;
         double h = iHigh(sym, PERIOD_M5, idx);
         double l = iLow(sym, PERIOD_M5, idx);
         if(h > rangeHigh) rangeHigh = h;
         if(l < rangeLow)  rangeLow = l;
      }

      double range = rangeHigh - rangeLow;
      if(range > rangeThreshold)
         continue;

      // フラット区間を発見
      flatStart = start;
      flatEnd = start + FlatRangeLookback - 1;

      // このフラットは「まだ続いているか」チェック
      // start==1 なら最新M5足がフラット区間内 → STILL_FLAT
      if(start == 1)
      {
         flatDir = "STILL_FLAT";
         matchResult = "STILL_FLAT";
         flatDuration = FlatRangeLookback;
         barsSince = 0;
         break;
      }

      // フラットのレンジ境界を算出
      double breakRangeHigh = -DBL_MAX;
      double breakRangeLow  = DBL_MAX;
      for(int j = 0; j < FlatRangeLookback; j++)
      {
         int idx = start + j;
         double h = iHigh(sym, PERIOD_M5, idx);
         double l = iLow(sym, PERIOD_M5, idx);
         if(h > breakRangeHigh) breakRangeHigh = h;
         if(l < breakRangeLow)  breakRangeLow = l;
      }

      // ブレイクアウト方向: フラット直後の足のclose vs range
      int breakoutBar = start - 1; // フラット直後の足
      double breakClose = iClose(sym, PERIOD_M5, breakoutBar);

      if(breakClose > breakRangeHigh)
         flatDir = "LONG";
      else if(breakClose < breakRangeLow)
         flatDir = "SHORT";
      else
         flatDir = "NONE"; // レンジ内に留まっている

      flatDuration = FlatRangeLookback;
      barsSince = start - 1;

      // Match判定
      if(flatDir == "LONG" || flatDir == "SHORT")
      {
         bool dirMatch = (flatDir == "LONG" && g_impulseDir == DIR_LONG) ||
                         (flatDir == "SHORT" && g_impulseDir == DIR_SHORT);
         matchResult = dirMatch ? "MATCH" : "MISMATCH";
      }
      else
      {
         matchResult = "NO_FLAT";
      }

      break; // 最初に見つかったフラットで判定
   }

   // stats記録
   g_stats.FlatFilterEnable = (int)FlatFilterMode;
   g_stats.FlatBreakoutDir  = flatDir;
   g_stats.FlatMatchResult  = matchResult;
   g_stats.FlatDuration     = flatDuration;
   g_stats.FlatBarsSince    = barsSince;
}

// FlatFilter合否判定
bool CheckFlatFilter(string &rejectStageOut)
{
   if(FlatFilterMode == FLAT_FILTER_OFF) return true;

   string flatDir = "";
   string matchResult = "";
   int flatDuration = 0;
   int barsSince = 0;

   EvaluateFlatFilter(flatDir, matchResult, flatDuration, barsSince);

   if(FlatFilterMode == FLAT_FILTER_GUARD)
   {
      // EA-A FlatGuard: STILL_FLAT除外
      if(matchResult == "STILL_FLAT")
      {
         rejectStageOut = "FLAT_STILL_FLAT";
         return false;
      }
      return true;
   }
   else if(FlatFilterMode == FLAT_FILTER_MATCH)
   {
      // EA-B FlatMatch: MATCH必須
      if(matchResult != "MATCH")
      {
         rejectStageOut = "FLAT_" + matchResult;
         return false;
      }
      return true;
   }

   return true;
}

#endif // __ENTRY_ENGINE_MQH__
