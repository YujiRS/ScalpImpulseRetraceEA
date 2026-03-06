//+------------------------------------------------------------------+
//| ImpulseDetector.mqh                                              |
//| Impulse認定・起点算出・Freeze判定・FreezeCancel                      |
//| GOLD専用: Level3 Freeze                                           |
//+------------------------------------------------------------------+
#ifndef __IMPULSE_DETECTOR_MQH__
#define __IMPULSE_DETECTOR_MQH__

// Impulse認定（単足基準）
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

// 起点算出ロジック（条件付き補正）
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
//| Freeze判定: GOLD Level3                                           |
//| 更新停止 + 反対色足 + 内部回帰(ATR×0.15)                           |
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

   // Level3: 更新停止 + 反対色 + 内部回帰
   bool updateStopped = false;
   bool oppositeColor = false;
   bool internalReturn = false;

   if(g_impulseDir == DIR_LONG)
      updateStopped = (high1 <= g_impulseHigh);
   else
      updateStopped = (low1 >= g_impulseLow);

   if(g_impulseDir == DIR_LONG)
      oppositeColor = (close1 < open1);
   else
      oppositeColor = (close1 > open1);

   double atr = GetATR_M1(1);
   double returnThreshold = atr * 0.15;

   if(g_impulseDir == DIR_LONG)
   {
      double returnAmount = g_impulseHigh - close1;
      internalReturn = (returnAmount >= returnThreshold);
   }
   else
   {
      double returnAmount = close1 - g_impulseLow;
      internalReturn = (returnAmount >= returnThreshold);
   }

   return (updateStopped && oppositeColor && internalReturn);
}

//+------------------------------------------------------------------+
//| Freeze取消判定: GOLD = Spread×2以上突破                             |
//+------------------------------------------------------------------+
bool CheckFreezeCancel()
{
   if(!g_frozen) return false;

   int barsSinceFreeze = g_barsAfterFreeze;
   if(barsSinceFreeze > g_profile.freezeCancelWindowBars)
      return false;

   double high0 = iHigh(Symbol(), PERIOD_M1, 0);
   double low0  = iLow(Symbol(), PERIOD_M1, 0);

   double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double threshold = spread * 2.0;

   if(g_impulseDir == DIR_LONG)
      return (high0 > g_frozen100 + threshold);
   else
      return (low0 < g_frozen100 - threshold);
}

#endif // __IMPULSE_DETECTOR_MQH__
