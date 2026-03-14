//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| FX専用: ログ出力・TradeUUID・MA Confluence解析                       |
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

   bool exists = FileIsExist(g_logFileName);

   // FILE_SHARE_WRITE: 複数インスタンス起動時の並行書き込みを許可
   g_logFileHandle = FileOpen(g_logFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, '\t');

   if(g_logFileHandle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open log file: ", g_logFileName);
      return;
   }

   if(exists)
   {
      FileSeek(g_logFileHandle, 0, SEEK_END);
   }
   else
   {
      string header = "Time\tSymbol\tMarketMode\tState\tTradeUUID\tEvent\t"
                      "StartAdjusted\tImpulseATR\tStartPrice\tEndPrice\t"
                      "BandLower\tBandUpper\tTouchCount\tFreezeCancelCount\t"
                      "ConfirmType\tEntryType\tEntryPrice\tSL\tTP\t"
                      "SpreadPts\tSlippagePts\tFillDeviationPts\tResult\tRejectReason\tExtra\t"
                      "M15_EMA50\tM15_EMA50_Dir\tH1_EMA50\tH1_EMA50_Dir\t"
                      "H4_EMA50\tH4_EMA50_Dir\tD1_EMA50\tD1_EMA50_Dir\tH4_ATR14\tD1_ATR14";
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
         "MA_ConfluenceCount", "MA_InBand_List", "MA_InBand_FibPct",
         "MA_TightHitCount", "MA_TightHit_List",
         "MA_NearBand_List", "MA_NearestDistance",
         "MA_DirectionAligned", "MA_Values", "MA_Eval_Price",
         "StructBreakReason", "StructBreakPriority", "StructBreakRefLevel",
         "StructBreakRefPrice", "StructBreakAtPrice", "StructBreakDistPts", "StructBreakBarShift",
         "StructBreakSide", "StructBreakAtKind", "StructBreakWickCross", "StructBreakWickDistPts",
         "TrendFilterEnable", "TrendTF", "TrendMethod", "TrendDir",
         "TrendSlope", "TrendSlopeMin", "TrendATRFloor", "TrendAligned",
         "ReversalGuardEnable", "ReversalTF", "ReversalGuardTriggered", "ReversalReason",
         // HTF Snapshot (H4/D1)
         "H4_EMA50", "H4_EMA50_Dir", "D1_EMA50", "D1_EMA50_Dir", "H4_ATR14", "D1_ATR14"
      );
   }

   FileSeek(handle, 0, SEEK_END);

   // --- HTF Snapshot (H4/D1) を事前計算
   string sym = Symbol();
   int htfDigits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double h4_ema1 = GetMAValue(sym, PERIOD_H4, 50, MODE_EMA, PRICE_CLOSE, 1);
   double h4_ema2 = GetMAValue(sym, PERIOD_H4, 50, MODE_EMA, PRICE_CLOSE, 2);
   string h4_dir = (h4_ema1 == EMPTY_VALUE || h4_ema2 == EMPTY_VALUE) ? "" :
                   (h4_ema1 > h4_ema2) ? "LONG" : (h4_ema1 < h4_ema2) ? "SHORT" : "FLAT";
   double d1_ema1 = GetMAValue(sym, PERIOD_D1, 50, MODE_EMA, PRICE_CLOSE, 1);
   double d1_ema2 = GetMAValue(sym, PERIOD_D1, 50, MODE_EMA, PRICE_CLOSE, 2);
   string d1_dir = (d1_ema1 == EMPTY_VALUE || d1_ema2 == EMPTY_VALUE) ? "" :
                   (d1_ema1 > d1_ema2) ? "LONG" : (d1_ema1 < d1_ema2) ? "SHORT" : "FLAT";
   double h4_atr = GetATRValue(sym, PERIOD_H4, 14, 1);
   double d1_atr = GetATRValue(sym, PERIOD_D1, 14, 1);
   string h4_ema_str = (h4_ema1 != EMPTY_VALUE) ? DoubleToString(h4_ema1, htfDigits) : "";
   string d1_ema_str = (d1_ema1 != EMPTY_VALUE) ? DoubleToString(d1_ema1, htfDigits) : "";
   string h4_atr_str = (h4_atr != EMPTY_VALUE) ? DoubleToString(h4_atr, htfDigits) : "";
   string d1_atr_str = (d1_atr != EMPTY_VALUE) ? DoubleToString(d1_atr, htfDigits) : "";

   FileWrite(handle,
      TimeToString(g_stats.StartTime, TIME_DATE|TIME_SECONDS),
      Symbol(),
      "FX",
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

      g_stats.FinalState,
      g_stats.RejectStage,

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

      g_stats.StructBreakReason,
      g_stats.StructBreakPriority,
      g_stats.StructBreakRefLevel,
      g_stats.StructBreakRefPrice,
      g_stats.StructBreakAtPrice,
      g_stats.StructBreakDistPts,
      g_stats.StructBreakBarShift,
      g_stats.StructBreakSide,
      g_stats.StructBreakAtKind,
      g_stats.StructBreakWickCross,
      g_stats.StructBreakWickDistPts,

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

      // HTF Snapshot (H4/D1)
      h4_ema_str, h4_dir, d1_ema_str, d1_dir, h4_atr_str, d1_atr_str
   );

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| HTF Snapshot: M15/H1/H4/D1 EMA50方向 + H4/D1 ATR               |
//+------------------------------------------------------------------+
string BuildHTFSnapshot()
{
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   string sym = Symbol();

   double m15_ema1 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 1);
   double m15_ema2 = GetMAValue(sym, PERIOD_M15, 50, MODE_EMA, PRICE_CLOSE, 2);
   string m15_dir = (m15_ema1 == EMPTY_VALUE || m15_ema2 == EMPTY_VALUE) ? "" :
                    (m15_ema1 > m15_ema2) ? "LONG" : (m15_ema1 < m15_ema2) ? "SHORT" : "FLAT";

   double h1_ema1 = GetMAValue(sym, PERIOD_H1, 50, MODE_EMA, PRICE_CLOSE, 1);
   double h1_ema2 = GetMAValue(sym, PERIOD_H1, 50, MODE_EMA, PRICE_CLOSE, 2);
   string h1_dir = (h1_ema1 == EMPTY_VALUE || h1_ema2 == EMPTY_VALUE) ? "" :
                   (h1_ema1 > h1_ema2) ? "LONG" : (h1_ema1 < h1_ema2) ? "SHORT" : "FLAT";

   double h4_ema1 = GetMAValue(sym, PERIOD_H4, 50, MODE_EMA, PRICE_CLOSE, 1);
   double h4_ema2 = GetMAValue(sym, PERIOD_H4, 50, MODE_EMA, PRICE_CLOSE, 2);
   string h4_dir = (h4_ema1 == EMPTY_VALUE || h4_ema2 == EMPTY_VALUE) ? "" :
                   (h4_ema1 > h4_ema2) ? "LONG" : (h4_ema1 < h4_ema2) ? "SHORT" : "FLAT";

   double d1_ema1 = GetMAValue(sym, PERIOD_D1, 50, MODE_EMA, PRICE_CLOSE, 1);
   double d1_ema2 = GetMAValue(sym, PERIOD_D1, 50, MODE_EMA, PRICE_CLOSE, 2);
   string d1_dir = (d1_ema1 == EMPTY_VALUE || d1_ema2 == EMPTY_VALUE) ? "" :
                   (d1_ema1 > d1_ema2) ? "LONG" : (d1_ema1 < d1_ema2) ? "SHORT" : "FLAT";

   double h4_atr = GetATRValue(sym, PERIOD_H4, 14, 1);
   double d1_atr = GetATRValue(sym, PERIOD_D1, 14, 1);

   return ((m15_ema1 != EMPTY_VALUE) ? DoubleToString(m15_ema1, digits) : "") + "\t" + m15_dir + "\t" +
          ((h1_ema1 != EMPTY_VALUE) ? DoubleToString(h1_ema1, digits) : "") + "\t" + h1_dir + "\t" +
          ((h4_ema1 != EMPTY_VALUE) ? DoubleToString(h4_ema1, digits) : "") + "\t" + h4_dir + "\t" +
          ((d1_ema1 != EMPTY_VALUE) ? DoubleToString(d1_ema1, digits) : "") + "\t" + d1_dir + "\t" +
          ((h4_atr != EMPTY_VALUE) ? DoubleToString(h4_atr, digits) : "") + "\t" +
          ((d1_atr != EMPTY_VALUE) ? DoubleToString(d1_atr, digits) : "");
}

void WriteLog(ENUM_LOG_EVENT event,
              string result = "",
              string rejectReason = "",
              string extra = "",
              double slippagePts = 0.0,
              double fillDeviationPts = 0.0)
{
   if(LogLevel == LOG_LEVEL_OFF)
      return;

   if(LogLevel == LOG_LEVEL_NORMAL)
   {
      if(event != LOG_STATE && event != LOG_ENTRY && event != LOG_EXIT &&
         event != LOG_POSITION)
         return;
   }

   if(event == LOG_STATE && !LogStateTransitions) return;
   if(event == LOG_IMPULSE && !LogImpulseEvents) return;
   if(event == LOG_TOUCH && !LogTouchEvents) return;
   if(event == LOG_CONFIRM && !LogConfirmEvents) return;
   if((event == LOG_ENTRY || event == LOG_EXIT) && !LogEntryExit) return;
   if(event == LOG_REJECT && !LogRejectReason) return;

   if(g_logFileHandle == INVALID_HANDLE)
      return;

   double currentSpread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * Point();

   double bandLower = g_primaryBandLower;
   double bandUpper = g_primaryBandUpper;
   if(g_touch2BandId == 2) { bandLower = g_optBand38Lower; bandUpper = g_optBand38Upper; }

   int totalTouches = g_touchCount_Primary;
   if(g_touch2BandId == 2) totalTouches = g_touchCount_Opt38;

   double atrVal = GetATR_M1(0);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\t" +
                 Symbol() + "\t" +
                 "FX" + "\t" +
                 StateToString(g_currentState) + "\t" +
                 g_tradeUUID + "\t" +
                 LogEventToString(event) + "\t" +
                 (g_startAdjusted ? "true" : "false") + "\t" +
                 DoubleToString(atrVal, digits) + "\t" +
                 DoubleToString(g_impulseStart, digits) + "\t" +
                 DoubleToString(g_impulseEnd, digits) + "\t" +
                 DoubleToString(bandLower, digits) + "\t" +
                 DoubleToString(bandUpper, digits) + "\t" +
                 IntegerToString(totalTouches) + "\t" +
                 IntegerToString(g_freezeCancelCount) + "\t" +
                 ConfirmTypeToString(g_confirmType) + "\t" +
                 EntryTypeToString(g_entryType) + "\t" +
                 DoubleToString(g_entryPrice, digits) + "\t" +
                 DoubleToString(g_sl, digits) + "\t" +
                 DoubleToString(g_tp, digits) + "\t" +
                 DoubleToString(currentSpread / Point(), 1) + "\t" +
                 DoubleToString(slippagePts, 1) + "\t" +
                 DoubleToString(fillDeviationPts, 1) + "\t" +
                 result + "\t" +
                 rejectReason + "\t" +
                 extra + "\t" +
                 BuildHTFSnapshot();

   FileWriteString(g_logFileHandle, line + "\n");
   FileFlush(g_logFileHandle);
}

string GenerateTradeUUID()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string ts = StringFormat("%04d%02d%02d%02d%02d%02d",
                            dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   string runStr = StringFormat("%02d", g_autoRunId);
   return ts + "_" + runStr;
}

//+------------------------------------------------------------------+
//| MA Confluence 解析（ログ専用、ロジック非関与）                        |
//+------------------------------------------------------------------+

// FX: MA期間 = {5, 13, 21, 100, 200}
void InitMAPeriods()
{
   g_maPeriodsCount = 5;
   ArrayResize(g_maPeriods, 5);
   g_maPeriods[0] = 5;
   g_maPeriods[1] = 13;
   g_maPeriods[2] = 21;
   g_maPeriods[3] = 100;
   g_maPeriods[4] = 200;
}

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

void EvaluateMAConfluence()
{
   if(LogLevel != LOG_LEVEL_ANALYZE || !LogMAConfluence)
      return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   double evalPrice = iClose(Symbol(), PERIOD_M1, 1);
   g_stats.MA_Eval_Price = evalPrice;
   g_stats.MA_Evaluated = true;

   double bandUpper = g_primaryBandUpper;
   double bandLower = g_primaryBandLower;

   double bandCenter = (bandUpper + bandLower) / 2.0;
   double bandWidth  = g_effectiveBandWidthPts;
   double nearRange  = bandWidth * 1.0;

   double tightPts = g_spreadBasePts * SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 2.0;

   double fib0   = g_impulseStart;
   double fib100 = g_impulseEnd;
   double fibRange = MathAbs(fib100 - fib0);

   int    confluenceCount = 0;
   int    tightHitCount   = 0;
   string inBandList      = "";
   string inBandFibPct    = "";
   string tightHitList    = "";
   string nearBandList    = "";
   string maValues        = "";
   double nearestDist     = 999999.0;

   double shortMAvals[];
   double longMAvals[];
   ArrayResize(shortMAvals, 0);
   ArrayResize(longMAvals, 0);

   for(int i = 0; i < g_maPeriodsCount; i++)
   {
      double maVal = GetSMAValue(i, 1);
      if(maVal <= 0) continue;

      int period = g_maPeriods[i];

      if(maValues != "") maValues += ";";
      maValues += IntegerToString(period) + "=" + DoubleToString(maVal, digits);

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

      double distFromCenter = maVal - bandCenter;
      if(g_impulseDir == DIR_SHORT)
         distFromCenter = -distFromCenter;

      if(MathAbs(maVal - bandCenter) < MathAbs(nearestDist))
         nearestDist = distFromCenter;

      bool inBand = (maVal >= bandLower && maVal <= bandUpper);
      bool tightHit = (MathAbs(maVal - evalPrice) <= tightPts);

      if(inBand)
      {
         confluenceCount++;
         if(inBandList != "") inBandList += ",";
         inBandList += IntegerToString(period);

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

   int dirAligned = -1;
   if(ArraySize(shortMAvals) > 0 && ArraySize(longMAvals) > 0)
   {
      ArraySort(shortMAvals);
      ArraySort(longMAvals);
      double shortMed = shortMAvals[ArraySize(shortMAvals) / 2];
      double longMed  = longMAvals[ArraySize(longMAvals) / 2];

      if(g_impulseDir == DIR_LONG)
         dirAligned = (shortMed > longMed) ? 1 : 0;
      else if(g_impulseDir == DIR_SHORT)
         dirAligned = (shortMed < longMed) ? 1 : 0;
   }

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
