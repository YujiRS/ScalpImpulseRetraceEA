//+------------------------------------------------------------------+
//| Logger.mqh - RoleReversalEA                                      |
//| ファイルログ出力                                                    |
//+------------------------------------------------------------------+
#ifndef __RR_LOGGER_MQH__
#define __RR_LOGGER_MQH__

#define RR_EA_NAME "RoleReversalEA"

//--- ログイベント種別
enum ENUM_RR_LOG_EVENT
{
   RR_LOG_STATE,         // ステート遷移
   RR_LOG_BREAKOUT,      // ブレイクアウト検出/確認
   RR_LOG_PULLBACK,      // プルバック到達
   RR_LOG_ENTRY,         // エントリー
   RR_LOG_EXIT,          // エグジット（SL/TP/外部決済）
   RR_LOG_REJECT,        // リジェクト（条件不成立）
   RR_LOG_SR_REFRESH,    // S/Rリフレッシュ
};

string RRLogEventToString(ENUM_RR_LOG_EVENT ev)
{
   switch(ev)
   {
      case RR_LOG_STATE:      return "STATE";
      case RR_LOG_BREAKOUT:   return "BREAKOUT";
      case RR_LOG_PULLBACK:   return "PULLBACK";
      case RR_LOG_ENTRY:      return "ENTRY";
      case RR_LOG_EXIT:       return "EXIT";
      case RR_LOG_REJECT:     return "REJECT";
      case RR_LOG_SR_REFRESH: return "SR_REFRESH";
      default:                return "UNKNOWN";
   }
}

string RRStateToString(ENUM_RR_STATE st)
{
   switch(st)
   {
      case RR_IDLE:               return "IDLE";
      case RR_BREAKOUT_DETECTED:  return "BREAKOUT_DETECTED";
      case RR_BREAKOUT_CONFIRMED: return "BREAKOUT_CONFIRMED";
      case RR_WAITING_PULLBACK:   return "WAITING_PULLBACK";
      case RR_PULLBACK_AT_LEVEL:  return "PULLBACK_AT_LEVEL";
      case RR_ENTRY_READY:        return "ENTRY_READY";
      case RR_IN_POSITION:        return "IN_POSITION";
      case RR_COOLDOWN:           return "COOLDOWN";
      default:                    return "UNKNOWN";
   }
}

//--- グローバル変数
string g_rrLogFileName = "";
int    g_rrLogFileHandle = INVALID_HANDLE;

string RR_BuildLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
   return RR_EA_NAME + "_" + dateStr + "_" + Symbol() + "_M" + IntegerToString(MagicOffset) + ".tsv";
}

void RR_LoggerInit()
{
   if(LogLevel == RR_LOG_NORMAL)  // RR_LOG_NORMAL==0 はログなし扱い（Print()のみ）
      return;

   g_rrLogFileName = RR_BuildLogFileName();
   bool exists = FileIsExist(g_rrLogFileName);

   g_rrLogFileHandle = FileOpen(g_rrLogFileName,
      FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, '\t');

   if(g_rrLogFileHandle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open log file: ", g_rrLogFileName);
      return;
   }

   if(exists)
   {
      FileSeek(g_rrLogFileHandle, 0, SEEK_END);
   }
   else
   {
      string header = "Time\tSymbol\tState\tEvent\tDirection\t"
                      "SRLevel\tPrice\tSL\tTP\tPattern\tDetail";
      FileWriteString(g_rrLogFileHandle, header + "\n");
      FileFlush(g_rrLogFileHandle);
   }
}

void RR_LoggerDeinit()
{
   if(g_rrLogFileHandle != INVALID_HANDLE)
   {
      FileClose(g_rrLogFileHandle);
      g_rrLogFileHandle = INVALID_HANDLE;
   }
}

//--- 日付変更時のファイルローテーション
void RR_LoggerCheckRotate()
{
   if(g_rrLogFileHandle == INVALID_HANDLE && LogLevel > RR_LOG_NORMAL)
   {
      // ログが有効なのにハンドルが無い → 初回 or ローテーション
      RR_LoggerInit();
      return;
   }

   string newName = RR_BuildLogFileName();
   if(newName != g_rrLogFileName)
   {
      RR_LoggerDeinit();
      RR_LoggerInit();
   }
}

void RR_WriteLog(ENUM_RR_LOG_EVENT event,
                 int direction = 0,
                 double srLevel = 0.0,
                 double price = 0.0,
                 double sl = 0.0,
                 double tp = 0.0,
                 string pattern = "",
                 string detail = "")
{
   if(LogLevel < RR_LOG_DEBUG)
      return;

   // NORMAL(0)はPrint()のみ。DEBUG(1)以上でファイル出力
   if(g_rrLogFileHandle == INVALID_HANDLE)
      return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   string dirStr = "";
   if(direction == RR_DIR_LONG)  dirStr = "LONG";
   else if(direction == RR_DIR_SHORT) dirStr = "SHORT";

   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\t" +
                 Symbol() + "\t" +
                 RRStateToString(g_state) + "\t" +
                 RRLogEventToString(event) + "\t" +
                 dirStr + "\t" +
                 (srLevel > 0 ? DoubleToString(srLevel, digits) : "") + "\t" +
                 (price > 0 ? DoubleToString(price, digits) : "") + "\t" +
                 (sl > 0 ? DoubleToString(sl, digits) : "") + "\t" +
                 (tp > 0 ? DoubleToString(tp, digits) : "") + "\t" +
                 pattern + "\t" +
                 detail;

   FileWriteString(g_rrLogFileHandle, line + "\n");
   FileFlush(g_rrLogFileHandle);
}

#endif // __RR_LOGGER_MQH__
