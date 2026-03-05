//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| FX専用: 構造無効判定・RiskGate・SL/TP計算                           |
//+------------------------------------------------------------------+
#ifndef __RISK_MANAGER_MQH__
#define __RISK_MANAGER_MQH__

//+------------------------------------------------------------------+
//| 構造無効判定: FX = 起点割れ/超え + 61.8終値突破                      |
//+------------------------------------------------------------------+
bool CheckStructureInvalid_Detail(
   string &reason, int &priority,
   string &refLevel, double &refPrice,
   double &atPrice, double &distPts,
   int &barShift
)
{
   barShift = 1;
   double close1 = iClose(Symbol(), PERIOD_M1, barShift);

   // 起点(START)割れ/超え
   if(g_impulseDir == DIR_LONG)
   {
      if(close1 < g_impulseStart)
      {
         reason="BRK_OUT_START"; priority=1; refLevel="START"; refPrice=g_impulseStart;
         atPrice=close1; distPts=(atPrice-refPrice)/_Point;
         return true;
      }
   }
   else
   {
      if(close1 > g_impulseStart)
      {
         reason="BRK_OUT_START"; priority=1; refLevel="START"; refPrice=g_impulseStart;
         atPrice=close1; distPts=(atPrice-refPrice)/_Point;
         return true;
      }
   }

   // FX: 61.8終値突破
   if(g_impulseDir == DIR_LONG)
   {
      if(close1 < g_fib618)
      {
         reason="BRK_CLOSE_61_8"; priority=2; refLevel="61.8"; refPrice=g_fib618;
         atPrice=close1; distPts=(atPrice-refPrice)/_Point;
         return true;
      }
   }
   else
   {
      if(close1 > g_fib618)
      {
         reason="BRK_CLOSE_61_8"; priority=2; refLevel="61.8"; refPrice=g_fib618;
         atPrice=close1; distPts=(atPrice-refPrice)/_Point;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| RiskGate: FX帯幅過大チェック                                       |
//+------------------------------------------------------------------+
bool CheckNoEntryRiskGate()
{
   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double rangeP = MathAbs(g_impulseEnd - g_impulseStart);
   if(rangeP <= point * 2.0)
      return true;

   double bandHeight = g_effectiveBandWidthPts * 2.0;
   double ratio = bandHeight / rangeP;

   if(ratio >= 0.85)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| TP算出（TP Extension対応）                                         |
//+------------------------------------------------------------------+
double GetExtendedTP()
{
   double impulseRange = MathAbs(g_impulseEnd - g_impulseStart);
   double ext = g_profile.tpExtensionRatio;
   if(g_impulseDir == DIR_LONG)
      return g_impulseEnd + impulseRange * ext;
   else
      return g_impulseEnd - impulseRange * ext;
}

//+------------------------------------------------------------------+
//| SL/TP計算: サーバーTP=0（EMAクロス決済）                             |
//+------------------------------------------------------------------+
void CalculateSLTP(double entryPrice)
{
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;

   if(g_impulseDir == DIR_LONG)
      g_sl = g_impulseStart - atr * mult;
   else
      g_sl = g_impulseStart + atr * mult;

   g_tp = 0;
}

void PreviewSLTP(double entryPrice, double &outSL, double &outTP)
{
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;
   outTP = GetExtendedTP();
   outSL = (g_impulseDir == DIR_LONG) ? (g_impulseStart - atr * mult) : (g_impulseStart + atr * mult);
}

#endif // __RISK_MANAGER_MQH__
