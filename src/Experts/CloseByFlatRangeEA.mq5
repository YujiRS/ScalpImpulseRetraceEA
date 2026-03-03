//+------------------------------------------------------------------+
//| CloseByFlatRangeEA.mq5                                           |
//| Closes a specific position on MA Flat + Range target reach        |
//+------------------------------------------------------------------+
#property copyright "CloseByFlatRangeEA"
#property version   "2.00"
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

enum ENUM_EXIT_TARGET
{
   EXIT_MID              = 0,   // Mid
   EXIT_FAVORABLE_EDGE   = 1,   // Favorable Edge
   EXIT_UNFAVORABLE_EDGE = 2    // Unfavorable Edge
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
input ENUM_TIMEFRAMES    SignalTF              = PERIOD_CURRENT;

//--- G2: Flat Detection (used when MarketMode=Custom)
input ENUM_FLAT_MA_METHOD FlatMaMethod         = FLAT_MA_SMA;     // MA method
input int                FlatMaPeriod          = 21;              // MA period
input int                FlatSlopeLookbackBars = 5;               // Slope lookback bars
input int                ATRPeriod             = 14;              // ATR period
input double             FlatSlopeAtrMult      = 0.10;            // Slope/ATR threshold

//--- G3: Range (used when MarketMode=Custom)
input int                RangeLookbackBars     = 10;              // Range lookback bars

//--- G4: Exit Target
input ENUM_EXIT_TARGET   ExitTarget            = EXIT_MID;        // Exit target

//--- G5: Failsafe (used when MarketMode=Custom)
input int                WaitBarsAfterFlat     = 8;               // Max wait bars after flat
input ENUM_FAILSAFE      FailSafe              = FS_MARKET_CLOSE; // Failsafe action

//--- G6: 5MA Assist (used when MarketMode=Custom)
input bool               UseAssist5MA          = false;           // Use 5MA assist

//--- G7: Label
input bool               ShowPanel             = true;
input int                LabelX                = 10;
input int                LabelY                = 20;
input int                LabelRow              = 0;

//--- State machine
enum EA_STATE
{
   ST_WAIT_POSITION,
   ST_WAIT_FLAT,
   ST_RANGE_LOCKED_WAIT_TARGET,
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
bool                w_useAssist5MA;

int       g_hMA             = INVALID_HANDLE;
int       g_hATR            = INVALID_HANDLE;
int       g_hAssistMA       = INVALID_HANDLE;

datetime  g_lastBar         = 0;

bool      g_rangeLocked     = false;
double    g_rangeHigh       = 0;
double    g_rangeLow        = 0;
double    g_rangeMid        = 0;

int       g_waitBarsCount   = 0;
int       g_goneCount       = 0;
int       g_closeRetry      = 0;
datetime  g_lastCloseTime   = 0;

string    g_objPrefix       = "";
CTrade    g_trade;

const int FONT_SIZE         = 9;
const int LINE_HEIGHT       = 20;
const int MAX_LINES         = 8;
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
         w_waitBarsAfterFlat    = 4;
         w_useAssist5MA         = false;
         break;

      case MM_GOLD:
         w_flatMaMethod         = FLAT_MA_EMA;
         w_flatMaPeriod         = 21;
         w_flatSlopeLookbackBars = 3;
         w_flatSlopeAtrMult     = 0.30;
         w_rangeLookbackBars    = 20;
         w_waitBarsAfterFlat    = 8;
         w_useAssist5MA         = false;
         break;

      case MM_CRYPTO:
         w_flatMaMethod         = FLAT_MA_EMA;
         w_flatMaPeriod         = 13;
         w_flatSlopeLookbackBars = 8;
         w_flatSlopeAtrMult     = 0.03;
         w_rangeLookbackBars    = 20;
         w_waitBarsAfterFlat    = 12;
         w_useAssist5MA         = false;
         break;

      case MM_CUSTOM:
      default:
         w_flatMaMethod         = FlatMaMethod;
         w_flatMaPeriod         = FlatMaPeriod;
         w_flatSlopeLookbackBars = FlatSlopeLookbackBars;
         w_flatSlopeAtrMult     = FlatSlopeAtrMult;
         w_rangeLookbackBars    = RangeLookbackBars;
         w_waitBarsAfterFlat    = WaitBarsAfterFlat;
         w_useAssist5MA         = UseAssist5MA;
         break;
   }

   Print("[CloseByFlatRangeEA] MarketMode=", MarketModeToString(),
         " MA=", (w_flatMaMethod == FLAT_MA_EMA ? "EMA" : "SMA"),
         "(", w_flatMaPeriod, ")",
         " SlopeLB=", w_flatSlopeLookbackBars,
         " Mult=", DoubleToString(w_flatSlopeAtrMult, 2),
         " RangeLB=", w_rangeLookbackBars,
         " WaitBars=", w_waitBarsAfterFlat,
         " 5MA=", (w_useAssist5MA ? "ON" : "OFF"));
}

//+------------------------------------------------------------------+
string StateToString(EA_STATE s)
{
   switch(s)
   {
      case ST_WAIT_POSITION:            return "WAIT_POSITION";
      case ST_WAIT_FLAT:                return "WAIT_FLAT";
      case ST_RANGE_LOCKED_WAIT_TARGET: return "WAIT_TARGET";
      case ST_CLOSE_REQUESTED:          return "CLOSE_REQUESTED";
      case ST_CLOSED:                   return "CLOSED";
      case ST_ERROR:                    return "ERROR";
   }
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
string ExitTargetToString()
{
   switch(ExitTarget)
   {
      case EXIT_MID:              return "MID";
      case EXIT_FAVORABLE_EDGE:   return "FAV_EDGE";
      case EXIT_UNFAVORABLE_EDGE: return "UNFAV_EDGE";
   }
   return "?";
}

//+------------------------------------------------------------------+
void SetState(EA_STATE s, string info="")
{
   g_state = s;
   g_stateInfo = info;
   Print("[CloseByFlatRangeEA] State -> ", StateToString(s),
         (info != "" ? " | " + info : ""),
         " | Ticket=", TargetTicket);
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
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == TargetTicket) return true;
   }
   return false;
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
      Print("[CloseByFlatRangeEA] Flat detected: SlopePts=", DoubleToString(slopePts, 1),
            " ATRPts=", DoubleToString(atrPts, 1),
            " Threshold=", DoubleToString(atrPts * w_flatSlopeAtrMult, 1));

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
bool CheckTargetReached()
{
   double price;
   if(g_posType == POSITION_TYPE_BUY)
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   switch(ExitTarget)
   {
      case EXIT_MID:
         if(g_posType == POSITION_TYPE_BUY)
            return (price >= g_rangeMid);
         else
            return (price <= g_rangeMid);

      case EXIT_FAVORABLE_EDGE:
         if(g_posType == POSITION_TYPE_BUY)
            return (price >= g_rangeHigh);
         else
            return (price <= g_rangeLow);

      case EXIT_UNFAVORABLE_EDGE:
         if(g_posType == POSITION_TYPE_BUY)
            return (price <= g_rangeLow);
         else
            return (price >= g_rangeHigh);
   }
   return false;
}

//+------------------------------------------------------------------+
bool CheckAssist5MA()
{
   if(!w_useAssist5MA) return false;
   if(g_hAssistMA == INVALID_HANDLE) return false;

   // emaBuf[0] = bar[2] (older), emaBuf[1] = bar[1] (newer)
   double emaBuf[2];
   if(CopyBuffer(g_hAssistMA, 0, 1, 2, emaBuf) < 2) return false;

   if(g_posType == POSITION_TYPE_BUY)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      // 1) Price not at MID yet  2) EMA5 turning down  3) At/below unfavorable edge
      if(bid < g_rangeMid && emaBuf[1] < emaBuf[0] && bid <= g_rangeLow)
      {
         Print("[CloseByFlatRangeEA] 5MA assist: Bid=", DoubleToString(bid, _Digits),
               " < Mid=", DoubleToString(g_rangeMid, _Digits),
               " EMA5[1]=", DoubleToString(emaBuf[1], _Digits),
               " < EMA5[2]=", DoubleToString(emaBuf[0], _Digits),
               " Bid<=RangeLow=", DoubleToString(g_rangeLow, _Digits));
         return true;
      }
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // 1) Price not at MID yet  2) EMA5 turning up  3) At/above unfavorable edge
      if(ask > g_rangeMid && emaBuf[1] > emaBuf[0] && ask >= g_rangeHigh)
      {
         Print("[CloseByFlatRangeEA] 5MA assist: Ask=", DoubleToString(ask, _Digits),
               " > Mid=", DoubleToString(g_rangeMid, _Digits),
               " EMA5[1]=", DoubleToString(emaBuf[1], _Digits),
               " > EMA5[2]=", DoubleToString(emaBuf[0], _Digits),
               " Ask>=RangeHigh=", DoubleToString(g_rangeHigh, _Digits));
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
void ExecuteClose(string reason)
{
   g_closeReason = reason;
   g_closeRetry = 0;
   g_goneCount = 0;

   if(!PositionExists())
   {
      SetState(ST_CLOSED, "Position gone before close: " + reason);
      return;
   }

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
int OnInit()
{
   g_objPrefix = "CloseByFlatRangeEA_" + (string)TargetTicket + "_";

   if(TargetTicket == 0)
   {
      SetState(ST_ERROR, "TargetTicket=0 is not allowed");
      return INIT_SUCCEEDED;
   }

   // Apply market mode preset
   ApplyPreset();

   // Create indicator handles
   ENUM_MA_METHOD maMethod = (w_flatMaMethod == FLAT_MA_SMA) ? MODE_SMA : MODE_EMA;
   g_hMA  = iMA(_Symbol, SignalTF, w_flatMaPeriod, 0, maMethod, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, SignalTF, ATRPeriod);

   if(g_hMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      SetState(ST_ERROR, "Failed to create MA/ATR handles");
      return INIT_SUCCEEDED;
   }

   if(w_useAssist5MA)
   {
      g_hAssistMA = iMA(_Symbol, SignalTF, 5, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hAssistMA == INVALID_HANDLE)
      {
         SetState(ST_ERROR, "Failed to create AssistMA handle");
         return INIT_SUCCEEDED;
      }
   }

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

   SetState(ST_WAIT_FLAT);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hMA != INVALID_HANDLE)       IndicatorRelease(g_hMA);
   if(g_hATR != INVALID_HANDLE)      IndicatorRelease(g_hATR);
   if(g_hAssistMA != INVALID_HANDLE) IndicatorRelease(g_hAssistMA);
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

      SetState(ST_WAIT_FLAT);
      return;
   }

   //--- Position alive check
   if(!CheckPositionAlive()) return;

   //--- Tick-level target check
   if(g_state == ST_RANGE_LOCKED_WAIT_TARGET)
   {
      if(CheckTargetReached())
      {
         ExecuteClose("Target(" + ExitTargetToString() + ") reached");
         return;
      }
   }

   //--- New bar gate
   if(!IsNewBar()) return;

   //--- ST_WAIT_FLAT: flat detection on confirmed bar
   if(g_state == ST_WAIT_FLAT)
   {
      if(CheckFlat())
      {
         if(LockRange())
         {
            g_waitBarsCount = 0;
            SetState(ST_RANGE_LOCKED_WAIT_TARGET,
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

   //--- ST_RANGE_LOCKED_WAIT_TARGET: bar-level checks
   if(g_state == ST_RANGE_LOCKED_WAIT_TARGET)
   {
      g_waitBarsCount++;

      // Failsafe: bar count exceeded
      if(g_waitBarsCount > w_waitBarsAfterFlat)
      {
         Print("[CloseByFlatRangeEA] WaitBars exceeded: ",
               g_waitBarsCount, ">", w_waitBarsAfterFlat);
         if(FailSafe == FS_MARKET_CLOSE)
            ExecuteClose("FailSafe: WaitBars exceeded");
         return;
      }

      // 5MA assist
      if(CheckAssist5MA())
      {
         if(FailSafe == FS_MARKET_CLOSE)
            ExecuteClose("5MA assist (bar " + (string)g_waitBarsCount
                         + "/" + (string)w_waitBarsAfterFlat + ")");
         return;
      }

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

   if(g_state == ST_RANGE_LOCKED_WAIT_TARGET)
      lines[count++] = "Target=" + ExitTargetToString()
                        + "  Bars=" + (string)g_waitBarsCount + "/" + (string)w_waitBarsAfterFlat;

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
      if(g_state == ST_WAIT_POSITION)            clr = clrGray;
      if(g_state == ST_WAIT_FLAT)                clr = clrYellow;
      if(g_state == ST_RANGE_LOCKED_WAIT_TARGET) clr = clrDodgerBlue;
      if(g_state == ST_CLOSE_REQUESTED)          clr = clrOrange;
      if(g_state == ST_CLOSED)                   clr = clrLime;
      if(g_state == ST_ERROR)                    clr = clrRed;
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
