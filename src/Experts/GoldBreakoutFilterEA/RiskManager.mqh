//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| GOLD専用: 構造無効判定・RiskGate・SL/TP計算・ロット計算               |
//+------------------------------------------------------------------+
#ifndef __RISK_MANAGER_MQH__
#define __RISK_MANAGER_MQH__

//+------------------------------------------------------------------+
//| 構造無効判定: GOLD                                                 |
//| 起点割れ/超え + DeepBandON時78.6 / OFF時61.8                       |
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

   // 共通: 起点(START)割れ/超え
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

   // GOLD: DeepBandON→78.6 / OFF→61.8
   if(g_goldDeepBandON)
   {
      if(g_impulseDir == DIR_LONG)
      {
         if(close1 < g_fib786)
         {
            reason="BRK_CLOSE_78_6"; priority=2; refLevel="78.6"; refPrice=g_fib786;
            atPrice=close1; distPts=(atPrice-refPrice)/_Point;
            return true;
         }
      }
      else
      {
         if(close1 > g_fib786)
         {
            reason="BRK_CLOSE_78_6"; priority=2; refLevel="78.6"; refPrice=g_fib786;
            atPrice=close1; distPts=(atPrice-refPrice)/_Point;
            return true;
         }
      }
   }
   else
   {
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
   }

   return false;
}

//+------------------------------------------------------------------+
//| RiskGate: レンジ過小チェック                                        |
//+------------------------------------------------------------------+
bool CheckNoEntryRiskGate()
{
   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double rangeP = MathAbs(g_impulseEnd - g_impulseStart);
   if(rangeP <= point * 2.0)
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
//| SL/TP計算: 保険TP対応（動的Exit が先に発動、PC断時の安全ネット）       |
//+------------------------------------------------------------------+
void CalculateSLTP(double entryPrice)
{
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;
   double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slMargin = spread * g_profile.slMarginSpreadMult;

   if(g_impulseDir == DIR_LONG)
      g_sl = g_impulseStart - atr * mult - slMargin;
   else
      g_sl = g_impulseStart + atr * mult + slMargin;

   // 保険TP: 0より大きい場合のみサーバーTPを設定
   if(InsuranceTP_ATRMult_GOLD > 0)
   {
      if(g_impulseDir == DIR_LONG)
         g_tp = entryPrice + atr * InsuranceTP_ATRMult_GOLD;
      else
         g_tp = entryPrice - atr * InsuranceTP_ATRMult_GOLD;
   }
   else
      g_tp = 0;
}

void PreviewSLTP(double entryPrice, double &outSL, double &outTP)
{
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;
   outTP = GetExtendedTP();
   double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slMargin = spread * g_profile.slMarginSpreadMult;
   outSL = (g_impulseDir == DIR_LONG) ? (g_impulseStart - atr * mult - slMargin) : (g_impulseStart + atr * mult + slMargin);
}

//+------------------------------------------------------------------+
//| ロット計算: RISK_PERCENT モード                                     |
//| Lot = (Equity × RiskPercent%) / (SL距離points × 1pointあたり価値)  |
//| FreeMargin上限チェック付き                                          |
//+------------------------------------------------------------------+
double CalcRiskPercentLot(double entryPrice, double slPrice)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
   double slDistPts  = MathAbs(entryPrice - slPrice) / _Point;

   if(slDistPts <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = tickValue * (_Point / tickSize);

   if(pointValue <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double rawLot  = riskAmount / (slDistPts * pointValue);

   Print("[RiskCalc] equity=", AccountInfoDouble(ACCOUNT_EQUITY),
         " RiskPercent=", RiskPercent,
         " riskAmount=", riskAmount,
         " entry=", entryPrice,
         " sl=", slPrice,
         " slDistPts=", slDistPts,
         " _Point=", _Point,
         " tickValue=", tickValue,
         " tickSize=", tickSize,
         " pointValue=", pointValue,
         " rawLot=", rawLot);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   rawLot = MathMax(minLot, MathMin(maxLot, rawLot));

   //--- FreeMargin上限チェック: 算出ロットが実際に建てられるか検証
   ENUM_ORDER_TYPE orderType = (entryPrice > slPrice) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin = 0;
   if(freeMargin > 0 && OrderCalcMargin(orderType, _Symbol, rawLot, entryPrice, margin))
   {
      if(margin > freeMargin * 0.95)
      {
         double maxAffordLot = rawLot * (freeMargin * 0.95) / margin;
         maxAffordLot = MathFloor(maxAffordLot / lotStep) * lotStep;
         rawLot = MathMax(minLot, maxAffordLot);
      }
   }

   rawLot = MathFloor(rawLot / lotStep) * lotStep;

   Print("[RiskCalc] finalLot=", rawLot, " minLot=", minLot, " lotStep=", lotStep);

   int lotDigits = (int)MathRound(-MathLog10(lotStep));
   return NormalizeDouble(rawLot, lotDigits);
}

#endif // __RISK_MANAGER_MQH__
