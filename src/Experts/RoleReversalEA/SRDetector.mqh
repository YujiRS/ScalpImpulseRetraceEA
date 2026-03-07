//+------------------------------------------------------------------+
//| SRDetector.mqh - RoleReversalEA                                   |
//| H1 Swing High/Low → S/R Level Detection                          |
//+------------------------------------------------------------------+
#ifndef __RR_SR_DETECTOR_MQH__
#define __RR_SR_DETECTOR_MQH__

#define MAX_SR_LEVELS 50

//--- S/R Level array (global)
SRLevel   g_srLevels[];
int       g_srCount = 0;

//+------------------------------------------------------------------+
//| Detect swing highs and lows on H1                                 |
//+------------------------------------------------------------------+
void DetectSRLevels(int swingLookback, double mergeATR, int maxAge)
{
   g_srCount = 0;
   ArrayResize(g_srLevels, MAX_SR_LEVELS);

   int h1Bars = iBars(Symbol(), PERIOD_H1);
   if(h1Bars < swingLookback * 2 + 1)
      return;

   int maxBars = MathMin(h1Bars - swingLookback, maxAge + swingLookback);
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   CopyHigh(Symbol(), PERIOD_H1, 0, maxBars + swingLookback, highs);
   CopyLow(Symbol(), PERIOD_H1, 0, maxBars + swingLookback, lows);

   // Temporary array for raw levels
   double rawPrices[];
   bool   rawIsRes[];
   int    rawBars[];
   int    rawCount = 0;
   ArrayResize(rawPrices, MAX_SR_LEVELS * 2);
   ArrayResize(rawIsRes, MAX_SR_LEVELS * 2);
   ArrayResize(rawBars, MAX_SR_LEVELS * 2);

   for(int i = swingLookback; i < maxBars && rawCount < MAX_SR_LEVELS * 2; i++)
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
      if(isSwingLow && rawCount < MAX_SR_LEVELS * 2)
      {
         rawPrices[rawCount] = lows[i];
         rawIsRes[rawCount] = false;
         rawBars[rawCount] = i;
         rawCount++;
      }
   }

   // Sort by price (simple bubble sort)
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
   for(int i = 0; i < rawCount && g_srCount < MAX_SR_LEVELS; i++)
   {
      if(g_srCount > 0 && MathAbs(rawPrices[i] - g_srLevels[g_srCount - 1].price) < mergeATR)
      {
         // Merge into previous
         g_srLevels[g_srCount - 1].price = (g_srLevels[g_srCount - 1].price + rawPrices[i]) / 2.0;
         g_srLevels[g_srCount - 1].touch_count++;
      }
      else
      {
         g_srLevels[g_srCount].price = rawPrices[i];
         g_srLevels[g_srCount].is_resistance = rawIsRes[i];
         g_srLevels[g_srCount].detected_bar = rawBars[i];
         g_srLevels[g_srCount].touch_count = 1;
         g_srLevels[g_srCount].broken = false;
         g_srLevels[g_srCount].broken_direction = 0;
         g_srLevels[g_srCount].broken_time = 0;
         g_srLevels[g_srCount].used = false;
         g_srCount++;
      }
   }
}

//+------------------------------------------------------------------+
//| Count touches for each S/R level on H1                            |
//+------------------------------------------------------------------+
void CountSRTouches(double toleranceATR)
{
   double h1ATR[];
   ArraySetAsSeries(h1ATR, true);

   int h1Handle = iATR(Symbol(), PERIOD_H1, 14);
   if(h1Handle == INVALID_HANDLE) return;
   CopyBuffer(h1Handle, 0, 0, 200, h1ATR);
   IndicatorRelease(h1Handle);

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   int bars = iBars(Symbol(), PERIOD_H1);
   CopyHigh(Symbol(), PERIOD_H1, 0, bars, highs);
   CopyLow(Symbol(), PERIOD_H1, 0, bars, lows);

   for(int s = 0; s < g_srCount; s++)
   {
      int touches = 0;
      int limit = MathMin(bars, g_srLevels[s].detected_bar);
      for(int i = 0; i < limit; i++)
      {
         double atr = (i < ArraySize(h1ATR)) ? h1ATR[i] : h1ATR[ArraySize(h1ATR) - 1];
         double zone = atr * toleranceATR;
         if(lows[i] <= g_srLevels[s].price + zone && highs[i] >= g_srLevels[s].price - zone)
            touches++;
      }
      g_srLevels[s].touch_count = MathMax(1, touches);
   }
}

//+------------------------------------------------------------------+
//| Find nearest S/R level in trade direction                         |
//+------------------------------------------------------------------+
double FindNextSRLevel(double currentPrice, int direction)
{
   double bestLevel = 0;
   double bestDist = DBL_MAX;

   for(int i = 0; i < g_srCount; i++)
   {
      if(g_srLevels[i].broken) continue;

      if(direction == RR_DIR_LONG && g_srLevels[i].price > currentPrice)
      {
         double dist = g_srLevels[i].price - currentPrice;
         if(dist < bestDist)
         {
            bestDist = dist;
            bestLevel = g_srLevels[i].price;
         }
      }
      else if(direction == RR_DIR_SHORT && g_srLevels[i].price < currentPrice)
      {
         double dist = currentPrice - g_srLevels[i].price;
         if(dist < bestDist)
         {
            bestDist = dist;
            bestLevel = g_srLevels[i].price;
         }
      }
   }
   return bestLevel;
}

#endif
