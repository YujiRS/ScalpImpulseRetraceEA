//+------------------------------------------------------------------+
//| Execution.mqh                                                     |
//| スプレッド管理・注文執行・ポジション管理                               |
//| CRYPTO専用                                                         |
//+------------------------------------------------------------------+
#ifndef __EXECUTION_MQH__
#define __EXECUTION_MQH__

//+------------------------------------------------------------------+
//| Spread取得・計算                                                    |
//+------------------------------------------------------------------+
double GetCurrentSpreadPts()
{
   return (double)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
}

void UpdateAdaptiveSpread()
{
   if(MaxSpreadMode == SPREAD_MODE_FIXED)
   {
      g_maxSpreadPts = InputMaxSpreadPts;
      return;
   }

   double spreadNow = GetCurrentSpreadPts();
   g_spreadBasePts = spreadNow;
   g_maxSpreadPts  = g_spreadBasePts * g_profile.spreadMult;
}

bool IsSpreadOK()
{
   double spread = GetCurrentSpreadPts();
   return (spread <= g_maxSpreadPts);
}

//+------------------------------------------------------------------+
//| Filling Mode 自動判定                                              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   long fillMode = SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Execution                                                          |
//+------------------------------------------------------------------+
bool ExecuteEntry()
{
   // 方向レートフィルター
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   if(g_impulseDir == DIR_LONG && LongDisableAbove > 0 && bid >= LongDisableAbove)
   {
      WriteLog(LOG_REJECT, "", "LongDisabledAbove",
         "Bid=" + DoubleToString(bid, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS))
         + " >= LongDisableAbove=" + DoubleToString(LongDisableAbove, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
      return false;
   }
   if(g_impulseDir == DIR_SHORT && ShortDisableBelow > 0 && bid <= ShortDisableBelow)
   {
      WriteLog(LOG_REJECT, "", "ShortDisabledBelow",
         "Bid=" + DoubleToString(bid, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS))
         + " <= ShortDisableBelow=" + DoubleToString(ShortDisableBelow, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
      return false;
   }

   if(!IsSpreadOK())
   {
      WriteLog(LOG_REJECT, "", "SpreadExceeded", "SpreadPts=" + DoubleToString(GetCurrentSpreadPts(), 1));
      return false;
   }

   double price = 0;
   ENUM_ORDER_TYPE orderType;

   if(UseLimitEntry)
   {
      g_entryType = ENTRY_LIMIT;
      if(g_impulseDir == DIR_LONG)
      {
         price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         orderType = ORDER_TYPE_BUY;
      }
      else
      {
         price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         orderType = ORDER_TYPE_SELL;
      }
   }
   else if(UseMarketFallback)
   {
      g_entryType = ENTRY_MARKET;
      if(g_impulseDir == DIR_LONG)
      {
         price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         orderType = ORDER_TYPE_BUY;
      }
      else
      {
         price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         orderType = ORDER_TYPE_SELL;
      }
   }
   else
   {
      WriteLog(LOG_REJECT, "", "NoEntryMethodEnabled");
      return false;
   }

   CalculateSLTP(price);

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = Symbol();
   request.volume    = (LotMode == LOT_MODE_RISK_PERCENT)
                       ? CalcRiskPercentLot(price, g_sl)
                       : FixedLot;
   request.type      = orderType;
   request.price     = price;
   request.sl        = g_sl;
   request.tp        = g_tp;
   request.deviation = (ulong)(g_profile.maxSlippagePts / Point());
   request.magic        = 20260201;
   request.comment      = EA_NAME + " " + g_tradeUUID;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      WriteLog(LOG_REJECT, "", "OrderSendFailed",
               "error=" + IntegerToString(result.retcode));
      return false;
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
   {
      WriteLog(LOG_REJECT, "", "OrderRetcodeFailed",
               "retcode=" + IntegerToString(result.retcode));
      return false;
   }

   g_ticket = result.order;
   g_entryPrice = result.price;

   double fillDeviation = MathAbs(result.price - price) / Point();
   if(fillDeviation > g_profile.maxFillDeviationPts)
   {
      ClosePosition("FillDeviationExceeded");
      WriteLog(LOG_REJECT, "", "FillDeviationExceeded",
               "deviation=" + DoubleToString(fillDeviation, 1));
      return false;
   }

   WriteLog(LOG_ENTRY, "", "", "ticket=" + IntegerToString(g_ticket),
            0, fillDeviation);

   return true;
}

//+------------------------------------------------------------------+
//| ポジション管理                                                     |
//+------------------------------------------------------------------+
void ClosePosition(string reason, string extraInfo = "")
{
   if(!PositionSelectByTicket(g_ticket))
      return;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = Symbol();
   request.volume       = PositionGetDouble(POSITION_VOLUME);
   request.deviation    = (ulong)(g_profile.maxSlippagePts / Point());
   request.type_filling = GetFillingMode();

   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
   {
      request.type  = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   }
   else
   {
      request.type  = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   }

   if(OrderSend(request, result))
   {
      string logExtra = "closePrice=" + DoubleToString(result.price,
               (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
      if(extraInfo != "")
         logExtra += ";" + extraInfo;
      WriteLog(LOG_EXIT, reason, "", logExtra);
   }
}

// Exit EMA値取得ヘルパー
double GetExitEMA(int handle, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}

// ポジション管理: EMAクロス決済（確定足＋1本確認）
void ManagePosition()
{
   if(!PositionSelectByTicket(g_ticket))
   {
      g_stats.FinalState = "PositionClosed";
      ChangeState(STATE_COOLDOWN, "PositionClosed");
      return;
   }

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   // Exit優先順位1: 構造破綻（ImpulseStart 終値割れ/超え）
   {
      double close1 = iClose(Symbol(), PERIOD_M1, 1);
      bool structBreak = false;

      if(g_impulseDir == DIR_LONG && close1 < g_impulseStart)
         structBreak = true;
      else if(g_impulseDir == DIR_SHORT && close1 > g_impulseStart)
         structBreak = true;

      if(structBreak)
      {
         g_stats.FinalState = "StructBreak_Fib0";
         ClosePosition("StructBreak_Fib0",
                  "ExitReason=STRUCT_BREAK;Fib0=" + DoubleToString(g_impulseStart, digits) +
                  ";Close1=" + DoubleToString(close1, digits));
         ChangeState(STATE_COOLDOWN, "StructBreak_Fib0");
         return;
      }
   }

   // Exit優先順位2: 時間撤退
   g_positionBars++;
   if(g_positionBars >= g_profile.timeExitBars)
   {
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit <= 0)
      {
         g_stats.FinalState = "TimeExit";
         ClosePosition("TimeExit",
                  "ExitReason=TIMEOUT;Bars=" + IntegerToString(g_positionBars));
         ChangeState(STATE_COOLDOWN, "TimeExit");
         return;
      }
   }

   // 建値移動: RR >= 1.0で建値
   {
      double risk = MathAbs(openPrice - g_sl);
      double reward = 0;
      double currentPrice;
      if(g_impulseDir == DIR_LONG)
      {
         currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         reward = currentPrice - openPrice;
      }
      else
      {
         currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         reward = openPrice - currentPrice;
      }

      if(risk > 0 && (reward / risk) >= 1.0)
      {
         if(g_impulseDir == DIR_LONG && currentSL < openPrice)
            ModifySL(openPrice);
         else if(g_impulseDir == DIR_SHORT && (currentSL > openPrice || currentSL == 0))
            ModifySL(openPrice);
      }
   }

   // Exit優先順位3: EMAクロス（確定足＋1本確認）
   {
      double emaFast1 = GetExitEMA(g_exitEMAFastHandle, 1);
      double emaSlow1 = GetExitEMA(g_exitEMASlowHandle, 1);
      double emaFast2 = GetExitEMA(g_exitEMAFastHandle, 2);
      double emaSlow2 = GetExitEMA(g_exitEMASlowHandle, 2);

      if(emaFast1 == 0.0 || emaSlow1 == 0.0 || emaFast2 == 0.0 || emaSlow2 == 0.0)
         return;

      if(g_exitPending)
      {
         g_exitPendingBars++;

         bool crossMaintained = false;
         string crossDir = "";

         if(g_impulseDir == DIR_LONG)
         {
            if(emaFast1 < emaSlow1)
            {
               crossMaintained = true;
               crossDir = "DEAD";
            }
         }
         else
         {
            if(emaFast1 > emaSlow1)
            {
               crossMaintained = true;
               crossDir = "GOLDEN";
            }
         }

         if(crossMaintained && g_exitPendingBars >= ExitConfirmBars)
         {
            g_stats.FinalState = "EMACross_Exit";
            ClosePosition("EMACross",
                     "ExitReason=EMA_CROSS;CrossDir=" + crossDir +
                     ";EMA" + IntegerToString(ExitMAFastPeriod) + "=" + DoubleToString(emaFast1, digits) +
                     ";EMA" + IntegerToString(ExitMASlowPeriod) + "=" + DoubleToString(emaSlow1, digits) +
                     ";ConfirmBars=" + IntegerToString(g_exitPendingBars));
            ChangeState(STATE_COOLDOWN, "EMACross_Exit");
            return;
         }
         else if(!crossMaintained)
         {
            g_exitPending     = false;
            g_exitPendingBars = 0;
         }
      }
      else
      {
         bool crossDetected = false;

         if(g_impulseDir == DIR_LONG)
         {
            if(emaFast2 >= emaSlow2 && emaFast1 < emaSlow1)
               crossDetected = true;
         }
         else
         {
            if(emaFast2 <= emaSlow2 && emaFast1 > emaSlow1)
               crossDetected = true;
         }

         if(crossDetected)
         {
            g_exitPending     = true;
            g_exitPendingBars = 0;
         }
      }
   }
}

void ModifySL(double newSL)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = Symbol();
   request.position = g_ticket;
   request.sl       = newSL;
   request.tp       = g_tp;

   if(!OrderSend(request, result))
   {
      Print("[WARN] ModifySL failed: retcode=", result.retcode);
   }
}

#endif // __EXECUTION_MQH__
