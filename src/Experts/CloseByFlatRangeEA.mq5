//+------------------------------------------------------------------+
//| CloseByFlatRangeEA.mq5                                           |
//| Closes a specific position on MA Flat + Range breakout + ATR trail|
//+------------------------------------------------------------------+
#property copyright "CloseByFlatRangeEA"
#property version   "3.01"
#property strict

#include <Trade\Trade.mqh>

//--- Enumerations
enum ENUM_MARKET_MODE
{
   MM_FX     = 0,   // FX
   MM_GOLD   = 1,   // GOLD
   MM_CRYPTO = 2,   // CRYPTO
   MM_CUSTOM = 3    // Custom (use inputs below)
};

enum ENUM_FLAT_MA_METHOD
{
   FLAT_MA_SMA = 0,   // SMA
   FLAT_MA_EMA = 1    // EMA
};

enum ENUM_FAILSAFE
{
   FS_MARKET_CLOSE = 0,   // Market Close
   FS_NONE         = 1    // None
};

//--- G0: Market Mode
input ENUM_MARKET_MODE   MarketMode            = MM_CUSTOM;       // Market mode preset

//--- G1: Target
input ulong              TargetTicket          = 0;
input ENUM_TIMEFRAMES    SignalTF              = PERIOD_M5;

//--- G2: Flat Detection (used when MarketMode=Custom)
input ENUM_FLAT_MA_METHOD FlatMaMethod         = FLAT_MA_SMA;     // MA method
input int                FlatMaPeriod          = 21;              // MA period
input int                FlatSlopeLookbackBars = 5;               // Slope lookback bars
input int                ATRPeriod             = 14;              // ATR period
input double             FlatSlopeAtrMult      = 0.10;            // Slope/ATR threshold

//--- G3: Range (used when MarketMode=Custom)
input int                RangeLookbackBars     = 10;              // Range lookback bars

//--- G4: Trail
input double             TrailATRMult          = 1.0;             // ATR multiplier for trailing stop

//--- G5: Failsafe (used when MarketMode=Custom)
input int                WaitBarsAfterFlat     = 30;              // Max wait bars after flat (safety valve)
input ENUM_FAILSAFE      FailSafe              = FS_MARKET_CLOSE; // Failsafe action

//--- G6: Startup Filter (used when MarketMode=Custom)
input bool               EnableStartupFilter   = true;            // Startup condition filter
input double             StartProfitATRMult    = 1.0;             // Min profit / ATR multiplier
input int                StartMinBars          = 5;               // Min bars from entry

//--- G7: Label
input bool               ShowPanel             = true;
input int                LabelX                = 10;
input int                LabelY                = 20;
input int                LabelRow              = 0;

//--- G8: Event Log
input bool               EnableEventLog        = true;            // Write event log TSV

//--- State machine
enum EA_STATE
{
   ST_WAIT_POSITION,
   ST_WAIT_FLAT,
   ST_RANGE_LOCKED,
   ST_TRAILING,
   ST_CLOSE_REQUESTED,
   ST_CLOSED,
   ST_ERROR
};

EA_STATE  g_state           = ST_WAIT_POSITION;
string    g_stateInfo       = "";
string    g_posDir          = "";
long      g_posType         = -1;
string    g_closeReason     = "";

//--- Working copies (resolved from MarketMode or inputs)
ENUM_FLAT_MA_METHOD w_flatMaMethod;
int                 w_flatMaPeriod;
int                 w_flatSlopeLookbackBars;
double              w_flatSlopeAtrMult;
int                 w_rangeLookbackBars;
int                 w_waitBarsAfterFlat;
double              w_startProfitATRMult;
int                 w_startMinBars;

int       g_hMA             = INVALID_HANDLE;
int       g_hATR            = INVALID_HANDLE;

datetime  g_lastBar         = 0;

bool      g_rangeLocked     = false;
double    g_rangeHigh       = 0;
double    g_rangeLow        = 0;
double    g_rangeMid        = 0;

int       g_waitBarsCount   = 0;
int       g_goneCount       = 0;
int       g_closeRetry      = 0;
datetime  g_lastCloseTime   = 0;

//--- Trailing
double    g_trailPeak       = 0.0;
double    g_trailLine       = 0.0;

//--- Event log
int       g_logHandle       = INVALID_HANDLE;
string    g_logFileName     = "";
datetime  g_entryTime       = 0;
double    g_entryPrice      = 0.0;
int       g_barsFromEntry   = 0;
int       g_barsFromFlat    = 0;
double    g_flatSlopePts    = 0.0;
double    g_flatATRPts      = 0.0;
double    g_closePrice      = 0.0;
double    g_closePnLPips    = 0.0;

string    g_objPrefix       = "";
CTrade    g_trade;

const int FONT_SIZE         = 9;
const int LINE_HEIGHT       = 20;
const int MAX_LINES         = 10;
const int GONE_THRESHOLD    = 5;
const int CLOSE_MAX_RETRY   = 10;

//+------------------------------------------------------------------+
string MarketModeToString()
{
   switch(MarketMode)
   {
      case MM_FX:     return "FX";
      case MM_GOLD:   return "GOLD";
      case MM_CRYPTO: return "CRYPTO";
      case MM_CUSTOM: return "CUSTOM";
   }
   return "?";
}

//+------------------------------------------------------------------+
void ApplyPreset()
{
   switch(MarketMode)
   {
      case MM_FX:
         w_flatMaMethod         = FLAT_MA_SMA;
         w_flatMaPeriod         = 21;
         w_flatSlopeLookbackBars = 3;
         w_flatSlopeAtrMult     = 0.03;
         w_rangeLookbackBars    = 10;
         w_waitBarsAfterFlat    = 16;
         w_startProfitATRMult   = 0.5;
         w_startMinBars         = 3;
         break;

      case MM_GOLD:
         w_flatMaMethod         = FLAT_MA_EMA;
         w_flatMaPeriod         = 21;
         w_flatSlopeLookbackBars = 3;
         w_flatSlopeAtrMult     = 0.30;
         w_rangeLookbackBars    = 20;
         w_waitBarsAfterFlat    = 30;
         w_startProfitATRMult   = 0.8;
         w_startMinBars         = 4;
         break;

      case MM_CRYPTO:
         w_flatMaMethod         = FLAT_MA_EMA;
         w_flatMaPeriod         = 13;
         w_flatSlopeLookbackBars = 8;
         w_flatSlopeAtrMult     = 0.03;
         w_rangeLookbackBars    = 20;
         w_waitBarsAfterFlat    = 40;
         w_startProfitATRMult   = 1.0;
         w_startMinBars         = 5;
         break;

      case MM_CUSTOM:
      default:
         w_flatMaMethod         = FlatMaMethod;
         w_flatMaPeriod         = FlatMaPeriod;
         w_flatSlopeLookbackBars = FlatSlopeLookbackBars;
         w_flatSlopeAtrMult     = FlatSlopeAtrMult;
         w_rangeLookbackBars    = RangeLookbackBars;
         w_waitBarsAfterFlat    = WaitBarsAfterFlat;
         w_startProfitATRMult   = StartProfitATRMult;
         w_startMinBars         = StartMinBars;
         break;
   }

   Print("[CloseByFlatRangeEA] MarketMode=", MarketModeToString(),
         " MA=", (w_flatMaMethod == FLAT_MA_EMA ? "EMA" : "SMA"),
         "(", w_flatMaPeriod, ")",
         " SlopeLB=", w_flatSlopeLookbackBars,
         " Mult=", DoubleToString(w_flatSlopeAtrMult, 2),
         " RangeLB=", w_rangeLookbackBars,
         " WaitBars=", w_waitBarsAfterFlat,
         " TrailATR=", DoubleToString(TrailATRMult, 2),
         " StartFilter=", (EnableStartupFilter ? "ON" : "OFF"),
         " ProfitATR=", DoubleToString(w_startProfitATRMult, 2),
         " MinBars=", w_startMinBars);
}

//+------------------------------------------------------------------+
string StateToString(EA_STATE s)
{
   switch(s)
   {
      case ST_WAIT_POSITION:  return "WAIT_POSITION";
      case ST_WAIT_FLAT:      return "WAIT_FLAT";
      case ST_RANGE_LOCKED:   return "RANGE_LOCKED";
      case ST_TRAILING:       return "TRAILING";
      case ST_CLOSE_REQUESTED: return "CLOSE_REQUESTED";
      case ST_CLOSED:         return "CLOSED";
      case ST_ERROR:          return "ERROR";
   }
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
void SetState(EA_STATE s, string info="")
{
   EA_STATE prev = g_state;
   g_state = s;
   g_stateInfo = info;
   Print("[CloseByFlatRangeEA] State -> ", StateToString(s),
         (info != "" ? " | " + info : ""),
         " | Ticket=", TargetTicket);

   // Write CLOSE event when transitioning to ST_CLOSED
   if(s == ST_CLOSED && prev != ST_CLOSED)
      WriteEventLog("CLOSE", g_closeReason);

   // State persistence
   if(s >= ST_RANGE_LOCKED && s <= ST_TRAILING)
      SaveState();
   else if(s == ST_CLOSED || s == ST_ERROR)
      ClearSavedState();

   UpdatePanel();
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, SignalTF, 0);
   if(t == 0) return false;
   if(t != g_lastBar)
   {
      g_lastBar = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool PositionExists()
{
   return PositionSelectByTicket(TargetTicket);
}

//+------------------------------------------------------------------+
bool CheckPositionAlive()
{
   if(PositionExists())
   {
      if(g_goneCount > 0)
      {
         Print("[CloseByFlatRangeEA] Position found again after ", g_goneCount, " miss(es)");
         g_goneCount = 0;
      }
      return true;
   }

   g_goneCount++;
   if(g_goneCount >= GONE_THRESHOLD)
   {
      CaptureClosePrice();  // will be 0 if position already gone
      g_closeReason = "PositionGone";
      SetState(ST_CLOSED, "Position gone (" + (string)GONE_THRESHOLD + " consecutive checks)");
      return false;
   }

   Print("[CloseByFlatRangeEA] Position not found (", g_goneCount, "/", GONE_THRESHOLD, ")");
   return true;
}

//+------------------------------------------------------------------+
bool CheckFlat()
{
   // Bar guard
   int barsNeeded = w_flatSlopeLookbackBars + 2;
   if(Bars(_Symbol, SignalTF) < barsNeeded) return false;

   // MA[1] (most recent confirmed bar)
   double maCurr[1];
   if(CopyBuffer(g_hMA, 0, 1, 1, maCurr) < 1) return false;

   // MA[1 + FlatSlopeLookbackBars]
   double maOld[1];
   if(CopyBuffer(g_hMA, 0, 1 + w_flatSlopeLookbackBars, 1, maOld) < 1) return false;

   double slopePts = MathAbs(maCurr[0] - maOld[0]) / _Point;

   // ATR[1]
   double atrBuf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) < 1) return false;

   double atrPts = atrBuf[0] / _Point;
   if(atrPts <= 0) return false;

   bool flat = (slopePts <= atrPts * w_flatSlopeAtrMult);

   if(flat)
   {
      // Cache for event log
      g_flatSlopePts = slopePts;
      g_flatATRPts   = atrPts;

      Print("[CloseByFlatRangeEA] Flat detected: SlopePts=", DoubleToString(slopePts, 1),
            " ATRPts=", DoubleToString(atrPts, 1),
            " Threshold=", DoubleToString(atrPts * w_flatSlopeAtrMult, 1));
   }

   return flat;
}

//+------------------------------------------------------------------+
bool LockRange()
{
   if(Bars(_Symbol, SignalTF) < w_rangeLookbackBars + 1) return false;

   double highBuf[];
   double lowBuf[];
   ArrayResize(highBuf, w_rangeLookbackBars);
   ArrayResize(lowBuf, w_rangeLookbackBars);

   if(CopyHigh(_Symbol, SignalTF, 1, w_rangeLookbackBars, highBuf) < w_rangeLookbackBars) return false;
   if(CopyLow(_Symbol, SignalTF, 1, w_rangeLookbackBars, lowBuf) < w_rangeLookbackBars) return false;

   g_rangeHigh = highBuf[ArrayMaximum(highBuf)];
   g_rangeLow  = lowBuf[ArrayMinimum(lowBuf)];
   g_rangeMid  = (g_rangeHigh + g_rangeLow) / 2.0;
   g_rangeLocked = true;

   Print("[CloseByFlatRangeEA] Range locked: High=", DoubleToString(g_rangeHigh, _Digits),
         " Low=", DoubleToString(g_rangeLow, _Digits),
         " Mid=", DoubleToString(g_rangeMid, _Digits));

   return true;
}

//+------------------------------------------------------------------+
// Returns: 0 = no breakout, 1 = favorable, -1 = unfavorable
int CheckBreakout()
{
   double closeBuf[1];
   if(CopyClose(_Symbol, SignalTF, 1, 1, closeBuf) < 1) return 0;
   double closePrice = closeBuf[0];

   if(g_posType == POSITION_TYPE_BUY)
   {
      if(closePrice < g_rangeLow)  return -1;  // unfavorable
      if(closePrice > g_rangeHigh) return  1;  // favorable
   }
   else // SELL
   {
      if(closePrice > g_rangeHigh) return -1;  // unfavorable
      if(closePrice < g_rangeLow)  return  1;  // favorable
   }
   return 0; // still in range
}

//+------------------------------------------------------------------+
// Returns true if trailing stop is hit (close signal)
bool UpdateTrailing()
{
   // Get confirmed bar High, Low, Close
   double highBuf[1], lowBuf[1], closeBuf[1];
   if(CopyHigh(_Symbol, SignalTF, 1, 1, highBuf) < 1) return false;
   if(CopyLow(_Symbol, SignalTF, 1, 1, lowBuf) < 1) return false;
   if(CopyClose(_Symbol, SignalTF, 1, 1, closeBuf) < 1) return false;

   // Get ATR[1]
   double atrBuf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) < 1) return false;
   if(atrBuf[0] <= 0) return false;

   double closePrice = closeBuf[0];

   if(g_posType == POSITION_TYPE_BUY)
   {
      // Update peak (highest High since favorable breakout)
      if(highBuf[0] > g_trailPeak)
         g_trailPeak = highBuf[0];

      // Trailing line = peak - ATR * mult
      g_trailLine = g_trailPeak - atrBuf[0] * TrailATRMult;

      // Exit when confirmed bar close crosses below trailing line
      if(closePrice < g_trailLine)
      {
         Print("[CloseByFlatRangeEA] TrailStop hit: Close=", DoubleToString(closePrice, _Digits),
               " < TrailLine=", DoubleToString(g_trailLine, _Digits),
               " Peak=", DoubleToString(g_trailPeak, _Digits));
         return true;
      }
   }
   else // SELL
   {
      // Update peak (lowest Low since favorable breakout)
      if(lowBuf[0] < g_trailPeak)
         g_trailPeak = lowBuf[0];

      // Trailing line = peak + ATR * mult
      g_trailLine = g_trailPeak + atrBuf[0] * TrailATRMult;

      // Exit when confirmed bar close crosses above trailing line
      if(closePrice > g_trailLine)
      {
         Print("[CloseByFlatRangeEA] TrailStop hit: Close=", DoubleToString(closePrice, _Digits),
               " > TrailLine=", DoubleToString(g_trailLine, _Digits),
               " Peak=", DoubleToString(g_trailPeak, _Digits));
         return true;
      }
   }

   return false;  // keep trailing
}

//+------------------------------------------------------------------+
void CaptureClosePrice()
{
   g_closePrice = 0.0;
   g_closePnLPips = 0.0;

   if(PositionSelectByTicket(TargetTicket))
   {
      g_closePrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(g_posType == POSITION_TYPE_BUY)
         g_closePnLPips = (g_closePrice - g_entryPrice) / _Point;
      else
         g_closePnLPips = (g_entryPrice - g_closePrice) / _Point;
   }
}

//+------------------------------------------------------------------+
void ExecuteClose(string reason)
{
   g_closeReason = reason;
   g_closeRetry = 0;
   g_goneCount = 0;

   if(!PositionExists())
   {
      CaptureClosePrice();  // will be 0 if position already gone
      SetState(ST_CLOSED, "Position gone before close: " + reason);
      return;
   }

   // Capture close price before attempting close
   CaptureClosePrice();

   g_closeRetry++;
   Print("[CloseByFlatRangeEA] Closing ticket ", TargetTicket,
         " reason=", reason, " attempt=", g_closeRetry);

   if(g_trade.PositionClose(TargetTicket))
   {
      SetState(ST_CLOSED, reason);
      return;
   }

   Print("[CloseByFlatRangeEA] Close FAILED: ", g_trade.ResultRetcode(),
         " ", g_trade.ResultRetcodeDescription());

   g_lastCloseTime = TimeCurrent();
   SetState(ST_CLOSE_REQUESTED, reason + " (retrying...)");
}

//+------------------------------------------------------------------+
void HandleCloseRetry()
{
   if(!PositionExists())
   {
      g_goneCount++;
      if(g_goneCount >= GONE_THRESHOLD)
      {
         CaptureClosePrice();  // will be 0 if position already gone
         SetState(ST_CLOSED, "Position gone during close retry");
         return;
      }
      Print("[CloseByFlatRangeEA] Position not found during retry (",
            g_goneCount, "/", GONE_THRESHOLD, ")");
      return;
   }
   g_goneCount = 0;

   // Throttle: 1 second between retries
   if(TimeCurrent() <= g_lastCloseTime) return;
   g_lastCloseTime = TimeCurrent();

   g_closeRetry++;
   if(g_closeRetry > CLOSE_MAX_RETRY)
   {
      SetState(ST_ERROR, "Close failed " + (string)CLOSE_MAX_RETRY + " times");
      return;
   }

   Print("[CloseByFlatRangeEA] Retry close ticket ", TargetTicket,
         " attempt=", g_closeRetry, "/", CLOSE_MAX_RETRY);

   // Re-capture close price on retry
   CaptureClosePrice();

   if(g_trade.PositionClose(TargetTicket))
   {
      SetState(ST_CLOSED, g_closeReason);
   }
   else
   {
      Print("[CloseByFlatRangeEA] Retry FAILED: ", g_trade.ResultRetcode(),
            " ", g_trade.ResultRetcodeDescription());
      UpdatePanel();
   }
}

//+------------------------------------------------------------------+
//| Event Log (TSV)                                                   |
//+------------------------------------------------------------------+
void InitEventLog()
{
   if(!EnableEventLog) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_logFileName = StringFormat("FlatRangeLog_%04d%02d%02d_%s_%llu.tsv",
                                dt.year, dt.mon, dt.day, _Symbol, TargetTicket);

   bool exists = FileIsExist(g_logFileName);

   g_logHandle = FileOpen(g_logFileName,
                          FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI
                          | FILE_SHARE_WRITE | FILE_SHARE_READ, '\t');

   if(g_logHandle == INVALID_HANDLE)
   {
      Print("[CloseByFlatRangeEA] ERROR: Cannot open event log: ", g_logFileName);
      return;
   }

   if(exists)
   {
      FileSeek(g_logHandle, 0, SEEK_END);
   }
   else
   {
      string header = "Time\tEvent\tTicket\tSymbol\tDir\t"
                      "EntryPrice\tEntryTime\tSpread\tHour\t"
                      "BarsFromEntry\tSlopePts\tATRPts\t"
                      "RangeHigh\tRangeLow\tRangeMid\tEntryPosInRange\t"
                      "Reason\tClosePrice\tPnLPips\tBarsFromFlat";
      FileWriteString(g_logHandle, header + "\n");
      FileFlush(g_logHandle);
   }
}

//+------------------------------------------------------------------+
void WriteEventLog(string eventType, string reason = "")
{
   if(g_logHandle == INVALID_HANDLE) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Common columns: Time, Event, Ticket, Symbol, Dir
   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\t"
               + eventType + "\t"
               + (string)TargetTicket + "\t"
               + _Symbol + "\t"
               + g_posDir + "\t";

   if(eventType == "ATTACH")
   {
      // EntryPrice, EntryTime, Spread, Hour
      line += DoubleToString(g_entryPrice, _Digits) + "\t"
            + TimeToString(g_entryTime, TIME_DATE | TIME_SECONDS) + "\t"
            + (string)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) + "\t"
            + (string)dt.hour + "\t";
      // Pad: BarsFromEntry, SlopePts, ATRPts, RangeHigh, RangeLow, RangeMid, EntryPosInRange, Reason, ClosePrice, PnLPips, BarsFromFlat
      line += "\t\t\t\t\t\t\t\t\t\t";
   }
   else if(eventType == "FLAT")
   {
      // Pad: EntryPrice, EntryTime, Spread, Hour
      line += "\t\t\t\t";
      // BarsFromEntry, SlopePts, ATRPts
      line += (string)g_barsFromEntry + "\t"
            + DoubleToString(g_flatSlopePts, 1) + "\t"
            + DoubleToString(g_flatATRPts, 1) + "\t";
      // Pad: RangeHigh, RangeLow, RangeMid, EntryPosInRange, Reason, ClosePrice, PnLPips, BarsFromFlat
      line += "\t\t\t\t\t\t\t";
   }
   else if(eventType == "RANGE")
   {
      // Pad: EntryPrice, EntryTime, Spread, Hour, BarsFromEntry, SlopePts, ATRPts
      line += "\t\t\t\t\t\t\t";
      // RangeHigh, RangeLow, RangeMid, EntryPosInRange
      double entryPosInRange = 0.0;
      if(g_rangeHigh > g_rangeLow)
         entryPosInRange = (g_entryPrice - g_rangeLow) / (g_rangeHigh - g_rangeLow);
      line += DoubleToString(g_rangeHigh, _Digits) + "\t"
            + DoubleToString(g_rangeLow, _Digits) + "\t"
            + DoubleToString(g_rangeMid, _Digits) + "\t"
            + DoubleToString(entryPosInRange, 2) + "\t";
      // Pad: Reason, ClosePrice, PnLPips, BarsFromFlat
      line += "\t\t\t";
   }
   else if(eventType == "CLOSE")
   {
      // Pad: EntryPrice, EntryTime, Spread, Hour, BarsFromEntry, SlopePts, ATRPts, RangeHigh, RangeLow, RangeMid, EntryPosInRange
      line += "\t\t\t\t\t\t\t\t\t\t\t";
      // Reason, ClosePrice, PnLPips, BarsFromFlat
      line += reason + "\t"
            + DoubleToString(g_closePrice, _Digits) + "\t"
            + DoubleToString(g_closePnLPips, 1) + "\t"
            + (string)g_barsFromFlat;
   }
   else if(eventType == "RESTORE")
   {
      // Pad: EntryPrice, EntryTime, Spread
      line += "\t\t\t";
      // Hour
      line += (string)dt.hour + "\t";
      // BarsFromEntry
      line += (string)g_barsFromEntry + "\t";
      // Pad: SlopePts, ATRPts
      line += "\t\t";
      // RangeHigh, RangeLow, RangeMid, EntryPosInRange
      double entryPosInRange = 0.0;
      if(g_rangeHigh > g_rangeLow)
         entryPosInRange = (g_entryPrice - g_rangeLow) / (g_rangeHigh - g_rangeLow);
      line += DoubleToString(g_rangeHigh, _Digits) + "\t"
            + DoubleToString(g_rangeLow, _Digits) + "\t"
            + DoubleToString(g_rangeMid, _Digits) + "\t"
            + DoubleToString(entryPosInRange, 2) + "\t";
      // Reason, Pad: ClosePrice, PnLPips
      line += reason + "\t\t\t";
      // BarsFromFlat
      line += (string)g_barsFromFlat;
   }

   FileWriteString(g_logHandle, line + "\n");
   FileFlush(g_logHandle);
}

//+------------------------------------------------------------------+
void DeinitEventLog()
{
   if(g_logHandle != INVALID_HANDLE)
   {
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
void CacheEntryInfo()
{
   if(PositionSelectByTicket(TargetTicket))
   {
      g_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_entryTime  = (datetime)PositionGetInteger(POSITION_TIME);
   }
   g_barsFromEntry = 0;
   g_barsFromFlat  = 0;
}

//+------------------------------------------------------------------+
//| State Persistence (GlobalVariable)                                |
//+------------------------------------------------------------------+
string GVKey(string varName)
{
   return "FlatRange_" + (string)TargetTicket + "_" + varName;
}

void SaveState()
{
   if(g_state < ST_RANGE_LOCKED || g_state > ST_TRAILING) return;

   GlobalVariableSet(GVKey("state"),      (double)g_state);
   GlobalVariableSet(GVKey("rangeHigh"),  g_rangeHigh);
   GlobalVariableSet(GVKey("rangeLow"),   g_rangeLow);
   GlobalVariableSet(GVKey("rangeMid"),   g_rangeMid);
   GlobalVariableSet(GVKey("trailPeak"),  g_trailPeak);
   GlobalVariableSet(GVKey("trailLine"),  g_trailLine);
   GlobalVariableSet(GVKey("waitBars"),   (double)g_waitBarsCount);
   GlobalVariableSet(GVKey("barsEntry"),  (double)g_barsFromEntry);
   GlobalVariableSet(GVKey("barsFlat"),   (double)g_barsFromFlat);
   GlobalVariableSet(GVKey("posType"),    (double)g_posType);
   GlobalVariableSet(GVKey("entryPrice"), g_entryPrice);
   GlobalVariableSet(GVKey("entryTime"),  (double)g_entryTime);
}

bool LoadState()
{
   if(!GlobalVariableCheck(GVKey("state"))) return false;

   EA_STATE savedState = (EA_STATE)(int)GlobalVariableGet(GVKey("state"));
   if(savedState < ST_RANGE_LOCKED || savedState > ST_TRAILING)
   {
      ClearSavedState();
      return false;
   }

   double savedPosType = GlobalVariableGet(GVKey("posType"));
   if((int)savedPosType != (int)g_posType)
   {
      Print("[CloseByFlatRangeEA] Saved posType mismatch, discarding");
      ClearSavedState();
      return false;
   }

   g_rangeHigh     = GlobalVariableGet(GVKey("rangeHigh"));
   g_rangeLow      = GlobalVariableGet(GVKey("rangeLow"));
   g_rangeMid      = GlobalVariableGet(GVKey("rangeMid"));
   g_rangeLocked   = true;
   g_trailPeak     = GlobalVariableGet(GVKey("trailPeak"));
   g_trailLine     = GlobalVariableGet(GVKey("trailLine"));
   g_waitBarsCount = (int)GlobalVariableGet(GVKey("waitBars"));
   g_barsFromEntry = (int)GlobalVariableGet(GVKey("barsEntry"));
   g_barsFromFlat  = (int)GlobalVariableGet(GVKey("barsFlat"));
   g_entryPrice    = GlobalVariableGet(GVKey("entryPrice"));
   g_entryTime     = (datetime)GlobalVariableGet(GVKey("entryTime"));

   g_state     = savedState;
   g_stateInfo = "Restored";

   Print("[CloseByFlatRangeEA] State restored: ", StateToString(savedState),
         " Range=[", DoubleToString(g_rangeLow, _Digits),
         "..", DoubleToString(g_rangeHigh, _Digits), "]",
         " WaitBars=", g_waitBarsCount,
         " TrailPeak=", DoubleToString(g_trailPeak, _Digits));

   WriteEventLog("RESTORE", StateToString(savedState));
   UpdatePanel();
   return true;
}

void ClearSavedState()
{
   GlobalVariableDel(GVKey("state"));
   GlobalVariableDel(GVKey("rangeHigh"));
   GlobalVariableDel(GVKey("rangeLow"));
   GlobalVariableDel(GVKey("rangeMid"));
   GlobalVariableDel(GVKey("trailPeak"));
   GlobalVariableDel(GVKey("trailLine"));
   GlobalVariableDel(GVKey("waitBars"));
   GlobalVariableDel(GVKey("barsEntry"));
   GlobalVariableDel(GVKey("barsFlat"));
   GlobalVariableDel(GVKey("posType"));
   GlobalVariableDel(GVKey("entryPrice"));
   GlobalVariableDel(GVKey("entryTime"));
}

//+------------------------------------------------------------------+
//| Startup Condition Filter                                          |
//+------------------------------------------------------------------+
string CheckStartupConditions()
{
   string warns[];
   int warnCount = 0;

   if(!PositionSelectByTicket(TargetTicket))
      return "";

   // --- 1. Unrealized profit vs ATR ---
   double atrVal = 0.0;
   double atrBuf[1];
   bool atrOK = (CopyBuffer(g_hATR, 0, 1, 1, atrBuf) >= 1 && atrBuf[0] > 0);
   if(atrOK) atrVal = atrBuf[0];

   if(atrOK)
   {
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double unrealized;
      if(g_posType == POSITION_TYPE_BUY)
         unrealized = currentPrice - g_entryPrice;
      else
         unrealized = g_entryPrice - currentPrice;

      double required = atrVal * w_startProfitATRMult;
      if(unrealized < required)
      {
         warnCount++;
         ArrayResize(warns, warnCount);
         warns[warnCount-1] = StringFormat("[%d] Profit: %.1f pts < ATR(14) x %.1f = %.1f pts\n"
                                           "     Trend may not be mature enough",
                                           warnCount,
                                           unrealized / _Point,
                                           w_startProfitATRMult,
                                           required / _Point);
      }
   }

   // --- 2. Elapsed bars from entry ---
   int totalBars = Bars(_Symbol, SignalTF, g_entryTime, TimeCurrent());
   int elapsed = (totalBars > 0) ? totalBars - 1 : 0;

   if(elapsed < w_startMinBars)
   {
      warnCount++;
      ArrayResize(warns, warnCount);
      int minMin = w_startMinBars * (int)(PeriodSeconds(SignalTF) / 60);
      warns[warnCount-1] = StringFormat("[%d] Elapsed: %d bars < min %d bars (%d min)\n"
                                        "     Position too new for flat monitoring",
                                        warnCount, elapsed, w_startMinBars, minMin);
   }

   // --- 3. MA slope vs entry direction ---
   double maCurr[1], maOld[1];
   if(CopyBuffer(g_hMA, 0, 1, 1, maCurr) >= 1 &&
      CopyBuffer(g_hMA, 0, 1 + w_flatSlopeLookbackBars, 1, maOld) >= 1 && atrOK)
   {
      double slope    = maCurr[0] - maOld[0];
      double slopePts = MathAbs(slope) / _Point;
      double atrPts   = atrVal / _Point;
      bool   isFlat   = (slopePts <= atrPts * w_flatSlopeAtrMult);
      bool   wrongDir = false;

      if(g_posType == POSITION_TYPE_BUY && slope <= 0)
         wrongDir = true;
      else if(g_posType == POSITION_TYPE_SELL && slope >= 0)
         wrongDir = true;

      if(isFlat || wrongDir)
      {
         warnCount++;
         ArrayResize(warns, warnCount);
         string status = wrongDir ? ("opposite to " + g_posDir) : "flat/horizontal";
         warns[warnCount-1] = StringFormat("[%d] MA(%d) slope: %s\n"
                                           "     Slope=%.1f pts, Threshold=%.1f pts",
                                           warnCount, w_flatMaPeriod, status,
                                           slopePts, atrPts * w_flatSlopeAtrMult);
      }
   }

   if(warnCount == 0)
      return "";

   // Build message
   string msg = "Startup Filter Warning  [" + _Symbol + " " + g_posDir + "]\n"
              + "Ticket: " + (string)TargetTicket + "  |  Mode: " + MarketModeToString() + "\n"
              + "-------------------------------------------\n\n";

   for(int i = 0; i < warnCount; i++)
      msg += warns[i] + "\n\n";

   msg += "[OK] = Acknowledge warning, continue\n"
          "[Cancel] = Stop EA";

   return msg;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_objPrefix = "CloseByFlatRangeEA_" + (string)TargetTicket + "_";

   if(TargetTicket == 0)
   {
      Print("[CloseByFlatRangeEA] ERROR: TargetTicket=0 is not allowed");
      return INIT_FAILED;
   }

   // Apply market mode preset
   ApplyPreset();

   // Create indicator handles
   ENUM_MA_METHOD maMethod = (w_flatMaMethod == FLAT_MA_SMA) ? MODE_SMA : MODE_EMA;
   g_hMA  = iMA(_Symbol, SignalTF, w_flatMaPeriod, 0, maMethod, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, SignalTF, ATRPeriod);

   if(g_hMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Print("[CloseByFlatRangeEA] ERROR: Failed to create MA/ATR handles");
      return INIT_FAILED;
   }

   // Init event log
   InitEventLog();

   // Check if target position exists
   if(!PositionExists())
   {
      SetState(ST_WAIT_POSITION, "Waiting for ticket " + (string)TargetTicket);
      return INIT_SUCCEEDED;
   }

   // Validate position
   if(!PositionSelectByTicket(TargetTicket))
   {
      SetState(ST_ERROR, "Cannot select ticket " + (string)TargetTicket);
      return INIT_SUCCEEDED;
   }

   string posSym = PositionGetString(POSITION_SYMBOL);
   if(posSym != _Symbol)
   {
      SetState(ST_ERROR, "Symbol mismatch: pos=" + posSym + " chart=" + _Symbol);
      return INIT_SUCCEEDED;
   }

   g_posType = PositionGetInteger(POSITION_TYPE);
   g_posDir  = (g_posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   g_lastBar       = iTime(_Symbol, SignalTF, 0);
   g_rangeLocked   = false;
   g_waitBarsCount = 0;
   g_goneCount     = 0;
   g_closeRetry    = 0;
   g_trailPeak     = 0.0;
   g_trailLine     = 0.0;

   // Cache entry info
   CacheEntryInfo();

   // Try to restore saved state (RESTORE event written inside LoadState)
   if(LoadState())
      return INIT_SUCCEEDED;

   // Startup filter (fresh attach only)
   if(EnableStartupFilter)
   {
      string warnings = CheckStartupConditions();
      if(warnings != "")
      {
         Print("[CloseByFlatRangeEA] Startup filter: warnings detected");
         int mbResult = MessageBox(warnings,
                                   "CloseByFlatRangeEA - Startup Filter",
                                   MB_OKCANCEL | MB_ICONWARNING);
         if(mbResult == IDCANCEL)
         {
            Print("[CloseByFlatRangeEA] EA stopped by user (startup filter)");
            return INIT_FAILED;
         }
         Print("[CloseByFlatRangeEA] Startup warning acknowledged, continuing");
      }
   }

   // Fresh start
   WriteEventLog("ATTACH");
   SetState(ST_WAIT_FLAT);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hMA != INVALID_HANDLE)  IndicatorRelease(g_hMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   DeinitEventLog();
   DeletePanel();
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(g_state == ST_CLOSED || g_state == ST_ERROR) return;

   //--- ST_CLOSE_REQUESTED: retry with throttle
   if(g_state == ST_CLOSE_REQUESTED)
   {
      HandleCloseRetry();
      return;
   }

   //--- ST_WAIT_POSITION: check if position appeared
   if(g_state == ST_WAIT_POSITION)
   {
      if(!PositionExists()) return;

      if(!PositionSelectByTicket(TargetTicket))
      {
         SetState(ST_ERROR, "Cannot select ticket " + (string)TargetTicket);
         return;
      }

      string posSym = PositionGetString(POSITION_SYMBOL);
      if(posSym != _Symbol)
      {
         SetState(ST_ERROR, "Symbol mismatch: pos=" + posSym + " chart=" + _Symbol);
         return;
      }

      g_posType = PositionGetInteger(POSITION_TYPE);
      g_posDir  = (g_posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      g_lastBar = iTime(_Symbol, SignalTF, 0);

      // Cache entry info and write ATTACH event
      CacheEntryInfo();
      WriteEventLog("ATTACH");

      SetState(ST_WAIT_FLAT);
      return;
   }

   //--- Position alive check (tick-level)
   if(!CheckPositionAlive()) return;

   //--- New bar gate (all signal checks are confirmed-bar only)
   if(!IsNewBar()) return;

   //--- Increment bar counters
   g_barsFromEntry++;
   if(g_state == ST_RANGE_LOCKED || g_state == ST_TRAILING)
      g_barsFromFlat++;

   //--- ST_WAIT_FLAT: flat detection on confirmed bar
   if(g_state == ST_WAIT_FLAT)
   {
      if(CheckFlat())
      {
         if(LockRange())
         {
            g_waitBarsCount = 0;
            g_barsFromFlat  = 0;

            // Write FLAT and RANGE events
            WriteEventLog("FLAT");
            WriteEventLog("RANGE");

            SetState(ST_RANGE_LOCKED,
                     "Range=[" + DoubleToString(g_rangeLow, _Digits)
                     + ".." + DoubleToString(g_rangeHigh, _Digits) + "]"
                     + " Mid=" + DoubleToString(g_rangeMid, _Digits));
         }
         else
         {
            Print("[CloseByFlatRangeEA] Flat detected but insufficient bars for range");
         }
      }
      return;
   }

   //--- ST_RANGE_LOCKED: breakout detection on confirmed bar
   if(g_state == ST_RANGE_LOCKED)
   {
      g_waitBarsCount++;

      // 1. Check breakout
      int breakout = CheckBreakout();

      if(breakout < 0)
      {
         // Unfavorable breakout -> immediate close
         ExecuteClose("UnfavBreak");
         return;
      }

      if(breakout > 0)
      {
         // Favorable breakout -> initialize trailing and transition
         double highBuf[1], lowBuf[1];
         if(CopyHigh(_Symbol, SignalTF, 1, 1, highBuf) < 1 ||
            CopyLow(_Symbol, SignalTF, 1, 1, lowBuf) < 1)
         {
            Print("[CloseByFlatRangeEA] WARN: CopyHigh/Low failed on breakout init, deferring");
            SaveState();
            UpdatePanel();
            return;
         }

         if(g_posType == POSITION_TYPE_BUY)
            g_trailPeak = highBuf[0];
         else
            g_trailPeak = lowBuf[0];

         // Calculate initial trail line
         double atrBuf[1];
         if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) >= 1 && atrBuf[0] > 0)
         {
            if(g_posType == POSITION_TYPE_BUY)
               g_trailLine = g_trailPeak - atrBuf[0] * TrailATRMult;
            else
               g_trailLine = g_trailPeak + atrBuf[0] * TrailATRMult;
         }
         else
         {
            Print("[CloseByFlatRangeEA] WARN: ATR unavailable on trail init, trailLine deferred");
         }

         SetState(ST_TRAILING,
                  "FavBreakout Peak=" + DoubleToString(g_trailPeak, _Digits)
                  + " Trail=" + DoubleToString(g_trailLine, _Digits));
         return;
      }

      // 2. No breakout -- check WaitBars safety valve
      if(g_waitBarsCount > w_waitBarsAfterFlat)
      {
         if(FailSafe == FS_MARKET_CLOSE)
         {
            Print("[CloseByFlatRangeEA] WaitBars exceeded: ",
                  g_waitBarsCount, ">", w_waitBarsAfterFlat);
            ExecuteClose("FailSafe: WaitBars exceeded");
            return;
         }
         // FS_NONE: continue monitoring breakout
      }

      SaveState();
      UpdatePanel();
      return;
   }

   //--- ST_TRAILING: ATR trailing on confirmed bar
   if(g_state == ST_TRAILING)
   {
      if(UpdateTrailing())
      {
         // Trailing stop hit -> close position
         ExecuteClose("TrailStop Peak=" + DoubleToString(g_trailPeak, _Digits)
                      + " Line=" + DoubleToString(g_trailLine, _Digits));
         return;
      }
      SaveState();
      UpdatePanel();
   }
}

//+------------------------------------------------------------------+
//| Panel                                                             |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;

   string lines[];
   ArrayResize(lines, MAX_LINES);
   int count = 0;

   lines[count++] = "FlatRangeEA  " + MarketModeToString() + "  TF=" + EnumToString(SignalTF);
   lines[count++] = "Ticket: " + (string)TargetTicket + "  " + g_posDir;
   lines[count++] = "State: " + StateToString(g_state);

   if(g_rangeLocked)
   {
      lines[count++] = "Range=[" + DoubleToString(g_rangeLow, _Digits)
                        + ".." + DoubleToString(g_rangeHigh, _Digits) + "]"
                        + " Mid=" + DoubleToString(g_rangeMid, _Digits);
   }

   if(g_state == ST_RANGE_LOCKED)
      lines[count++] = "Bars=" + (string)g_waitBarsCount + "/" + (string)w_waitBarsAfterFlat;

   if(g_state == ST_TRAILING && count < MAX_LINES)
      lines[count++] = "Peak=" + DoubleToString(g_trailPeak, _Digits)
                        + "  Trail=" + DoubleToString(g_trailLine, _Digits);

   if(g_state == ST_CLOSE_REQUESTED)
      lines[count++] = "CloseRetry: " + (string)g_closeRetry + "/" + (string)CLOSE_MAX_RETRY;

   if(g_stateInfo != "" && count < MAX_LINES)
      lines[count++] = g_stateInfo;

   int baseY = LabelY + LabelRow * (MAX_LINES * LINE_HEIGHT);

   for(int i = 0; i < count; i++)
   {
      string name = g_objPrefix + (string)i;
      int yPos = baseY + (count - 1 - i) * LINE_HEIGHT;

      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FONT_SIZE);
      }

      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, LabelX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yPos);
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);

      color clr = clrWhite;
      if(g_state == ST_WAIT_POSITION)  clr = clrGray;
      if(g_state == ST_WAIT_FLAT)      clr = clrYellow;
      if(g_state == ST_RANGE_LOCKED)   clr = clrDodgerBlue;
      if(g_state == ST_TRAILING)       clr = clrMagenta;
      if(g_state == ST_CLOSE_REQUESTED) clr = clrOrange;
      if(g_state == ST_CLOSED)         clr = clrLime;
      if(g_state == ST_ERROR)          clr = clrRed;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }

   // Clean up unused lines
   for(int i = count; i < MAX_LINES; i++)
   {
      string name = g_objPrefix + (string)i;
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
void DeletePanel()
{
   for(int i = 0; i < MAX_LINES; i++)
   {
      string name = g_objPrefix + (string)i;
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }
   ChartRedraw();
}
//+------------------------------------------------------------------+
