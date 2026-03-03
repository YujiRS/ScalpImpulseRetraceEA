//+------------------------------------------------------------------+
//| CloseByCrossEA.mq5                                                |
//| Closes a specific position on SMA13/SMA21 cross                   |
//+------------------------------------------------------------------+
#property copyright "CloseByCrossEA"
#property version   "1.05"
#property strict

#include <Trade\Trade.mqh>

//--- G1: Inputs
input ENUM_TIMEFRAMES SignalTF          = PERIOD_CURRENT;
input ulong           TargetTicket      = 0;

//--- Panel
input bool            ShowPanel         = true;
input int             PanelX            = 10;
input int             PanelY            = 20;

//--- Internal
enum EA_STATE {
   ST_INIT,
   ST_WAIT_SYNC,
   ST_ARMED,
   ST_CONFIRM_WAIT,    // Cross detected, waiting 1 bar to confirm
   ST_PENDING_CLOSE,   // Close failed, retrying
   ST_CLOSED,
   ST_ERROR
};

EA_STATE  g_state       = ST_INIT;
string    g_error       = "";
string    g_posDir      = "";
string    g_crossType   = "";          // "GoldenCross" or "DeadCross"
bool      g_crossIsGolden = false;     // true=Golden, false=Dead
int       g_hSMA13      = INVALID_HANDLE;
int       g_hSMA21      = INVALID_HANDLE;
datetime  g_lastBar     = 0;
bool      g_synced      = false;
string    g_objPrefix   = "";
CTrade    g_trade;

int       g_closeRetry  = 0;
int       g_goneCount   = 0;
datetime  g_lastRetryTime = 0;

const int FONT_SIZE     = 9;
const int LINE_HEIGHT   = 20;
const int MAX_LINES     = 6;
const int CLOSE_MAX_RETRY  = 10;
const int GONE_THRESHOLD   = 5;

//+------------------------------------------------------------------+
string StateToString(EA_STATE s)
{
   switch(s)
   {
      case ST_INIT:          return "INIT";
      case ST_WAIT_SYNC:     return "WAIT_SYNC";
      case ST_ARMED:         return "ARMED";
      case ST_CONFIRM_WAIT:  return "CONFIRM_WAIT";
      case ST_PENDING_CLOSE: return "PENDING_CLOSE";
      case ST_CLOSED:        return "CLOSED";
      case ST_ERROR:         return "ERROR";
   }
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
void SetState(EA_STATE s, string err="")
{
   g_state = s;
   g_error = err;
   Print("[CloseByCrossEA] State -> ", StateToString(s),
         (err != "" ? " | " + err : ""), " | Ticket=", TargetTicket);
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
bool GetSMA(double &sma13_prev, double &sma13_curr, double &sma21_prev, double &sma21_curr)
{
   double buf13[2], buf21[2];
   if(CopyBuffer(g_hSMA13, 0, 1, 2, buf13) < 2) return false;
   if(CopyBuffer(g_hSMA21, 0, 1, 2, buf21) < 2) return false;
   sma13_prev = buf13[0]; sma13_curr = buf13[1];
   sma21_prev = buf21[0]; sma21_curr = buf21[1];
   return true;
}

//+------------------------------------------------------------------+
// Get SMA at shift=1 only (for confirmation check)
bool GetSMACurrent(double &sma13, double &sma21)
{
   double buf13[1], buf21[1];
   if(CopyBuffer(g_hSMA13, 0, 1, 1, buf13) < 1) return false;
   if(CopyBuffer(g_hSMA21, 0, 1, 1, buf21) < 1) return false;
   sma13 = buf13[0];
   sma21 = buf21[0];
   return true;
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
         Print("[CloseByCrossEA] Position found again after ", g_goneCount, " miss(es)");
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

   Print("[CloseByCrossEA] Position not found (", g_goneCount, "/", GONE_THRESHOLD, ")");
   return true;
}

//+------------------------------------------------------------------+
bool TryClose()
{
   if(!PositionExists())
   {
      g_goneCount++;
      if(g_goneCount >= GONE_THRESHOLD)
      {
         SetState(ST_CLOSED, "Position gone during close retry");
         return true;
      }
      Print("[CloseByCrossEA] Position not found before close attempt (", g_goneCount, "/", GONE_THRESHOLD, ")");
      return false;
   }
   g_goneCount = 0;

   g_closeRetry++;
   Print("[CloseByCrossEA] Closing ticket ", TargetTicket, " attempt ", g_closeRetry, "/", CLOSE_MAX_RETRY);

   if(g_trade.PositionClose(TargetTicket))
   {
      SetState(ST_CLOSED, "Closed by " + g_crossType + " (attempt " + (string)g_closeRetry + ")");
      return true;
   }

   Print("[CloseByCrossEA] Close FAILED: ", g_trade.ResultRetcode(),
         " ", g_trade.ResultRetcodeDescription());
   UpdatePanel();

   if(g_closeRetry >= CLOSE_MAX_RETRY)
   {
      SetState(ST_ERROR, "Close failed " + (string)CLOSE_MAX_RETRY + " times");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_objPrefix = "CloseByCrossEA_" + (string)TargetTicket + "_";

   if(TargetTicket == 0)
   {
      SetState(ST_ERROR, "TargetTicket=0 is not allowed");
      return INIT_SUCCEEDED;
   }

   if(!PositionExists())
   {
      SetState(ST_ERROR, "Ticket " + (string)TargetTicket + " not found");
      return INIT_SUCCEEDED;
   }

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

   long posType = PositionGetInteger(POSITION_TYPE);
   g_posDir = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   g_hSMA13 = iMA(_Symbol, SignalTF, 13, 0, MODE_SMA, PRICE_CLOSE);
   g_hSMA21 = iMA(_Symbol, SignalTF, 21, 0, MODE_SMA, PRICE_CLOSE);
   if(g_hSMA13 == INVALID_HANDLE || g_hSMA21 == INVALID_HANDLE)
   {
      SetState(ST_ERROR, "Failed to create MA handles");
      return INIT_SUCCEEDED;
   }

   g_lastBar       = iTime(_Symbol, SignalTF, 0);
   g_synced        = false;
   g_closeRetry    = 0;
   g_goneCount     = 0;
   g_lastRetryTime = 0;

   SetState(ST_WAIT_SYNC);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hSMA13 != INVALID_HANDLE) IndicatorRelease(g_hSMA13);
   if(g_hSMA21 != INVALID_HANDLE) IndicatorRelease(g_hSMA21);
   DeletePanel();
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(g_state == ST_CLOSED || g_state == ST_ERROR) return;
   if(g_state == ST_INIT) return;

   //--- PENDING_CLOSE: retry with 1-second throttle
   if(g_state == ST_PENDING_CLOSE)
   {
      datetime now = TimeCurrent();
      if(now <= g_lastRetryTime) return;
      g_lastRetryTime = now;
      TryClose();
      return;
   }

   //--- Position alive check
   if(!CheckPositionAlive()) return;

   if(!IsNewBar()) return;

   //--- CONFIRM_WAIT: check if cross still holds on the next confirmed bar
   if(g_state == ST_CONFIRM_WAIT)
   {
      double s13, s21;
      if(!GetSMACurrent(s13, s21))
      {
         Print("[CloseByCrossEA] CopyBuffer failed in CONFIRM_WAIT, retry next bar");
         return;
      }

      // DeadCross confirm: SMA13 still below SMA21
      // GoldenCross confirm: SMA13 still above SMA21
      bool confirmed = false;
      if(!g_crossIsGolden && (s13 < s21))   confirmed = true;  // Dead still holds
      if( g_crossIsGolden && (s13 > s21))   confirmed = true;  // Golden still holds

      if(!confirmed)
      {
         Print("[CloseByCrossEA] Cross NOT confirmed (SMA13=", s13, " SMA21=", s21,
               ") -> false cross, back to ARMED");
         SetState(ST_ARMED, "False cross rejected");
         return;
      }

      Print("[CloseByCrossEA] Cross CONFIRMED (SMA13=", s13, " SMA21=", s21, ") -> closing");

      // Direction match (re-check for safety)
      bool shouldClose = false;
      if( g_crossIsGolden && g_posDir == "SELL") shouldClose = true;
      if(!g_crossIsGolden && g_posDir == "BUY")  shouldClose = true;

      if(!shouldClose)
      {
         Print("[CloseByCrossEA] Confirmed cross direction vs position (", g_posDir, ") mismatch. Back to ARMED.");
         SetState(ST_ARMED);
         return;
      }

      // Attempt close
      g_closeRetry = 0;
      g_goneCount  = 0;
      if(!TryClose())
      {
         SetState(ST_PENDING_CLOSE, g_crossType + " confirmed, retrying close...");
      }
      return;
   }

   //--- ARMED: normal cross detection
   double s13p, s13c, s21p, s21c;
   if(!GetSMA(s13p, s13c, s21p, s21c))
   {
      Print("[CloseByCrossEA] CopyBuffer failed, retry next bar");
      return;
   }

   // Initial sync
   if(!g_synced)
   {
      g_synced = true;
      SetState(ST_ARMED);
      Print("[CloseByCrossEA] Synced: SMA13=", s13c, " SMA21=", s21c,
            " rel=", (s13c > s21c ? "ABOVE" : "BELOW_OR_EQ"));
      return;
   }

   // Cross detection
   bool goldenCross = (s13p <= s21p) && (s13c > s21c);
   bool deadCross   = (s13p >= s21p) && (s13c < s21c);

   if(!goldenCross && !deadCross) return;

   g_crossIsGolden = goldenCross;
   g_crossType     = goldenCross ? "GoldenCross" : "DeadCross";

   Print("[CloseByCrossEA] Cross detected: ", g_crossType,
         " | SMA13[2]=", s13p, " SMA21[2]=", s21p,
         " | SMA13[1]=", s13c, " SMA21[1]=", s21c,
         " -> waiting 1 bar to confirm");

   // Direction pre-check (skip confirmation wait if direction won't match anyway)
   bool wouldClose = false;
   if( goldenCross && g_posDir == "SELL") wouldClose = true;
   if( deadCross   && g_posDir == "BUY")  wouldClose = true;

   if(!wouldClose)
   {
      Print("[CloseByCrossEA] Cross direction vs position (", g_posDir, ") mismatch. Ignoring.");
      return;
   }

   SetState(ST_CONFIRM_WAIT, g_crossType + " detected, confirming...");
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

   lines[count++] = "CloseByCrossEA  TF=" + EnumToString(SignalTF);
   lines[count++] = "Ticket: " + (string)TargetTicket + "  " + g_posDir;
   lines[count++] = "State:  " + StateToString(g_state);
   if(g_state == ST_PENDING_CLOSE)
      lines[count++] = "Retry: " + (string)g_closeRetry + "/" + (string)CLOSE_MAX_RETRY;
   if(g_error != "")
      lines[count++] = g_error;

   for(int i = 0; i < count; i++)
   {
      string name = g_objPrefix + (string)i;
      int yPos = PanelY + (count - 1 - i) * LINE_HEIGHT;

      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FONT_SIZE);
      }

      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yPos);
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);

      color clr = clrWhite;
      if(g_state == ST_ERROR)         clr = clrRed;
      if(g_state == ST_CLOSED)        clr = clrLime;
      if(g_state == ST_ARMED)         clr = clrDodgerBlue;
      if(g_state == ST_WAIT_SYNC)     clr = clrYellow;
      if(g_state == ST_CONFIRM_WAIT)  clr = clrGold;
      if(g_state == ST_PENDING_CLOSE) clr = clrOrange;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }

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