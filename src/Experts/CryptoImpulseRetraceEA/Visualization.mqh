//+------------------------------------------------------------------+
//| Visualization.mqh                                                 |
//| Fib描画・押し帯描画・チャート上STATUS表示パネル                          |
//| CRYPTO専用                                                         |
//+------------------------------------------------------------------+
#ifndef __VISUALIZATION_MQH__
#define __VISUALIZATION_MQH__

//+------------------------------------------------------------------+
//| Fib Visualization                                                 |
//+------------------------------------------------------------------+
string BuildFibObjName(const string trade_uuid)
{
   return "EA_FIB_" + trade_uuid;
}

string BuildBandObjName(const string trade_uuid)
{
   return "EA_BAND_" + trade_uuid;
}

void PurgeOldFibObjectsExcept(const string keepFibName, const string keepBandName)
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(name == "") continue;

      bool isFib  = (StringFind(name, "EA_FIB_")  == 0);
      bool isBand = (StringFind(name, "EA_BAND_") == 0);
      if(!isFib && !isBand) continue;

      if(name == keepFibName || name == keepBandName) continue;

      ObjectDelete(0, name);
   }
}

color GetBandColor()
{
   // CRYPTO: Purple系
   return (color)ColorToARGB(clrMediumPurple, 150);
}

void CreateFibVisualization()
{
   if(!EnableFibVisualization) return;
   if(g_tradeUUID == "") return;

   string fibName = BuildFibObjName(g_tradeUUID);
   string bandName = BuildBandObjName(g_tradeUUID);

   g_fibObjName = fibName;
   g_bandObjName = bandName;

   PurgeOldFibObjectsExcept(fibName, bandName);

   if(ObjectFind(0, fibName) < 0)
   {
      datetime t1 = iTime(Symbol(), PERIOD_M1, g_impulseBarIndex);
      datetime t2 = g_freezeBarTime;
      if(t1 <= 0) t1 = iTime(Symbol(), PERIOD_M1, 0);
      if(t1 <= 0) t1 = TimeCurrent();
      if(t2 <= 0) t2 = iTime(Symbol(), PERIOD_M1, 0);
      if(t2 <= 0) t2 = TimeCurrent();
      if(t2 < t1) t2 = t1 + PeriodSeconds(PERIOD_M1);

      if(!ObjectCreate(0, fibName, OBJ_FIBO, 0, t1, g_impulseStart, t2, g_impulseEnd))
      {
         Print("[VIS] Fib create failed: ", GetLastError());
      }
      else
      {
         ObjectSetInteger(0, fibName, OBJPROP_RAY_RIGHT, true);
         ObjectSetInteger(0, fibName, OBJPROP_SELECTABLE, true);
         ObjectSetInteger(0, fibName, OBJPROP_HIDDEN, false);

         ObjectSetInteger(0, fibName, OBJPROP_LEVELS, 6);

         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 0, 0.0);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 1, 0.382);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 2, 0.5);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 3, 0.618);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 4, 0.786);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 5, 1.0);

         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 0, "0");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 1, "38.2");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 2, "50");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 3, "61.8");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 4, "78.6");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 5, "100");
      }
   }

   // CRYPTO: Band = PrimaryBand (50-61.8 always)
   if(ObjectFind(0, bandName) < 0)
   {
      double bandUpper = g_primaryBandUpper;
      double bandLower = g_primaryBandLower;

      if(bandUpper > 0 && bandLower > 0)
      {
         datetime t1 = g_freezeBarTime;
         if(t1 <= 0) t1 = iTime(Symbol(), PERIOD_M1, 0);
         if(t1 <= 0) t1 = TimeCurrent();

         int futureBars = g_profile.retouchTimeLimitBars + 50;
         if(futureBars < 200) futureBars = 200;
         if(futureBars > 2000) futureBars = 2000;
         datetime t2 = t1 + (datetime)(PeriodSeconds(PERIOD_M1) * futureBars);
         if(t2 <= t1) t2 = t1 + 60 * 60 * 4;

         if(!ObjectCreate(0, bandName, OBJ_RECTANGLE, 0, t1, bandUpper, t2, bandLower))
         {
            Print("[VIS] Band create failed: ", GetLastError());
         }
         else
         {
            ObjectSetInteger(0, bandName, OBJPROP_BACK, true);
            ObjectSetInteger(0, bandName, OBJPROP_FILL, true);
            ObjectSetInteger(0, bandName, OBJPROP_SELECTABLE, true);
            ObjectSetInteger(0, bandName, OBJPROP_HIDDEN, false);
            ObjectSetInteger(0, bandName, OBJPROP_COLOR, GetBandColor());
         }
      }
   }
}

void DeleteFibVisualizationForUUID(const string trade_uuid)
{
   if(trade_uuid == "") return;

   string fibName  = BuildFibObjName(trade_uuid);
   string bandName = BuildBandObjName(trade_uuid);

   if(ObjectFind(0, fibName) >= 0)  ObjectDelete(0, fibName);
   if(ObjectFind(0, bandName) >= 0) ObjectDelete(0, bandName);

   if(g_tradeUUID == trade_uuid)
   {
      g_fibObjName  = "";
      g_bandObjName = "";
   }
}

void DeleteCurrentFibVisualization()
{
   DeleteFibVisualizationForUUID(g_tradeUUID);
}

//+------------------------------------------------------------------+
//| On-Chart Status Panel (OBJ_LABEL — 左下配置)                       |
//+------------------------------------------------------------------+
#define PANEL_PREFIX  "CirEA_SP_"
#define PANEL_FONT    "Consolas"
#define PANEL_FSIZE   9
#define PANEL_CLR     clrWhite
#define PANEL_CLR_DIM clrDarkGray
#define PANEL_LINE_H  14        // 行あたりピクセル高

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

   // row 0 = 最下行。Y が大きいほど上に上がる
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

   // 行を下から積み上げる（row=0 が最下段）
   int r = 0;

   // --- 最下段: Server Time ---
   PanelSetLine(r++, "Server : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), PANEL_CLR_DIM);

   // --- Cooldown ---
   if(g_currentState == STATE_COOLDOWN)
   {
      PanelSetLine(r++, "Cooldown : " + IntegerToString(g_cooldownBars) +
                        " / " + IntegerToString(g_cooldownDuration));
   }

   // --- Position ---
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

   // --- Confirm wait ---
   if(g_currentState == STATE_TOUCH_2_WAIT_CONFIRM)
   {
      PanelSetLine(r++, "Confirm  : WAITING (" + IntegerToString(g_confirmWaitBars) +
                        "/" + IntegerToString(g_profile.confirmTimeLimitBars) + ")", clrYellow);
   }

   // --- Band info ---
   if(g_currentState >= STATE_FIB_ACTIVE && g_currentState <= STATE_IN_POSITION)
   {
      PanelSetLine(r++, "Bars(Frz): " + IntegerToString(g_barsAfterFreeze) +
                        " / " + IntegerToString(g_profile.retouchTimeLimitBars), PANEL_CLR_DIM);
      PanelSetLine(r++, "Touch    : " + IntegerToString(g_touchCount_Primary));
      PanelSetLine(r++, "Band     : " + DoubleToString(g_primaryBandLower, digits) +
                        " - " + DoubleToString(g_primaryBandUpper, digits));
      PanelSetLine(r++, "Fib 61.8 : " + DoubleToString(g_fib618, digits));
      PanelSetLine(r++, "Fib 50   : " + DoubleToString(g_fib500, digits));
   }

   // --- Impulse info ---
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

   // --- separator ---
   PanelSetLine(r++, "-------------------", PANEL_CLR_DIM);

   // --- Price ---
   PanelSetLine(r++, "Spread   : " + DoubleToString(spread, 1) + " pts");
   PanelSetLine(r++, "Ask      : " + DoubleToString(ask, digits));
   PanelSetLine(r++, "Bid      : " + DoubleToString(bid, digits));

   // --- separator ---
   PanelSetLine(r++, "-------------------", PANEL_CLR_DIM);

   // --- Header ---
   PanelSetLine(r++, "Trading  : " + (EnableTrading ? "ON" : "OFF"),
                EnableTrading ? clrLime : clrOrangeRed);
   PanelSetLine(r++, "Flat     : " + FlatFilterModeToString(FlatFilterMode));

   color stateClr = PANEL_CLR;
   if(g_currentState == STATE_IN_POSITION) stateClr = clrLime;
   else if(g_currentState >= STATE_FIB_ACTIVE) stateClr = clrYellow;
   else if(g_currentState >= STATE_IMPULSE_FOUND) stateClr = clrAqua;
   PanelSetLine(r++, "State    : " + StateToString(g_currentState), stateClr);

   PanelSetLine(r++, EA_NAME + " " + EA_VERSION + "  " + Symbol(), clrGold);

   // 前回より行数が減った場合の残骸を消す
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
