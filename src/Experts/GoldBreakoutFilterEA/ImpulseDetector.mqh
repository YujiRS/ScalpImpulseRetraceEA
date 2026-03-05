//+------------------------------------------------------------------+
//| ImpulseDetector.mqh                                              |
//| Impulse認定・起点算出・Freeze判定・FreezeCancel（第2章・第4章）       |
//+------------------------------------------------------------------+
#ifndef __IMPULSE_DETECTOR_MQH__
#define __IMPULSE_DETECTOR_MQH__

// 第4章: Impulse認定（単足基準）
bool DetectImpulse()
{
   // M1確定足[1]で判定
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

   // 方向判定
   if(close1 > open1)
      g_impulseDir = DIR_LONG;
   else if(close1 < open1)
      g_impulseDir = DIR_SHORT;
   else
      return false;

   // Impulse足の高安を記録
   g_impulseHigh = high1;
   g_impulseLow  = low1;
   g_impulseBarIndex = 1; // 確定足[1]

   // 起点算出（第2章 ImpulseDetector: 起点算出ロジック）
   CalculateImpulseStart();

   // 終点（100）はImpulse方向の先端
   if(g_impulseDir == DIR_LONG)
      g_impulseEnd = high1;
   else
      g_impulseEnd = low1;

   return true;
}

// 第2章: 起点算出ロジック（条件付き補正）
void CalculateImpulseStart()
{
   int impBar = g_impulseBarIndex; // 確定足のshift

   double open_imp  = iOpen(Symbol(), PERIOD_M1, impBar);
   double close_imp = iClose(Symbol(), PERIOD_M1, impBar);
   double high_imp  = iHigh(Symbol(), PERIOD_M1, impBar);
   double low_imp   = iLow(Symbol(), PERIOD_M1, impBar);

   // 前足（Impulse足の1本前）
   int prevBar = impBar + 1;
   double open_prev  = iOpen(Symbol(), PERIOD_M1, prevBar);
   double close_prev = iClose(Symbol(), PERIOD_M1, prevBar);
   double high_prev  = iHigh(Symbol(), PERIOD_M1, prevBar);
   double low_prev   = iLow(Symbol(), PERIOD_M1, prevBar);

   double prevBody = MathAbs(close_prev - open_prev);
   double atr      = GetATR_M1(impBar);

   g_startAdjusted = false;

   // ■ 条件（両方成立時のみ補正）
   bool cond1 = false; // 前足がImpulse方向と逆色
   bool cond2 = false; // 前足実体 <= ATR(M1) × SmallBodyRatio

   if(g_impulseDir == DIR_LONG)
      cond1 = (close_prev < open_prev); // 前足陰線 = Long方向と逆色
   else
      cond1 = (close_prev > open_prev); // 前足陽線 = Short方向と逆色

   if(atr > 0)
      cond2 = (prevBody <= atr * g_profile.smallBodyRatio);

   if(cond1 && cond2)
   {
      // ■ 条件成立時
      g_startAdjusted = true;
      if(g_impulseDir == DIR_LONG)
         g_impulseStart = MathMin(low_imp, low_prev);
      else
         g_impulseStart = MathMax(high_imp, high_prev);
   }
   else
   {
      // ■ 条件不成立時
      if(g_impulseDir == DIR_LONG)
         g_impulseStart = low_imp;
      else
         g_impulseStart = high_imp;
   }
}

//+------------------------------------------------------------------+
//| Freeze判定（第4章: 市場別）                                        |
//+------------------------------------------------------------------+
bool CheckFreeze()
{
   // 確定足[1]で判定
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

   // Freeze判定
   switch(g_resolvedMarketMode)
   {
      case MARKET_MODE_FX:
         return CheckFreeze_FX(open1, close1, high1, low1);

      case MARKET_MODE_GOLD:
         return CheckFreeze_GOLD(open1, close1, high1, low1);

      case MARKET_MODE_CRYPTO:
         return CheckFreeze_CRYPTO(open1, close1, high1, low1);

      default:
         return CheckFreeze_FX(open1, close1, high1, low1);
   }
}

// ■ FX（Level2固定）
bool CheckFreeze_FX(double open1, double close1, double high1, double low1)
{
   bool updateStopped = false;
   bool oppositeColor = false;

   // 1) 更新停止
   if(g_impulseDir == DIR_LONG)
      updateStopped = (high1 <= g_impulseHigh);
   else
      updateStopped = (low1 >= g_impulseLow);

   // 2) 反対色足
   if(g_impulseDir == DIR_LONG)
      oppositeColor = (close1 < open1);
   else
      oppositeColor = (close1 > open1);

   return (updateStopped && oppositeColor);
}

// ■ GOLD（Level3固定）
bool CheckFreeze_GOLD(double open1, double close1, double high1, double low1)
{
   bool updateStopped = false;
   bool oppositeColor = false;
   bool internalReturn = false;

   // 1) 更新停止
   if(g_impulseDir == DIR_LONG)
      updateStopped = (high1 <= g_impulseHigh);
   else
      updateStopped = (low1 >= g_impulseLow);

   // 2) 反対色足
   if(g_impulseDir == DIR_LONG)
      oppositeColor = (close1 < open1);
   else
      oppositeColor = (close1 > open1);

   // 3) 内部回帰（ATR(M1)×0.15以上戻す）
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

// ■ CRYPTO（Level2）
bool CheckFreeze_CRYPTO(double open1, double close1, double high1, double low1)
{
   // FXと同一条件（Level2）
   return CheckFreeze_FX(open1, close1, high1, low1);
}

//+------------------------------------------------------------------+
//| Freeze取消判定（第4章: 市場別）                                     |
//+------------------------------------------------------------------+
bool CheckFreezeCancel()
{
   if(!g_frozen) return false;

   // CancelWindowBars内のみチェック
   int barsSinceFreeze = g_barsAfterFreeze;
   if(barsSinceFreeze > g_profile.freezeCancelWindowBars)
      return false;

   double high0 = iHigh(Symbol(), PERIOD_M1, 0); // 現在足（Tick単位）
   double low0  = iLow(Symbol(), PERIOD_M1, 0);

   switch(g_resolvedMarketMode)
   {
      case MARKET_MODE_FX:
         return CheckFreezeCancel_FX(high0, low0);
      case MARKET_MODE_GOLD:
         return CheckFreezeCancel_GOLD(high0, low0);
      case MARKET_MODE_CRYPTO:
         return CheckFreezeCancel_CRYPTO(high0, low0);
      default:
         return CheckFreezeCancel_FX(high0, low0);
   }
}

// FX: Frozen100を1tick超えて更新
bool CheckFreezeCancel_FX(double high0, double low0)
{
   double tick = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(g_impulseDir == DIR_LONG)
      return (high0 > g_frozen100 + tick);
   else
      return (low0 < g_frozen100 - tick);
}

// GOLD: Frozen100をSpread×2以上突破
bool CheckFreezeCancel_GOLD(double high0, double low0)
{
   double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double threshold = spread * 2.0;

   if(g_impulseDir == DIR_LONG)
      return (high0 > g_frozen100 + threshold);
   else
      return (low0 < g_frozen100 - threshold);
}

// CRYPTO: Frozen100を0.1%以上更新
bool CheckFreezeCancel_CRYPTO(double high0, double low0)
{
   double threshold = g_frozen100 * 0.001;

   if(g_impulseDir == DIR_LONG)
      return (high0 > g_frozen100 + threshold);
   else
      return (low0 < g_frozen100 - threshold);
}

#endif // __IMPULSE_DETECTOR_MQH__
