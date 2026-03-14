//+------------------------------------------------------------------+
//| Logger.mqh - RoleReversalEA                                      |
//| ファイルログ出力（解析用拡張版）                                       |
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
int    g_rrAutoInstanceId = 1;
int    g_rrLockFileHandle = INVALID_HANDLE;

// Trade Summary ログ
string g_rrTradeLogFileName = "";
int    g_rrTradeLogHandle = INVALID_HANDLE;

string RR_BuildLogDateStr()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

void RR_AcquireLogSlot()
{
   string dateStr = RR_BuildLogDateStr();
   for(int i = 1; i <= 10; i++)
   {
      string lockName = RR_EA_NAME + "_" + dateStr + "_" + Symbol() + "_M" + IntegerToString(i) + ".lock";
      int h = FileOpen(lockName, FILE_WRITE | FILE_TXT);
      if(h != INVALID_HANDLE)
      {
         g_rrLockFileHandle = h;
         g_rrAutoInstanceId = i;
         return;
      }
   }
   g_rrAutoInstanceId = 1;
}

void RR_ReleaseLogSlot()
{
   if(g_rrLockFileHandle != INVALID_HANDLE)
   {
      FileClose(g_rrLockFileHandle);
      g_rrLockFileHandle = INVALID_HANDLE;
   }
}

string RR_BuildLogFileName()
{
   string dateStr = RR_BuildLogDateStr();
   return RR_EA_NAME + "_" + dateStr + "_" + Symbol() + "_M" + IntegerToString(g_rrAutoInstanceId) + ".tsv";
}

string RR_BuildTradeLogFileName()
{
   string dateStr = RR_BuildLogDateStr();
   return RR_EA_NAME + "_TRADE_" + dateStr + "_" + Symbol() + "_M" + IntegerToString(g_rrAutoInstanceId) + ".tsv";
}

//+------------------------------------------------------------------+
//| HTF ヘルパー: EMA/ATR 取得（オンデマンド生成・即解放）                  |
//+------------------------------------------------------------------+
double RR_GetMAValue(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iMA(Symbol(), tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return EMPTY_VALUE;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, shift, 1, buf) != 1) { IndicatorRelease(h); return EMPTY_VALUE; }
   double val = buf[0];
   IndicatorRelease(h);
   return val;
}

double RR_GetATRValue(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(Symbol(), tf, period);
   if(h == INVALID_HANDLE) return EMPTY_VALUE;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, shift, 1, buf) != 1) { IndicatorRelease(h); return EMPTY_VALUE; }
   double val = buf[0];
   IndicatorRelease(h);
   return val;
}

string RR_GetEMADir(ENUM_TIMEFRAMES tf, int period)
{
   double ema1 = RR_GetMAValue(tf, period, 1);
   double ema2 = RR_GetMAValue(tf, period, 2);
   if(ema1 == EMPTY_VALUE || ema2 == EMPTY_VALUE) return "";
   if(ema1 > ema2) return "LONG";
   if(ema1 < ema2) return "SHORT";
   return "FLAT";
}

// M5 ATR取得（既存 g_atrM5Handle を使用）
double RR_GetATR_M5(int shift)
{
   if(g_atrM5Handle == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrM5Handle, 0, shift, 1, buf) <= 0) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| イベントログ初期化                                                  |
//+------------------------------------------------------------------+
void RR_LoggerInit()
{
   if(LogLevel == RR_LOG_NORMAL)  // RR_LOG_NORMAL==0 はログなし扱い（Print()のみ）
      return;

   RR_AcquireLogSlot();
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
                      "SRLevel\tPrice\tSL\tTP\tPattern\tDetail\t"
                      "SpreadPts\tATR_M5\tLot\tRR\t"
                      "M15_EMA50_Dir\tH1_EMA50_Dir\t"
                      "H4_EMA50_Dir\tD1_EMA50_Dir\tH4_ATR14\tD1_ATR14";
      FileWriteString(g_rrLogFileHandle, header + "\n");
      FileFlush(g_rrLogFileHandle);
   }

   // ANALYZE モードではトレードサマリーログも初期化
   if(LogLevel >= RR_LOG_ANALYZE)
   {
      g_rrTradeLogFileName = RR_BuildTradeLogFileName();
      bool tradeExists = FileIsExist(g_rrTradeLogFileName);

      g_rrTradeLogHandle = FileOpen(g_rrTradeLogFileName,
         FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, '\t');

      if(g_rrTradeLogHandle != INVALID_HANDLE && !tradeExists)
      {
         string tradeHeader = "EntryTime\tExitTime\tSymbol\tDirection\t"
                              "SRLevel\tEntryPrice\tExitPrice\tLot\t"
                              "SL\tTP\tProfitPts\tProfitMoney\tRR\t"
                              "Pattern\tExitReason\t"
                              "SpreadEntry\tATR_M5_Entry\t"
                              "M15_EMA50_Dir\tH1_EMA50_Dir\t"
                              "H4_EMA50_Dir\tD1_EMA50_Dir\tH4_ATR14\tD1_ATR14";
         FileWriteString(g_rrTradeLogHandle, tradeHeader + "\n");
         FileFlush(g_rrTradeLogHandle);
      }
      else if(g_rrTradeLogHandle != INVALID_HANDLE)
      {
         FileSeek(g_rrTradeLogHandle, 0, SEEK_END);
      }
   }
}

void RR_LoggerDeinit()
{
   if(g_rrLogFileHandle != INVALID_HANDLE)
   {
      FileClose(g_rrLogFileHandle);
      g_rrLogFileHandle = INVALID_HANDLE;
   }
   if(g_rrTradeLogHandle != INVALID_HANDLE)
   {
      FileClose(g_rrTradeLogHandle);
      g_rrTradeLogHandle = INVALID_HANDLE;
   }
   RR_ReleaseLogSlot();
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

   string newDateStr = RR_BuildLogDateStr();
   string currentDateStr = "";
   if(g_rrLogFileName != "")
   {
      // 現在のファイル名から日付部分を抽出して比較
      int datePos = StringFind(g_rrLogFileName, "_") + 1;
      currentDateStr = StringSubstr(g_rrLogFileName, datePos, 8);
   }
   if(newDateStr != currentDateStr)
   {
      RR_LoggerDeinit();  // ログ+ロック両方解放
      RR_LoggerInit();    // ロック再取得+ログ再オープン
   }
}

//+------------------------------------------------------------------+
//| イベントログ出力（拡張版）                                           |
//+------------------------------------------------------------------+
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

   // スプレッド・ATR・ロット取得
   double spreadPts = (double)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   double atrM5 = RR_GetATR_M5(1);

   // ロット（ポジション保有時のみ）
   double lot = 0;
   if(g_posTicket > 0 && PositionSelectByTicket(g_posTicket))
      lot = PositionGetDouble(POSITION_VOLUME);

   // R:R 計算
   string rrStr = "";
   if(sl > 0 && tp > 0 && price > 0)
   {
      double slDist = MathAbs(price - sl);
      double tpDist = MathAbs(tp - price);
      if(slDist > 0)
         rrStr = DoubleToString(tpDist / slDist, 2);
   }

   // HTF方向
   string m15Dir = RR_GetEMADir(PERIOD_M15, 50);
   string h1Dir  = RR_GetEMADir(PERIOD_H1, 50);
   string h4Dir  = RR_GetEMADir(PERIOD_H4, 50);
   string d1Dir  = RR_GetEMADir(PERIOD_D1, 50);
   double h4Atr  = RR_GetATRValue(PERIOD_H4, 14, 1);
   double d1Atr  = RR_GetATRValue(PERIOD_D1, 14, 1);

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
                 detail + "\t" +
                 DoubleToString(spreadPts, 0) + "\t" +
                 DoubleToString(atrM5, digits) + "\t" +
                 (lot > 0 ? DoubleToString(lot, 2) : "") + "\t" +
                 rrStr + "\t" +
                 m15Dir + "\t" + h1Dir + "\t" +
                 h4Dir + "\t" + d1Dir + "\t" +
                 ((h4Atr != EMPTY_VALUE) ? DoubleToString(h4Atr, digits) : "") + "\t" +
                 ((d1Atr != EMPTY_VALUE) ? DoubleToString(d1Atr, digits) : "");

   FileWriteString(g_rrLogFileHandle, line + "\n");
   FileFlush(g_rrLogFileHandle);
}

//+------------------------------------------------------------------+
//| Trade Summary ログ（ANALYZE モード・1トレード=1行）                   |
//+------------------------------------------------------------------+
void RR_WriteTradeLog(datetime entryTime, datetime exitTime,
                      int direction, double srLevel,
                      double entryPrice, double exitPrice, double lot,
                      double sl, double tp,
                      double profitPts, double profitMoney,
                      string pattern, string exitReason,
                      double spreadEntry, double atrM5Entry,
                      string m15Dir, string h1Dir,
                      string h4Dir, string d1Dir,
                      double h4Atr, double d1Atr)
{
   if(LogLevel < RR_LOG_ANALYZE || g_rrTradeLogHandle == INVALID_HANDLE)
      return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   string dirStr = (direction == RR_DIR_LONG) ? "LONG" : (direction == RR_DIR_SHORT) ? "SHORT" : "";

   double rr = 0;
   double slDist = MathAbs(entryPrice - sl);
   if(slDist > 0)
      rr = MathAbs(tp - entryPrice) / slDist;

   string line = TimeToString(entryTime, TIME_DATE | TIME_SECONDS) + "\t" +
                 TimeToString(exitTime, TIME_DATE | TIME_SECONDS) + "\t" +
                 Symbol() + "\t" +
                 dirStr + "\t" +
                 DoubleToString(srLevel, digits) + "\t" +
                 DoubleToString(entryPrice, digits) + "\t" +
                 DoubleToString(exitPrice, digits) + "\t" +
                 DoubleToString(lot, 2) + "\t" +
                 DoubleToString(sl, digits) + "\t" +
                 DoubleToString(tp, digits) + "\t" +
                 DoubleToString(profitPts, 1) + "\t" +
                 DoubleToString(profitMoney, 2) + "\t" +
                 DoubleToString(rr, 2) + "\t" +
                 pattern + "\t" +
                 exitReason + "\t" +
                 DoubleToString(spreadEntry, 0) + "\t" +
                 DoubleToString(atrM5Entry, digits) + "\t" +
                 m15Dir + "\t" + h1Dir + "\t" +
                 h4Dir + "\t" + d1Dir + "\t" +
                 DoubleToString(h4Atr, digits) + "\t" +
                 DoubleToString(d1Atr, digits);

   FileWriteString(g_rrTradeLogHandle, line + "\n");
   FileFlush(g_rrTradeLogHandle);
}

#endif // __RR_LOGGER_MQH__
