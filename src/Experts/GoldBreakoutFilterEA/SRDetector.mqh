//+------------------------------------------------------------------+
//| SRDetector.mqh - GoldBreakoutFilterEA                            |
//| M15 Swing High/Low → S/R Level Detection (GOLD専用)              |
//| RoleReversalEA版を M15 に適応、名前衝突回避                        |
//+------------------------------------------------------------------+
#ifndef __GBF_SR_DETECTOR_MQH__
#define __GBF_SR_DETECTOR_MQH__

#define GBF_MAX_SR_LEVELS 50

//+------------------------------------------------------------------+
//| S/R Level 構造体（GoldBreakoutFilterEA専用）                       |
//+------------------------------------------------------------------+
struct SRLevel_Gold
{
   double   price;
   bool     is_resistance;
   int      detected_bar;
   int      touch_count;
   bool     broken;
};

//+------------------------------------------------------------------+
//| Detect swing highs/lows on M15                                   |
//+------------------------------------------------------------------+
void DetectSRLevels_Gold(
   SRLevel_Gold &levels[], int &count,
   int swingLookback, double mergeATR, int maxAge)
{
   count = 0;
   ArrayResize(levels, GBF_MAX_SR_LEVELS);

   int m15Bars = iBars(Symbol(), PERIOD_M15);
   if(m15Bars < swingLookback * 2 + 1)
      return;

   int maxBars = MathMin(m15Bars - swingLookback, maxAge + swingLookback);
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   CopyHigh(Symbol(), PERIOD_M15, 0, maxBars + swingLookback, highs);
   CopyLow(Symbol(), PERIOD_M15, 0, maxBars + swingLookback, lows);

   // Raw levels
   double rawPrices[];
   bool   rawIsRes[];
   int    rawBars[];
   int    rawCount = 0;
   int    rawMax = GBF_MAX_SR_LEVELS * 2;
   ArrayResize(rawPrices, rawMax);
   ArrayResize(rawIsRes, rawMax);
   ArrayResize(rawBars, rawMax);

   for(int i = swingLookback; i < maxBars && rawCount < rawMax; i++)
   {
      // Swing High → Resistance
      bool isSwingHigh = true;
      for(int j = 1; j <= swingLookback; j++)
      {
         if(highs[i] <= highs[i - j] || highs[i] <= highs[i + j])
         {
            isSwingHigh = false;
            break;
         }
      }
      if(isSwingHigh)
      {
         rawPrices[rawCount] = highs[i];
         rawIsRes[rawCount] = true;
         rawBars[rawCount] = i;
         rawCount++;
      }

      // Swing Low → Support
      bool isSwingLow = true;
      for(int j = 1; j <= swingLookback; j++)
      {
         if(lows[i] >= lows[i - j] || lows[i] >= lows[i + j])
         {
            isSwingLow = false;
            break;
         }
      }
      if(isSwingLow && rawCount < rawMax)
      {
         rawPrices[rawCount] = lows[i];
         rawIsRes[rawCount] = false;
         rawBars[rawCount] = i;
         rawCount++;
      }
   }

   // Sort by price (bubble sort)
   for(int i = 0; i < rawCount - 1; i++)
   {
      for(int j = 0; j < rawCount - i - 1; j++)
      {
         if(rawPrices[j] > rawPrices[j + 1])
         {
            double tmpP = rawPrices[j]; rawPrices[j] = rawPrices[j + 1]; rawPrices[j + 1] = tmpP;
            bool tmpR = rawIsRes[j]; rawIsRes[j] = rawIsRes[j + 1]; rawIsRes[j + 1] = tmpR;
            int tmpB = rawBars[j]; rawBars[j] = rawBars[j + 1]; rawBars[j + 1] = tmpB;
         }
      }
   }

   // Merge nearby levels
   for(int i = 0; i < rawCount && count < GBF_MAX_SR_LEVELS; i++)
   {
      if(count > 0 && MathAbs(rawPrices[i] - levels[count - 1].price) < mergeATR)
      {
         levels[count - 1].price = (levels[count - 1].price + rawPrices[i]) / 2.0;
         levels[count - 1].touch_count++;
      }
      else
      {
         levels[count].price = rawPrices[i];
         levels[count].is_resistance = rawIsRes[i];
         levels[count].detected_bar = rawBars[i];
         levels[count].touch_count = 1;
         levels[count].broken = false;
         count++;
      }
   }
}

//+------------------------------------------------------------------+
//| Count touches for each S/R level on M15                          |
//+------------------------------------------------------------------+
void CountSRTouches_Gold(SRLevel_Gold &levels[], int count, double toleranceATR)
{
   int m15Handle = iATR(Symbol(), PERIOD_M15, 14);
   if(m15Handle == INVALID_HANDLE) return;

   double m15ATR[];
   ArraySetAsSeries(m15ATR, true);
   CopyBuffer(m15Handle, 0, 0, 200, m15ATR);
   IndicatorRelease(m15Handle);

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   int bars = MathMin(iBars(Symbol(), PERIOD_M15), 500);
   CopyHigh(Symbol(), PERIOD_M15, 0, bars, highs);
   CopyLow(Symbol(), PERIOD_M15, 0, bars, lows);

   for(int s = 0; s < count; s++)
   {
      int touches = 0;
      int limit = MathMin(bars, levels[s].detected_bar);
      for(int i = 0; i < limit; i++)
      {
         double atr = (i < ArraySize(m15ATR)) ? m15ATR[i] : m15ATR[ArraySize(m15ATR) - 1];
         double zone = atr * toleranceATR;
         if(lows[i] <= levels[s].price + zone && highs[i] >= levels[s].price - zone)
            touches++;
      }
      levels[s].touch_count = MathMax(1, touches);
   }
}

//+------------------------------------------------------------------+
//| Find nearest valid S/R target for exit                           |
//| skip_zone = ATR(M15) × SR_SkipATRMult 圏内はスキップ             |
//| minTouches 未満のレベルも除外                                     |
//+------------------------------------------------------------------+
double FindSRTarget_Gold(
   const SRLevel_Gold &levels[], int count,
   double currentPrice, ENUM_DIRECTION dir,
   double skipZone, int minTouches)
{
   double bestLevel = 0;
   double bestDist = DBL_MAX;

   for(int i = 0; i < count; i++)
   {
      if(levels[i].broken) continue;
      if(levels[i].touch_count < minTouches) continue;

      if(dir == DIR_LONG && levels[i].price > currentPrice)
      {
         double dist = levels[i].price - currentPrice;
         if(dist <= skipZone) continue;  // 近すぎるレベルをスキップ
         if(dist < bestDist)
         {
            bestDist = dist;
            bestLevel = levels[i].price;
         }
      }
      else if(dir == DIR_SHORT && levels[i].price < currentPrice)
      {
         double dist = currentPrice - levels[i].price;
         if(dist <= skipZone) continue;
         if(dist < bestDist)
         {
            bestDist = dist;
            bestLevel = levels[i].price;
         }
      }
   }
   return bestLevel;
}

//+------------------------------------------------------------------+
//| Refresh S/R levels (M15新バー時に呼び出し)                        |
//+------------------------------------------------------------------+
bool RefreshSRLevels_Gold(
   SRLevel_Gold &levels[], int &count,
   datetime &lastRefreshBarTime,
   int swingLookback, double mergeATRMult, int maxAge,
   double touchToleranceATR, int refreshInterval)
{
   datetime currentM15Bar = iTime(Symbol(), PERIOD_M15, 0);
   if(currentM15Bar == lastRefreshBarTime)
      return false;

   // refreshInterval チェック（M15バー数換算）
   if(lastRefreshBarTime > 0)
   {
      int barsSinceRefresh = (int)((currentM15Bar - lastRefreshBarTime) / PeriodSeconds(PERIOD_M15));
      if(barsSinceRefresh < refreshInterval)
         return false;
   }

   lastRefreshBarTime = currentM15Bar;

   // ATR(M15,14) でマージ距離を算出
   double atrVal = GetATRValue(Symbol(), PERIOD_M15, 14, 1);
   if(atrVal <= 0) return false;

   double mergeATR = atrVal * mergeATRMult;

   DetectSRLevels_Gold(levels, count, swingLookback, mergeATR, maxAge);
   CountSRTouches_Gold(levels, count, touchToleranceATR);

   return true;
}

#endif // __GBF_SR_DETECTOR_MQH__
