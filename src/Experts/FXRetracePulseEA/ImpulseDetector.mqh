//+------------------------------------------------------------------+
//| ImpulseDetector.mqh                                              |
//| FX専用: Impulse認定・起点算出・Freeze判定（Level2）・FreezeCancel    |
//+------------------------------------------------------------------+
#ifndef __IMPULSE_DETECTOR_MQH__
#define __IMPULSE_DETECTOR_MQH__

bool DetectImpulse()
{
   double open1  = iOpen(Symbol(), PERIOD_M1, 1);
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double high1  = iHigh(Symbol(), PERIOD_M1, 1);
   double low1   = iLow(Symbol(), PERIOD_M1, 1);

   double body = MathAbs(close1 - open1);
   double atr  = GetATR_M1(1);

   if(atr <= 0) return false;

   double impulseThreshold = atr * g_profile.impulseATRMult;
   if(body < impulseThreshold)
      return false;

   if(close1 > open1)
      g_impulseDir = DIR_LONG;
   else if(close1 < open1)
      g_impulseDir = DIR_SHORT;
   else
      return false;

   g_impulseHigh = high1;
   g_impulseLow  = low1;
   g_impulseBarIndex = 1;

   CalculateImpulseStart();

   if(g_impulseDir == DIR_LONG)
      g_impulseEnd = high1;
   else
      g_impulseEnd = low1;

   return true;
}

void CalculateImpulseStart()
{
   int impBar = g_impulseBarIndex;

   double open_imp  = iOpen(Symbol(), PERIOD_M1, impBar);
   double close_imp = iClose(Symbol(), PERIOD_M1, impBar);
   double high_imp  = iHigh(Symbol(), PERIOD_M1, impBar);
   double low_imp   = iLow(Symbol(), PERIOD_M1, impBar);

   int prevBar = impBar + 1;
   double open_prev  = iOpen(Symbol(), PERIOD_M1, prevBar);
   double close_prev = iClose(Symbol(), PERIOD_M1, prevBar);
   double high_prev  = iHigh(Symbol(), PERIOD_M1, prevBar);
   double low_prev   = iLow(Symbol(), PERIOD_M1, prevBar);

   double prevBody = MathAbs(close_prev - open_prev);
   double atr      = GetATR_M1(impBar);

   g_startAdjusted = false;

   bool cond1 = false;
   bool cond2 = false;

   if(g_impulseDir == DIR_LONG)
      cond1 = (close_prev < open_prev);
   else
      cond1 = (close_prev > open_prev);

   if(atr > 0)
      cond2 = (prevBody <= atr * g_profile.smallBodyRatio);

   if(cond1 && cond2)
   {
      g_startAdjusted = true;
      if(g_impulseDir == DIR_LONG)
         g_impulseStart = MathMin(low_imp, low_prev);
      else
         g_impulseStart = MathMax(high_imp, high_prev);
   }
   else
   {
      if(g_impulseDir == DIR_LONG)
         g_impulseStart = low_imp;
      else
         g_impulseStart = high_imp;
   }
}

//+------------------------------------------------------------------+
//| Freeze判定（FX: Level2固定）                                       |
//+------------------------------------------------------------------+
bool CheckFreeze()
{
   double open1  = iOpen(Symbol(), PERIOD_M1, 1);
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double high1  = iHigh(Symbol(), PERIOD_M1, 1);
   double low1   = iLow(Symbol(), PERIOD_M1, 1);

   // 100追従更新（Freeze前）
   if(!g_frozen)
   {
      if(g_impulseDir == DIR_LONG)
      {
         if(high1 > g_impulseEnd)
         {
            g_impulseEnd  = high1;
            g_impulseHigh = high1;
         }
      }
      else
      {
         if(low1 < g_impulseEnd)
         {
            g_impulseEnd = low1;
            g_impulseLow = low1;
         }
      }
   }

   // Level2: 更新停止 + 反対色足
   bool updateStopped = false;
   bool oppositeColor = false;

   if(g_impulseDir == DIR_LONG)
      updateStopped = (high1 <= g_impulseHigh);
   else
      updateStopped = (low1 >= g_impulseLow);

   if(g_impulseDir == DIR_LONG)
      oppositeColor = (close1 < open1);
   else
      oppositeColor = (close1 > open1);

   return (updateStopped && oppositeColor);
}

//+------------------------------------------------------------------+
//| FreezeCancel（FX: Frozen100を1tick超えて更新）                      |
//+------------------------------------------------------------------+
bool CheckFreezeCancel()
{
   if(!g_frozen) return false;

   if(g_barsAfterFreeze > g_profile.freezeCancelWindowBars)
      return false;

   double high0 = iHigh(Symbol(), PERIOD_M1, 0);
   double low0  = iLow(Symbol(), PERIOD_M1, 0);

   double tick = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(g_impulseDir == DIR_LONG)
      return (high0 > g_frozen100 + tick);
   else
      return (low0 < g_frozen100 - tick);
}

#endif // __IMPULSE_DETECTOR_MQH__
