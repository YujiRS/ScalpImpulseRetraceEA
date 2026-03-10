//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| ログ出力（第13章）・TradeUUID・MA Confluence解析                      |
//+------------------------------------------------------------------+
#ifndef __LOGGER_MQH__
#define __LOGGER_MQH__

// ログスロット自動連番
int g_autoRunId = 1;
int g_lockFileHandle = INVALID_HANDLE;

string BuildLogDateStr()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

void AcquireLogSlot()
{
   // RunId > 0 → ユーザー手動指定を優先
   if(RunId > 0)
   {
      g_autoRunId = RunId;
      return;
   }

   string dateStr = BuildLogDateStr();
   for(int i = 1; i <= 10; i++)
   {
      string lockName = EA_NAME + "_" + dateStr + "_" + Symbol() + "_R" + IntegerToString(i) + ".lock";
      int h = FileOpen(lockName, FILE_WRITE | FILE_TXT);
      if(h != INVALID_HANDLE)
      {
         g_lockFileHandle = h;
         g_autoRunId = i;
         return;
      }
   }
   // フォールバック
   g_autoRunId = 1;
}

void ReleaseLogSlot()
{
   if(g_lockFileHandle != INVALID_HANDLE)
   {
      FileClose(g_lockFileHandle);
      g_lockFileHandle = INVALID_HANDLE;
   }
}

string BuildLogFileName()
{
   string dateStr = BuildLogDateStr();
   return EA_NAME + "_" + dateStr + "_" + Symbol() + "_R" + IntegerToString(g_autoRunId) + ".tsv";
}

string BuildSummaryFileName()
{
   string dateStr = BuildLogDateStr();
   return EA_NAME + "_SUMMARY_" + dateStr + "_" + Symbol() + "_R" + IntegerToString(g_autoRunId) + ".tsv";
}

void LoggerInit()
{
   if(LogLevel == LOG_LEVEL_OFF)
      return;

   AcquireLogSlot();
   g_logFileName = BuildLogFileName();

   // 既存ファイルがあれば追記、無ければ新規作成してヘッダ出力
   bool exists = FileIsExist(g_logFileName);

   // FILE_WRITE は先頭上書きになるため、READ|WRITE で開いて末尾へシークする
   // FILE_SHARE_READ: 外部ツールでの並行読み取りを許可
   // FILE_SHARE_WRITE: 複数インスタンス起動時の並行書き込みを許可
   g_logFileHandle = FileOpen(g_logFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, '\t');

   if(g_logFileHandle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open log file: ", g_logFileName);
      return;
   }

   if(exists)
   {
      // 追記モード：末尾へ
      FileSeek(g_logFileHandle, 0, SEEK_END);
   }
   else
   {
      // 第13.1章: TSV固定列ヘッダ
      string header = "Time\tSymbol\tMarketMode\tState\tTradeUUID\tEvent\t"
                      "StartAdjusted\tDeepBandON\tImpulseATR\tStartPrice\tEndPrice\t"
                      "BandLower\tBandUpper\tTouchCount\tFreezeCancelCount\t"
                      "ConfirmType\tEntryType\tEntryPrice\tSL\tTP\t"
                      "SpreadPts\tSlippagePts\tFillDeviationPts\tResult\tRejectReason\tExtra";
      FileWriteString(g_logFileHandle, header + "\n");
      FileFlush(g_logFileHandle);
   }
}

void LoggerDeinit()
{
   if(g_logFileHandle != INVALID_HANDLE)
   {
      FileClose(g_logFileHandle);
      g_logFileHandle = INVALID_HANDLE;
   }
   ReleaseLogSlot();
}

// === ANALYZE追加 === ImpulseSummary TSV出力（1 Impulse = 1行）
void DumpImpulseSummary()
{
   if(LogLevel != LOG_LEVEL_ANALYZE) return;
   if(g_stats.TradeUUID == "") return;

   string fileName = BuildSummaryFileName();
   bool headerNeeded = !FileIsExist(fileName);

   int handle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_SHARE_WRITE | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) return;

   if(headerNeeded)
   {
      string header =
         "Time\tSymbol\tMarketMode\tTradeUUID\t"
         "RangePts\tBandWidthPts\tLeaveDistancePts\tSpreadBasePts\t"
         "FreezeCancelCount\t"
         "Touch1Count\tLeaveCount\tTouch2Count\tConfirmCount\t"
         "RiskGatePass\tTouch2Reached\tConfirmReached\tEntryGatePass\t"
         "RR_Actual\tRR_Min\t"
         "RangeCostMult_Actual\tRangeCostMult_Min\t"
         "FinalState\tRejectStage\t"
         // --- MA Confluence
         "MA_ConfluenceCount\tMA_InBand_List\tMA_InBand_FibPct\t"
         "MA_TightHitCount\tMA_TightHit_List\t"
         "MA_NearBand_List\tMA_NearestDistance\t"
         "MA_DirectionAligned\tMA_Values\tMA_Eval_Price\t"
         // --- STRUCTURE_BREAK
         "StructBreakReason\tStructBreakPriority\tStructBreakRefLevel\t"
         "StructBreakRefPrice\tStructBreakAtPrice\tStructBreakDistPts\tStructBreakBarShift\t"
         "StructBreakSide\tStructBreakAtKind\tStructBreakWickCross\tStructBreakWickDistPts\t"
         // --- TrendFilter / ReversalGuard
         "TrendFilterEnable\tTrendTF\tTrendMethod\tTrendDir\t"
         "TrendSlope\tTrendSlopeMin\tTrendATRFloor\tTrendAligned\t"
         "ReversalGuardEnable\tReversalTF\tReversalGuardTriggered\tReversalReason\t"
         // --- EMA Cross Filter / Impulse Exceed Filter
         "EMACrossFilterEnable\tEMACrossFastVal\tEMACrossSlowVal\t"
         "EMACrossDir\tEMACrossAligned\t"
         "ImpulseExceedEnable\tImpulseRangeATR\tImpulseExceedMax\tImpulseExceedTriggered";
      FileWriteString(handle, header + "\n");
   }

   FileSeek(handle, 0, SEEK_END);

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   string line =
      TimeToString(g_stats.StartTime, TIME_DATE|TIME_SECONDS) + "\t" +
      Symbol() + "\t" +
      "GOLD" + "\t" +
      g_stats.TradeUUID + "\t" +

      DoubleToString(g_stats.RangePts, 1) + "\t" +
      DoubleToString(g_stats.BandWidthPts, 1) + "\t" +
      DoubleToString(g_stats.LeaveDistancePts, 1) + "\t" +
      DoubleToString(g_stats.SpreadBasePts, 1) + "\t" +

      IntegerToString(g_stats.FreezeCancelCount) + "\t" +

      IntegerToString(g_stats.Touch1Count) + "\t" +
      IntegerToString(g_stats.LeaveCount) + "\t" +
      IntegerToString(g_stats.Touch2Count) + "\t" +
      IntegerToString(g_stats.ConfirmCount) + "\t" +

      IntegerToString(g_stats.RiskGatePass ? 1 : 0) + "\t" +
      IntegerToString(g_stats.Touch2Reached ? 1 : 0) + "\t" +
      IntegerToString(g_stats.ConfirmReached ? 1 : 0) + "\t" +
      IntegerToString(g_stats.EntryGatePass ? 1 : 0) + "\t" +

      DoubleToString(g_stats.RR_Actual, 2) + "\t" +
      DoubleToString(g_stats.RR_Min, 2) + "\t" +

      DoubleToString(g_stats.RangeCostMult_Actual, 2) + "\t" +
      DoubleToString(g_stats.RangeCostMult_Min, 2) + "\t" +

      g_stats.FinalState + "\t" +
      g_stats.RejectStage + "\t" +

      // --- MA Confluence
      ((g_stats.MA_ConfluenceCount >= 0) ? IntegerToString(g_stats.MA_ConfluenceCount) : "") + "\t" +
      g_stats.MA_InBand_List + "\t" +
      g_stats.MA_InBand_FibPct + "\t" +
      ((g_stats.MA_TightHitCount >= 0) ? IntegerToString(g_stats.MA_TightHitCount) : "") + "\t" +
      g_stats.MA_TightHit_List + "\t" +
      g_stats.MA_NearBand_List + "\t" +
      DoubleToString(g_stats.MA_NearestDistance, 1) + "\t" +
      ((g_stats.MA_DirectionAligned >= 0) ? IntegerToString(g_stats.MA_DirectionAligned) : "") + "\t" +
      g_stats.MA_Values + "\t" +
      DoubleToString(g_stats.MA_Eval_Price, digits) + "\t" +

      // --- STRUCTURE_BREAK
      g_stats.StructBreakReason + "\t" +
      IntegerToString(g_stats.StructBreakPriority) + "\t" +
      g_stats.StructBreakRefLevel + "\t" +
      DoubleToString(g_stats.StructBreakRefPrice, digits) + "\t" +
      DoubleToString(g_stats.StructBreakAtPrice, digits) + "\t" +
      DoubleToString(g_stats.StructBreakDistPts, 1) + "\t" +
      IntegerToString(g_stats.StructBreakBarShift) + "\t" +
      g_stats.StructBreakSide + "\t" +
      g_stats.StructBreakAtKind + "\t" +
      IntegerToString(g_stats.StructBreakWickCross) + "\t" +
      DoubleToString(g_stats.StructBreakWickDistPts, 1) + "\t" +

      // --- TrendFilter / ReversalGuard
      ((g_stats.TrendFilterEnable>=0) ? IntegerToString(g_stats.TrendFilterEnable) : "") + "\t" +
      g_stats.TrendTF + "\t" +
      g_stats.TrendMethod + "\t" +
      g_stats.TrendDir + "\t" +
      DoubleToString(g_stats.TrendSlope, 4) + "\t" +
      DoubleToString(g_stats.TrendSlopeMin, 4) + "\t" +
      DoubleToString(g_stats.TrendATRFloor, 1) + "\t" +
      ((g_stats.TrendAligned>=0) ? IntegerToString(g_stats.TrendAligned) : "") + "\t" +
      ((g_stats.ReversalGuardEnable>=0) ? IntegerToString(g_stats.ReversalGuardEnable) : "") + "\t" +
      g_stats.ReversalTF + "\t" +
      ((g_stats.ReversalGuardTriggered>=0) ? IntegerToString(g_stats.ReversalGuardTriggered) : "") + "\t" +
      g_stats.ReversalReason + "\t" +

      // --- EMA Cross Filter / Impulse Exceed Filter
      ((g_stats.EMACrossFilterEnable>=0) ? IntegerToString(g_stats.EMACrossFilterEnable) : "") + "\t" +
      DoubleToString(g_stats.EMACrossFastVal, digits) + "\t" +
      DoubleToString(g_stats.EMACrossSlowVal, digits) + "\t" +
      g_stats.EMACrossDir + "\t" +
      ((g_stats.EMACrossAligned>=0) ? IntegerToString(g_stats.EMACrossAligned) : "") + "\t" +
      ((g_stats.ImpulseExceedEnable>=0) ? IntegerToString(g_stats.ImpulseExceedEnable) : "") + "\t" +
      DoubleToString(g_stats.ImpulseRangeATR, 2) + "\t" +
      DoubleToString(g_stats.ImpulseExceedMax, 2) + "\t" +
      ((g_stats.ImpulseExceedTriggered>=0) ? IntegerToString(g_stats.ImpulseExceedTriggered) : "");

   FileWriteString(handle, line + "\n");

   FileClose(handle);
}

// ログ1行出力
void WriteLog(ENUM_LOG_EVENT event,
              string result = "",
              string rejectReason = "",
              string extra = "",
              double slippagePts = 0.0,
              double fillDeviationPts = 0.0)
{
   if(LogLevel == LOG_LEVEL_OFF)
      return;

   // NORMAL: State変更 + ENTRY/EXITのみ
   if(LogLevel == LOG_LEVEL_NORMAL)
   {
      if(event != LOG_STATE && event != LOG_ENTRY && event != LOG_EXIT &&
         event != LOG_POSITION)
         return;
   }

   // G4個別フラグチェック
   if(event == LOG_STATE && !LogStateTransitions) return;
   if(event == LOG_IMPULSE && !LogImpulseEvents) return;
   if(event == LOG_TOUCH && !LogTouchEvents) return;
   if(event == LOG_CONFIRM && !LogConfirmEvents) return;
   if((event == LOG_ENTRY || event == LOG_EXIT) && !LogEntryExit) return;
   if(event == LOG_REJECT && !LogRejectReason) return;

   if(g_logFileHandle == INVALID_HANDLE)
      return;

   double currentSpread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * Point();

   // MA Bounceバンド情報
   double bandLower = g_maBounceMAValue - g_maBounceBandWidth;
   double bandUpper = g_maBounceMAValue + g_maBounceBandWidth;

   int totalTouches = g_stats.ConfirmCount;

   // ATR値
   double atrVal = GetATR_M1(0);

   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\t" +
                 Symbol() + "\t" +
                 "GOLD" + "\t" +
                 StateToString(g_currentState) + "\t" +
                 g_tradeUUID + "\t" +
                 LogEventToString(event) + "\t" +
                 (g_startAdjusted ? "true" : "false") + "\t" +
                 (g_goldDeepBandON ? "true" : "false") + "\t" +
                 DoubleToString(atrVal, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(g_impulseStart, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(g_impulseEnd, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(bandLower, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(bandUpper, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 IntegerToString(totalTouches) + "\t" +
                 IntegerToString(g_freezeCancelCount) + "\t" +
                 ConfirmTypeToString(g_confirmType) + "\t" +
                 EntryTypeToString(g_entryType) + "\t" +
                 DoubleToString(g_entryPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(g_sl, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(g_tp, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) + "\t" +
                 DoubleToString(currentSpread / Point(), 1) + "\t" +
                 DoubleToString(slippagePts, 1) + "\t" +
                 DoubleToString(fillDeviationPts, 1) + "\t" +
                 result + "\t" +
                 rejectReason + "\t" +
                 extra;

   FileWriteString(g_logFileHandle, line + "\n");
   FileFlush(g_logFileHandle);
}

//+------------------------------------------------------------------+
//| TradeUUID生成（第13.7章）                                          |
//+------------------------------------------------------------------+
string GenerateTradeUUID()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string ts = StringFormat("%04d%02d%02d%02d%02d%02d",
                            dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   string runStr = StringFormat("%02d", g_autoRunId);
   return ts + "_" + Symbol() + "_" + runStr;
}

//+------------------------------------------------------------------+
//| MA Confluence 解析（第13.9.6章）                                    |
//| ロジックへの影響なし。ImpulseSummary用の純粋なログ機能                  |
//+------------------------------------------------------------------+

// MA期間の初期化（MarketProfile内部定義・SMA固定）
void InitMAPeriods()
{
   // GOLD: {5, 13, 21, 100, 200}
   g_maPeriodsCount = 5;
   ArrayResize(g_maPeriods, 5);
   g_maPeriods[0] = 5;
   g_maPeriods[1] = 13;
   g_maPeriods[2] = 21;
   g_maPeriods[3] = 100;
   g_maPeriods[4] = 200;
}

// SMA値取得ヘルパー（shift=1: 確定足）
double GetSMAValue(int handleIndex, int shift)
{
   if(handleIndex < 0 || handleIndex >= g_maPeriodsCount) return 0.0;
   if(g_smaHandles[handleIndex] == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_smaHandles[handleIndex], 0, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}

// MA Confluence評価（IMPULSE_CONFIRMED時点で1回だけ呼ぶ）
void EvaluateMAConfluence()
{
   // 条件チェック: ANALYZE + LogMAConfluence のみ
   if(LogLevel != LOG_LEVEL_ANALYZE || !LogMAConfluence)
      return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   // 評価価格: IMPULSE_CONFIRMED成立足のClose（shift=1）
   double evalPrice = iClose(Symbol(), PERIOD_M1, 1);
   g_stats.MA_Eval_Price = evalPrice;
   g_stats.MA_Evaluated = true;

   // MA Bounceバンドを使用
   double bandUpper = g_maBounceMAValue + g_maBounceBandWidth;
   double bandLower = g_maBounceMAValue - g_maBounceBandWidth;

   double bandCenter = (bandUpper + bandLower) / 2.0;
   double bandWidth  = g_effectiveBandWidthPts;
   double nearRange  = bandWidth * 1.0; // 近傍定義: 帯外BandWidthPts×1.0以内

   // TightPts定義（市場別・固定: SpreadBasePts × 2.0）
   // g_spreadBasePts は SYMBOL_SPREAD（ポイント整数）由来 → 価格単位に変換
   double tightPts = g_spreadBasePts * SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 2.0;

   // 0-100幅（Fib%算出用）
   double fib0   = g_impulseStart;
   double fib100 = g_impulseEnd;
   double fibRange = MathAbs(fib100 - fib0);

   // 各MA値の取得と分類
   int    confluenceCount = 0;
   int    tightHitCount   = 0;
   string inBandList      = "";
   string inBandFibPct    = "";
   string tightHitList    = "";
   string nearBandList    = "";
   string maValues        = "";
   double nearestDist     = 999999.0;

   // 短期群・長期群（DirectionAligned用）
   double shortMAvals[];  // {5, 13, 21}
   double longMAvals[];   // {100, 200} or {100, 200, 365}
   ArrayResize(shortMAvals, 0);
   ArrayResize(longMAvals, 0);

   for(int i = 0; i < g_maPeriodsCount; i++)
   {
      double maVal = GetSMAValue(i, 1); // shift=1: 確定足
      if(maVal <= 0) continue;

      int period = g_maPeriods[i];

      // MA_Values記録
      if(maValues != "") maValues += ";";
      maValues += IntegerToString(period) + "=" + DoubleToString(maVal, digits);

      // 短期/長期分類
      if(period <= 21)
      {
         int sz = ArraySize(shortMAvals);
         ArrayResize(shortMAvals, sz + 1);
         shortMAvals[sz] = maVal;
      }
      else
      {
         int sz = ArraySize(longMAvals);
         ArrayResize(longMAvals, sz + 1);
         longMAvals[sz] = maVal;
      }

      // 帯中心からの距離
      double distFromCenter = maVal - bandCenter;
      // 符号: Impulse方向側=正、起点方向側=負
      if(g_impulseDir == DIR_SHORT)
         distFromCenter = -distFromCenter; // Short時は反転

      if(MathAbs(maVal - bandCenter) < MathAbs(nearestDist))
      {
         // nearestDistは符号つきで記録
         nearestDist = distFromCenter;
      }

      // 帯内判定
      bool inBand = (maVal >= bandLower && maVal <= bandUpper);

      // TightHit判定（evalPriceとの距離）
      bool tightHit = (MathAbs(maVal - evalPrice) <= tightPts);

      if(inBand)
      {
         confluenceCount++;

         if(inBandList != "") inBandList += ",";
         inBandList += IntegerToString(period);

         // Fib%算出
         double fibPct = 0.0;
         if(fibRange > 0)
         {
            if(g_impulseDir == DIR_LONG)
               fibPct = (maVal - fib0) / fibRange * 100.0;
            else
               fibPct = (fib0 - maVal) / fibRange * 100.0;
         }
         if(inBandFibPct != "") inBandFibPct += ",";
         inBandFibPct += IntegerToString(period) + ":" + DoubleToString(fibPct, 1);
      }

      if(tightHit)
      {
         tightHitCount++;
         if(tightHitList != "") tightHitList += ",";
         tightHitList += IntegerToString(period);
      }

      // 近傍判定（帯外だが近い）
      if(!inBand)
      {
         double distFromBand = 0.0;
         if(maVal > bandUpper)
            distFromBand = maVal - bandUpper;
         else if(maVal < bandLower)
            distFromBand = bandLower - maVal;

         if(distFromBand <= nearRange && distFromBand > 0)
         {
            if(nearBandList != "") nearBandList += ",";
            nearBandList += IntegerToString(period);
         }
      }
   }

   // DirectionAligned判定
   int dirAligned = -1; // -1 = 評価不能
   if(ArraySize(shortMAvals) > 0 && ArraySize(longMAvals) > 0)
   {
      // 中央値算出
      ArraySort(shortMAvals);
      ArraySort(longMAvals);
      double shortMed = shortMAvals[ArraySize(shortMAvals) / 2];
      double longMed  = longMAvals[ArraySize(longMAvals) / 2];

      if(g_impulseDir == DIR_LONG)
         dirAligned = (shortMed > longMed) ? 1 : 0;
      else if(g_impulseDir == DIR_SHORT)
         dirAligned = (shortMed < longMed) ? 1 : 0;
   }

   // 結果をg_statsに格納
   g_stats.MA_ConfluenceCount = confluenceCount;
   g_stats.MA_InBand_List     = inBandList;
   g_stats.MA_InBand_FibPct   = inBandFibPct;
   g_stats.MA_TightHitCount   = tightHitCount;
   g_stats.MA_TightHit_List   = tightHitList;
   g_stats.MA_NearBand_List   = nearBandList;
   g_stats.MA_NearestDistance  = (nearestDist < 999999.0) ? nearestDist : 0.0;
   g_stats.MA_DirectionAligned = dirAligned;
   g_stats.MA_Values          = maValues;
}

#endif // __LOGGER_MQH__
