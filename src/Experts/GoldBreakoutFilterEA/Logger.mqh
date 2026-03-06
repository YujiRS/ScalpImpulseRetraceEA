//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| ログ出力（第13章）・TradeUUID・MA Confluence解析                      |
//+------------------------------------------------------------------+
#ifndef __LOGGER_MQH__
#define __LOGGER_MQH__

// 第13.5章: ログファイル命名規則
string BuildLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string runId = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);

   string fileName = EA_NAME + "_" + runId + "_" + Symbol() + ".tsv";
   return fileName;
}

string BuildSummaryFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string runId = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);

   string fileName = EA_NAME + "_SUMMARY_" + runId + "_" + Symbol() + ".tsv";
   return fileName;
}

void LoggerInit()
{
   if(LogLevel == LOG_LEVEL_OFF)
      return;

   g_logFileName = BuildLogFileName();

   // 既存ファイルがあれば追記、無ければ新規作成してヘッダ出力
   bool exists = FileIsExist(g_logFileName);

   // FILE_WRITE は先頭上書きになるため、READ|WRITE で開いて末尾へシークする
   // === IMPROVEMENT === FILE_SHARE_READ追加: 外部ツールでの並行読み取りを許可
   g_logFileHandle = FileOpen(g_logFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ, '\t');

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
}

// === ANALYZE追加 === ImpulseSummary TSV出力（1 Impulse = 1行）
void DumpImpulseSummary()
{
   if(LogLevel != LOG_LEVEL_ANALYZE) return;
   if(g_stats.TradeUUID == "") return;

   string fileName = BuildSummaryFileName();
   bool headerNeeded = !FileIsExist(fileName);

   int handle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_SHARE_WRITE | FILE_SHARE_READ, '\t');
   if(handle == INVALID_HANDLE) return;

   if(headerNeeded)
   {
      FileWrite(handle,
         "Time", "Symbol", "MarketMode", "TradeUUID",
         "RangePts", "BandWidthPts", "LeaveDistancePts", "SpreadBasePts",
         "FreezeCancelCount",
         "Touch1Count", "LeaveCount", "Touch2Count", "ConfirmCount",
         "RiskGatePass", "Touch2Reached", "ConfirmReached", "EntryGatePass",
         "RR_Actual", "RR_Min",
         "RangeCostMult_Actual", "RangeCostMult_Min",
         "FinalState", "RejectStage",

         // --- MA Confluence（列順はDOC-LOG 3.3が正典：この位置固定）
         "MA_ConfluenceCount", "MA_InBand_List", "MA_InBand_FibPct",
         "MA_TightHitCount", "MA_TightHit_List",
         "MA_NearBand_List", "MA_NearestDistance",
         "MA_DirectionAligned", "MA_Values", "MA_Eval_Price",

         // --- STRUCTURE_BREAK（後方互換：末尾追加）
         "StructBreakReason", "StructBreakPriority", "StructBreakRefLevel",
         "StructBreakRefPrice", "StructBreakAtPrice", "StructBreakDistPts", "StructBreakBarShift",
         "StructBreakSide",

         // --- TrendFilter / ReversalGuard（後方互換：末尾追加）
         "TrendFilterEnable", "TrendTF", "TrendMethod", "TrendDir",
         "TrendSlope", "TrendSlopeMin", "TrendATRFloor", "TrendAligned",
         "ReversalGuardEnable", "ReversalTF", "ReversalGuardTriggered", "ReversalReason",

         // --- EMA Cross Filter / Impulse Exceed Filter（後方互換：末尾追加）
         "EMACrossFilterEnable", "EMACrossFastVal", "EMACrossSlowVal",
         "EMACrossDir", "EMACrossAligned",
         "ImpulseExceedEnable", "ImpulseRangeATR", "ImpulseExceedMax", "ImpulseExceedTriggered"
      );
   }

   FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
      TimeToString(g_stats.StartTime, TIME_DATE|TIME_SECONDS),
      Symbol(),
      "GOLD",
      g_stats.TradeUUID,

      g_stats.RangePts,
      g_stats.BandWidthPts,
      g_stats.LeaveDistancePts,
      g_stats.SpreadBasePts,

      g_stats.FreezeCancelCount,

      g_stats.Touch1Count,
      g_stats.LeaveCount,
      g_stats.Touch2Count,
      g_stats.ConfirmCount,

      g_stats.RiskGatePass ? 1 : 0,
      g_stats.Touch2Reached ? 1 : 0,
      g_stats.ConfirmReached ? 1 : 0,
      g_stats.EntryGatePass ? 1 : 0,

      g_stats.RR_Actual,
      g_stats.RR_Min,

      g_stats.RangeCostMult_Actual,
      g_stats.RangeCostMult_Min,

      // ★FIX: FinalState は string のため StateToString() を通さずそのまま出力
      g_stats.FinalState,
      g_stats.RejectStage,

      // --- MA Confluence
      (g_stats.MA_ConfluenceCount >= 0) ? IntegerToString(g_stats.MA_ConfluenceCount) : "",
      g_stats.MA_InBand_List,
      g_stats.MA_InBand_FibPct,
      (g_stats.MA_TightHitCount >= 0) ? IntegerToString(g_stats.MA_TightHitCount) : "",
      g_stats.MA_TightHit_List,
      g_stats.MA_NearBand_List,
      g_stats.MA_NearestDistance,
      (g_stats.MA_DirectionAligned >= 0) ? IntegerToString(g_stats.MA_DirectionAligned) : "",
      g_stats.MA_Values,
      g_stats.MA_Eval_Price,

      // --- STRUCTURE_BREAK
      g_stats.StructBreakReason,
      g_stats.StructBreakPriority,
      g_stats.StructBreakRefLevel,
      g_stats.StructBreakRefPrice,
      g_stats.StructBreakAtPrice,
      g_stats.StructBreakDistPts,
      g_stats.StructBreakBarShift,
      g_stats.StructBreakSide,

      // --- TrendFilter / ReversalGuard
      (g_stats.TrendFilterEnable>=0) ? IntegerToString(g_stats.TrendFilterEnable) : "",
      g_stats.TrendTF,
      g_stats.TrendMethod,
      g_stats.TrendDir,
      g_stats.TrendSlope,
      g_stats.TrendSlopeMin,
      g_stats.TrendATRFloor,
      (g_stats.TrendAligned>=0) ? IntegerToString(g_stats.TrendAligned) : "",
      (g_stats.ReversalGuardEnable>=0) ? IntegerToString(g_stats.ReversalGuardEnable) : "",
      g_stats.ReversalTF,
      (g_stats.ReversalGuardTriggered>=0) ? IntegerToString(g_stats.ReversalGuardTriggered) : "",
      g_stats.ReversalReason,

      // --- EMA Cross Filter / Impulse Exceed Filter
      (g_stats.EMACrossFilterEnable>=0) ? IntegerToString(g_stats.EMACrossFilterEnable) : "",
      g_stats.EMACrossFastVal,
      g_stats.EMACrossSlowVal,
      g_stats.EMACrossDir,
      (g_stats.EMACrossAligned>=0) ? IntegerToString(g_stats.EMACrossAligned) : "",
      (g_stats.ImpulseExceedEnable>=0) ? IntegerToString(g_stats.ImpulseExceedEnable) : "",
      g_stats.ImpulseRangeATR,
      g_stats.ImpulseExceedMax,
      (g_stats.ImpulseExceedTriggered>=0) ? IntegerToString(g_stats.ImpulseExceedTriggered) : ""
   );

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

   // 押し帯情報（アクティブな帯を出力）
   double bandLower = g_primaryBandLower;
   double bandUpper = g_primaryBandUpper;
   if(g_touch2BandId == 1) { bandLower = g_deepBandLower; bandUpper = g_deepBandUpper; }
   if(g_touch2BandId == 2) { bandLower = g_optBand38Lower; bandUpper = g_optBand38Upper; }

   int totalTouches = g_touchCount_Primary;
   if(g_touch2BandId == 1) totalTouches = g_touchCount_Deep;
   if(g_touch2BandId == 2) totalTouches = g_touchCount_Opt38;

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
   string runStr = StringFormat("%02d", RunId);
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

   // アクティブ帯のUpper/Lower取得
   double bandUpper = g_primaryBandUpper;
   double bandLower = g_primaryBandLower;
   // GOLD DeepBandがONの場合はDeepBandを使用
   if(g_goldDeepBandON && g_deepBandUpper > 0 && g_deepBandLower > 0)
   {
      bandUpper = g_deepBandUpper;
      bandLower = g_deepBandLower;
   }

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
