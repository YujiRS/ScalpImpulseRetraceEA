//+------------------------------------------------------------------+
//| Visualization.mqh                                                 |
//| On-Chart Status Panel                                             |
//| v2.1: Fib描画はMABounceEngine.mqhに移行。パネルをMA Bounce対応      |
//+------------------------------------------------------------------+
#ifndef __VISUALIZATION_MQH__
#define __VISUALIZATION_MQH__

//+------------------------------------------------------------------+
//| On-Chart Status Panel (OBJ_LABEL — 左下配置)                       |
//+------------------------------------------------------------------+
#define PANEL_PREFIX  "GbfEA_SP_"
#define PANEL_FONT    "Consolas"
#define PANEL_FSIZE   9
#define PANEL_CLR     clrWhite
#define PANEL_CLR_DIM clrDarkGray
#define PANEL_LINE_H  16

void PanelSetLine(int row, const string text, color clr = PANEL_CLR)
{
   string name = PANEL_PREFIX + IntegerToString(row);

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetString(0, name, OBJPROP_FONT, PANEL_FONT);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, PANEL_FSIZE);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 14);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20 + row * PANEL_LINE_H);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void PanelDeleteAll()
{
   int total = ObjectsTotal(0, -1, OBJ_LABEL);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, OBJ_LABEL);
      if(StringFind(name, PANEL_PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

void UpdateChartStatusPanel()
{
   if(!EnableStatusPanel) return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   int r = 0;

   PanelSetLine(r++, "Server : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), PANEL_CLR_DIM);

   // Cooldown
   if(g_currentState == STATE_COOLDOWN)
   {
      PanelSetLine(r++, "Cooldown : " + IntegerToString(g_cooldownBars) +
                        " / " + IntegerToString(g_cooldownDuration));
   }

   // Position
   if(g_currentState == STATE_IN_POSITION && g_ticket > 0)
   {
      if(PositionSelectByTicket(g_ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         color plClr = (profit >= 0) ? clrLime : clrOrangeRed;
         PanelSetLine(r++, "P/L      : " + DoubleToString(profit, 2), plClr);
      }
      PanelSetLine(r++, "Bars(Pos): " + IntegerToString(g_positionBars) +
                        " / " + IntegerToString(g_profile.timeExitBars));
      PanelSetLine(r++, "SL       : " + DoubleToString(g_sl, digits));
      PanelSetLine(r++, "Entry    : " + DoubleToString(g_entryPrice, digits));
      PanelSetLine(r++, "Ticket   : " + IntegerToString(g_ticket));
   }

   // MA Bounce info
   if(g_currentState >= STATE_MA_PULLBACK_WAIT && g_currentState <= STATE_IN_POSITION)
   {
      PanelSetLine(r++, "Bars(Frz): " + IntegerToString(g_barsAfterFreeze) +
                        " / " + IntegerToString(g_profile.retouchTimeLimitBars), PANEL_CLR_DIM);
      PanelSetLine(r++, "MA(" + IntegerToString(MABounce_Period) + ")  : " +
                        DoubleToString(g_maBounceMAValue, digits));
      PanelSetLine(r++, "MA Band  : " +
                        DoubleToString(g_maBounceMAValue - g_maBounceBandWidth, digits) +
                        " - " +
                        DoubleToString(g_maBounceMAValue + g_maBounceBandWidth, digits));
      PanelSetLine(r++, "Fib 61.8 : " + DoubleToString(g_fib618, digits));
      PanelSetLine(r++, "Fib 50   : " + DoubleToString(g_fib500, digits));
   }

   // Impulse info
   if(g_currentState >= STATE_IMPULSE_FOUND && g_currentState <= STATE_IN_POSITION)
   {
      PanelSetLine(r++, "UUID     : " + g_tradeUUID, PANEL_CLR_DIM);
      if(g_frozen)
         PanelSetLine(r++, "Frozen   : YES (" + DoubleToString(g_frozen100, digits) + ")", clrAqua);
      else
         PanelSetLine(r++, "Frozen   : NO");
      PanelSetLine(r++, "End(100) : " + DoubleToString(g_impulseEnd, digits));
      PanelSetLine(r++, "Start(0) : " + DoubleToString(g_impulseStart, digits));

      color dirClr = (g_impulseDir == DIR_LONG) ? clrDodgerBlue : clrOrangeRed;
      PanelSetLine(r++, "Direction: " + DirectionToString(g_impulseDir), dirClr);
   }

   PanelSetLine(r++, "-------------------", PANEL_CLR_DIM);

   PanelSetLine(r++, "Spread   : " + DoubleToString(spread, 1) + " pts");
   PanelSetLine(r++, "Ask      : " + DoubleToString(ask, digits));
   PanelSetLine(r++, "Bid      : " + DoubleToString(bid, digits));

   PanelSetLine(r++, "-------------------", PANEL_CLR_DIM);

   PanelSetLine(r++, "Trading  : " + (EnableTrading ? "ON" : "OFF"),
                EnableTrading ? clrLime : clrOrangeRed);

   color stateClr = PANEL_CLR;
   if(g_currentState == STATE_IN_POSITION) stateClr = clrLime;
   else if(g_currentState >= STATE_MA_PULLBACK_WAIT) stateClr = clrYellow;
   else if(g_currentState >= STATE_IMPULSE_FOUND) stateClr = clrAqua;
   PanelSetLine(r++, "State    : " + StateToString(g_currentState), stateClr);

   PanelSetLine(r++, EA_NAME + "  " + Symbol(), clrGold);

   g_panelMaxRow = MathMax(g_panelMaxRow, r);
   for(int i = r; i < g_panelMaxRow; i++)
   {
      string name = PANEL_PREFIX + IntegerToString(i);
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }
   g_panelMaxRow = r;
}

void ClearChartStatusPanel()
{
   PanelDeleteAll();
}

#endif // __VISUALIZATION_MQH__
