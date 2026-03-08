//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| ログ出力・TradeUUID                                                 |
//| CRYPTO専用                                                         |
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

// ImpulseSummary TSV出力
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

         // STRUCTURE_BREAK
         "StructBreakReason", "StructBreakPriority", "StructBreakRefLevel",
         "StructBreakRefPrice", "StructBreakAtPrice", "StructBreakDistPts", "StructBreakBarShift",
         "StructBreakSide",

         // TrendFilter / ReversalGuard
         "TrendFilterEnable", "TrendTF", "TrendMethod", "TrendDir",
         "TrendSlope", "TrendSlopeMin", "TrendAligned",
         "ReversalGuardEnable", "ReversalTF", "ReversalGuardTriggered", "ReversalReason",

         // EMA Cross (CRYPTO: EMA21 vs EMA50)
         "EMACrossFilterEnable", "EMACrossFastVal", "EMACrossSlowVal",
         "EMACrossDir", "EMACrossAligned",

         // FlatFilter
         "FlatFilterEnable", "FlatBreakoutDir", "FlatMatchResult",
         "FlatDuration", "FlatBarsSince"
      );
   }

   FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
      TimeToString(g_stats.StartTime, TIME_DATE|TIME_SECONDS),
      Symbol(),
      "CRYPTO",
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

      // STRUCTURE_BREAK
      g_stats.StructBreakReason,
      g_stats.StructBreakPriority,
      g_stats.StructBreakRefLevel,
      g_stats.StructBreakRefPrice,
      g_stats.StructBreakAtPrice,
      g_stats.StructBreakDistPts,
      g_stats.StructBreakBarShift,
      g_stats.StructBreakSide,

      // TrendFilter / ReversalGuard
      (g_stats.TrendFilterEnable>=0) ? IntegerToString(g_stats.TrendFilterEnable) : "",
      g_stats.TrendTF,
      g_stats.TrendMethod,
      g_stats.TrendDir,
      g_stats.TrendSlope,
      g_stats.TrendSlopeMin,
      (g_stats.TrendAligned>=0) ? IntegerToString(g_stats.TrendAligned) : "",
      (g_stats.ReversalGuardEnable>=0) ? IntegerToString(g_stats.ReversalGuardEnable) : "",
      g_stats.ReversalTF,
      (g_stats.ReversalGuardTriggered>=0) ? IntegerToString(g_stats.ReversalGuardTriggered) : "",
      g_stats.ReversalReason,

      // EMA Cross
      (g_stats.EMACrossFilterEnable>=0) ? IntegerToString(g_stats.EMACrossFilterEnable) : "",
      g_stats.EMACrossFastVal,
      g_stats.EMACrossSlowVal,
      g_stats.EMACrossDir,
      (g_stats.EMACrossAligned>=0) ? IntegerToString(g_stats.EMACrossAligned) : "",

      // FlatFilter
      (g_stats.FlatFilterEnable>=0) ? IntegerToString(g_stats.FlatFilterEnable) : "",
      g_stats.FlatBreakoutDir,
      g_stats.FlatMatchResult,
      g_stats.FlatDuration,
      g_stats.FlatBarsSince
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

   // MA Bounceバンド情報
   double bandLower = g_maBounceMAValue - g_maBounceBandWidth;
   double bandUpper = g_maBounceMAValue + g_maBounceBandWidth;

   int totalTouches = g_stats.ConfirmCount;

   double atrVal = GetATR_M1(0);

   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\t" +
                 Symbol() + "\t" +
                 "CRYPTO" + "\t" +
                 StateToString(g_currentState) + "\t" +
                 g_tradeUUID + "\t" +
                 LogEventToString(event) + "\t" +
                 (g_startAdjusted ? "true" : "false") + "\t" +
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
//| TradeUUID生成                                                      |
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

#endif // __LOGGER_MQH__
