//+------------------------------------------------------------------+
//| Execution.mqh                                                     |
//| スプレッド管理・注文執行・ポジション管理                               |
//+------------------------------------------------------------------+
#ifndef __EXECUTION_MQH__
#define __EXECUTION_MQH__

//+------------------------------------------------------------------+
//| Spread取得・計算（第12.3章）                                        |
//+------------------------------------------------------------------+
double GetCurrentSpreadPts()
{
   return (double)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
}

void UpdateAdaptiveSpread()
{
   // ADAPTIVE算出更新: 新規IMPULSE_FOUND発生時のみ
   if(MaxSpreadMode == SPREAD_MODE_FIXED)
   {
      g_maxSpreadPts = InputMaxSpreadPts;
      return;
   }

   // SpreadBasePts = 直近N分のスプレッド中央値（簡易実装: 現在スプレッドを使用）
   // 仕様: N は内部定数（例：15分）
   double spreadNow = GetCurrentSpreadPts();
   g_spreadBasePts = spreadNow; // 簡易版：Impulse発生時点のスプレッド
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
//| Execution（第8章）                                                 |
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

   // ガードチェック
   if(!IsSpreadOK())
   {
      WriteLog(LOG_REJECT, "", "SpreadExceeded", "SpreadPts=" + DoubleToString(GetCurrentSpreadPts(), 1));
      return false;
   }

   double price = 0;
   ENUM_ORDER_TYPE orderType;

   if(UseLimitEntry)
   {
      // 指値エントリー
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
      // 成行エントリー
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

   // SL/TP計算（第9章）
   CalculateSLTP(price);

   // 注文実行
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
   request.magic        = 20260101; // Magic Number固定
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

   // 約定後乖離チェック（第8.2章）
   double fillDeviation = MathAbs(result.price - price) / Point();
   if(fillDeviation > g_profile.maxFillDeviationPts)
   {
      // 即撤退（保険）
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
//| ポジション管理（第9章）                                             |
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

// === CHANGE-008 === Exit EMA値取得ヘルパー
double GetExitEMA(int handle, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}

// ポジション管理：Hybrid Exit（FlatRange / EMAクロス条件分岐）
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
   bool useFR = (g_frState != FR_INACTIVE);

   // =====================================================================
   // Exit優先順位1: 構造破綻（Fib0 = ImpulseStart 終値割れ/超え：確定足）
   // =====================================================================
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
                  ";Close1=" + DoubleToString(close1, digits) +
                  ";ExitMode=" + (useFR ? "FR" : "Conv"));
         ChangeState(STATE_COOLDOWN, "StructBreak_Fib0");
         return;
      }
   }

   // =====================================================================
   // Exit優先順位2: 時間撤退（FlatRangeモード時は延長値を使用）
   // =====================================================================
   g_positionBars++;
   int timeExitLimit = useFR ? HybridExit_TimeExitBars : g_profile.timeExitBars;
   if(g_positionBars >= timeExitLimit)
   {
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit <= 0)
      {
         g_stats.FinalState = "TimeExit";
         ClosePosition("TimeExit",
                  "ExitReason=TIMEOUT;Bars=" + IntegerToString(g_positionBars) +
                  ";Limit=" + IntegerToString(timeExitLimit) +
                  ";ExitMode=" + (useFR ? "FR" : "Conv"));
         ChangeState(STATE_COOLDOWN, "TimeExit");
         return;
      }
   }

   // =====================================================================
   // 建値移動: RR >= BreakevenRR で建値（維持）— 両モード共通
   // =====================================================================
   if(EnableBreakeven)
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

      if(risk > 0 && (reward / risk) >= BreakevenRR)
      {
         if(g_impulseDir == DIR_LONG && currentSL < openPrice)
            ModifySL(openPrice);
         else if(g_impulseDir == DIR_SHORT && (currentSL > openPrice || currentSL == 0))
            ModifySL(openPrice);
      }
   }

   // =====================================================================
   // Exit優先順位3: モード分岐
   // =====================================================================
   if(useFR)
      ManagePosition_FlatRange(digits);
   else
      ManagePosition_EMACross(digits);
}

//+------------------------------------------------------------------+
//| FlatRange Exit（Hybrid Exit: 21MA方向一致時）                       |
//+------------------------------------------------------------------+
void ManagePosition_FlatRange(int digits)
{
   double close1 = iClose(Symbol(), PERIOD_M1, 1);
   double atr1   = GetATR_M1(1);

   if(atr1 <= 0) return;

   // ── FR_WAIT_FLAT: フラット検出 ──
   if(g_frState == FR_WAIT_FLAT)
   {
      double maCurr[1], maOld[1];
      if(CopyBuffer(g_frMAHandle, 0, 1, 1, maCurr) < 1) return;
      if(CopyBuffer(g_frMAHandle, 0, 1 + FR_FlatSlopeLookback, 1, maOld) < 1) return;

      double slopePts = MathAbs(maCurr[0] - maOld[0]) / _Point;
      double atrPts   = atr1 / _Point;

      if(slopePts <= atrPts * FR_FlatSlopeAtrMult)
      {
         // Flat検出 → レンジ確定
         double highs[], lows[];
         ArraySetAsSeries(highs, true);
         ArraySetAsSeries(lows, true);
         if(CopyHigh(Symbol(), PERIOD_M1, 1, FR_RangeLookback, highs) < FR_RangeLookback) return;
         if(CopyLow(Symbol(), PERIOD_M1, 1, FR_RangeLookback, lows) < FR_RangeLookback) return;

         g_frRangeHigh = highs[ArrayMaximum(highs)];
         g_frRangeLow  = lows[ArrayMinimum(lows)];
         g_frRangeMid  = (g_frRangeHigh + g_frRangeLow) / 2.0;
         g_frWaitBarsCount = 0;
         g_frState = FR_RANGE_LOCKED;

         Print("[FlatRange] Flat detected. Range=",
               DoubleToString(g_frRangeHigh, digits), "/",
               DoubleToString(g_frRangeLow, digits),
               " SlopePts=", DoubleToString(slopePts, 1),
               " ATRPts=", DoubleToString(atrPts, 1));
      }
      return;
   }

   // ── FR_RANGE_LOCKED: ブレイクアウト判定 ──
   if(g_frState == FR_RANGE_LOCKED)
   {
      g_frWaitBarsCount++;

      int breakout = 0;
      if(g_impulseDir == DIR_LONG)
      {
         if(close1 < g_frRangeLow)  breakout = -1;  // 不利ブレイク
         else if(close1 > g_frRangeHigh) breakout = +1;  // 有利ブレイク
      }
      else
      {
         if(close1 > g_frRangeHigh) breakout = -1;
         else if(close1 < g_frRangeLow) breakout = +1;
      }

      if(breakout < 0)
      {
         g_stats.FinalState = "FR_UnfavBreak";
         ClosePosition("FR_UnfavBreak",
                  "ExitReason=UNFAV_BREAK;Range=" +
                  DoubleToString(g_frRangeHigh, digits) + "/" +
                  DoubleToString(g_frRangeLow, digits) +
                  ";Close1=" + DoubleToString(close1, digits));
         ChangeState(STATE_COOLDOWN, "FR_UnfavBreak");
         return;
      }

      if(breakout > 0)
      {
         // 有利ブレイク → トレーリング開始
         if(g_impulseDir == DIR_LONG)
         {
            g_frTrailPeak = iHigh(Symbol(), PERIOD_M1, 1);
            // 過去バーの最高値も考慮
            for(int k = 2; k <= g_positionBars && k <= 500; k++)
            {
               double h = iHigh(Symbol(), PERIOD_M1, k);
               if(h > g_frTrailPeak) g_frTrailPeak = h;
            }
            g_frTrailLine = g_frTrailPeak - atr1 * FR_TrailATRMult;
         }
         else
         {
            g_frTrailPeak = iLow(Symbol(), PERIOD_M1, 1);
            for(int k = 2; k <= g_positionBars && k <= 500; k++)
            {
               double l = iLow(Symbol(), PERIOD_M1, k);
               if(l < g_frTrailPeak) g_frTrailPeak = l;
            }
            g_frTrailLine = g_frTrailPeak + atr1 * FR_TrailATRMult;
         }
         g_frState = FR_TRAILING;

         Print("[FlatRange] Favorable breakout → trailing. Peak=",
               DoubleToString(g_frTrailPeak, digits),
               " Line=", DoubleToString(g_frTrailLine, digits));
         return;
      }

      // FailSafe: WaitBars超過
      if(g_frWaitBarsCount > FR_WaitBarsAfterFlat)
      {
         g_stats.FinalState = "FR_FailSafe";
         ClosePosition("FR_FailSafe",
                  "ExitReason=FAILSAFE;WaitBars=" + IntegerToString(g_frWaitBarsCount) +
                  ";Range=" + DoubleToString(g_frRangeHigh, digits) + "/" +
                  DoubleToString(g_frRangeLow, digits));
         ChangeState(STATE_COOLDOWN, "FR_FailSafe");
         return;
      }
      return;
   }

   // ── FR_TRAILING: ATRトレーリング ──
   if(g_frState == FR_TRAILING)
   {
      if(g_impulseDir == DIR_LONG)
      {
         double h1 = iHigh(Symbol(), PERIOD_M1, 1);
         if(h1 > g_frTrailPeak) g_frTrailPeak = h1;
         g_frTrailLine = g_frTrailPeak - atr1 * FR_TrailATRMult;

         if(close1 < g_frTrailLine)
         {
            g_stats.FinalState = "FR_TrailStop";
            ClosePosition("FR_TrailStop",
                     "ExitReason=TRAIL_STOP;Peak=" + DoubleToString(g_frTrailPeak, digits) +
                     ";Line=" + DoubleToString(g_frTrailLine, digits) +
                     ";Close1=" + DoubleToString(close1, digits));
            ChangeState(STATE_COOLDOWN, "FR_TrailStop");
            return;
         }
      }
      else
      {
         double l1 = iLow(Symbol(), PERIOD_M1, 1);
         if(l1 < g_frTrailPeak) g_frTrailPeak = l1;
         g_frTrailLine = g_frTrailPeak + atr1 * FR_TrailATRMult;

         if(close1 > g_frTrailLine)
         {
            g_stats.FinalState = "FR_TrailStop";
            ClosePosition("FR_TrailStop",
                     "ExitReason=TRAIL_STOP;Peak=" + DoubleToString(g_frTrailPeak, digits) +
                     ";Line=" + DoubleToString(g_frTrailLine, digits) +
                     ";Close1=" + DoubleToString(close1, digits));
            ChangeState(STATE_COOLDOWN, "FR_TrailStop");
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EMA Cross Exit（従来方式：21MA不一致時 or HybridExit無効時）         |
//+------------------------------------------------------------------+
void ManagePosition_EMACross(int digits)
{
   // EMA値取得（確定足: shift=1, 1本前: shift=2）
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
