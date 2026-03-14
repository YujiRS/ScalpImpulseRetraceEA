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
         "StructBreakSide", "StructBreakAtKind", "StructBreakWickCross", "StructBreakWickDistPts",

         // TrendFilter / ReversalGuard
         "TrendFilterEnable", "TrendTF", "TrendMethod", "TrendDir",
         "TrendSlope", "TrendSlopeMin", "TrendAligned",
         "ReversalGuardEnable", "ReversalTF", "ReversalGuardTriggered", "ReversalReason",

         // EMA Cross (CRYPTO: EMA21 vs EMA50)
         "EMACrossFilterEnable", "EMACrossFastVal", "EMACrossSlowVal",
         "EMACrossDir", "EMACrossAligned",

         // FlatFilter
         "FlatFilterMode", "FlatBreakoutDir", "FlatMatchResult",
         "FlatDuration", "FlatBarsSince",
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
      g_stats.StructBreakAtKind,
      g_stats.StructBreakWickCross,
      g_stats.StructBreakWickDistPts,

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
      g_stats.FlatFilterMode,
      g_stats.FlatBreakoutDir,
      g_stats.FlatMatchResult,
      g_stats.FlatDuration,
      g_stats.FlatBarsSince,

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
                 extra + "\t" +
                 BuildHTFSnapshot();

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
   return ts + "_" + runStr;
}

#endif // __LOGGER_MQH__
